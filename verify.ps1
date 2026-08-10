# ============================================================
# verify.ps1 - Check all prerequisites for Antec Display tool
# Run: powershell -ExecutionPolicy Bypass -File verify.ps1
# ============================================================

param(
    [string]$InstallDir = $PSScriptRoot
)

$ErrorActionPreference = "SilentlyContinue"
$logPath = "$env:ProgramData\AntecDisplay\antec_display.log"

$pass = 0
$fail = 0
$warn = 0

function Test-Item {
    param(
        [string]$Name,
        [scriptblock]$Test,
        [string]$FailMessage,
        [string]$FailFix,
        [string]$Severity = "Critical"
    )
    Write-Host "[ ... ] $Name" -NoNewline
    try {
        $result = & $Test
        if ($result) {
            Write-Host "`r[  OK  ] $Name" -ForegroundColor Green
            $script:pass++
        } else {
            $color = if ($Severity -eq "Critical") { "Red" } else { "Yellow" }
            $marker = if ($Severity -eq "Critical") { " FAIL " } else { " WARN " }
            Write-Host "`r[$marker] $Name" -ForegroundColor $color
            Write-Host "         Problem: $FailMessage" -ForegroundColor $color
            if ($FailFix) { Write-Host "         Fix:     $FailFix" -ForegroundColor Cyan }
            if ($Severity -eq "Critical") { $script:fail++ } else { $script:warn++ }
        }
    } catch {
        Write-Host "`r[ FAIL ] $Name" -ForegroundColor Red
        Write-Host "         Error: $_" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  Antec Display Driver - Prerequisites Check" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "===============================================================" -ForegroundColor Cyan

# === HARDWARE ===
Write-Host ""
Write-Host "## HARDWARE ##" -ForegroundColor Yellow

Test-Item -Name "Antec display device connected (VID_2022 PID_0522)" `
    -Test { (Get-PnpDevice -InstanceId "*VID_2022*PID_0522*" -Status OK -ErrorAction SilentlyContinue) -ne $null } `
    -FailMessage "Display not visible in Device Manager" `
    -FailFix "Check USB cable from display to internal USB header / hub"

Test-Item -Name "Internal USB hub connected" `
    -Test { (Get-PnpDevice -Class USB -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like "*Hub*" -and $_.Status -eq "OK" }) -ne $null } `
    -FailMessage "No USB hub detected" `
    -FailFix "Check internal USB header connection"

# === FILES ===
Write-Host ""
Write-Host "## FILES ##" -ForegroundColor Yellow

Test-Item -Name "Main script file present" `
    -Test { Test-Path "$InstallDir\antec-display.ps1" } `
    -FailMessage "antec-display.ps1 missing" `
    -FailFix "Re-extract release archive"

Test-Item -Name "LibreHardwareMonitor library" `
    -Test { Test-Path "$InstallDir\lhm\LibreHardwareMonitorLib.dll" } `
    -FailMessage "LibreHardwareMonitorLib.dll missing" `
    -FailFix "Re-extract release archive"

Test-Item -Name "HidSharp library" `
    -Test { Test-Path "$InstallDir\lhm\HidSharp.dll" } `
    -FailMessage "HidSharp.dll missing" `
    -FailFix "Re-extract release archive"

Test-Item -Name "Libraries are not blocked by Windows" `
    -Test {
        $blocked = Get-ChildItem "$InstallDir\lhm" -File -ErrorAction SilentlyContinue |
            Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue }
        $null -eq $blocked -or @($blocked).Count -eq 0
    } `
    -FailMessage "Downloaded library files have a Zone.Identifier and .NET may reject them with 0x80131515" `
    -FailFix "Get-ChildItem `"$InstallDir`" -Recurse -File | Unblock-File"

Test-Item -Name "PawnIO installer present" `
    -Test { Test-Path "$InstallDir\PawnIO_setup.exe" } `
    -FailMessage "PawnIO_setup.exe missing (only needed for reinstall)" `
    -FailFix "Download from https://github.com/namazso/PawnIO.Setup/releases" `
    -Severity "Warning"

# === DRIVERS / SERVICES ===
Write-Host ""
Write-Host "## DRIVERS / SERVICES ##" -ForegroundColor Yellow

Test-Item -Name "PawnIO driver installed" `
    -Test { (Get-Service PawnIO -ErrorAction SilentlyContinue) -ne $null } `
    -FailMessage "PawnIO service not installed - CPU temperature will not work" `
    -FailFix "Run PawnIO_setup.exe as administrator"

Test-Item -Name "PawnIO driver running" `
    -Test { (Get-Service PawnIO -ErrorAction SilentlyContinue).Status -eq "Running" } `
    -FailMessage "PawnIO installed but not running" `
    -FailFix "As admin: Start-Service PawnIO"

Test-Item -Name "iUnity not present (no conflict)" `
    -Test { (Get-Service "Antec iUnity Service" -ErrorAction SilentlyContinue) -eq $null } `
    -FailMessage "iUnity is installed - it will conflict with this tool" `
    -FailFix "Uninstall iUnity from Windows Settings > Apps"

