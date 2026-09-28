<#
.SYNOPSIS
    Virus & malware check for Windows, built on Microsoft Defender.

.DESCRIPTION
    1. Checks that virus protection is turned on and up to date.
    2. Updates Defender's virus definitions.
    3. Runs a Defender Quick or Full scan (Defender removes/quarantines what it finds).
    4. Lists every threat Defender has detected on this PC.
    5. Looks for common signs of hidden malware and REPORTS them (never deletes):
       programs running from temp folders, suspicious startup entries and
       scheduled tasks, Defender exclusions, hosts file and proxy changes.
    6. Optionally checks and repairs damaged Windows system files (DISM + SFC).

    Needs Administrator rights; it asks for them automatically.

.PARAMETER ScanType
    Quick, Full, or None (skip the Defender scan, only run the other checks).

.PARAMETER Yes
    Answer "yes" to every prompt.
#>
[CmdletBinding()]
param(
    [ValidateSet('Ask', 'Quick', 'Full', 'None')]
    [string]$ScanType = 'Ask',
    [switch]$Yes
)

$ErrorActionPreference = 'SilentlyContinue'
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:Warnings = 0

# ---------- helpers ----------

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    $script:LogLines.Add("[$(Get-Date -Format 'HH:mm:ss')] $Message")
}

function Write-Flag {
    param([string]$Message)
    $script:Warnings++
    Write-Log "  [!] $Message" Yellow
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

# Places legit software rarely runs from, but malware loves.
$SuspiciousPathPattern = '(?i)(\\AppData\\Local\\Temp\\|\\Windows\\Temp\\|\\Users\\Public\\|\\Downloads\\|\\\$Recycle\.Bin\\|\\AppData\\Roaming\\[^\\]+\.(exe|dll|scr)$|\\ProgramData\\[^\\]+\.(exe|dll|scr)$)'

# Command-line tricks commonly used by malware to hide or download payloads.
$SuspiciousCommandPattern = '(?i)(\s-e(nc|ncodedcommand)?\s+[A-Za-z0-9+/=]{20,}|-w(indowstyle)?\s+h(idden)?\b|\bmshta\b|\bwscript\b|\bcscript\b|\.(vbs|vbe|jse?|hta|wsf)\b|frombase64string|downloadstring|downloadfile|invoke-webrequest|\biwr\b|\biex\b|invoke-expression|certutil.*-urlcache|bitsadmin.*/transfer|regsvr32.*(/i:http|scrobj)|rundll32.*\\(temp|public|appdata)\\)'

# Pulls the program path out of a command line like
#   "C:\Program Files\App\app.exe" --flag     or     C:\Tools\app.exe /min
function Get-ExePath {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $null }
    $cmd = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($cmd -match '^"([^"]+)"') { return $Matches[1] }
    if ($cmd -match '^(.+?\.(exe|com|bat|cmd|scr|dll|ps1|vbs|js))(\s|,|$)') { return $Matches[1] }
    return ($cmd -split '\s+')[0]
}

$script:SigCache = @{}
function Get-SignatureStatus {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 'Missing' }
    if (-not $script:SigCache.ContainsKey($Path)) {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        $script:SigCache[$Path] = if ($sig.Status -eq 'Valid') {
            "Signed: $($sig.SignerCertificate.GetNameInfo('SimpleName', $false))"
        } else { 'Unsigned' }
    }
    return $script:SigCache[$Path]
}

# Returns a list of reasons an entry looks suspicious (empty = looks fine).
function Get-SuspicionReasons {
    param([string]$CommandLine)
    $reasons = @()
    $exe = Get-ExePath $CommandLine
    $sig = Get-SignatureStatus $exe
    if ($CommandLine -match $SuspiciousCommandPattern) { $reasons += 'uses a script/hidden-window trick' }
    if ($exe -match $SuspiciousPathPattern) {
        $reasons += 'runs from a temp/public/downloads folder'
        if ($sig -eq 'Unsigned') { $reasons += 'not digitally signed' }
    }
    if ($sig -eq 'Missing' -and $exe -match '\\') { $reasons += 'program file no longer exists' }
    return $reasons
}

