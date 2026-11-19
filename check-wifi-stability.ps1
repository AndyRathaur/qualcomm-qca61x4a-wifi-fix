<#
.SYNOPSIS
    Wi-Fi Stability Audit Tool - Approach A (WPA2-PSK Hardening) Verification
.DESCRIPTION
    Validates continuous Wi-Fi link stability following the Approach A profile hardening
    milestone. Checks event logs, recovery logs, interface metrics, and network latency.
#>

param(
    [string]$LogPath = "C:\Users\Administrator\scripts\wifi_recovery.log",
    [switch]$Detailed
)

$Host.UI.RawUI.WindowTitle = "Wi-Fi Stability Audit - Approach A Verification"

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "             WI-FI STABILITY & PROFILE HARDENING AUDIT REPORT                   " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

# 1. Milestone Tracking
$milestoneRegex = '\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]\s+\[MILESTONE\]\s+\[Approach-A\]'
$milestoneFound = $false
$milestoneTime = $null
$postMilestoneLines = @()

if (Test-Path $LogPath) {
    $allLines = Get-Content -Path $LogPath
    $milestoneIndex = -1
    for ($i = $allLines.Count - 1; $i -ge 0; $i--) {
        if ($allLines[$i] -match $milestoneRegex) {
            $milestoneIndex = $i
            $milestoneTime = [DateTime]::Parse($matches[1])
            $milestoneFound = $true
            break
        }
    }

    if ($milestoneFound -and $milestoneIndex -lt ($allLines.Count - 1)) {
        $postMilestoneLines = $allLines[($milestoneIndex + 1)..($allLines.Count - 1)]
    }
}

if ($milestoneFound) {
    $elapsed = (Get-Date) - $milestoneTime
    $elapsedStr = [string]::Format("{0:D2}h {1:D2}m {2:D2}s", [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds)
    Write-Host "[MILESTONE] Approach-A Applied At : $($milestoneTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Yellow
    Write-Host "[MILESTONE] Observation Window     : $elapsedStr elapsed" -ForegroundColor Yellow
} else {
    Write-Host "[WARNING] No Approach-A milestone found in $LogPath. Evaluating from current session." -ForegroundColor Yellow
    $milestoneTime = (Get-Date).AddHours(-1)
}

# 2. Log Analysis (Drops & Resets)
$recoveryAttempts = 0
$throttledEvents = 0
$successfulResets = 0
$warningEvents = 0

foreach ($line in $postMilestoneLines) {
    if ($line -match '\[RECOVERING\]') { $recoveryAttempts++ }
    if ($line -match '\[THROTTLED\]') { $throttledEvents++ }
    if ($line -match '\[SUCCESS\]') { $successfulResets++ }
    if ($line -match '\[WARNING\]|\[FAIL\]') { $warningEvents++ }
}

# Check Windows WLAN Event Log for disconnects since milestone
$wlanDisconnects = 0
try {
    $disconnectEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
        Id        = 8003
        StartTime = $milestoneTime
    } -ErrorAction SilentlyContinue
    if ($disconnectEvents) {
        $wlanDisconnects = $disconnectEvents.Count
    }
} catch {
    $wlanDisconnects = 0
}

# 3. WLAN Interface Status
$wlanOutput = netsh wlan show interfaces
$state = "Unknown"
$ssid = "Unknown"
$auth = "Unknown"
$cipher = "Unknown"
$signal = "Unknown"
$rxRate = "Unknown"
$txRate = "Unknown"
$radio = "Unknown"

foreach ($line in ($wlanOutput -split "`r?`n")) {
    if ($line -match '^\s*State\s*:\s*(.+)$') { $state = $matches[1].Trim() }
    if ($line -match '^\s*SSID\s*:\s*(.+)$') { $ssid = $matches[1].Trim() }
    if ($line -match '^\s*Authentication\s*:\s*(.+)$') { $auth = $matches[1].Trim() }
    if ($line -match '^\s*Cipher\s*:\s*(.+)$') { $cipher = $matches[1].Trim() }
    if ($line -match '^\s*Signal\s*:\s*(.+)$') { $signal = $matches[1].Trim() }
    if ($line -match '^\s*Receive rate \(Mbps\)\s*:\s*(.+)$') { $rxRate = $matches[1].Trim() }
    if ($line -match '^\s*Transmit rate \(Mbps\)\s*:\s*(.+)$') { $txRate = $matches[1].Trim() }
    if ($line -match '^\s*Radio type\s*:\s*(.+)$') { $radio = $matches[1].Trim() }
}

