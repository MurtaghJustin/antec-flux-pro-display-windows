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

# Prefer a discrete GPU when LibreHardwareMonitor exposes multiple GPUs.
$script:gpuHardware = $null
$script:gpuSensorName = $null

function Get-GpuTempSensor {
    param($hw)
    foreach ($name in @("GPU Core", "GPU Hot Spot", "Core")) {
        foreach ($s in $hw.Sensors) {
            if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Temperature -and
                $s.Name -eq $name -and $null -ne $s.Value -and [float]$s.Value -gt 0) {
                return $s
            }
        }
    }
    return $null
}

function Select-GpuHardware {
    $best = $null
    $bestScore = -1
    foreach ($hw in $computer.Hardware) {
        # String match rather than the HardwareType enum so an Intel iGPU
        # (GpuIntel, absent from older LHM builds) is still considered.
        if (-not $hw.HardwareType.ToString().StartsWith("Gpu")) { continue }
        $hw.Update()
        if ($null -eq (Get-GpuTempSensor $hw)) { continue }

        $vram = 0.0
        $hasFan = $false
        foreach ($s in $hw.Sensors) {
            if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::SmallData -and
                $s.Name -eq "GPU Memory Total" -and $null -ne $s.Value) {
                $vram = [float]$s.Value
            }
            if ($s.SensorType -eq [LibreHardwareMonitor.Hardware.SensorType]::Fan) {
                $hasFan = $true
            }
        }
        $discrete = ($vram -ge 1024) -or $hasFan
        $score = $vram
        if ($discrete) { $score += 1000000 }

        Write-Log "  GPU candidate: $($hw.Name) [$($hw.HardwareType)] vram=$([int]$vram)MB fan=$hasFan discrete=$discrete score=$([int]$score)"
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $hw
        }
    }
    return $best
}

function Read-GpuTemp {
    if ($null -eq $script:gpuHardware) {
        $script:gpuHardware = Select-GpuHardware
        if ($null -eq $script:gpuHardware) { return $null }
        Write-Log "Using GPU: $($script:gpuHardware.Name) [$($script:gpuHardware.HardwareType)]"
    }

    $hw = $script:gpuHardware
    $hw.Update()
    $s = Get-GpuTempSensor $hw
    if ($null -eq $s) {
        # Do not silently fall through to another GPU - a temperature that
        # jumps between two cards is worse than one honest N/A frame.
        Write-Log "GPU '$($hw.Name)' stopped reporting a temperature, will reselect" "WARN"
        $script:gpuHardware = $null
        $script:gpuSensorName = $null
        return $null
    }
    if ($script:gpuSensorName -ne $s.Name) {
        $script:gpuSensorName = $s.Name
        Write-Log "Using GPU temperature sensor: $($s.Name) ($($s.Identifier))"
    }
    return [float]$s.Value
}

# === Main loop ===
Write-Log "Entering main loop"
$stream = $null
$outputReportLength = 65
$lastLog = [DateTime]::MinValue
$consecutiveErrors = 0

# The display blanks whenever it stops being fed, so every millisecond spent
# not writing is visible on the panel. These tunables all exist to keep the
# gaps short.

# HidSharp defaults to a 3000ms write timeout. A wedged write therefore costs
# three seconds of blank display before we even learn it failed.
$WriteTimeoutMs = 500

# A write that takes this long is already a visible stutter - log it, because
# the once-a-minute summary below is far too coarse to show it.
$SlowWriteMs = 250

# Across S3 the USB device is reset and re-enumerated while our handle stays
# open. Writes to the stale handle then block for seconds instead of failing.
# There is no reliable power-broadcast to subscribe to from session 0 (the
# task runs as SYSTEM, non-interactive), so detect the suspend by its
# wall-clock footprint instead: an iteration gap far larger than the poll
# period means the process was frozen.
$ResumeGapSeconds = [Math]::Max(5, $PollSeconds * 3)

# Reconnect backoff. The first retries are fast because a 5s sleep here is a
# 5s blank panel; only sustained failure backs off far.
$backoffMs = @(250, 250, 500, 1000, 2000, 5000)

