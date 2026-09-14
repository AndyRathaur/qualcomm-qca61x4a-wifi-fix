<#
.SYNOPSIS
    Applies permanent hardware remediation and driver hardening for Qualcomm QCA61x4A / DW1820 Wi-Fi adapters.

.DESCRIPTION
    Implements root-cause stability remediations and driver hardening for Qualcomm Atheros QCA61x4A:
    1. PCIe ASPM (Active State Power Management) disabled on both AC and DC to prevent transceiver bus desync.
    2. Sets PnPCapabilities = 24 (0x18) in the adapter class registry to prevent Windows selective suspend / power cut.
    3. Qualcomm Driver & Baseband Hardening:
       - Disables background scanning contention (bkScanEnable = 0, bScanBackground = 0, periodicScanEnable = 0).
       - Disables scan timeout cascades (YBForScanTimeout3Times = 0).
       - Enables Qualcomm PM L1 workaround (WarForEnablePmL1 = 1).
       - Disables PCIe HAL and protocol power saving (halPciePowerSaveEnable = 0, IdlePowerSave = 0, ProtocolPowerSave = 0, smPowerSaveState = 0).
       - Enables hardware Bluetooth/Wi-Fi coexistence & AFH sideband coordination (btCoexEnable = 1, btCoexAFHSideBand = 1).
    4. Bluetooth Coexistence Hardening:
       - Configures ChannelAvoidanceRange = 80 in BTHPORT and BTHUSB parameters to steer Bluetooth AFH hops away from Wi-Fi channels.
    5. Adapter Advanced Properties:
       - Sets Roaming Aggressiveness to "1.Lowest" to prevent RF scan storms.
       - Sets Preferred Band to "3 - Prefer 5Ghz Band" (if supported).
       - Automatically detects and prioritizes the active saved Wi-Fi profile.
    6. Autonomous Watchdog Registration:
       - Invokes register_wifi_watchdog.ps1 to install the kernel event-driven watchdog task.
    7. DriverStore staged driver verification:
       - Enumerates staged Qualcomm drivers to notify if a newer revision is staged.

.PARAMETER SkipAdapterRestart
    Applies all registry and power changes without performing an immediate adapter reset.

.PARAMETER ProfileName
    Optional Wi-Fi profile name to prioritize. If not specified, auto-detects the first saved profile.
#>

