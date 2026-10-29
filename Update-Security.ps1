<#
.SYNOPSIS
    Installs every security-relevant update on this PC in one go, with a live status screen.

.DESCRIPTION
    Checks four places, builds one queue, then works through it while showing what's done,
    what's running now and what's next:

      Defender  Microsoft Defender virus definitions (skipped if another antivirus is in charge)
      Windows   Windows Update: security, critical and rollup updates only. Drivers, feature
                upgrades, previews and optional updates are left alone.
      App       Every app winget can update. App updates are where most security fixes for
                browsers, PDF readers, runtimes and chat apps arrive, and winget can't tell a
                security fix from a cosmetic one, so all of them are included. Browsers and
                other internet-facing apps go first. Use -ExcludeApps or -SkipApps to opt out.
      Office    Microsoft 365 / Office (Click-to-Run), if installed

    Asks for administrator rights if it doesn't have them. Keeps the PC awake while it runs.
    Writes a log to %TEMP%\SecurityUpdate-<date>.log.

.PARAMETER CreateShortcut
    Put a "Security Update" icon on the desktop that runs this script when double-clicked.

.PARAMETER ListOnly
    Show what would be updated, then stop without installing anything.

.PARAMETER SkipWindowsUpdate
    Leave Windows Update out.

.PARAMETER SkipApps
    Leave winget apps out.

.PARAMETER ExcludeApps
    winget IDs to leave alone, e.g. -ExcludeApps Spotify.Spotify,Valve.Steam

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-Security.ps1

.EXAMPLE
    .\Update-Security.ps1 -ListOnly

.EXAMPLE
    .\Update-Security.ps1 -CreateShortcut
