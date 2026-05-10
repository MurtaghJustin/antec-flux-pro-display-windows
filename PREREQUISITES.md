# Prerequisites & Troubleshooting

This document explains what must be in place for the tool to work,
and how to diagnose problems if it isn't working.

**Quick check:** run `verify.ps1` — it tests everything automatically.

---

## 1. Hardware

| Requirement | Why | How to check |
|---|---|---|
| Antec display physically connected | Source of the USB device | `Get-PnpDevice -InstanceId "*VID_2022*PID_0522*"` |
| Internal USB hub powered | Device path | Look for "Generic USB Hub" in Device Manager |
| If using SATA-powered hub: SATA cable connected | Powers the hub | If missing, devices on hub disappear |

---

## 2. Software (required)

### 2.1 PawnIO (kernel driver)

**Why:** Reading Intel CPU temperature requires access to MSRs (Model-Specific Registers).
PawnIO is a small, signed kernel driver that provides this access safely.

**Required version:** 2.2.0 or later (Arrow Lake support)

**Verify:**
```powershell
sc.exe query PawnIO    # Should show STATE: 4 RUNNING
```

**Install if missing:**
```powershell
& .\PawnIO_setup.exe
# Or download latest from: https://github.com/namazso/PawnIO.Setup/releases
```

### 2.2 LibreHardwareMonitor library

The release archive includes the necessary DLLs in the `lhm/` folder.
If you accidentally deleted them, re-extract the release ZIP.

### 2.3 NVIDIA driver (for GPU temperature)

**Verify:**
```powershell
nvidia-smi
```

If `nvidia-smi` fails, install/repair your GPU driver.

---

## 3. System configuration

### 3.1 Scheduled task

The installer creates a Windows Scheduled Task that runs the tool as SYSTEM at every boot.

**Verify (as administrator):**
```powershell
Get-ScheduledTask -TaskName "AntecDisplay"
```

Should show:
- State: Ready or Running
- Principal.UserId: S-1-5-18 (NT AUTHORITY\SYSTEM)

**Recreate if missing:**
```powershell
cd D:\path\to\antec-display
.\install.ps1
```

### 3.2 PowerShell execution policy

The scheduled task uses `-ExecutionPolicy Bypass` so this isn't normally an issue.
If running scripts manually:
```powershell
Get-ExecutionPolicy
# Should be RemoteSigned, Bypass, or Unrestricted - not Restricted
```

---

## 4. Conflicts that block the tool

### 4.1 iUnity reinstalled

**Why this breaks things:** iUnity acquires the USB device exclusively, blocking our tool from writing.

**Verify:**
```powershell
Get-Service "Antec iUnity Service" -ErrorAction SilentlyContinue
Get-Process -Name "iunity*" -ErrorAction SilentlyContinue
```

**Fix:** Uninstall iUnity from Windows Settings > Apps.

### 4.2 Other vendor utilities

Some vendor tools (CPUID, AIDA64, OpenHardwareMonitor) load their own kernel drivers that may conflict with PawnIO. Stop them temporarily to test.

---

## 5. Symptoms & diagnoses

| Symptom | Likely cause | Fix |
|---|---|---|
| Display blank | Tool not running OR device disconnected | `schtasks /run /tn AntecDisplay` |
| Display shows EE/EE | Tool running but sensors return null | Restart-Service PawnIO; restart task |
| Display shows GPU but CPU says 0 | PawnIO not running | `Start-Service PawnIO` |
| Display works briefly then freezes | iUnity is running in background | Uninstall iUnity |
| `verify.ps1` fails on "task exists" | You're not running as admin | Re-run as administrator |

---

## 6. Quick recovery

**Tool not working — restart it:**
```powershell
# As administrator
schtasks /end /tn AntecDisplay
Start-Sleep 2
schtasks /run /tn AntecDisplay
Start-Sleep 5
Get-Content "$env:LOCALAPPDATA\AntecDisplay\antec_display.log" -Tail 5 -Encoding UTF8
```

**CPU temperature stuck at N/A:**
```powershell
# As administrator
Restart-Service PawnIO
schtasks /end /tn AntecDisplay
schtasks /run /tn AntecDisplay
```

**Reinstall everything from scratch:**
```powershell
# As administrator
cd D:\path\to\antec-display
.\install.ps1
```

---

## 7. When to file an issue

Open a GitHub issue if:
- `verify.ps1` shows failures you can't fix from PREREQUISITES.md
- The display shows wrong values consistently
- You see new errors in the log that aren't documented here

When filing, include:
1. Output of `verify.ps1`
2. Last 50 lines of log: `Get-Content "$env:LOCALAPPDATA\AntecDisplay\antec_display.log" -Tail 50 -Encoding UTF8`
3. Your CPU model and motherboard
4. Windows version: `winver`
