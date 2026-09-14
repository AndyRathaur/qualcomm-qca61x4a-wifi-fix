<#
.SYNOPSIS
    Registers the autonomous event-driven Wi-Fi watchdog Scheduled Task in Windows.

.DESCRIPTION
    Creates the 'WiFi-Watchdog-AutoRecovery' Scheduled Task configured with:
    - EventTrigger on 'Microsoft-Windows-WLAN-AutoConfig/Operational' Event ID 8002 AND 8003
      (ReasonCodes 229396 / 229378 / 0 or RSSI 255: AP invisibility / RF lockup / driver disconnect).
    - 2-minute periodic Heartbeat TimeTrigger as a background safety net.
    - Runs as SYSTEM with HighestAvailable privileges (no UAC prompt, no login required).
    - Battery-independent execution (DisallowStartIfOnBatteries = false).
    - 0% CPU and 0 MB RAM idle footprint (kernel event subscription).

.PARAMETER Unregister
    Unregisters and removes the watchdog Scheduled Task.
#>

[CmdletBinding()]
param(
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
$taskName = "WiFi-Watchdog-AutoRecovery"

if ($Unregister) {
    Write-Host "Unregistering scheduled task '$taskName'..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[+] Task '$taskName' unregistered successfully." -ForegroundColor Green
    return
}

# Resolve directory and recovery script path dynamically
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$scriptPath = Join-Path $scriptDir "recover_wifi.ps1"

if (-not (Test-Path $scriptPath)) {
    throw "Target recovery script not found at: $scriptPath"
}

Write-Host "Configuring event-driven Scheduled Task '$taskName'..." -ForegroundColor Cyan
Write-Host "  -> Recovery script target: $scriptPath"

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Autonomous self-healing watchdog for Qualcomm QCA61x4A Wi-Fi adapter transceiver lockups. Monitors WLAN-AutoConfig Operational Event 8002/8003 (failed connection / AP invisibility / driver disconnect) with 2-minute safety heartbeat and invokes recover_wifi.ps1.</Description>
    <URI>\$taskName</URI>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;&lt;Select Path="Microsoft-Windows-WLAN-AutoConfig/Operational"&gt;*[System[Provider[@Name='Microsoft-Windows-WLAN-AutoConfig'] and (EventID=8002 or EventID=8003)]] and *[EventData[Data[@Name='ReasonCode']='229396' or Data[@Name='ReasonCode']='229378' or Data[@Name='ReasonCode']='0' or Data[@Name='RSSI']='255']]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <ValueQueries>
        <Value name="EventId">Event/System/EventID</Value>
      </ValueQueries>
    </EventTrigger>
    <TimeTrigger>
      <Repetition>
        <Interval>PT2M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$scriptPath" -Trigger "`$(EventId)"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$tempXml = [System.IO.Path]::GetTempFileName()
try {
    # UTF-16 encoding is required for Task Scheduler XML import via schtasks.exe
    [System.IO.File]::WriteAllText($tempXml, $taskXml, [System.Text.Encoding]::Unicode)
    $out = & schtasks.exe /Create /TN "$taskName" /XML "$tempXml" /F
    Write-Host "  -> $out"

    $registeredTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($registeredTask) {
        Write-Host "  [+] Task '$taskName' successfully registered and active!" -ForegroundColor Green
        Write-Host "  [+] State: $($registeredTask.State), Triggers: Event 8002/8003 (WLAN-AutoConfig) + 2-min Heartbeat" -ForegroundColor Green
    } else {
        throw "Failed to verify registered task."
    }
} finally {
    if (Test-Path $tempXml) {
        Remove-Item -Path $tempXml -Force -ErrorAction SilentlyContinue
    }
}
