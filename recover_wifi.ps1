<#
.SYNOPSIS
    Fast-healing autonomous recovery engine for Qualcomm QCA61x4A / DW1820 Wi-Fi transceiver lockups.

.DESCRIPTION
    Safely resets the Wi-Fi adapter when triggered by an Event 8002/8003 watchdog or periodic Heartbeat.
    Includes rate-limiting (throttling to max 1 reset per 60s), pre-flight ping checks (for heartbeat),
    fast native Win32/netsh adapter cycling (500ms settle), reactive radio readiness polling, dynamic
    profile auto-detection, and reactive reconnection.

.PARAMETER Trigger
    Identifies the trigger source (e.g. '8002', '8003', 'Heartbeat', 'Manual').

.PARAMETER Force
    Bypasses rate limiting and pre-flight connectivity checks.

.PARAMETER ProfileName
    Optional SSID/Profile name to connect to. If omitted, automatically detects the first saved profile.

.PARAMETER InterfaceName
    Optional network interface name. If omitted, automatically detects the wireless adapter or defaults to 'Wi-Fi'.
#>

[CmdletBinding()]
param(
    [string]$Trigger = "Manual",
    [switch]$Force,
    [string]$ProfileName,
    [string]$InterfaceName
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

# Resolve interface name dynamically if not specified
if ([string]::IsNullOrWhiteSpace($InterfaceName)) {
    $wlanAdapter = Get-NetAdapter | Where-Object { 
        $_.InterfaceDescription -match "Qualcomm|QCA61x4A|168C|Wireless|Wi-Fi|802\.11" -or 
        $_.MediaType -match "Native 802\.11|Wireless" 
    } | Select-Object -First 1

    $InterfaceName = if ($wlanAdapter) { $wlanAdapter.Name } else { "Wi-Fi" }
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
        # Quick .NET ping to verify if internet is already reachable
        $pingOk = $false
        try {
            $p = New-Object System.Net.NetworkInformation.Ping
            $reply = $p.Send("8.8.8.8", 800)
            if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $pingOk = $true
            }
        } catch {}

        if ($pingOk) {
            # Internet is working normally, no reset needed
            exit 0
        }
    }
}

# -------------------------------------------------------------------------
# Dynamic Wi-Fi Profile Detection (if not explicitly passed)
# -------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ProfileName)) {
    $profilesOut = & netsh wlan show profiles interface="$InterfaceName" 2>$null
    if (-not $profilesOut) {
        $profilesOut = & netsh wlan show profiles 2>$null
    }
    foreach ($line in $profilesOut) {
        if ($line -match 'All User Profile\s*:\s*(.+)$') {
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
try {
    # Fast native Win32/NDIS disable
    & netsh interface set interface name="$InterfaceName" admin=DISABLED
    if ($LASTEXITCODE -ne 0) {
        Disable-NetAdapter -Name "$InterfaceName" -Confirm:$false -ErrorAction Stop
    }
} catch {
    Write-RecoveryLog "WARNING" "Netsh disable failed, fell back to Disable-NetAdapter: $_"
}

# 500ms hardware settle time
Start-Sleep -Milliseconds 500

try {
    # Fast native Win32/NDIS enable
    & netsh interface set interface name="$InterfaceName" admin=ENABLED
    if ($LASTEXITCODE -ne 0) {
        Enable-NetAdapter -Name "$InterfaceName" -Confirm:$false -ErrorAction Stop
    }
} catch {
    Write-RecoveryLog "WARNING" "Netsh enable failed, fell back to Enable-NetAdapter: $_"
}

# -------------------------------------------------------------------------
# 4. Reactive Radio Readiness (100ms polling, max 1.5s)
# -------------------------------------------------------------------------
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Milliseconds 100
    $ifOut = & netsh wlan show interfaces
    if ($ifOut -match "State\s*:\s*(disconnected|connected|associating)") {
        break
    }
}

# -------------------------------------------------------------------------
# 5. Fast Reconnection to Detected/Specified Profile
# -------------------------------------------------------------------------
$connected = $false

if ($ProfileName) {
    # Attempt connection to target profile
    & netsh wlan connect name="$ProfileName" interface="$InterfaceName" 2>$null | Out-Null

    # Reactive polling loop (max 3.5s)
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Milliseconds 150
        $ifStatus = & netsh wlan show interfaces
        if ($ifStatus -match "State\s*:\s*connected") {
            $connected = $true
            break
        }
    }

    # Fallback attempt with trimmed profile name if string differed
    if (-not $connected -and $ProfileName.Trim() -ne $ProfileName) {
        & netsh wlan connect name="$($ProfileName.Trim())" interface="$InterfaceName" 2>$null | Out-Null
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Milliseconds 150
            $ifStatus = & netsh wlan show interfaces
            if ($ifStatus -match "State\s*:\s*connected") {
                $connected = $true
                break
            }
        }
    }
} else {
    # No profile saved; wait for Windows AutoConfig association
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        $ifStatus = & netsh wlan show interfaces
        if ($ifStatus -match "State\s*:\s*connected") {
            $connected = $true
            break
        }
    }
}

# -------------------------------------------------------------------------
# 6. Verification & Final Status Logging with Elapsed Milliseconds
# -------------------------------------------------------------------------
$sw.Stop()
$elapsedMs = $sw.ElapsedMilliseconds
$elapsedSec = [math]::Round($elapsedMs / 1000.0, 2)

$finalStatus = & netsh wlan show interfaces
$stateMatch  = ($finalStatus | Select-String -Pattern "State\s*:\s*(\w+)").Matches.Groups[1].Value
$ssidMatch   = ($finalStatus | Select-String -Pattern "SSID\s*:\s*(.+)").Matches.Groups[1].Value.Trim()
$signalMatch = ($finalStatus | Select-String -Pattern "Signal\s*:\s*(\d+%)").Matches.Groups[1].Value

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
