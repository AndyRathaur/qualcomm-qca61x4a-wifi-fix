<#
.SYNOPSIS
    One-click administrator uninstaller for Qualcomm QCA61x4A / DW1820 Wi-Fi fix.

.DESCRIPTION
    Removes the 'WiFi-Watchdog-AutoRecovery' scheduled task, removes runtime state files,
    and optionally restores Windows default PCIe ASPM power scheme settings.

.PARAMETER RestorePowerDefaults
    Restores default Windows PCIe ASPM Link State Power Management settings (Moderate AC / Max DC).
#>

[CmdletBinding()]
param(
    [switch]$RestorePowerDefaults
)

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
Write-Host " Qualcomm QCA61x4A / Dell DW1820 Wi-Fi Fix - Uninstaller" -ForegroundColor Cyan
Write-Host "========================================================================`n" -ForegroundColor Cyan

# Step 1: Unregister Watchdog Scheduled Task
Write-Host "[1/3] Removing Watchdog Scheduled Task..." -ForegroundColor Yellow
$watchdogScript = Join-Path $scriptDir "register_wifi_watchdog.ps1"
if (Test-Path $watchdogScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$watchdogScript" -Unregister
} else {
    & schtasks.exe /Delete /TN "WiFi-Watchdog-AutoRecovery" /F 2>$null | Out-Null
    Write-Host "  [+] Watchdog task removed." -ForegroundColor Green
}

# Step 2: Clean Runtime Files
Write-Host "`n[2/3] Cleaning runtime log and throttle state files..." -ForegroundColor Yellow
$throttleFile = Join-Path $scriptDir ".wifi_recovery_throttle"
$logFile = Join-Path $scriptDir "wifi_recovery.log"

if (Test-Path $throttleFile) {
    Remove-Item -Path $throttleFile -Force -ErrorAction SilentlyContinue
    Write-Host "  [+] Removed .wifi_recovery_throttle" -ForegroundColor Green
}
if (Test-Path $logFile) {
    Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
    Write-Host "  [+] Removed wifi_recovery.log" -ForegroundColor Green
}

# Step 3: Optional Power Defaults
Write-Host "`n[3/3] Power settings..." -ForegroundColor Yellow
if ($RestorePowerDefaults) {
    $subgroup = "501a4d13-42af-4429-9fd1-a8218c268e20" # SUB_PCIEXPRESS
    $setting  = "ee12f906-d277-404b-b6da-e5fa1a576df5" # ASPM
    & powercfg /setacvalueindex SCHEME_CURRENT $subgroup $setting 1
    & powercfg /setdcvalueindex SCHEME_CURRENT $subgroup $setting 2
    & powercfg /setactive SCHEME_CURRENT
    Write-Host "  [+] PCIe ASPM restored to standard Windows defaults (Moderate AC / Maximum DC)." -ForegroundColor Green
} else {
    Write-Host "  [i] PCIe ASPM kept at 0 (Off) to preserve link stability. Pass -RestorePowerDefaults to revert." -ForegroundColor Gray
}

Write-Host "`n========================================================================" -ForegroundColor Cyan
Write-Host " Uninstallation Complete." -ForegroundColor Cyan
Write-Host "========================================================================`n" -ForegroundColor Cyan
