<#
.SYNOPSIS
    One-click administrator installer for Qualcomm QCA61x4A / DW1820 Wi-Fi fix and autonomous watchdog.

.DESCRIPTION
    Applies PCIe ASPM power hardening, baseband stability registry keys,
    configures adapter properties, registers the SYSTEM-level Event 8002/8003 watchdog task,
    and performs automated connectivity verification.

.EXAMPLE
    .\install.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Ensure Administrator Privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevated administrator privileges are required. Requesting elevation..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " Qualcomm QCA61x4A / Dell DW1820 Wi-Fi Permanent Fix & Watchdog Setup" -ForegroundColor Cyan
Write-Host " Author: Andy Rathaur (@AndyRathaur)" -ForegroundColor DarkCyan
Write-Host "========================================================================`n" -ForegroundColor Cyan

# Step 1: Apply Permanent Remediations & Driver Hardening
Write-Host "[1/3] Applying PCIe ASPM, Baseband & Registry Hardening..." -ForegroundColor Yellow
$fixScript = Join-Path $scriptDir "apply_wifi_permanent_fix.ps1"
if (Test-Path $fixScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$fixScript"
} else {
    throw "Script not found: $fixScript"
}

# Step 2: Register Autonomous Watchdog Scheduled Task
Write-Host "`n[2/3] Registering Event-Driven Watchdog Scheduled Task..." -ForegroundColor Yellow
$watchdogScript = Join-Path $scriptDir "register_wifi_watchdog.ps1"
if (Test-Path $watchdogScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$watchdogScript"
} else {
    throw "Script not found: $watchdogScript"
}

# Step 3: Verification & Network Health Check
Write-Host "`n[3/3] Verifying Network Connectivity..." -ForegroundColor Yellow
Start-Sleep -Seconds 2

$pingOk = $false
try {
    $ping = New-Object System.Net.NetworkInformation.Ping
    $reply = $ping.Send("8.8.8.8", 1500)
    if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
        $pingOk = $true
    }
} catch {}

$wlanStatus = & netsh wlan show interfaces
$ssid = ($wlanStatus | Select-String -Pattern "SSID\s*:\s*(.+)").Matches.Groups[1].Value.Trim()
$state = ($wlanStatus | Select-String -Pattern "State\s*:\s*(\w+)").Matches.Groups[1].Value

Write-Host "`n========================================================================" -ForegroundColor Cyan
if ($pingOk) {
    Write-Host " [+] INSTALLATION SUCCESSFUL! Network is online and fully operational." -ForegroundColor Green
    if ($ssid) {
        Write-Host "     SSID:  $ssid" -ForegroundColor Green
    }
    Write-Host "     State: $state" -ForegroundColor Green
} else {
    Write-Host " [!] Hardening applied, but internet ping check did not complete yet." -ForegroundColor Yellow
    Write-Host "     State: $state (Watchdog task is active and will auto-heal if needed)" -ForegroundColor Yellow
}
Write-Host "     Watchdog Task: 'WiFi-Watchdog-AutoRecovery' (SYSTEM, Event 8002/8003 + 2m Heartbeat)" -ForegroundColor White
Write-Host "========================================================================`n" -ForegroundColor Cyan