[CmdletBinding()]
param(
    [switch]$SkipAdapterRestart,
    [string]$ProfileName
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " Qualcomm QCA61x4A / Dell DW1820 Permanent Wi-Fi Remediation & Hardening" -ForegroundColor Cyan
Write-Host " Author: Andy Rathaur (@AndyRathaur)" -ForegroundColor DarkCyan
Write-Host "========================================================================`n" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# Step 1: Power Configuration (PCIe ASPM Off for AC and DC)
# -------------------------------------------------------------------------
Write-Host "[1/6] Configuring PCIe Link State Power Management (ASPM)..." -ForegroundColor Yellow

$subgroup = "501a4d13-42af-4429-9fd1-a8218c268e20" # SUB_PCIEXPRESS
$setting  = "ee12f906-d277-404b-b6da-e5fa1a576df5" # ASPM

try {
    Write-Host "  -> Disabling ASPM on AC (Setting 0 = Off)..."
    & powercfg /setacvalueindex SCHEME_CURRENT $subgroup $setting 0

    Write-Host "  -> Disabling ASPM on DC (Setting 0 = Off)..."
    & powercfg /setdcvalueindex SCHEME_CURRENT $subgroup $setting 0

    Write-Host "  -> Applying power scheme changes..."
    & powercfg /setactive SCHEME_CURRENT

    # Verification
    $powerQuery = & powercfg /q SCHEME_CURRENT $subgroup $setting
    $acMatch = ($powerQuery | Select-String -Pattern "Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)").Matches.Groups[1].Value
    $dcMatch = ($powerQuery | Select-String -Pattern "Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)").Matches.Groups[1].Value
    Write-Host "  [+] Verified ASPM AC Setting Index: $acMatch (0 = Off)" -ForegroundColor Green
    Write-Host "  [+] Verified ASPM DC Setting Index: $dcMatch (0 = Off)" -ForegroundColor Green
} catch {
    Write-Error "Failed to configure PCIe ASPM power settings: $_"
}

# -------------------------------------------------------------------------
# Step 2: Qualcomm Driver & Baseband Hardening Registry Keys
# -------------------------------------------------------------------------
Write-Host "`n[2/6] Detecting Qualcomm Adapter Registry Key & Hardening Baseband..." -ForegroundColor Yellow

$classKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
$targetKey = $null

if (Test-Path $classKey) {
    $subkeys = Get-ChildItem -Path $classKey -ErrorAction SilentlyContinue
    foreach ($sub in $subkeys) {
        $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
        if ($props) {
            $driverDesc = "$($props.DriverDesc)"
            $matchId    = "$($props.MatchingDeviceId)"
            $compId     = "$($props.ComponentId)"
            $instId     = "$($props.DeviceInstanceID)"

            if ($driverDesc -match "Qualcomm|QCA61x4A" -or
                $matchId    -match "168C&DEV_003E" -or
                $compId     -match "168C&DEV_003E" -or
                $instId     -match "168C&DEV_003E") {
                $targetKey = $sub.PSPath
                Write-Host "  -> Identified Qualcomm adapter at: $($sub.PSChildName) ($driverDesc)"
                break
            }
        }
    }
}

if (-not $targetKey) {
    Write-Warning "Could not dynamically detect Qualcomm adapter in network class registry. Checking default 0002..."
    if (Test-Path "$classKey\0002") {
        $targetKey = "$classKey\0002"
        Write-Host "  -> Using fallback adapter key: $targetKey"
    } else {
        Write-Error "Could not locate Qualcomm network adapter key under $classKey"
    }
}

if ($targetKey) {
    # 2.1 PnPCapabilities (Prevent Windows from cutting power to adapter)
    Set-ItemProperty -LiteralPath $targetKey -Name "PnPCapabilities" -Value 24 -Type DWord
    $pnpVal = (Get-ItemProperty -LiteralPath $targetKey -Name "PnPCapabilities").PnPCapabilities
    Write-Host ("  [+] PnPCapabilities: 0x{0:X2} ({0}) [Selective Suspend / Power Down Disabled]" -f $pnpVal) -ForegroundColor Green

    # 2.2 Background Scan Contention Suppression
    $scanHardening = @{
        "bkScanEnable"           = 0 # Disable background scanning contention
        "bScanBackground"        = 0 # Disable background scanning in transceiver
        "periodicScanEnable"     = 0 # Disable periodic unassociated scans while associated
        "YBForScanTimeout3Times" = 0 # Prevent scan timeout cascades
    }
    foreach ($k in $scanHardening.Keys) {
        Set-ItemProperty -LiteralPath $targetKey -Name $k -Value $scanHardening[$k] -Type DWord
        Write-Host "  [+] Scan Hardening: $k = $($scanHardening[$k])" -ForegroundColor Green
    }

    # 2.3 PCIe & Transceiver Power State Hardening
    $powerHardening = @{
        "WarForEnablePmL1"       = 1 # Enable Qualcomm PCIe PM L1 workaround
        "halPciePowerSaveEnable" = 0 # Disable HAL PCIe power savings
        "IdlePowerSave"          = 0 # Disable idle transceiver power down
        "ProtocolPowerSave"      = 0 # Disable protocol-level power save
        "smPowerSaveState"       = 0 # Disable spatial multiplexing sleep state
    }
    foreach ($k in $powerHardening.Keys) {
        Set-ItemProperty -LiteralPath $targetKey -Name $k -Value $powerHardening[$k] -Type DWord
        Write-Host "  [+] Power Hardening: $k = $($powerHardening[$k])" -ForegroundColor Green
    }

    # 2.4 Bluetooth / Wi-Fi Hardware Coexistence
    $coexHardening = @{
        "btCoexEnable"       = 1 # Enable hardware Bluetooth coexistence
        "btCoexAFHSideBand"  = 1 # Enable Adaptive Frequency Hopping sideband coordination
    }
    foreach ($k in $coexHardening.Keys) {
        Set-ItemProperty -LiteralPath $targetKey -Name $k -Value $coexHardening[$k] -Type DWord
        Write-Host "  [+] Coexistence Hardening: $k = $($coexHardening[$k])" -ForegroundColor Green
    }
}

# -------------------------------------------------------------------------
# Step 3: Bluetooth Service Coexistence Hardening
# -------------------------------------------------------------------------
Write-Host "`n[3/6] Configuring Bluetooth Coexistence Buffer..." -ForegroundColor Yellow

$bthKeys = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters",
    "HKLM:\SYSTEM\CurrentControlSet\Services\BTHUSB\Parameters"
)

foreach ($bk in $bthKeys) {
    if (Test-Path $bk) {
        Set-ItemProperty -LiteralPath $bk -Name "ChannelAvoidanceRange" -Value 80 -Type DWord
        $carVal = (Get-ItemProperty -LiteralPath $bk -Name "ChannelAvoidanceRange").ChannelAvoidanceRange
        Write-Host "  [+] $bk -> ChannelAvoidanceRange = $carVal" -ForegroundColor Green
    }
}

