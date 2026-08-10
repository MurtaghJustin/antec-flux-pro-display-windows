# ============================================================
# install.ps1 - One-click installer for Antec Display Driver
#
# Run as Administrator. Will:
#   1. Verify all required files are present
#   2. Install PawnIO if not already installed
#   3. Create a Scheduled Task that runs at every boot as SYSTEM
#   4. Start the tool immediately
# ============================================================

#Requires -RunAsAdministrator

param(
    [string]$InstallDir = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

function Write-Step($msg, $color = "Cyan") {
    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor $color
    Write-Host "  $msg" -ForegroundColor $color
    Write-Host "===============================================================" -ForegroundColor $color
}

# === Pre-flight checks ===
Write-Step "0. Pre-flight checks"

$requiredFiles = @(
    "$InstallDir\antec-display.ps1",
    "$InstallDir\lhm\LibreHardwareMonitorLib.dll",
    "$InstallDir\lhm\HidSharp.dll"
)
foreach ($f in $requiredFiles) {
    if (-not (Test-Path $f)) {
        Write-Host "[FAIL] Missing required file: $f" -ForegroundColor Red
        Write-Host "       Make sure you extracted all release files." -ForegroundColor Yellow
        exit 1
    }
}
Write-Host "[OK] All required files found" -ForegroundColor Green

# Release ZIPs downloaded by a browser can mark every extracted DLL as coming
# from the Internet. .NET Framework then refuses to load them (0x80131515).
Get-ChildItem -Path $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue
Write-Host "[OK] Cleared Windows download blocking from installation files" -ForegroundColor Green

# Check display device is connected
$displayDev = Get-PnpDevice -InstanceId "*VID_2022*PID_0522*" -Status OK -ErrorAction SilentlyContinue
if (-not $displayDev) {
    Write-Host "[WARN] Antec display device not detected (VID_2022 PID_0522)" -ForegroundColor Yellow
    Write-Host "       Continuing anyway - device may appear later." -ForegroundColor Yellow
} else {
    Write-Host "[OK] Antec display device detected" -ForegroundColor Green
}

# === PawnIO ===
Write-Step "1. PawnIO Driver"
$pawnSvc = Get-Service "PawnIO" -ErrorAction SilentlyContinue
if ($pawnSvc) {
    Write-Host "[OK] PawnIO already installed (Status: $($pawnSvc.Status))" -ForegroundColor Green
    if ($pawnSvc.Status -ne "Running") {
        Write-Host "     Starting service..." -ForegroundColor Yellow
        Start-Service PawnIO
    }
} else {
    $setup = "$InstallDir\PawnIO_setup.exe"
    if (Test-Path $setup) {
        Write-Host "Launching PawnIO installer - click 'Install' / 'Next' to continue" -ForegroundColor Yellow
        $proc = Start-Process -FilePath $setup -Wait -PassThru
        Start-Sleep 3
        $pawnSvc = Get-Service "PawnIO" -ErrorAction SilentlyContinue
        if (-not $pawnSvc) {
            Write-Host "[FAIL] PawnIO installation failed - install manually from $setup" -ForegroundColor Red
            exit 1
        }
        Write-Host "[OK] PawnIO installed successfully" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] PawnIO_setup.exe not found in $InstallDir" -ForegroundColor Red
        Write-Host "       Download from: https://github.com/namazso/PawnIO.Setup/releases" -ForegroundColor Yellow
        exit 1
    }
}

# === Scheduled Task ===
Write-Step "2. Create Scheduled Task"

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Antec Flux Pro Display Driver - Open-source replacement for iUnity</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT15S</Delay>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$InstallDir\antec-display.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = "$env:TEMP\antec_task.xml"
[System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)

cmd.exe /c 'schtasks /delete /tn "AntecDisplay" /f >nul 2>&1'
$result = schtasks /create /tn "AntecDisplay" /xml $xmlPath /f 2>&1
Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue

if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Scheduled task 'AntecDisplay' created" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Could not create scheduled task: $result" -ForegroundColor Red
    exit 1
}

# === Start now ===
Write-Step "3. Starting tool"
schtasks /run /tn "AntecDisplay" | Out-Null
Start-Sleep 8

$logPath = "$env:ProgramData\AntecDisplay\antec_display.log"
if (Test-Path $logPath) {
    Write-Host "[OK] Tool is running - last log entries:" -ForegroundColor Green
    Get-Content $logPath -Tail 5 -Encoding UTF8 | ForEach-Object {
        Write-Host "    $_" -ForegroundColor Gray
    }
} else {
    Write-Host "[WARN] Log not created yet - check status manually with verify.ps1" -ForegroundColor Yellow
}

Write-Step "Installation complete!" "Green"
Write-Host ""
Write-Host "The display should now show CPU and GPU temperatures." -ForegroundColor Green
Write-Host ""
Write-Host "Useful commands:" -ForegroundColor Cyan
Write-Host "  Verify everything works:" -ForegroundColor Gray
Write-Host "    powershell -ExecutionPolicy Bypass -File `"$InstallDir\verify.ps1`""
Write-Host "  View live log:" -ForegroundColor Gray
Write-Host "    Get-Content `"$logPath`" -Tail 20 -Wait -Encoding UTF8"
Write-Host "  Restart tool:" -ForegroundColor Gray
Write-Host "    schtasks /run /tn AntecDisplay"
Write-Host "  Stop tool:" -ForegroundColor Gray
Write-Host "    schtasks /end /tn AntecDisplay"
Write-Host ""
