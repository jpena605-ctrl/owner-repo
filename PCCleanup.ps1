<#
.SYNOPSIS
    Safe PC cleanup + health check, tuned to keep the Claude desktop app running smoothly.

.DESCRIPTION
    - Shows a health report: free memory, free disk space, uptime, top memory users.
    - Deletes only disposable files: temp folders, Claude app caches, crash dumps,
      and (optionally) the Recycle Bin and Windows Update download cache.
    - Never touches documents, settings, passwords, or Claude conversations/login.

.PARAMETER DryRun
    Show what would be cleaned without deleting anything.

.PARAMETER Yes
    Answer "yes" to every prompt (useful for scheduled runs).

.PARAMETER ReportOnly
    Only show the health report; do not clean anything.

.EXAMPLE
    .\PCCleanup.ps1 -DryRun
    .\PCCleanup.ps1
    .\PCCleanup.ps1 -Yes
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$ReportOnly
)

$ErrorActionPreference = 'SilentlyContinue'
$script:TotalFreed = 0
$script:LogLines = New-Object System.Collections.Generic.List[string]

# ---------- helpers ----------

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    $script:LogLines.Add("[$(Get-Date -Format 'HH:mm:ss')] $Message")
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$([int]$Bytes) B"
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Confirm-Step {
    param([string]$Question)
    if ($Yes) { return $true }
    $answer = Read-Host "$Question [y/N]"
    return ($answer -match '^(y|yes)$')
}

function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [double]$sum
}

# Deletes the *contents* of a folder (not the folder itself). Files that are
# in use are skipped silently, which is normal for temp folders.
function Clear-Folder {
    param(
        [string]$Label,
        [string]$Path,
        [int]$OlderThanDays = 0
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }

    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $files = Get-ChildItem -LiteralPath $Path -Recurse -Force -File |
             Where-Object { $OlderThanDays -eq 0 -or $_.LastWriteTime -lt $cutoff }
    $before = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $before) { $before = 0 }

    if ($before -eq 0) {
        Write-Log ("  {0,-34} already clean" -f $Label) DarkGray
        return
    }

    if ($DryRun) {
        Write-Log ("  {0,-34} would free {1}" -f $Label, (Format-Size $before)) Yellow
        $script:TotalFreed += $before
        return
    }

    foreach ($f in $files) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
    # Remove now-empty subfolders (deepest first).
    Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    $remaining = ($files | Where-Object { Test-Path -LiteralPath $_.FullName } |
                  Measure-Object -Property Length -Sum).Sum
    if ($null -eq $remaining) { $remaining = 0 }
    $freed = $before - $remaining
    $script:TotalFreed += $freed
    $note = if ($remaining -gt 0) { " (some files in use, skipped)" } else { "" }
    Write-Log ("  {0,-34} freed {1}{2}" -f $Label, (Format-Size $freed), $note) Green
}

# ---------- health report ----------

function Show-HealthReport {
    Write-Log ""
    Write-Log "=== PC HEALTH REPORT ===" Cyan

    $os = Get-CimInstance Win32_OperatingSystem
    $totalRam = [double]$os.TotalVisibleMemorySize * 1KB
    $freeRam  = [double]$os.FreePhysicalMemory * 1KB
    $usedPct  = [math]::Round((1 - $freeRam / $totalRam) * 100)
    $ramColor = if ($usedPct -ge 85) { 'Red' } elseif ($usedPct -ge 70) { 'Yellow' } else { 'Green' }
    Write-Log ("Memory:  {0} free of {1}  ({2}% used)" -f (Format-Size $freeRam), (Format-Size $totalRam), $usedPct) $ramColor

    $sysDrive = $env:SystemDrive
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'"
    $freePct = [math]::Round($disk.FreeSpace / $disk.Size * 100)
    $diskColor = if ($freePct -lt 10) { 'Red' } elseif ($freePct -lt 20) { 'Yellow' } else { 'Green' }
    Write-Log ("Disk {0}  {1} free of {2}  ({3}% free)" -f $sysDrive, (Format-Size $disk.FreeSpace), (Format-Size $disk.Size), $freePct) $diskColor

    $uptime = (Get-Date) - $os.LastBootUpTime
    $upColor = if ($uptime.TotalDays -ge 7) { 'Yellow' } else { 'Green' }
    Write-Log ("Uptime:  {0} days {1} hours" -f [int][math]::Floor($uptime.TotalDays), $uptime.Hours) $upColor

    Write-Log ""
    Write-Log "Top 10 apps using memory:" Cyan
    Get-Process |
        Group-Object ProcessName |
        ForEach-Object {
            [pscustomobject]@{
                Name  = $_.Name
                Count = $_.Count
                Bytes = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum
            }
        } |
        Sort-Object Bytes -Descending |
        Select-Object -First 10 |
        ForEach-Object {
            $procs = if ($_.Count -gt 1) { " ($($_.Count) processes)" } else { "" }
            Write-Log ("  {0,-28} {1,10}{2}" -f $_.Name, (Format-Size $_.Bytes), $procs)
        }

    $claude = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
    if ($claude) {
        $claudeMem = ($claude | Measure-Object WorkingSet64 -Sum).Sum
        Write-Log ""
        Write-Log ("Claude app is running: {0} across {1} processes" -f (Format-Size $claudeMem), $claude.Count) Cyan
    }

    # Tips
    Write-Log ""
    Write-Log "Tips:" Cyan
    $tips = 0
    if ($usedPct -ge 70) {
        Write-Log "  - Memory is getting full. Close browser tabs and apps you are not using" Yellow
        Write-Log "    (see the list above) before long Claude sessions." Yellow
        $tips++
    }
    if ($freePct -lt 20) {
        Write-Log "  - Disk is low. Windows slows down and apps crash when C: is nearly full." Yellow
        Write-Log "    Run the cleanup, then uninstall unused programs (Settings > Apps)." Yellow
        $tips++
    }
    if ($uptime.TotalDays -ge 7) {
        Write-Log "  - PC hasn't restarted in a week. A restart clears memory leaks and" Yellow
        Write-Log "    finishes pending updates. (Shut Down with Fast Startup doesn't count.)" Yellow
        $tips++
    }
    if ($totalRam -lt 8GB) {
        Write-Log "  - This PC has under 8 GB of RAM. Keep other apps closed while using Claude." Yellow
        $tips++
    }
    if ($tips -eq 0) { Write-Log "  - Everything looks healthy." Green }
}