#>
[CmdletBinding()]
param(
    [switch]$CreateShortcut,
    [switch]$ListOnly,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipApps,
    [string[]]$ExcludeApps = @()
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

# Windows Update classifications to install (these IDs are the same in every language).
$WindowsClassifications = @{
    '0FA1201D-4330-4FA8-8AE9-B877473B6441' = 'Security'
    'E6CF1350-C01B-414D-A61F-263D14D133B4' = 'Critical'
    '28BC880E-0592-4CBF-8F95-C79B17911D5F' = 'Rollup'    # includes the Malicious Software Removal Tool
}

# Apps that face the internet or open files from it. They're updated before everything else.
$HighExposureApps = 'Chrome|Firefox|Edge|Brave|Opera|Vivaldi|Thunderbird|Java|JDK|JRE|Temurin|Zulu|Corretto|' +
    'DotNet|VCRedist|Adobe|Acrobat|Reader|Foxit|Zoom|Teams|Slack|Discord|Skype|Telegram|WhatsApp|Signal|' +
    '7zip|7-Zip|WinRAR|VLC|Python|NodeJS|Git\.Git|PuTTY|WinSCP|FileZilla|OpenSSH|PowerShell|Notepad\+\+|' +
    'LibreOffice|OpenVPN|WireGuard|TeamViewer|AnyDesk'

# ---------------------------------------------------------------------------
# Desktop icon
# ---------------------------------------------------------------------------

if ($CreateShortcut) {
    Unblock-File -Path $PSCommandPath -ErrorAction SilentlyContinue   # so a downloaded copy isn't blocked
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Security Update.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,73"   # the blue and yellow shield
    $lnk.Description = 'Install all security updates for Windows, Defender, apps and Office'
    $lnk.Save()

    # Tick "Run as administrator" on the shortcut, so it opens straight into one admin window.
    $bytes = [IO.File]::ReadAllBytes($lnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [IO.File]::WriteAllBytes($lnkPath, $bytes)

    Write-Host "Done. Double-click 'Security Update' on your desktop to run it." -ForegroundColor Green
    Write-Host 'Right-click it and choose "Pin to Start" or "Pin to taskbar" if you want it there too.'
    return
}

# ---------------------------------------------------------------------------
# Run as administrator
# ---------------------------------------------------------------------------

# Accept both -ExcludeApps a,b and the single "a,b" string that the elevated relaunch passes.
$ExcludeApps = @($ExcludeApps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Asking for administrator rights...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    if ($ListOnly) { $argList += '-ListOnly' }
    if ($SkipWindowsUpdate) { $argList += '-SkipWindowsUpdate' }
    if ($SkipApps) { $argList += '-SkipApps' }
    if ($ExcludeApps.Count) { $argList += '-ExcludeApps'; $argList += "`"$($ExcludeApps -join ',')`"" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

$LogPath = Join-Path $env:TEMP ('SecurityUpdate-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$Queue = New-Object System.Collections.ArrayList
$RebootNeeded = $false
$Spin = '|', '/', '-', '\'
$NowRow = $null
$Width = 79

function Write-Log([string]$Message) {
    Add-Content -Path $LogPath -Value ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Message)
}

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max - 3) + '...'
}

function New-QueueItem([string]$Kind, [string]$Name, [string]$Detail, $Data, [scriptblock]$Run) {
    [pscustomobject]@{ Kind = $Kind; Name = $Name; Detail = $Detail; Data = $Data; Run = $Run; Status = 'Pending'; Note = '' }
}

function Get-NowText($Item, [string]$Extra) {
    '   >> {0,-8} {1}   {2}' -f $Item.Kind, $Item.Name, $Extra
}

# Rewrites the "NOW" line of the dashboard in place, so the spinner and timer move.
function Update-NowLine([string]$Text) {
    if ($null -eq $script:NowRow) { return }
    try {
        $back = [Console]::CursorTop
        [Console]::SetCursorPosition(0, $script:NowRow)
        Write-Host ((Limit-Text $Text $script:Width).PadRight($script:Width)) -ForegroundColor Yellow -NoNewline
        [Console]::SetCursorPosition(0, $back)
    } catch { }
}

# Runs a program with its output captured, animating the NOW line until it exits.
function Invoke-External($Item, [string]$FilePath, [string[]]$Arguments, [string]$Phase) {
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle   # without this, Windows PowerShell 5.1 sometimes loses the exit code
        $t0 = Get-Date
        $i = 0
        while (-not $p.WaitForExit(250)) {
            Update-NowLine (Get-NowText $Item ('{0} {1}  {2:mm\:ss}' -f $Spin[$i % 4], $Phase, ((Get-Date) - $t0)))
            $i++
        }
        $p.WaitForExit()
        $text = @(Get-Content $out, $err -ErrorAction SilentlyContinue) -join "`n"
        if ($p.ExitCode -ne 0) { Write-Log "$FilePath $Arguments exited $($p.ExitCode):`n$text" }
        [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $text }
    } finally {
        Remove-Item $out, $err -ErrorAction SilentlyContinue
    }
}

function Write-QueueLine($Item) {
    $tag, $color = switch ($Item.Status) {
        'OK'      { '[OK]', 'Green' }
        'Failed'  { '[!!]', 'Red' }
        'Skipped' { '[--]', 'DarkYellow' }
        default   { '[..]', 'Gray' }
    }
    $note = if ($Item.Note) { $Item.Note } else { $Item.Detail }
    Write-Host (Limit-Text ('   {0} {1,-8} {2}   {3}' -f $tag, $Item.Kind, $Item.Name, $note) $script:Width) -ForegroundColor $color
}

function Show-Dashboard([string]$NowText) {
    try { $script:Width = [Math]::Max(60, [Math]::Min([Console]::WindowWidth - 1, 120)) } catch { $script:Width = 79 }
    $w = $script:Width
    $total = $Queue.Count
    $finished = @($Queue | Where-Object { $_.Status -in 'OK', 'Failed', 'Skipped' })
    $pending = @($Queue | Where-Object Status -eq 'Pending')
    $pct = if ($total) { [int][Math]::Floor(100 * $finished.Count / $total) } else { 100 }
    $fill = [int][Math]::Floor(40 * $pct / 100)
    $elapsed = '{0:hh\:mm\:ss}' -f ((Get-Date) - $StartTime)

    Clear-Host
    Write-Host ''
    Write-Host ('  SECURITY UPDATE' + ('elapsed ' + $elapsed).PadLeft($w - 17)) -ForegroundColor Cyan
    Write-Host ('  ' + ('=' * ($w - 2))) -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '  [' -NoNewline
    Write-Host ('#' * $fill) -ForegroundColor Green -NoNewline
    Write-Host ('.' * (40 - $fill)) -ForegroundColor DarkGray -NoNewline
    Write-Host (']  {0,3}%   {1} of {2} done' -f $pct, $finished.Count, $total)
    Write-Host ('  Installed {0}   Failed {1}   Skipped {2}   Restart needed: {3}' -f `
        @($finished | Where-Object Status -eq 'OK').Count,
        @($finished | Where-Object Status -eq 'Failed').Count,
        @($finished | Where-Object Status -eq 'Skipped').Count,
        $(if ($script:RebootNeeded) { 'yes' } else { 'no' })) -ForegroundColor Gray

    Write-Host ''
    Write-Host '  DONE' -ForegroundColor White
    if (-not $finished.Count) { Write-Host '     nothing yet' -ForegroundColor DarkGray }
    if ($finished.Count -gt 8) { Write-Host ('     ... {0} earlier' -f ($finished.Count - 8)) -ForegroundColor DarkGray }
    $finished | Select-Object -Last 8 | ForEach-Object { Write-QueueLine $_ }

    Write-Host ''
    Write-Host '  NOW' -ForegroundColor White
    try { $script:NowRow = [Console]::CursorTop } catch { $script:NowRow = $null }
    Write-Host (Limit-Text $NowText $w) -ForegroundColor Yellow

    Write-Host ''
    Write-Host '  UP NEXT' -ForegroundColor White
    if (-not $pending.Count) { Write-Host '     nothing left' -ForegroundColor DarkGray }
    $pending | Select-Object -First 6 | ForEach-Object { Write-QueueLine $_ }
    if ($pending.Count -gt 6) { Write-Host ('     ... and {0} more' -f ($pending.Count - 6)) -ForegroundColor DarkGray }
    Write-Host ''
}

function Write-Step([int]$Number, [string]$Text) {
    Write-Host ('  [{0}/4] {1}... ' -f $Number, $Text) -NoNewline
}

# ---------------------------------------------------------------------------
# What needs updating
# ---------------------------------------------------------------------------

function Find-DefenderUpdate {
    try { $status = Get-MpComputerStatus } catch { return 'not available' }
    if (-not $status.AntivirusEnabled) { return 'another antivirus is in charge, skipped' }
    $mpcmd = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (-not (Test-Path $mpcmd)) { return 'not available' }

    $detail = 'definitions {0}, {1} day(s) old' -f $status.AntivirusSignatureVersion, $status.AntivirusSignatureAge
    [void]$Queue.Add((New-QueueItem 'Defender' 'Virus definitions' $detail $mpcmd {
        param($q)
        $r = Invoke-External $q $q.Data @('-SignatureUpdate') 'downloading definitions'
        if ($r.ExitCode -ne 0) { $q.Status = 'Failed'; $q.Note = "MpCmdRun exit code $($r.ExitCode)"; return }
        $q.Note = 'now ' + (Get-MpComputerStatus).AntivirusSignatureVersion
    }))
    $detail
}

function Find-WindowsUpdates {
    $script:WuSession = New-Object -ComObject Microsoft.Update.Session
    $searcher = $WuSession.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

    $found = @()
    $ignored = 0
    foreach ($u in $result.Updates) {
        $class = $null
        foreach ($c in $u.Categories) {
            if ($WindowsClassifications.ContainsKey($c.CategoryID.ToUpper())) { $class = $WindowsClassifications[$c.CategoryID.ToUpper()] }
        }
        if ($u.Title -match 'antimalware platform') { $class = 'Defender' }
        if (-not $class -or $u.BrowseOnly -or $u.Title -match 'Preview') { $ignored++; continue }
        $found += [pscustomobject]@{ Update = $u; Class = $class; Severity = [string]$u.MsrcSeverity }
    }

    # Most severe first.
    $rank = @{ Critical = 0; Important = 1; Moderate = 2; Low = 3 }
    $found = $found | Sort-Object { if ($rank.ContainsKey($_.Severity)) { $rank[$_.Severity] } else { 4 } }

    foreach ($f in $found) {
        $sizeMb = [Math]::Round($f.Update.MaxDownloadSize / 1MB)
        $detail = (@($f.Severity, $f.Class, "$sizeMb MB") | Where-Object { $_ }) -join ', '
        [void]$Queue.Add((New-QueueItem 'Windows' $f.Update.Title $detail $f.Update {
            param($q)
            $u = $q.Data
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
            if (-not $u.IsDownloaded) {
                Update-NowLine (Get-NowText $q ('downloading ({0})...' -f $q.Detail))
                $downloader = $script:WuSession.CreateUpdateDownloader()
                $downloader.Updates = $coll
                $dr = $downloader.Download()
                if ($dr.ResultCode -notin 2, 3) { $q.Status = 'Failed'; $q.Note = "download failed (code $($dr.ResultCode))"; return }
            }
            Update-NowLine (Get-NowText $q 'installing... big updates can take 20+ minutes, this is normal')
            $installer = $script:WuSession.CreateUpdateInstaller()
            $installer.Updates = $coll
            $ir = $installer.Install()
            if ($ir.RebootRequired) { $script:RebootNeeded = $true }
            switch ($ir.ResultCode) {
                2 { $q.Note = if ($ir.RebootRequired) { 'installed, restart to finish' } else { 'installed' } }
                3 { $q.Note = 'installed with warnings' }
                default { $q.Status = 'Failed'; $q.Note = 'install failed (0x{0:X8})' -f $ir.GetUpdateResult(0).HResult }
            }
        }))
    }
    '{0} to install, {1} non-security/optional left alone' -f @($found).Count, $ignored
}

# Reads the table that `winget upgrade` prints. Column positions come from the header line,
# so this works whatever language winget is in.
function Get-WingetUpgradesFromText {
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $raw = & $script:Winget upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    } finally { [Console]::OutputEncoding = $prev }

    # winget draws spinners with carriage returns; keep only what's left visible on each line.
    $lines = @($raw -split "`n" | ForEach-Object {
        $seg = @($_ -split "`r" | Where-Object { $_.Trim() }) | Select-Object -Last 1
        if ($seg) { $seg.TrimEnd() } else { '' }
    })
    $sep = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{10,}$') { $sep = $i; break } }
    if ($sep -lt 0 -or $sep -ge $lines.Count - 1) { return }

    $starts = @([regex]::Matches($lines[$sep - 1], '\S+') | ForEach-Object { $_.Index })
    if ($starts.Count -lt 4) { return }
    $col = {
        param($line, $n)
        if ($starts[$n] -ge $line.Length) { return '' }
        $end = if ($n + 1 -lt $starts.Count) { [Math]::Min($starts[$n + 1], $line.Length) } else { $line.Length }
        $line.Substring($starts[$n], $end - $starts[$n]).Trim()
    }

    foreach ($line in $lines[($sep + 1)..($lines.Count - 1)]) {
        if (-not $line.Trim()) { break }   # a second table (pinned apps) follows a blank line
        $id = & $col $line 1
        $available = & $col $line 3
        if (-not $id -or -not $available -or $id -match '\s') { continue }
        [pscustomobject]@{ Name = (& $col $line 0); Id = $id; Version = (& $col $line 2); Available = $available }
    }
}

function Find-AppUpdates {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $cmd) { return 'winget not installed (get "App Installer" from the Microsoft Store), skipped' }
    $script:Winget = $cmd.Source

    $apps = $null
    if (Get-Module -ListAvailable Microsoft.WinGet.Client) {
        try {
            Import-Module Microsoft.WinGet.Client
            $apps = @(Get-WinGetPackage | Where-Object IsUpdateAvailable | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Id = $_.Id; Version = $_.InstalledVersion; Available = $_.AvailableVersions[0] }
            })
        } catch { $apps = $null }
    }
    if ($null -eq $apps) { $apps = @(Get-WingetUpgradesFromText) }

    $truncated = @($apps | Where-Object { $_.Id.EndsWith([string][char]0x2026) })
    $excluded = @($apps | Where-Object { $_.Id -in $ExcludeApps })
    $apps = @($apps | Where-Object { $_ -notin $truncated -and $_ -notin $excluded })
    foreach ($t in $truncated) { Write-Log "Skipped $($t.Name): winget cut its ID short. Widen the window and run again." }

    $sorted = @($apps | Where-Object { $_.Id -match $HighExposureApps -or $_.Name -match $HighExposureApps }) +
              @($apps | Where-Object { $_.Id -notmatch $HighExposureApps -and $_.Name -notmatch $HighExposureApps })
    foreach ($a in $sorted) {
        [void]$Queue.Add((New-QueueItem 'App' $a.Name ('{0} -> {1}' -f $a.Version, $a.Available) $a {
            param($q)
            $wa = @('upgrade', '--id', $q.Data.Id, '--exact', '--silent', '--accept-package-agreements',
                    '--accept-source-agreements', '--disable-interactivity')
            $r = Invoke-External $q $script:Winget $wa 'downloading and installing'
            switch ($r.ExitCode) {
                0           { $q.Note = 'now ' + $q.Data.Available }
                -1978334967 { $q.Note = 'updated, restart to finish'; $script:RebootNeeded = $true }   # 0x8A150109
                -1978335189 { $q.Status = 'Skipped'; $q.Note = 'already up to date' }                  # 0x8A15002B
                default     { $q.Status = 'Failed'; $q.Note = 'winget error 0x{0:X8}' -f $r.ExitCode }
            }
        }))
    }
    $msg = '{0} app(s) to update' -f $sorted.Count
    if ($excluded.Count) { $msg += ", $($excluded.Count) excluded" }
    if ($truncated.Count) { $msg += ", $($truncated.Count) skipped (see log)" }
    $msg
}

