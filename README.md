# PC Cleanup & Health Check

A safe, double-click Windows tool that frees up disk space and memory so the
Claude desktop app (and everything else) runs smoother and crashes less.

## How to use

1. Download this folder (green **Code** button → **Download ZIP**) and unzip it.
2. Double-click **`Run-PCCleanup.bat`**.
3. Pick an option:
   - **1 – Health report**: shows free memory, disk space, uptime, and the apps using the most memory. Changes nothing.
   - **2 – Preview cleanup**: shows what *would* be deleted. Changes nothing.
   - **3 – Clean now**: does the cleanup.
   - **4 – Deep clean as Administrator**: also clears Windows' own temp files and the Windows Update download cache.

If Windows shows "Windows protected your PC", click **More info → Run anyway**
(it appears because the file was downloaded from the internet).

## What it cleans

| Item | Notes |
|---|---|
| Your temp files | Only files older than 1 day |
| Claude app cache | `Cache`, `Code Cache`, `GPUCache`, crash reports, logs. If Claude is open, it asks to close it and reopens it afterwards |
| Crash dumps & error reports | Leftovers from programs that crashed |
| Recycle Bin | **Always asks first** |
| Windows temp + Windows Update cache | Admin mode only; update cache asks first |
| DNS cache | Refreshed (can fix connection hiccups) |

## What it never touches

Your documents, photos, downloads, browser data, passwords, program settings,
your Claude login, or your Claude conversations (those live on Claude's servers).
No registry edits and no "tweaks": just deleting throwaway files.

A log of each run is saved in `%LOCALAPPDATA%\PCCleanup`.

## Biggest wins for stability

Cleanup helps, but these matter most if Claude crashes or freezes:

- **Restart your PC at least once a week.** The report warns you when it's been longer.
- **Keep at least 15–20% of your C: drive free.**
- **Close heavy apps and extra browser tabs** (the report lists the worst offenders) before long sessions.
- **Keep Windows and the Claude app updated.**
- If memory stays above ~85% used, the PC may simply need more RAM (8 GB minimum, 16 GB is comfortable).

## Advanced (PowerShell)

```powershell
.\PCCleanup.ps1 -ReportOnly   # health report only
.\PCCleanup.ps1 -DryRun       # preview
.\PCCleanup.ps1               # clean, with prompts
.\PCCleanup.ps1 -Yes          # clean, no prompts (e.g. for Task Scheduler)
```