# ---------- cleanup ----------

function Invoke-Cleanup {
    $isAdmin = Test-IsAdmin
    Write-Log ""
    $mode = if ($DryRun) { 'DRY RUN - nothing will be deleted' } else { 'CLEANING' }
    Write-Log "=== $mode ===" Cyan

    # 1. User temp files (only older than 1 day, so running installers aren't disturbed)
    Clear-Folder -Label 'Your temp files'          -Path $env:TEMP -OlderThanDays 1

    # 2. Claude desktop app caches. Only cache folders: your login, settings and
    #    conversations are NOT stored here and are not touched.
    $claudeDir = Join-Path $env:APPDATA 'Claude'
    if (Test-Path -LiteralPath $claudeDir) {
        $running = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
        $doClaude = $true
        if ($running -and -not $DryRun) {
            if (Confirm-Step "Claude is open. Close it now to clear its cache? (It will reopen after)") {
                $claudeExe = ($running | Select-Object -First 1).Path
                $running | Stop-Process -Force
                Start-Sleep -Seconds 3
            } else {
                $doClaude = $false
                Write-Log "  Claude app cache                   skipped (Claude is open)" DarkGray
            }
        }
        if ($doClaude) {
            foreach ($sub in 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache',
                             'DawnWebGPUCache', 'Crashpad\reports', 'logs') {
                Clear-Folder -Label "Claude: $sub" -Path (Join-Path $claudeDir $sub)
            }
        }
    }

    # 3. Crash dumps and error reports
    Clear-Folder -Label 'App crash dumps'          -Path (Join-Path $env:LOCALAPPDATA 'CrashDumps')
    Clear-Folder -Label 'Windows error reports'    -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive')
    Clear-Folder -Label 'Windows error queue'      -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue')

    # 4. Admin-only locations
    if ($isAdmin) {
        Clear-Folder -Label 'Windows temp files'   -Path (Join-Path $env:SystemRoot 'Temp') -OlderThanDays 1
        Clear-Folder -Label 'System error reports' -Path (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')

        $wuPath = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
        $wuSize = Get-FolderSize $wuPath
        if ($wuSize -gt 100MB -and (Confirm-Step "Clear Windows Update download cache ($(Format-Size $wuSize))? Safe; updates re-download if needed")) {
            if (-not $DryRun) { Stop-Service wuauserv -Force }
            Clear-Folder -Label 'Windows Update cache' -Path $wuPath
            if (-not $DryRun) { Start-Service wuauserv }
        }
    } else {
        Write-Log "  (Run as administrator to also clean Windows temp and update caches)" DarkGray
    }

    # 5. Recycle Bin (always asks unless -Yes)
    $shell = New-Object -ComObject Shell.Application
    $bin = $shell.Namespace(10)
    $binItems = @($bin.Items())
    if ($binItems.Count -gt 0) {
        $binSize = ($binItems | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum
        if (Confirm-Step "Empty the Recycle Bin ($($binItems.Count) items, $(Format-Size $binSize))?") {
            if ($DryRun) {
                Write-Log ("  {0,-34} would free {1}" -f 'Recycle Bin', (Format-Size $binSize)) Yellow
            } else {
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                Write-Log ("  {0,-34} freed {1}" -f 'Recycle Bin', (Format-Size $binSize)) Green
            }
            $script:TotalFreed += $binSize
        }
    }

    # 6. Refresh DNS cache (fixes some "can't connect" issues)
    if (-not $DryRun) {
        Clear-DnsClientCache
        Write-Log "  DNS cache                          refreshed" Green
    }

    Write-Log ""
    $verb = if ($DryRun) { 'Would free' } else { 'Freed' }
    Write-Log ("{0} a total of {1}" -f $verb, (Format-Size $script:TotalFreed)) Cyan

    # Reopen Claude if we closed it
    if ($claudeExe -and (Test-Path -LiteralPath $claudeExe)) {
        Write-Log "Reopening Claude..." Cyan
        Start-Process -FilePath $claudeExe
    }
}

# ---------- main ----------

Write-Host ""
Write-Host "  PC Cleanup & Health Check" -ForegroundColor White
Write-Host "  Only removes temporary/cache files. Your files, settings and Claude chats are safe." -ForegroundColor DarkGray

Show-HealthReport
if (-not $ReportOnly) { Invoke-Cleanup }

$logDir = Join-Path $env:LOCALAPPDATA 'PCCleanup'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("cleanup-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
$script:LogLines | Set-Content -LiteralPath $logFile -Encoding UTF8
Write-Host ""
Write-Host "Log saved to $logFile" -ForegroundColor DarkGray
