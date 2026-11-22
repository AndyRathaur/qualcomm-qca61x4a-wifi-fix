<#
.SYNOPSIS
    Fast-healing autonomous recovery engine for Qualcomm QCA61x4A / DW1820 Wi-Fi transceiver lockups.

.DESCRIPTION
    Safely resets the Wi-Fi adapter when triggered by an Event 8002/8003 watchdog or periodic Heartbeat.
    Includes rate-limiting (throttling to max 1 reset per 60s), two-strike pre-flight ping checks (for heartbeat),
    fast native Win32/NDIS adapter cycling (250ms settle), in-memory Win32 Native Wifi API (wlanapi.dll)
    state polling (<1ms latency), dynamic profile auto-detection preserving whitespace, and fast reconnection.

.PARAMETER Trigger
    Identifies the trigger source (e.g. '8002', '8003', 'Heartbeat', 'Manual').

.PARAMETER Force
    Bypasses rate limiting and pre-flight connectivity checks.

.PARAMETER ProfileName
    Optional SSID/Profile name to connect to. If omitted, automatically detects the first saved profile.

.PARAMETER InterfaceName
    Optional network interface name. Defaults to 'Wi-Fi'.
#>

[CmdletBinding()]
param(
    [string]$Trigger = "Manual",
    [switch]$Force,
    [string]$ProfileName,
    [string]$InterfaceName = "Wi-Fi"
)

$ErrorActionPreference = 'SilentlyContinue'

# Normalize empty or default trigger from scheduled tasks
if ([string]::IsNullOrWhiteSpace($Trigger)) {
    $Trigger = "Heartbeat"
}

# Resolve directory dynamically
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$logPath      = Join-Path $scriptDir "wifi_recovery.log"
$throttleFile = Join-Path $scriptDir ".wifi_recovery_throttle"
$throttleSecs = 60

# Resolve interface name dynamically if not specified or empty
if ([string]::IsNullOrWhiteSpace($InterfaceName)) {
    $wlanAdapter = Get-NetAdapter | Where-Object { 
        $_.InterfaceDescription -match "Qualcomm|QCA61x4A|168C|Wireless|Wi-Fi|802\.11" -or 
        $_.MediaType -match "Native 802\.11|Wireless" 
    } | Select-Object -First 1

    $InterfaceName = if ($wlanAdapter) { $wlanAdapter.Name } else { "Wi-Fi" }
}

# -------------------------------------------------------------------------
# Define Native Win32 Wifi API (wlanapi.dll) Type for Sub-millisecond Polling
# -------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'NativeWlan').Type) {
    $nativeWlanSource = @'
using System;
using System.Runtime.InteropServices;

public class NativeWlan {
    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanOpenHandle(
        uint dwClientVersion,
        IntPtr pReserved,
        out uint pdwNegotiatedVersion,
        out IntPtr phClientHandle
    );

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanCloseHandle(
        IntPtr hClientHandle,
        IntPtr pReserved
    );

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanEnumInterfaces(
        IntPtr hClientHandle,
        IntPtr pReserved,
        out IntPtr ppInterfaceList
    );

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanQueryInterface(
        IntPtr hClientHandle,
        [In] ref Guid pInterfaceGuid,
        int OpCode,
        IntPtr pReserved,
        out uint pdwDataSize,
        out IntPtr ppData,
        IntPtr pWlanOpcodeValueType
    );

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern void WlanFreeMemory(IntPtr pMemory);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_CONNECTION_PARAMETERS {
        public int wlanConnectionMode; // 0 = profile
        [MarshalAs(UnmanagedType.LPWStr)]
        public string strProfile;
        public IntPtr pDot11Ssid;
        public IntPtr pDesiredBssidList;
        public int dot11BssType; // 1 = infrastructure
        public uint dwFlags;
    }

    [DllImport("wlanapi.dll", SetLastError = true)]
    public static extern uint WlanConnect(
        IntPtr hClientHandle,
        [In] ref Guid pInterfaceGuid,
        [In] ref WLAN_CONNECTION_PARAMETERS pConnectionParameters,
        IntPtr pReserved
    );

