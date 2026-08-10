# ============================================================
# uninstall.ps1 - Remove the Antec Display tool from your system
# Does NOT remove PawnIO (it might be used by other tools)
# ============================================================

#Requires -RunAsAdministrator

Write-Host ""
Write-Host "Uninstalling Antec Display tool..." -ForegroundColor Cyan

# Stop and remove scheduled task
$task = Get-ScheduledTask -TaskName "AntecDisplay" -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName "AntecDisplay" -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "AntecDisplay" -Confirm:$false
    Write-Host "[OK] Removed scheduled task 'AntecDisplay'" -ForegroundColor Green
} else {
    Write-Host "[--] Scheduled task 'AntecDisplay' was not present" -ForegroundColor Gray
}

# Kill any running instances
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.CommandLine -like "*antec-display.ps1*") {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Killed running instance PID $($_.ProcessId)" -ForegroundColor Green
    }
}

# Optional: remove logs
$logDir = "$env:ProgramData\AntecDisplay"
if (Test-Path $logDir) {
    Remove-Item $logDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Removed log directory $logDir" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. The display will go blank on next reboot." -ForegroundColor Cyan
Write-Host ""
Write-Host "Note: PawnIO driver was NOT removed (it may be used by other tools)." -ForegroundColor Yellow
Write-Host "      To remove it manually, use Windows Settings > Apps." -ForegroundColor Yellow
Write-Host ""
