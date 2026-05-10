# ============================================================
# Antec Flux Pro Display Driver for Windows
# Open-source replacement for Antec iUnity
#
# Sends CPU and GPU temperatures to the side-panel display
# (Vortex View Screen) on Antec Flux Pro cases.
#
# Repo:    https://github.com/motiop/antec-flux-pro-display-windows
# License: MIT
# ============================================================

param(
    [int]$PollSeconds = 1,
    [string]$LhmPath = "$PSScriptRoot\lhm",
    [string]$LogPath = "$env:LOCALAPPDATA\AntecDisplay\antec_display.log"
)

# === Logging ===
function Write-Log($msg, $level = "INFO") {
    try {
        $logDir = Split-Path -Parent $LogPath
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $line = "$ts | $level | $msg"
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch {}
}

# Reset log on each run
try { Remove-Item $LogPath -Force -ErrorAction SilentlyContinue } catch {}

Write-Log "==================================================="
Write-Log "Antec Display Driver - Starting"
Write-Log "PID: $PID | LhmPath: $LhmPath | PollSeconds: $PollSeconds"
Write-Log "Working dir: $(Get-Location)"
Write-Log "PowerShell: $($PSVersionTable.PSVersion)"
Write-Log "User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

$ErrorActionPreference = "Stop"
trap {
    Write-Log "FATAL: $_" "ERROR"
    Write-Log "STACK: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}

# === Load DLLs ===
try {
    Add-Type -Path "$LhmPath\LibreHardwareMonitorLib.dll"
    Write-Log "LibreHardwareMonitorLib.dll loaded"
    Add-Type -Path "$LhmPath\HidSharp.dll"
    Write-Log "HidSharp.dll loaded"
} catch {
    Write-Log "DLL load failed: $_" "ERROR"
    exit 1
}

# === Initialize sensors ===
try {
    $computer = New-Object LibreHardwareMonitor.Hardware.Computer
    $computer.IsCpuEnabled = $true
    $computer.IsGpuEnabled = $true
    $computer.IsMotherboardEnabled = $true
    $computer.IsMemoryEnabled = $true
    $computer.IsStorageEnabled = $false
    $computer.IsNetworkEnabled = $false
    $computer.IsControllerEnabled = $false
    $computer.Open()
    Write-Log "Computer opened, $($computer.Hardware.Count) hardware items"
    foreach ($hw in $computer.Hardware) {
        Write-Log "  Hardware: $($hw.HardwareType) - $($hw.Name)"
    }
} catch {
    Write-Log "Computer.Open failed: $_" "ERROR"
    Write-Log "Make sure PawnIO is installed and running for CPU sensor support" "ERROR"
    exit 1
}

# === USB constants ===
$VID = 0x2022
$PID_DEVICE = 0x0522

# === HID device finder ===
function Find-DisplayDevice {
    try {
        $list = [HidSharp.DeviceList]::Local
        foreach ($d in $list.GetHidDevices()) {
            if ($d.VendorID -eq $VID -and $d.ProductID -eq $PID_DEVICE) {
                return $d
            }
        }
    } catch {
        Write-Log "Find-DisplayDevice error: $_" "ERROR"
    }
    return $null
}

# === Protocol encoding ===
function Encode-Temp {
    param([Nullable[float]]$temp)
    if ($null -eq $temp) {
        return @([byte]0xEE, [byte]0xEE, [byte]0xEE)
    }
    $t = [Math]::Min(99.9, [Math]::Max(0, [float]$temp))
    $tens = [int]($t / 10) % 10
    $ones = [int]$t % 10
    $tenths = [int]($t * 10) % 10
    return @([byte]$tens, [byte]$ones, [byte]$tenths)
}

function Build-Payload {
    param([Nullable[float]]$cpu, [Nullable[float]]$gpu)
    $bytes = [byte[]]@(0x55, 0xAA, 0x01, 0x01, 0x06)
    $cpuEnc = Encode-Temp $cpu
    $gpuEnc = Encode-Temp $gpu
    $bytes += $cpuEnc
    $bytes += $gpuEnc
    $sum = 0
    foreach ($b in $bytes) { $sum = ($sum + $b) -band 0xFF }
    $bytes += [byte]$sum
    return ,$bytes
}

# === Sensor reading ===
function Read-CpuTemp {
    foreach ($hw in $computer.Hardware) {
        if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) {
            $hw.Update()
            foreach ($s in $hw.Sensors) {
                if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and
                    $s.Name -eq "CPU Package" -and $null -ne $s.Value) {
                    return [float]$s.Value
                }
            }
            # Fallback: use Core Max if CPU Package not available
            foreach ($s in $hw.Sensors) {
                if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and
                    $s.Name -eq "Core Max" -and $null -ne $s.Value) {
                    return [float]$s.Value
                }
            }
        }
    }
    return $null
}

function Read-GpuTemp {
    foreach ($hw in $computer.Hardware) {
        if ($hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuNvidia -or
            $hw.HardwareType -eq [LibreHardwareMonitor.Hardware.HardwareType]::GpuAmd) {
            $hw.Update()
            foreach ($s in $hw.Sensors) {
                if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and
                    $s.Name -eq "GPU Core" -and $null -ne $s.Value) {
                    return [float]$s.Value
                }
            }
        }
    }
    return $null
}

# === Main loop ===
Write-Log "Entering main loop"
$stream = $null
$lastLog = [DateTime]::MinValue
$consecutiveErrors = 0

while ($true) {
    try {
        if (-not $stream) {
            $dev = Find-DisplayDevice
            if (-not $dev) {
                Write-Log "Display device not found, retry in 5s" "WARN"
                Start-Sleep 5
                continue
            }
            $tempStream = $null
            if (-not $dev.TryOpen([ref]$tempStream)) {
                Write-Log "Could not open device, retry in 5s" "WARN"
                Start-Sleep 5
                continue
            }
            $stream = $tempStream
            Write-Log "Display device opened"
            $consecutiveErrors = 0
        }

        $cpu = Read-CpuTemp
        $gpu = Read-GpuTemp

        $payload = Build-Payload $cpu $gpu

        # HID Output Report - byte 0 is Report ID
        $buffer = [byte[]]::new($payload.Length + 1)
        $buffer[0] = 0
        [Array]::Copy($payload, 0, $buffer, 1, $payload.Length)

        $stream.Write($buffer, 0, $buffer.Length)
        $consecutiveErrors = 0

        # Log once per minute (avoid log spam)
        $now = Get-Date
        if (($now - $lastLog).TotalSeconds -ge 60) {
            $cpuStr = if ($null -ne $cpu) { "$([Math]::Round($cpu, 1))C" } else { "N/A" }
            $gpuStr = if ($null -ne $gpu) { "$([Math]::Round($gpu, 1))C" } else { "N/A" }
            $hexStr = ($payload | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
            Write-Log "CPU=$cpuStr GPU=$gpuStr | bytes: $hexStr"
            $lastLog = $now
        }

        Start-Sleep -Seconds $PollSeconds
    }
    catch {
        $consecutiveErrors++
        Write-Log "Loop error: $_" "ERROR"
        try { if ($stream) { $stream.Dispose() } } catch {}
        $stream = $null
        if ($consecutiveErrors -gt 10) {
            Write-Log "Too many errors, exiting" "FATAL"
            break
        }
        Start-Sleep 5
    }
}

# Cleanup
try { if ($stream) { $stream.Dispose() } } catch {}
try { $computer.Close() } catch {}
Write-Log "Exiting"