function Find-OfficeUpdate {
    $c2r = Join-Path $env:CommonProgramFiles 'microsoft shared\ClickToRun\OfficeC2RClient.exe'
    if (-not (Test-Path $c2r)) { return 'not installed' }
    [void]$Queue.Add((New-QueueItem 'Office' 'Microsoft 365 / Office' 'check and install updates' $c2r {
        param($q)
        $r = Invoke-External $q $q.Data @('/update', 'user', 'updatepromptuser=false', 'forceappshutdown=false', 'displaylevel=false') 'starting Office update'
        if ($r.ExitCode -ne 0) { $q.Status = 'Failed'; $q.Note = "OfficeC2RClient exit code $($r.ExitCode)"; return }
        $q.Note = 'update started, Office finishes it in the background'
    }))
    'found'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$StartTime = Get-Date
Write-Log 'Started'

# Keep the PC from sleeping while updates run.
try {
    Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    [void][Win32.Power]::SetThreadExecutionState(0x80000001)   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
} catch { }

Clear-Host
Write-Host ''
Write-Host '  SECURITY UPDATE - checking what this PC needs' -ForegroundColor Cyan
Write-Host ''

$checks = @(
    @{ Text = 'Microsoft Defender'; Skip = $false; Find = { Find-DefenderUpdate } }
    @{ Text = 'Windows Update (can take a few minutes)'; Skip = $SkipWindowsUpdate; Find = { Find-WindowsUpdates } }
    @{ Text = 'Apps (winget)'; Skip = $SkipApps; Find = { Find-AppUpdates } }
    @{ Text = 'Microsoft Office'; Skip = $false; Find = { Find-OfficeUpdate } }
)
$n = 0
foreach ($c in $checks) {
    $n++
    Write-Step $n $c.Text
    if ($c.Skip) { Write-Host 'skipped' -ForegroundColor DarkGray; continue }
    try {
        $msg = & $c.Find
        Write-Host $msg -ForegroundColor Green
        Write-Log "$($c.Text): $msg"
    } catch {
        Write-Host ('could not check: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Log "$($c.Text) check failed: $($_.Exception.Message)"
    }
}

Write-Host ''
if (-not $Queue.Count) {
    Write-Host '  Everything is already up to date.' -ForegroundColor Green
    return
}

try { $Width = [Math]::Max(60, [Math]::Min([Console]::WindowWidth - 1, 120)) } catch { }
Write-Host ('  The plan, in order ({0} items):' -f $Queue.Count) -ForegroundColor White
$n = 0
foreach ($q in $Queue) {
    $n++
    Write-Host (Limit-Text ('  {0,3}. {1,-8} {2}   {3}' -f $n, $q.Kind, $q.Name, $q.Detail) $Width)
}
Write-Host ''

if ($ListOnly) {
    Write-Host '  -ListOnly was given, so nothing was installed.' -ForegroundColor DarkGray
    return
}

Write-Host '  Starting in 10 seconds. Press Ctrl+C to cancel. Save your work: some apps may close while they update.' -ForegroundColor Yellow
Start-Sleep -Seconds 10

foreach ($q in $Queue) {
    $q.Status = 'Running'
    Show-Dashboard (Get-NowText $q 'starting...')
    $t0 = Get-Date
    try {
        & $q.Run $q
    } catch {
        $q.Status = 'Failed'
        $q.Note = $_.Exception.Message
    }
    if ($q.Status -eq 'Running') { $q.Status = 'OK' }
    $q.Note = ('{0} ({1:mm\:ss})' -f $q.Note, ((Get-Date) - $t0)).Trim()
    Write-Log ('{0,-7} {1,-8} {2}: {3}' -f $q.Status, $q.Kind, $q.Name, $q.Note)
}

$NowRow = $null
Show-Dashboard '   All done.'
try { [void][Win32.Power]::SetThreadExecutionState(0x80000000) } catch { }

$failed = @($Queue | Where-Object Status -eq 'Failed')
Write-Host ('  Finished in {0:hh\:mm\:ss}.' -f ((Get-Date) - $StartTime)) -ForegroundColor Cyan
if ($failed.Count) {
    Write-Host ''
    Write-Host '  These did not install:' -ForegroundColor Red
    foreach ($f in $failed) { Write-Host ('   - {0}: {1}' -f $f.Name, $f.Note) -ForegroundColor Red }
    Write-Host '  An app often fails because it is open. Close it and run this script again;' -ForegroundColor Gray
    Write-Host '  everything that already succeeded will be skipped.' -ForegroundColor Gray
}
Write-Host ''
Write-Host "  Log: $LogPath" -ForegroundColor DarkGray
Write-Log 'Finished'

if ($RebootNeeded) {
    Write-Host ''
    Write-Host '  A restart is needed to finish installing. Updates are not protecting you until you restart.' -ForegroundColor Yellow
    $answer = Read-Host '  Restart now? (y/N)'
    if ($answer -match '^(y|yes)$') { Restart-Computer -Force }
}