# ---------- 1. protection status ----------

function Test-ProtectionStatus {
    Write-Log ""
    Write-Log "=== 1. VIRUS PROTECTION STATUS ===" Cyan

    $other = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct |
             Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' }
    foreach ($av in $other) { Write-Log "  Other antivirus installed: $($av.displayName)" }

    $status = Get-MpComputerStatus
    if (-not $status) {
        if ($other) {
            Write-Log "  Microsoft Defender is off because another antivirus is in charge." Yellow
            Write-Log "  Run a full scan from that program as well." Yellow
        } else {
            Write-Flag "Microsoft Defender isn't responding and no other antivirus was found."
            Write-Log  "      Open Windows Security > Virus & threat protection and turn it on." Yellow
        }
        return $false
    }

    $checks = [ordered]@{
        'Antivirus enabled'        = $status.AntivirusEnabled
        'Real-time protection'     = $status.RealTimeProtectionEnabled
        'Behavior monitoring'      = $status.BehaviorMonitorEnabled
        'Download/attachment scan' = $status.IOAVProtectionEnabled
        'Tamper protection'        = $status.IsTamperProtected
    }
    foreach ($name in $checks.Keys) {
        if ($checks[$name]) { Write-Log ("  {0,-26} ON" -f $name) Green }
        else { Write-Flag ("{0,-26} OFF  (turn it on in Windows Security)" -f $name) }
    }

    $age = $status.AntivirusSignatureAge
    if ($age -gt 3) { Write-Flag "Virus definitions are $age days old (will update now)" }
    else { Write-Log ("  {0,-26} {1} day(s) old" -f 'Virus definitions', $age) Green }
    return $true
}

# ---------- 2+3. update and scan ----------

function Invoke-DefenderScan {
    Write-Log ""
    Write-Log "=== 2. UPDATING VIRUS DEFINITIONS ===" Cyan
    Update-MpSignature -ErrorAction SilentlyContinue
    $status = Get-MpComputerStatus
    Write-Log ("  Definitions version {0}, updated {1}" -f $status.AntivirusSignatureVersion, $status.AntivirusSignatureLastUpdated) Green

    $type = $ScanType
    if ($type -eq 'Ask') {
        Write-Host ""
        Write-Host "  Q = Quick scan (5-15 min, checks where malware usually hides)"
        Write-Host "  F = Full scan  (1-3+ hours, checks every file; best if you suspect an infection)"
        Write-Host "  S = Skip the scan"
        $answer = Read-Host "  Choose Q, F or S"
        $type = switch -Regex ($answer) { '^[fF]' { 'Full' } '^[sS]' { 'None' } default { 'Quick' } }
    }
    if ($type -eq 'None') { Write-Log "  Scan skipped." DarkGray; return }

    Write-Log ""
    Write-Log "=== 3. RUNNING $($type.ToUpper()) SCAN (please wait, don't close this window) ===" Cyan
    $start = Get-Date
    Start-MpScan -ScanType "${type}Scan"
    $mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
    Write-Log "  Scan finished in $mins minutes." Green
}

# ---------- 4. detected threats ----------

function Show-Threats {
    Write-Log ""
    Write-Log "=== 4. THREATS FOUND BY DEFENDER ===" Cyan
    $detections = @(Get-MpThreatDetection)
    if ($detections.Count -eq 0) { Write-Log "  None. No viruses or malware detected." Green; return }

    $threats = @{}
    Get-MpThreat | ForEach-Object { $threats[$_.ThreatID] = $_ }
    foreach ($d in $detections | Sort-Object InitialDetectionTime -Descending) {
        $t = $threats[$d.ThreatID]
        $name = if ($t) { $t.ThreatName } else { "Threat ID $($d.ThreatID)" }
        $sev  = if ($t) { @{1='Low';2='Moderate';4='High';5='Severe'}[[int]$t.SeverityID] } else { '?' }
        $state = if ($d.ActionSuccess) { 'handled (removed/quarantined)' } else { 'NOT YET HANDLED' }
        $color = if ($d.ActionSuccess) { 'Gray' } else { 'Red' }
        if (-not $d.ActionSuccess) { $script:Warnings++ }
        Write-Log ("  {0:yyyy-MM-dd}  {1}  [{2}]  {3}" -f $d.InitialDetectionTime, $name, $sev, $state) $color
        foreach ($r in $d.Resources | Select-Object -First 3) { Write-Log "      $r" DarkGray }
    }
    if ($detections | Where-Object { -not $_.ActionSuccess }) {
        Write-Log ""
        Write-Log "  Open Windows Security > Virus & threat protection > Protection history" Yellow
        Write-Log "  and choose 'Remove' for anything still active, then restart the PC." Yellow
    }
}

