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
    [string]$LogPath = "$env:ProgramData\AntecDisplay\antec_display.log"
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
    # PowerShell's [int] conversion rounds rather than truncates. Convert the
    # rounded tenths value to integer digits explicitly (39.8 -> 3, 9, 8).
    $scaled = [int][Math]::Round($t * 10, 0, [MidpointRounding]::AwayFromZero)
    $tens = [int][Math]::Floor($scaled / 100) % 10
    $ones = [int][Math]::Floor($scaled / 10) % 10
    $tenths = $scaled % 10
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
            # Sensor names vary by CPU vendor. Prefer the package/control
            # temperature, then fall back to the hottest core sensor.
            $preferredNames = @("CPU Package", "Core (Tctl/Tdie)", "Core Max")
            foreach ($name in $preferredNames) {
                foreach ($s in $hw.Sensors) {
                    if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and
                        $s.Name -eq $name -and $null -ne $s.Value -and [float]$s.Value -gt 0) {
                        if ($script:cpuSensorName -ne $s.Name) {
                            $script:cpuSensorName = $s.Name
                            Write-Log "Using CPU temperature sensor: $($s.Name) ($($s.Identifier))"
                        }
                        return [float]$s.Value
                    }
                }
            }

            # Future CPUs may use another name. Use the first plausible CPU
            # temperature rather than returning N/A solely because of naming.
            foreach ($s in $hw.Sensors) {
                if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and
                    $null -ne $s.Value -and [float]$s.Value -gt 0 -and [float]$s.Value -le 125) {
                    if ($script:cpuSensorName -ne $s.Name) {
                        $script:cpuSensorName = $s.Name
                        Write-Log "Using fallback CPU temperature sensor: $($s.Name) ($($s.Identifier))" "WARN"
                    }
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
$outputReportLength = 65
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
            $outputReportLength = [Math]::Max(13, $dev.GetMaxOutputReportLength())
            Write-Log "Display device opened (output report length: $outputReportLength)"
            $consecutiveErrors = 0
        }

        $cpu = Read-CpuTemp
        $gpu = Read-GpuTemp

        $payload = Build-Payload $cpu $gpu

        # HID Output Report - byte 0 is Report ID
        # Windows HID writes use the descriptor's complete report length. Byte
        # zero is the report ID; the remaining unused bytes stay zero-padded.
        $buffer = [byte[]]::new($outputReportLength)
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