    public enum WLAN_INTERFACE_STATE {
        not_ready = 0,
        connected = 1,
        ad_hoc_network_formed = 2,
        disconnecting = 3,
        disconnected = 4,
        associating = 5,
        discovering = 6,
        authenticating = 7
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WLAN_INTERFACE_INFO {
        public Guid InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strInterfaceDescription;
        public WLAN_INTERFACE_STATE isState;
    }

    private static IntPtr _cachedHandle = IntPtr.Zero;
    private static Guid _cachedGuid = Guid.Empty;
    private static readonly object _lock = new object();

    public static void Reset() {
        lock (_lock) {
            if (_cachedHandle != IntPtr.Zero) {
                try { WlanCloseHandle(_cachedHandle, IntPtr.Zero); } catch {}
                _cachedHandle = IntPtr.Zero;
            }
            _cachedGuid = Guid.Empty;
        }
    }

    public static string GetInterfaceState(string descriptionFilter = null) {
        lock (_lock) {
            if (_cachedHandle == IntPtr.Zero) {
                uint negVer;
                if (WlanOpenHandle(2, IntPtr.Zero, out negVer, out _cachedHandle) != 0) {
                    _cachedHandle = IntPtr.Zero;
                    return "not_ready";
                }
            }

            if (_cachedGuid != Guid.Empty && string.IsNullOrEmpty(descriptionFilter)) {
                uint dataSize;
                IntPtr pData;
                uint res = WlanQueryInterface(_cachedHandle, ref _cachedGuid, 6, IntPtr.Zero, out dataSize, out pData, IntPtr.Zero);
                if (res == 0 && pData != IntPtr.Zero) {
                    try {
                        int stateVal = Marshal.ReadInt32(pData);
                        return ((WLAN_INTERFACE_STATE)stateVal).ToString();
                    } finally {
                        WlanFreeMemory(pData);
                    }
                }
                _cachedGuid = Guid.Empty;
            }

            IntPtr pList = IntPtr.Zero;
            try {
                uint enumRes = WlanEnumInterfaces(_cachedHandle, IntPtr.Zero, out pList);
                if (enumRes != 0 || pList == IntPtr.Zero) {
                    try { WlanCloseHandle(_cachedHandle, IntPtr.Zero); } catch {}
                    _cachedHandle = IntPtr.Zero;
                    uint negVer;
                    if (WlanOpenHandle(2, IntPtr.Zero, out negVer, out _cachedHandle) == 0) {
                        enumRes = WlanEnumInterfaces(_cachedHandle, IntPtr.Zero, out pList);
                    }
                    if (enumRes != 0 || pList == IntPtr.Zero) return "not_ready";
                }

                int count = Marshal.ReadInt32(pList, 0);
                if (count == 0) return "not_ready";

                int itemSize = Marshal.SizeOf(typeof(WLAN_INTERFACE_INFO));
                for (int i = 0; i < count; i++) {
                    IntPtr pItem = new IntPtr(pList.ToInt64() + 8 + (i * itemSize));
                    WLAN_INTERFACE_INFO info = (WLAN_INTERFACE_INFO)Marshal.PtrToStructure(pItem, typeof(WLAN_INTERFACE_INFO));
                    if (string.IsNullOrEmpty(descriptionFilter) || 
                        info.strInterfaceDescription.IndexOf(descriptionFilter, StringComparison.OrdinalIgnoreCase) >= 0) {
                        _cachedGuid = info.InterfaceGuid;
                        return info.isState.ToString();
                    }
                }

                IntPtr pFirst = new IntPtr(pList.ToInt64() + 8);
                WLAN_INTERFACE_INFO firstInfo = (WLAN_INTERFACE_INFO)Marshal.PtrToStructure(pFirst, typeof(WLAN_INTERFACE_INFO));
                _cachedGuid = firstInfo.InterfaceGuid;
                return firstInfo.isState.ToString();
            } catch {
                return "unknown";
            } finally {
                if (pList != IntPtr.Zero) WlanFreeMemory(pList);
            }
        }
    }