# === SCHEDULED TASK ===
Write-Host ""
Write-Host "## SCHEDULED TASK ##" -ForegroundColor Yellow

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$task = Get-ScheduledTask -TaskName "AntecDisplay" -ErrorAction SilentlyContinue

if ($isAdmin) {
    Test-Item -Name "AntecDisplay task exists" `
        -Test { $task -ne $null } `
        -FailMessage "Task missing - tool will not auto-start on boot" `
        -FailFix "As admin: cd `"$InstallDir`"; .\install.ps1"

    if ($task) {
        Test-Item -Name "Task runs as SYSTEM" `
            -Test { $task.Principal.UserId -eq "SYSTEM" -or $task.Principal.UserId -eq "S-1-5-18" } `
            -FailMessage "Task not configured to run as SYSTEM" `
            -FailFix "Re-run install.ps1"

        Test-Item -Name "Task is enabled" `
            -Test { $task.State -eq "Ready" -or $task.State -eq "Running" } `
            -FailMessage "Task is disabled" `
            -FailFix "Enable-ScheduledTask -TaskName AntecDisplay"
    }
} else {
    Write-Host "  [INFO] Not running as admin - cannot directly check SYSTEM tasks" -ForegroundColor Gray
    Write-Host "  [INFO] Will verify indirectly via log activity below" -ForegroundColor Gray

    Test-Item -Name "Task verifiable indirectly (log activity)" `
        -Test {
            if (-not (Test-Path $logPath)) { return $false }
            $lastEntry = Get-Content $logPath -Tail 1 -Encoding UTF8
            if ($lastEntry -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                $lastTime = [DateTime]::ParseExact($matches[1], "yyyy-MM-dd HH:mm:ss", $null)
                return ((Get-Date) - $lastTime).TotalMinutes -lt 2
            }
            return $false
        } `
        -FailMessage "Log not updating - task may be missing or stopped" `
        -FailFix "Re-run as admin to verify directly. Or: schtasks /run /tn AntecDisplay"
}

# === RUNTIME ===
Write-Host ""
Write-Host "## RUNTIME (TOOL ACTUALLY WORKING) ##" -ForegroundColor Yellow

Test-Item -Name "Log file exists" `
    -Test { Test-Path $logPath } `
    -FailMessage "Tool never ran or log was deleted" `
    -FailFix "schtasks /run /tn AntecDisplay"

if (Test-Path $logPath) {
    $lastEntry = Get-Content $logPath -Tail 1 -Encoding UTF8
    $lastTime = $null
    if ($lastEntry -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
        try { $lastTime = [DateTime]::ParseExact($matches[1], "yyyy-MM-dd HH:mm:ss", $null) } catch {}
    }

    Test-Item -Name "Log updated within last 2 minutes" `
        -Test { $lastTime -and ((Get-Date) - $lastTime).TotalMinutes -lt 2 } `
        -FailMessage "Log is stale - tool probably not running" `
        -FailFix "schtasks /run /tn AntecDisplay" `
        -Severity "Warning"

    Test-Item -Name "No errors in last 10 log entries" `
        -Test {
            $errors = Get-Content $logPath -Tail 10 -Encoding UTF8 | Where-Object { $_ -match "ERROR|FATAL" }
            $errors.Count -eq 0
        } `
        -FailMessage "Errors found in log" `
        -FailFix "Check: Get-Content `"$logPath`" -Tail 50 -Encoding UTF8" `
        -Severity "Warning"
}

# === FUNCTIONAL ===
Write-Host ""
Write-Host "## FUNCTIONAL ##" -ForegroundColor Yellow

if (Test-Path $logPath) {
    $recentLog = Get-Content $logPath -Tail 20 -Encoding UTF8
    $hasCpu = $recentLog -match "CPU=\d+\.?\d*C"
    $hasGpu = $recentLog -match "GPU=\d+\.?\d*C"

    Test-Item -Name "CPU temperature being read" `
        -Test { $hasCpu } `
        -FailMessage "CPU shows N/A or 0" `
        -FailFix "Run install.ps1 as administrator so the task runs as SYSTEM, then inspect the ProgramData log" `
        -Severity "Warning"

    Test-Item -Name "GPU temperature being read" `
        -Test { $hasGpu } `
        -FailMessage "GPU shows N/A" `
        -FailFix "Check NVIDIA driver: nvidia-smi" `
        -Severity "Warning"
}

# === SUMMARY ===
Write-Host ""
Write-Host "===============================================================" -ForegroundColor Cyan
Write-Host "  SUMMARY:  Pass=$pass  Fail=$fail  Warn=$warn" -ForegroundColor Cyan
Write-Host "===============================================================" -ForegroundColor Cyan

if ($fail -eq 0 -and $warn -eq 0) {
    Write-Host ""
    Write-Host "[OK] All checks passed - tool is working correctly" -ForegroundColor Green
} elseif ($fail -eq 0) {
    Write-Host ""
    Write-Host "[WARN] Critical checks pass, $warn warnings to review" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "[FAIL] $fail critical failures - tool will not work until fixed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Read PREREQUISITES.md for full troubleshooting guide" -ForegroundColor Cyan
}
Write-Host ""