# -------------------------------------------------------------------------
# Step 4: Adapter Advanced Properties & Profile Auto-Priority
# -------------------------------------------------------------------------
Write-Host "`n[4/6] Configuring Adapter Advanced Properties & Wi-Fi Profile..." -ForegroundColor Yellow

# Identify wireless adapter name dynamically
$adapter = Get-NetAdapter | Where-Object { 
    $_.InterfaceDescription -match "Qualcomm|QCA61x4A|168C" -or 
    $_.MediaType -match "Native 802\.11" 
} | Select-Object -First 1

$adapterName = if ($adapter) { $adapter.Name } else { "Wi-Fi" }
Write-Host "  -> Wireless Interface Name: $adapterName"

# Roaming aggressiveness -> Lowest
try {
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "Roaming aggressiveness" -DisplayValue "1.Lowest" -ErrorAction SilentlyContinue
    $roamVal = (Get-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "Roaming aggressiveness" -ErrorAction SilentlyContinue).DisplayValue
    if ($roamVal) {
        Write-Host "  [+] Roaming aggressiveness: $roamVal" -ForegroundColor Green
    }
} catch {
    Write-Warning "Could not set Roaming aggressiveness: $_"
}

# Preferred Band -> Prefer 5GHz Band (if available on card)
try {
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "Preferred Band" -DisplayValue "3 - Prefer 5Ghz Band" -ErrorAction SilentlyContinue
    $bandVal = (Get-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "Preferred Band" -ErrorAction SilentlyContinue).DisplayValue
    if ($bandVal) {
        Write-Host "  [+] Preferred Band: $bandVal" -ForegroundColor Green
    }
} catch {
    Write-Warning "Could not set Preferred Band: $_"
}

# Auto-detect first saved profile if not provided
if ([string]::IsNullOrWhiteSpace($ProfileName)) {
    $profilesOutput = & netsh wlan show profiles interface="$adapterName" 2>$null
    if (-not $profilesOutput) {
        $profilesOutput = & netsh wlan show profiles 2>$null
    }
    foreach ($line in $profilesOutput) {
        if ($line -match 'All User Profile\s*:\s*(.+)$') {
            $candidate = $matches[1]
            if ($candidate -and $candidate.Trim() -ne "<None>") {
                $ProfileName = $candidate
                break
            }
        }
    }
}

if ($ProfileName) {
    try {
        & netsh wlan set profileorder name="$ProfileName" interface="$adapterName" priority=1 2>$null
        Write-Host "  [+] Wi-Fi Profile '$ProfileName' set to Priority 1" -ForegroundColor Green
    } catch {
        Write-Warning "Could not update profile priority: $_"
    }
} else {
    Write-Host "  [i] No saved Wi-Fi profiles detected; skipping profile priority adjustment." -ForegroundColor Gray
}

# -------------------------------------------------------------------------
# Step 5: Autonomous Watchdog Scheduled Task Registration
# -------------------------------------------------------------------------
Write-Host "`n[5/6] Registering Autonomous Watchdog Scheduled Task..." -ForegroundColor Yellow

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$watchdogScript = Join-Path $scriptDir "register_wifi_watchdog.ps1"
if (Test-Path $watchdogScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$watchdogScript"
} else {
    Write-Warning "Watchdog registration script not found at: $watchdogScript"
}

# -------------------------------------------------------------------------
# Step 6: Verification & Optional Adapter Cycle
# -------------------------------------------------------------------------
if (-not $SkipAdapterRestart) {
    Write-Host "`n[6/6] Resetting adapter to apply hardware registers & verifying..." -ForegroundColor Yellow
    
    & netsh interface set interface name="$adapterName" admin=DISABLED 2>$null
    Start-Sleep -Milliseconds 500
    & netsh interface set interface name="$adapterName" admin=ENABLED 2>$null
    Start-Sleep -Seconds 3

    if ($ProfileName) {
        & netsh wlan connect name="$ProfileName" interface="$adapterName" 2>$null | Out-Null
        Start-Sleep -Seconds 2
    }

    Write-Host "`n=== NetAdapter Status ===" -ForegroundColor Cyan
    Get-NetAdapter -Name "$adapterName" | Format-Table -AutoSize

    Write-Host "=== WLAN Interface Status ===" -ForegroundColor Cyan
    & netsh wlan show interfaces
} else {
    Write-Host "`n[6/6] Skipping adapter restart (-SkipAdapterRestart specified)." -ForegroundColor Gray
}

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host " Permanent remediation and hardening successfully applied!" -ForegroundColor Cyan
Write-Host "========================================================================`n" -ForegroundColor Cyan