    public static uint Connect(string profileName) {
        lock (_lock) {
            if (_cachedHandle == IntPtr.Zero) {
                uint negVer;
                if (WlanOpenHandle(2, IntPtr.Zero, out negVer, out _cachedHandle) != 0) {
                    _cachedHandle = IntPtr.Zero;
                    return 999;
                }
            }

            if (_cachedGuid == Guid.Empty) {
                GetInterfaceState();
            }

            if (_cachedGuid == Guid.Empty) return 998;

            WLAN_CONNECTION_PARAMETERS p = new WLAN_CONNECTION_PARAMETERS();
            p.wlanConnectionMode = 0; // profile
            p.strProfile = profileName;
            p.dot11BssType = 1; // infrastructure
            p.dwFlags = 0;

            return WlanConnect(_cachedHandle, ref _cachedGuid, ref p, IntPtr.Zero);
        }
    }
}
'@
    Add-Type -TypeDefinition $nativeWlanSource -Language CSharp
}

function Write-RecoveryLog {
    param([string]$Level, [string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] [Trigger: $Trigger] $Message"
    Write-Output $line
    try {
        Add-Content -Path $logPath -Value $line -Encoding utf8
    } catch {}
}

# -------------------------------------------------------------------------
# 1. Throttling / Rate-Limiting Guard
# -------------------------------------------------------------------------
if (-not $Force -and (Test-Path $throttleFile)) {
    try {
        $lastTimestampStr = (Get-Content -Path $throttleFile -Raw).Trim()
        $lastTime = [DateTime]::Parse($lastTimestampStr).ToUniversalTime()
        $now = [DateTime]::UtcNow
        $elapsed = ($now - $lastTime).TotalSeconds

        if ($elapsed -lt $throttleSecs) {
            Write-RecoveryLog "THROTTLED" ("Recovery requested but last reset was only {0:N0}s ago (< {1}s threshold). Skipping to avoid reset loops." -f $elapsed, $throttleSecs)
            exit 0
        }
    } catch {
        # If parsing fails, continue with recovery
    }
}

# -------------------------------------------------------------------------
# 2. Pre-flight Check: Only skip ping on confirmed crash events (8002, 8003) or -Force
# -------------------------------------------------------------------------
$isConfirmedCrash = ($Trigger -eq "8002" -or $Trigger -eq "8003")

if (-not $Force -and -not $isConfirmedCrash) {
    $adapter = Get-NetAdapter -Name $InterfaceName -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Status -eq "Up") {
        # Two-strike .NET ping check to verify if internet is already reachable (eliminates false positives)
        $pingOk = $false
        try {
            $p = New-Object System.Net.NetworkInformation.Ping
            foreach ($target in @("8.8.8.8", "1.1.1.1")) {
                try {
                    $reply = $p.Send($target, 1000)
                    if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $pingOk = $true
                        break
                    }
                } catch {}
            }
        } catch {}

        if ($pingOk) {
            # Internet is working normally, no reset needed
            exit 0
        }
    }
}

# -------------------------------------------------------------------------
# Dynamic Wi-Fi Profile Detection (preserving trailing whitespace)
# -------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ProfileName)) {
    $profilesOut = & netsh wlan show profiles interface="$InterfaceName" 2>$null
    if (-not $profilesOut) {
        $profilesOut = & netsh wlan show profiles 2>$null
    }
    foreach ($line in $profilesOut) {
        if ($line -match '^\s*All User Profile\s*:\s*(.+)$') {
            $candidate = $matches[1]
            if ($candidate -and $candidate.Trim() -ne "<None>") {
                $ProfileName = $candidate
                break
            }
        }
    }
}

# Update throttle timestamp immediately before starting recovery
try {
    [DateTime]::UtcNow.ToString("o") | Out-File -FilePath $throttleFile -Encoding utf8 -Force
} catch {}

# Start precise stopwatch timing for total recovery duration
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-RecoveryLog "RECOVERING" "Initiating transceiver hardware reset cycle on '$InterfaceName'..."

# -------------------------------------------------------------------------
# 3. Fast Transceiver Hardware Cycle (Disable -> Settle -> Enable)
# -------------------------------------------------------------------------
[NativeWlan]::Reset()
try {
    # Fast netsh hardware cycle with NetAdapter fallback
    & netsh interface set interface name="$InterfaceName" admin=DISABLED
    if ($LASTEXITCODE -ne 0) {
        Disable-NetAdapter -Name "$InterfaceName" -Confirm:$false -ErrorAction Stop
    }
} catch {
    Disable-NetAdapter -Name "$InterfaceName" -Confirm:$false -ErrorAction SilentlyContinue
}

