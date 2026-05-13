[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FolderPath,

    [switch]$NoBackup,
    [switch]$DryRun,

    # Regex applied to the codec name of the first audio track.
    # Default catches "TrueHD Atmos" - to broaden, pass e.g. -Filter 'TrueHD'.
    [string]$Filter = 'TrueHD Atmos',

    # CSV log path. Defaults to a timestamped file next to the target folder.
    [string]$LogPath = '',
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'

function Find-Mkvmerge {
    $candidates = @(
        'C:\Program Files\MKVToolNix\mkvmerge.exe',
        'C:\Program Files (x86)\MKVToolNix\mkvmerge.exe'
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command mkvmerge.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Format-Channels($n) {
    switch ([int]$n) {
        1 { '1.0' ; break }
        2 { '2.0' ; break }
        3 { '2.1' ; break }
        6 { '5.1' ; break }
        7 { '6.1' ; break }
        8 { '7.1' ; break }
        default { "${n}ch" }
    }
}

function Write-Err($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
}

function Get-RelativePath($base, $path) {
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $b = $base.TrimEnd($sep, '/') + $sep
    if ($path.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $path.Substring($b.Length)
    }
    return $path
}

function Format-CsvField($v) {
    if ($null -eq $v) { return '' }
    $s = "$v"
    if ($s -match '[",\r\n]') {
        return '"' + $s.Replace('"', '""') + '"'
    }
    return $s
}

function Write-LogRow($logFile, $fields) {
    if (-not $logFile) { return }
    $line = (($fields | ForEach-Object { Format-CsvField $_ }) -join ',')
    try {
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch {
        Write-Host "  (warning: log write failed: $_)" -ForegroundColor Yellow
    }
}

function Format-Track($a, $highlight) {
    $codec   = $a.codec
    $ch      = Format-Channels $a.properties.audio_channels
    $lang    = if ($a.properties.language) { $a.properties.language } else { 'und' }
    $title   = if ($a.properties.track_name) { '"' + $a.properties.track_name + '"' } else { '' }
    $default = if ($a.properties.default_track) { '[DEFAULT]' } else { '' }
    "  [{0,2}] {1,-24} {2,-5} {3,-4} {4,-30} {5}" -f $a.id, $codec, $ch, $lang, $title, $default
}

function Get-MkvInfo($mkvmerge, $filePath) {
    $jsonRaw = & $mkvmerge --identify --identification-format json $filePath 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    try { return ($jsonRaw -join "`n") | ConvertFrom-Json }
    catch { return $null }
}

function Invoke-Remux($mkvmerge, $file, $info, $chosenId, $noBackup, $dryRun) {
    $audioTracks    = @($info.tracks | Where-Object { $_.type -eq 'audio' })
    $videoTracks    = @($info.tracks | Where-Object { $_.type -eq 'video' })
    $subtitleTracks = @($info.tracks | Where-Object { $_.type -eq 'subtitles' })

    $orderParts = @()
    foreach ($v in $videoTracks)    { $orderParts += "0:$($v.id)" }
    $orderParts += "0:$chosenId"
    foreach ($a in $audioTracks)    { if ([int]$a.id -ne $chosenId) { $orderParts += "0:$($a.id)" } }
    foreach ($s in $subtitleTracks) { $orderParts += "0:$($s.id)" }
    $trackOrderArg = $orderParts -join ','

    $defaultArgs = @()
    foreach ($a in $audioTracks) {
        $flag = if ([int]$a.id -eq $chosenId) { '1' } else { '0' }
        $defaultArgs += '--default-track-flag'
        $defaultArgs += "$($a.id):$flag"
    }

    $tempFile   = "$($file.FullName).tmp"
    $backupFile = "$($file.FullName).bak"

    $mkvmergeArgs = @(
        '--output', $tempFile,
        '--track-order', $trackOrderArg
    ) + $defaultArgs + @($file.FullName)

    if ($dryRun) {
        return [pscustomobject]@{ Ok = $true; Elapsed = [TimeSpan]::Zero; Error = $null; DryRun = $true }
    }

    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }

    $start = Get-Date
    try {
        & $mkvmerge @mkvmergeArgs | Out-Null
        $exitCode = $LASTEXITCODE
    } catch {
        $elapsed = (Get-Date) - $start
        if (Test-Path -LiteralPath $tempFile -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        return [pscustomobject]@{ Ok = $false; Elapsed = $elapsed; Error = "mkvmerge could not start: $_"; DryRun = $false }
    }
    $elapsed = (Get-Date) - $start

    if ($exitCode -ne 0) {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        return [pscustomobject]@{ Ok = $false; Elapsed = $elapsed; Error = "mkvmerge exit $exitCode"; DryRun = $false }
    }

    if (-not (Test-Path -LiteralPath $tempFile)) {
        return [pscustomobject]@{ Ok = $false; Elapsed = $elapsed; Error = 'mkvmerge succeeded but output missing'; DryRun = $false }
    }

    try {
        if ($noBackup) {
            Remove-Item -LiteralPath $file.FullName -Force
        } else {
            if (Test-Path -LiteralPath $backupFile) {
                Remove-Item -LiteralPath $backupFile -Force
            }
            Rename-Item -LiteralPath $file.FullName -NewName ($file.Name + '.bak')
        }
        Rename-Item -LiteralPath $tempFile -NewName $file.Name
    } catch {
        return [pscustomobject]@{ Ok = $false; Elapsed = $elapsed; Error = "file swap failed: $_"; DryRun = $false }
    }

    return [pscustomobject]@{ Ok = $true; Elapsed = $elapsed; Error = $null; DryRun = $false }
}

# --- Locate mkvmerge ---
$mkvmerge = Find-Mkvmerge
if (-not $mkvmerge) {
    Write-Err "mkvmerge.exe not found."
    Write-Host "Install MKVToolNix from: https://mkvtoolnix.download/"
    exit 1
}

# --- Validate folder ---
if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
    Write-Err "Not a folder: $FolderPath"
    exit 1
}
$folder = Get-Item -LiteralPath $FolderPath

# --- Find MKVs ---
Write-Host ""
Write-Host "Folder: $($folder.FullName)" -ForegroundColor Cyan
Write-Host "Searching for .mkv files (recursive)..."
$mkvFiles = @(Get-ChildItem -LiteralPath $folder.FullName -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue)
Write-Host "Found $($mkvFiles.Count) .mkv files."
if ($mkvFiles.Count -eq 0) {
    Write-Host "Nothing to scan. Exiting."
    exit 0
}

# --- Choose filter interactively if not passed as a parameter ---
if (-not $PSBoundParameters.ContainsKey('Filter')) {
    Write-Host ""
    Write-Host "Filter by first audio track codec:"
    Write-Host "  [1] TrueHD Atmos        (Atmos only)"
    Write-Host "  [2] TrueHD              (any TrueHD, including Atmos)"
    Write-Host "  [3] DTS                 (DTS, DTS-HD Master Audio, etc.)"
    Write-Host "  [4] Any                 (all MKVs regardless of codec)"
    Write-Host ""
    $filterChoice = (Read-Host "Choice [1]").Trim()
    switch ($filterChoice) {
        '2' { $Filter = 'TrueHD' }
        '3' { $Filter = 'DTS' }
        '4' { $Filter = '.' }
        default { $Filter = 'TrueHD Atmos' }
    }
}

# --- Scan for candidates (first audio matches filter) ---
Write-Host ""
Write-Host "Scanning audio tracks (filter: codec matches /$Filter/)..."
$candidates = New-Object System.Collections.Generic.List[object]
$total = $mkvFiles.Count
for ($i = 0; $i -lt $total; $i++) {
    $f = $mkvFiles[$i]
    $pct = [int](($i + 1) * 100 / $total)
    Write-Progress -Activity "Scanning" -Status "$($i+1)/$total - $($f.Name)" -PercentComplete $pct

    $info = Get-MkvInfo $mkvmerge $f.FullName
    if (-not $info) { continue }

    $audioTracks = @($info.tracks | Where-Object { $_.type -eq 'audio' })
    if ($audioTracks.Count -eq 0) { continue }

    $firstAudio = $audioTracks[0]
    if ($firstAudio.codec -match $Filter) {
        $candidates.Add([pscustomobject]@{
            File         = $f
            Info         = $info
            AudioTracks  = $audioTracks
            FirstAudio   = $firstAudio
        }) | Out-Null
    }
}
Write-Progress -Activity "Scanning" -Completed

Write-Host ""
Write-Host "Matches: $($candidates.Count) of $total" -ForegroundColor Cyan
if ($candidates.Count -eq 0) {
    Write-Host "Nothing matched. Exiting."
    exit 0
}

# --- Show match summary ---
Write-Host ""
Write-Host "Movies with first audio matching /$Filter/:"
$idx = 1
foreach ($c in $candidates) {
    $rel = Get-RelativePath $folder.FullName $c.File.FullName
    $ch  = Format-Channels $c.FirstAudio.properties.audio_channels
    Write-Host ("  {0,3}. {1}   ({2} {3})" -f $idx, $rel, $c.FirstAudio.codec, $ch)
    $idx++
}
Write-Host ""

# --- Review phase: per-movie selection ---
Write-Host "Review each movie - pick a new first audio track, skip, or stop."
Write-Host ""

$queue = New-Object System.Collections.Generic.List[object]
$cancelled = $false
$reviewIdx = 0
foreach ($c in $candidates) {
    $reviewIdx++
    $rel = Get-RelativePath $folder.FullName $c.File.FullName

    Write-Host ""
    Write-Host ("[{0} of {1}] {2}" -f $reviewIdx, $candidates.Count, $rel) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Audio tracks:"
    foreach ($a in $c.AudioTracks) {
        Write-Host (Format-Track $a $false)
    }
    Write-Host ""

    $validIds = @($c.AudioTracks | ForEach-Object { [int]$_.id })
    $chosenId = $null
    $skip = $false
    $attempts = 0
    while ($attempts -lt 3) {
        $userInput = Read-Host "Track ID for new default, [s]kip, [q]uit review, [c]ancel all"
        $u = $userInput.Trim().ToLower()
        if ($u -eq '' -or $u -eq 's') { $skip = $true; break }
        if ($u -eq 'q')               { $skip = $true; $stopReview = $true; break }
        if ($u -eq 'c')               { $cancelled = $true; break }

        $parsed = 0
        if ([int]::TryParse($u, [ref]$parsed) -and ($validIds -contains $parsed)) {
            if ($parsed -eq [int]$c.FirstAudio.id) {
                Write-Host "  That's already the first track. Pick another, or skip." -ForegroundColor Yellow
                $attempts++
                continue
            }
            $chosenId = $parsed
            break
        }
        Write-Host "  Invalid. Valid track IDs: $($validIds -join ', '), or s/q/c." -ForegroundColor Yellow
        $attempts++
    }

    if ($cancelled) {
        Write-Host ""
        Write-Host "Cancelled. No changes made." -ForegroundColor Yellow
        exit 0
    }

    if ($skip) {
        Write-Host "  Skipped."
        if ($stopReview) {
            Write-Host "  Stopping review."
            break
        }
        continue
    }

    if ($null -eq $chosenId) {
        Write-Host "  Too many invalid inputs - skipping this file." -ForegroundColor Yellow
        continue
    }

    $chosenTrack = $c.AudioTracks | Where-Object { [int]$_.id -eq $chosenId } | Select-Object -First 1
    $queue.Add([pscustomobject]@{
        File        = $c.File
        Info        = $c.Info
        ChosenId    = $chosenId
        ChosenTrack = $chosenTrack
    }) | Out-Null
    $chosenCh = Format-Channels $chosenTrack.properties.audio_channels
    Write-Host "  Queued: move [$chosenId] $($chosenTrack.codec) $chosenCh to first." -ForegroundColor Green
}

# --- Show queue ---
Write-Host ""
Write-Host "============================================================"
Write-Host " Queue: $($queue.Count) file(s)" -ForegroundColor Cyan
Write-Host "============================================================"
if ($queue.Count -eq 0) {
    Write-Host "Queue is empty. Nothing to do."
    exit 0
}

$qi = 1
foreach ($q in $queue) {
    $rel = Get-RelativePath $folder.FullName $q.File.FullName
    $ch  = Format-Channels $q.ChosenTrack.properties.audio_channels
    Write-Host ("  {0,3}. {1}" -f $qi, $rel)
    Write-Host ("        -> [{0}] {1} {2}" -f $q.ChosenId, $q.ChosenTrack.codec, $ch)
    $qi++
}
Write-Host ""
if ($NoBackup) {
    Write-Host "Originals will be REPLACED (no .bak backups)." -ForegroundColor Yellow
} else {
    Write-Host "Each original will be backed up to <name>.mkv.bak."
}
if ($DryRun) {
    Write-Host "[DRY RUN] No files will actually be changed." -ForegroundColor Yellow
}
Write-Host ""

$go = Read-Host "Process queue? [Y/N]"
if ($go -notmatch '^[Yy]') {
    Write-Host "Cancelled. No changes made."
    exit 0
}

# --- Initialize log ---
$logFile = $null
if (-not $NoLog) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    if ($LogPath) {
        $logFile = $LogPath
    } else {
        $parent = Split-Path -Parent $folder.FullName
        if (-not $parent) { $parent = $folder.FullName }
        $safeName = ($folder.Name -replace '[\\/:*?"<>|]', '_')
        $logFile = Join-Path $parent "mkv-batch-reorder-$safeName-$stamp.csv"
    }
    try {
        $header = 'timestamp,relative_path,chosen_track_id,chosen_codec,chosen_channels,status,elapsed_seconds,error'
        Set-Content -LiteralPath $logFile -Value $header -Encoding UTF8
        Write-Host ""
        Write-Host "Log: $logFile" -ForegroundColor DarkGray
    } catch {
        Write-Host "Warning: could not create log file ($_). Continuing without log." -ForegroundColor Yellow
        $logFile = $null
    }
}

# --- Process queue ---
Write-Host ""
Write-Host "Processing..."
$results = New-Object System.Collections.Generic.List[object]
$batchStart = Get-Date
$n = 0
foreach ($q in $queue) {
    $n++
    $rel = Get-RelativePath $folder.FullName $q.File.FullName
    Write-Host ""
    Write-Host ("[{0}/{1}] {2}" -f $n, $queue.Count, $rel) -ForegroundColor Cyan
    $r = Invoke-Remux $mkvmerge $q.File $q.Info $q.ChosenId $NoBackup.IsPresent $DryRun.IsPresent
    $elapsedStr = '{0:D2}:{1:D2}' -f [int]$r.Elapsed.TotalMinutes, $r.Elapsed.Seconds
    $status = if ($r.DryRun) { 'dry-run' } elseif ($r.Ok) { 'ok' } else { 'failed' }
    if ($r.Ok) {
        if ($r.DryRun) {
            Write-Host "  [DRY RUN] would remux." -ForegroundColor Yellow
        } else {
            Write-Host "  ok ($elapsedStr)" -ForegroundColor Green
        }
    } else {
        Write-Host "  FAILED: $($r.Error)" -ForegroundColor Red
    }
    $results.Add([pscustomobject]@{ File = $q.File; Ok = $r.Ok; Error = $r.Error; Elapsed = $r.Elapsed }) | Out-Null

    Write-LogRow $logFile @(
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),
        $rel,
        $q.ChosenId,
        $q.ChosenTrack.codec,
        (Format-Channels $q.ChosenTrack.properties.audio_channels),
        $status,
        [int]$r.Elapsed.TotalSeconds,
        $r.Error
    )
}

$batchElapsed = (Get-Date) - $batchStart
$batchStr = '{0:D2}:{1:D2}' -f [int]$batchElapsed.TotalMinutes, $batchElapsed.Seconds
$okCount   = @($results | Where-Object { $_.Ok }).Count
$failCount = @($results | Where-Object { -not $_.Ok }).Count

Write-Host ""
Write-Host "============================================================"
Write-Host (" Done: {0} succeeded, {1} failed in {2}" -f $okCount, $failCount, $batchStr) -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "============================================================"

if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "Failed files:" -ForegroundColor Red
    foreach ($r in $results) {
        if (-not $r.Ok) {
            $rel = Get-RelativePath $folder.FullName $r.File.FullName
            Write-Host "  - $rel : $($r.Error)"
        }
    }
}

if ($logFile) {
    Write-Host ""
    Write-Host "Log written to:" -ForegroundColor DarkGray
    Write-Host "  $logFile"
}

if ($failCount -gt 0) { exit 1 } else { exit 0 }