# ---------- 5. hidden-malware checks (report only) ----------

function Test-RunningProcesses {
    Write-Log ""
    Write-Log "--- Programs running from risky locations ---" Cyan
    $found = 0
    $procs = Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath }
    foreach ($p in $procs) {
        $reasons = @()
        if ($p.ExecutablePath -match $SuspiciousPathPattern) {
            $reasons += 'running from a temp/public/downloads folder'
            if ((Get-SignatureStatus $p.ExecutablePath) -eq 'Unsigned') { $reasons += 'not digitally signed' }
        }
        if ($p.CommandLine -match $SuspiciousCommandPattern) { $reasons += 'uses a script/hidden-window trick' }
        if ($reasons) {
            $found++
            Write-Flag "$($p.Name) (PID $($p.ProcessId)): $($reasons -join ', ')"
            Write-Log  "      $($p.ExecutablePath)" DarkGray
        }
    }
    if ($found -eq 0) { Write-Log "  Nothing suspicious." Green }
}

function Test-StartupEntries {
    Write-Log ""
    Write-Log "--- Programs that start with Windows ---" Cyan
    $entries = @()
    $keys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    foreach ($key in $keys) {
        $props = Get-ItemProperty -Path $key
        if (-not $props) { continue }
        foreach ($prop in $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
            $entries += [pscustomobject]@{ Name = $prop.Name; Command = [string]$prop.Value }
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    $folders = [Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')
    foreach ($folder in $folders) {
        foreach ($f in Get-ChildItem -LiteralPath $folder -File -Force | Where-Object { $_.Name -ne 'desktop.ini' }) {
            $cmd = $f.FullName
            if ($f.Extension -eq '.lnk') {
                $lnk = $shell.CreateShortcut($f.FullName)
                $cmd = "`"$($lnk.TargetPath)`" $($lnk.Arguments)"
            }
            $entries += [pscustomobject]@{ Name = $f.Name; Command = $cmd }
        }
    }

    foreach ($e in $entries) {
        $reasons = Get-SuspicionReasons $e.Command
        if ($reasons) {
            Write-Flag "$($e.Name): $($reasons -join ', ')"
            Write-Log  "      $($e.Command)" DarkGray
        } else {
            Write-Log ("  {0,-30} {1}" -f $e.Name, (Get-SignatureStatus (Get-ExePath $e.Command)))
        }
    }
    if (-not $entries) { Write-Log "  No startup programs." Green }
}

function Test-ScheduledTasks {
    Write-Log ""
    Write-Log "--- Scheduled tasks ---" Cyan
    $found = 0
    $tasks = Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' }
    foreach ($t in $tasks) {
        foreach ($a in $t.Actions | Where-Object { $_.Execute }) {
            $cmd = "`"$($a.Execute.Trim('"'))`" $($a.Arguments)"
            $reasons = Get-SuspicionReasons $cmd
            if ($reasons) {
                $found++
                Write-Flag "$($t.TaskPath)$($t.TaskName): $($reasons -join ', ')"
                Write-Log  "      $cmd" DarkGray
            }
        }
    }
    if ($found -eq 0) { Write-Log "  Checked $(@($tasks).Count) non-Microsoft tasks, nothing suspicious." Green }
}

function Test-SystemSettings {
    Write-Log ""
    Write-Log "--- Settings malware often changes ---" Cyan
    $clean = $true

    $pref = Get-MpPreference
    if ($pref) {
        $exclusions = @($pref.ExclusionPath) + @($pref.ExclusionProcess) + @($pref.ExclusionExtension) |
                      Where-Object { $_ -and $_ -notmatch '^N/A' }
        foreach ($x in $exclusions) {
            $clean = $false
            Write-Flag "Defender is told to skip: $x  (remove it in Windows Security if you didn't add it)"
        }
    }

    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $lines = Get-Content -LiteralPath $hosts | Where-Object { $_ -match '^\s*[^#\s]' } |
             Where-Object { $_ -notmatch '^\s*(127\.0\.0\.1|::1)\s+localhost\s*$' }
    if ($lines) {
        $clean = $false
        Write-Flag "Hosts file has $(@($lines).Count) custom entries (can redirect websites):"
        $lines | Select-Object -First 10 | ForEach-Object { Write-Log "      $_" DarkGray }
    }

    $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($inet.ProxyEnable -eq 1 -or $inet.AutoConfigURL) {
        $clean = $false
        Write-Flag "A web proxy is set: $($inet.ProxyServer)$($inet.AutoConfigURL)  (fine if work/school set it; otherwise suspicious)"
    }

    $uac = (Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA
    if ($uac -eq 0) { $clean = $false; Write-Flag "User Account Control (UAC) is turned off." }

    $fw = Get-NetFirewallProfile | Where-Object { -not $_.Enabled }
    foreach ($p in $fw) { $clean = $false; Write-Flag "Windows Firewall is OFF for the $($p.Name) network profile." }

    if ($clean) { Write-Log "  Defender exclusions, hosts file, proxy, UAC and firewall all look normal." Green }
}

# ---------- 6. system file repair ----------

function Repair-SystemFiles {
    Write-Log ""
    Write-Log "=== 6. WINDOWS SYSTEM FILE CHECK ===" Cyan
    if (-not (Confirm-Step "Check and repair damaged Windows system files? (takes 10-30 min)")) {
        Write-Log "  Skipped." DarkGray
        return
    }
    Write-Log "  Step 1/2: DISM (repairs the Windows component store)..." Cyan
    & DISM.exe /Online /Cleanup-Image /RestoreHealth
    Write-Log "  Step 2/2: SFC (checks and fixes system files)..." Cyan
    & sfc.exe /scannow
    Write-Log "  System file check finished. Restart the PC to complete any repairs." Green
}

# ---------- main ----------

if (-not (Test-IsAdmin)) {
    Write-Host "Requesting Administrator rights (needed to scan the whole system)..." -ForegroundColor Yellow
    $argList = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`" -ScanType $ScanType"
    if ($Yes) { $argList += ' -Yes' }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

Write-Host ""
Write-Host "  Virus & Malware Check" -ForegroundColor White
Write-Host "  Uses Microsoft Defender to scan and remove threats; other checks only report." -ForegroundColor DarkGray

$defenderOk = Test-ProtectionStatus
if ($defenderOk) {
    Invoke-DefenderScan
    Show-Threats
}

Write-Log ""
Write-Log "=== 5. CHECKING FOR SIGNS OF HIDDEN MALWARE ===" Cyan
Test-RunningProcesses
Test-StartupEntries
Test-ScheduledTasks
Test-SystemSettings

Repair-SystemFiles

Write-Log ""
Write-Log "=== SUMMARY ===" Cyan
if ($script:Warnings -eq 0) {
    Write-Log "  No problems found. Your PC looks clean." Green
} else {
    Write-Log "  $($script:Warnings) item(s) need a look (marked [!] above)." Yellow
    Write-Log "  A [!] means 'worth checking', not 'definitely a virus'. If you don't recognize" Yellow
    Write-Log "  an item, don't delete it by hand: share the log and ask for help first." Yellow
}

$logDir = Join-Path $env:LOCALAPPDATA 'PCCleanup'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("security-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
$script:LogLines | Set-Content -LiteralPath $logFile -Encoding UTF8
Write-Host ""
Write-Host "Log saved to $logFile" -ForegroundColor DarkGray