# 250ms hardware settle time (optimized from 500ms for faster recovery)
Start-Sleep -Milliseconds 250

try {
    # Fast netsh hardware cycle with NetAdapter fallback
    & netsh interface set interface name="$InterfaceName" admin=ENABLED
    if ($LASTEXITCODE -ne 0) {
        Enable-NetAdapter -Name "$InterfaceName" -Confirm:$false -ErrorAction Stop
    }
} catch {
    Enable-NetAdapter -Name "$InterfaceName" -Confirm:$false -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------------------
# 4. Reactive Radio Readiness Polling (50ms polling, max 2.0s via Native Wifi API)
# -------------------------------------------------------------------------
for ($i = 0; $i -lt 40; $i++) {
    $state = [NativeWlan]::GetInterfaceState()
    if ($state -ne "not_ready" -and $state -ne "unknown" -and $state -ne "none") {
        break
    }
    Start-Sleep -Milliseconds 50
}

# -------------------------------------------------------------------------
# 5. Fast Reconnection to Target Profile (In-Memory Polling, No Bogus Fallback)
# -------------------------------------------------------------------------
$connected = $false

if ($ProfileName) {
    # Issue fast asynchronous connection request via Win32 Native Wifi API
    $connectRes = [NativeWlan]::Connect($ProfileName)
    if ($connectRes -ne 0) {
        & netsh wlan connect name="$ProfileName" interface="$InterfaceName" 2>$null | Out-Null
    }

    # Reactive polling loop via in-memory Win32 Native Wifi API (every 50ms, max 4.0s)
    for ($i = 0; $i -lt 80; $i++) {
        $state = [NativeWlan]::GetInterfaceState()
        if ($state -eq "connected") {
            $connected = $true
            break
        }
        Start-Sleep -Milliseconds 50
    }

    # If still actively completing association/authentication at 4.0s, allow grace period
    if (-not $connected) {
        for ($i = 0; $i -lt 40; $i++) {
            $state = [NativeWlan]::GetInterfaceState()
            if ($state -eq "connected") {
                $connected = $true
                break
            }
            if ($state -ne "associating" -and $state -ne "authenticating") {
                break
            }
            Start-Sleep -Milliseconds 50
        }
    }
} else {
    # No profile saved; wait for Windows AutoConfig association
    for ($i = 0; $i -lt 80; $i++) {
        $state = [NativeWlan]::GetInterfaceState()
        if ($state -eq "connected") {
            $connected = $true
            break
        }
        Start-Sleep -Milliseconds 50
    }
}

# -------------------------------------------------------------------------
# 6. Verification & Final Status Logging with Elapsed Milliseconds
# -------------------------------------------------------------------------
$sw.Stop()
$elapsedMs = $sw.ElapsedMilliseconds
$elapsedSec = [math]::Round($elapsedMs / 1000.0, 2)

$finalStatus = & netsh wlan show interfaces
$stateMatch  = [NativeWlan]::GetInterfaceState()
$ssidLine    = $finalStatus | Select-String -Pattern '^\s*SSID\s*:\s*(.+)$'
$ssidMatch   = if ($ssidLine) { $ssidLine.Matches.Groups[1].Value.Trim() } else { "Unknown" }
$signalLine  = $finalStatus | Select-String -Pattern '^\s*Signal\s*:\s*(\d+%)'
$signalMatch = if ($signalLine) { $signalLine.Matches.Groups[1].Value } else { "Unknown" }

if ($stateMatch -eq "connected") {
    Write-RecoveryLog "SUCCESS" ("Recovery successful in {0}ms ({1}s)! State: {2}, SSID: '{3}', Signal: {4}." -f $elapsedMs, $elapsedSec, $stateMatch, $ssidMatch, $signalMatch)
} else {
    Write-RecoveryLog "WARNING" ("Transceiver reset completed in {0}ms ({1}s), but adapter state is currently: {2}." -f $elapsedMs, $elapsedSec, $stateMatch)
}

# Maintain log file size (keep latest 500 lines)
try {
    if (Test-Path $logPath) {
        $lines = Get-Content -Path $logPath
        if ($lines.Count -gt 500) {
            $lines | Select-Object -Last 500 | Set-Content -Path $logPath -Encoding utf8
        }
    }
} catch {}