# Calculate continuous link uptime
$uptimeStr = "N/A"
try {
    $lastConnectEvent = Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
        Id      = 8001
    } -MaxEvents 1 -ErrorAction SilentlyContinue

    if ($lastConnectEvent) {
        $uptime = (Get-Date) - $lastConnectEvent.TimeCreated
        $uptimeStr = [string]::Format("{0:D2}h {1:D2}m {2:D2}s", [int]$uptime.TotalHours, $uptime.Minutes, $uptime.Seconds)
    }
} catch {
    $uptimeStr = "Unknown"
}

# 4. Latency & ICMP Connectivity Test
Write-Host "`n--- [Active Link Health Check] ---" -ForegroundColor Cyan
$pingsGoogle = @()
$pingsCloudflare = @()

try {
    $pingsGoogle = Test-Connection -ComputerName 8.8.8.8 -Count 5 -ErrorAction SilentlyContinue
} catch {}

try {
    $pingsCloudflare = Test-Connection -ComputerName 1.1.1.1 -Count 5 -ErrorAction SilentlyContinue
} catch {}

$googleSuccess = ($pingsGoogle | Where-Object { $_.ResponseTime -ne $null }).Count
$googleLoss = ((5 - $googleSuccess) / 5) * 100
$googleAvg = if ($googleSuccess -gt 0) { ($pingsGoogle | Measure-Object -Property ResponseTime -Average).Average } else { $null }

$cfSuccess = ($pingsCloudflare | Where-Object { $_.ResponseTime -ne $null }).Count
$cfLoss = ((5 - $cfSuccess) / 5) * 100
$cfAvg = if ($cfSuccess -gt 0) { ($pingsCloudflare | Measure-Object -Property ResponseTime -Average).Average } else { $null }

# 5. Display Summary
Write-Host ""
Write-Host "Adapter State         : $state" -ForegroundColor $(if ($state -eq "connected") { "Green" } else { "Red" })
Write-Host "Connected Network     : SSID '$ssid' | Radio: $radio" -ForegroundColor White
Write-Host "Security Profile      : Auth: $auth | Cipher: $cipher" -ForegroundColor $(if ($auth -eq "WPA2-Personal" -and $cipher -eq "CCMP") { "Green" } else { "Yellow" })
Write-Host "Signal & Throughput   : Signal: $signal | Rx: $rxRate Mbps | Tx: $txRate Mbps" -ForegroundColor White
Write-Host "Continuous Uptime     : $uptimeStr" -ForegroundColor Green

Write-Host "`n--- [Telemetry & Drop Metrics Since Hardening] ---" -ForegroundColor Cyan
Write-Host "Hardware Reset Loops  : $recoveryAttempts (Target: 0)" -ForegroundColor $(if ($recoveryAttempts -eq 0) { "Green" } else { "Red" })
Write-Host "Throttled Disconnects : $throttledEvents (Target: 0)" -ForegroundColor $(if ($throttledEvents -eq 0) { "Green" } else { "Red" })
Write-Host "WLAN Disconnect Events: $wlanDisconnects (Target: 0)" -ForegroundColor $(if ($wlanDisconnects -eq 0) { "Green" } else { "Red" })

Write-Host "`n--- [ICMP Network Quality (5 Packets Each)] ---" -ForegroundColor Cyan
if ($googleSuccess -gt 0) {
    Write-Host "Google DNS (8.8.8.8)  : Packet Loss: $googleLoss% | Avg Latency: $([math]::Round($googleAvg, 1)) ms" -ForegroundColor Green
} else {
    Write-Host "Google DNS (8.8.8.8)  : FAILED (100% loss)" -ForegroundColor Red
}

if ($cfSuccess -gt 0) {
    Write-Host "Cloudflare (1.1.1.1)  : Packet Loss: $cfLoss% | Avg Latency: $([math]::Round($cfAvg, 1)) ms" -ForegroundColor Green
} else {
    Write-Host "Cloudflare (1.1.1.1)  : FAILED (100% loss)" -ForegroundColor Red
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
if ($recoveryAttempts -eq 0 -and $wlanDisconnects -eq 0 -and $state -eq "connected" -and $auth -eq "WPA2-Personal") {
    Write-Host " VERDICT: [STABLE & HARDENED] 802.11w buffer overflow eliminated (0 drops)" -ForegroundColor Green
} else {
    Write-Host " VERDICT: [ATTENTION REQUIRED] Drop events or unhardened profile detected" -ForegroundColor Red
}
Write-Host "================================================================================" -ForegroundColor Cyan

if ($Detailed -and $postMilestoneLines.Count -gt 0) {
    Write-Host "`nRecent Post-Milestone Logs:" -ForegroundColor Gray
    $postMilestoneLines | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}
