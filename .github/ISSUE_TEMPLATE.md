# Issue template

**Before opening, please check:**
- [ ] I ran `verify.ps1` and read the output
- [ ] I read `PREREQUISITES.md` for my symptom
- [ ] I checked the [closed issues](../issues?q=is%3Aissue+is%3Aclosed) for similar problems

---

## Symptom

What's wrong? (display blank / wrong values / freezes / can't install / etc.)

## Hardware

- CPU model:
- Motherboard model:
- GPU model:
- Case (Antec model + display version):

## Software

- Windows version (run `winver`):
- PawnIO version (`sc.exe query PawnIO`):
- iUnity currently installed? (yes/no)

## Logs

Output of `verify.ps1`:

```
(paste here)
```

Last 50 lines of the tool log:

```powershell
Get-Content "$env:LOCALAPPDATA\AntecDisplay\antec_display.log" -Tail 50 -Encoding UTF8
```

```
(paste here)
```

## Steps already tried

- [ ] Restarted the scheduled task: `schtasks /run /tn AntecDisplay`
- [ ] Restarted PawnIO: `Restart-Service PawnIO`
- [ ] Ran `install.ps1` again as administrator
- [ ] Rebooted the computer
- [ ] Other: ...