# Fixed-cadence pacing. Sleeping the full poll period *after* the work made
# the real period 1s + read/write time, which drifted.
$periodMs = [Math]::Max(100, $PollSeconds * 1000)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$nextTickMs = 0.0

$lastIterationEnd = [DateTime]::UtcNow
$maxWriteMs = 0.0
$naStreak = 0

while ($true) {
    try {
        if ($stream) {
            $gap = ([DateTime]::UtcNow - $lastIterationEnd).TotalSeconds
            if ($gap -ge $ResumeGapSeconds) {
                Write-Log ("Wall-clock gap of {0:N1}s (suspend/resume?) - reopening display device" -f $gap) "WARN"
                try { $stream.Dispose() } catch {}
                $stream = $null
                $nextTickMs = $sw.Elapsed.TotalMilliseconds
            }
        }

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
            try {
                $stream.WriteTimeout = $WriteTimeoutMs
            } catch {
                Write-Log "Could not set write timeout: $_" "WARN"
            }
            $outputReportLength = [Math]::Max(13, $dev.GetMaxOutputReportLength())
            Write-Log "Display device opened (output report length: $outputReportLength, write timeout: ${WriteTimeoutMs}ms)"
            $lastIterationEnd = [DateTime]::UtcNow
            $nextTickMs = $sw.Elapsed.TotalMilliseconds
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

        $writeSw = [System.Diagnostics.Stopwatch]::StartNew()
        $stream.Write($buffer, 0, $buffer.Length)
        $writeSw.Stop()
        $consecutiveErrors = 0
        $lastIterationEnd = [DateTime]::UtcNow

        $writeMs = $writeSw.Elapsed.TotalMilliseconds
        if ($writeMs -gt $maxWriteMs) { $maxWriteMs = $writeMs }
        if ($writeMs -ge $SlowWriteMs) {
            Write-Log ("Slow HID write: {0:N0}ms" -f $writeMs) "WARN"
        }

        # A null sensor is encoded as 0xEE 0xEE 0xEE, which the display shows
        # as a blank field. Log the edges only, so a permanently dead sensor
        # cannot flood the log.
        if ($null -eq $cpu -or $null -eq $gpu) {
            $naStreak++
            if ($naStreak -eq 1) {
                $which = @()
                if ($null -eq $cpu) { $which += "CPU" }
                if ($null -eq $gpu) { $which += "GPU" }
                Write-Log "Sensor N/A for $($which -join '+') - sending blank (0xEE) to display" "WARN"
            }
        } elseif ($naStreak -gt 0) {
            Write-Log "Sensor readings recovered after $naStreak N/A frame(s)" "WARN"
            $naStreak = 0
        }

        # Log once per minute (avoid log spam)
        $now = Get-Date
        if (($now - $lastLog).TotalSeconds -ge 60) {
            $cpuStr = if ($null -ne $cpu) { "$([Math]::Round($cpu, 1))C" } else { "N/A" }
            $gpuStr = if ($null -ne $gpu) { "$([Math]::Round($gpu, 1))C" } else { "N/A" }
            $hexStr = ($payload | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
            Write-Log ("CPU=$cpuStr GPU=$gpuStr | bytes: $hexStr | peak write {0:N0}ms" -f $maxWriteMs)
            $lastLog = $now
            $maxWriteMs = 0.0
        }

        $nextTickMs += $periodMs
        $remainingMs = $nextTickMs - $sw.Elapsed.TotalMilliseconds
        if ($remainingMs -lt 1) {
            $nextTickMs = $sw.Elapsed.TotalMilliseconds
        } else {
            Start-Sleep -Milliseconds ([int]$remainingMs)
        }
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
        $delayMs = $backoffMs[[Math]::Min($consecutiveErrors - 1, $backoffMs.Count - 1)]
        Write-Log "Reconnecting in ${delayMs}ms (consecutive failures: $consecutiveErrors)" "WARN"
        Start-Sleep -Milliseconds $delayMs
        $lastIterationEnd = [DateTime]::UtcNow
        $nextTickMs = $sw.Elapsed.TotalMilliseconds
    }
}

# Cleanup
try { if ($stream) { $stream.Dispose() } } catch {}
try { $computer.Close() } catch {}
Write-Log "Exiting"
