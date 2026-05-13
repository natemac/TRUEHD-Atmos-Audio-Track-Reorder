[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FilePath,

    [switch]$NoBackup,
    [switch]$DryRun
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

# --- Locate mkvmerge ---
$mkvmerge = Find-Mkvmerge
if (-not $mkvmerge) {
    Write-Err "mkvmerge.exe not found."
    Write-Host "Install MKVToolNix from: https://mkvtoolnix.download/"
    exit 1
}

# --- Validate file ---
if (-not (Test-Path -LiteralPath $FilePath)) {
    Write-Err "File not found: $FilePath"
    exit 1
}

$file = Get-Item -LiteralPath $FilePath
if ($file.Extension -inotmatch '^\.mkv$') {
    Write-Err "Not an MKV file: $($file.Name)"
    Write-Host "This tool only handles .mkv files."
    exit 1
}

# --- Identify tracks ---
Write-Host ""
Write-Host "File: $($file.Name)" -ForegroundColor Cyan
Write-Host ""

$jsonRaw = & $mkvmerge --identify --identification-format json $file.FullName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "mkvmerge failed to identify the file:"
    Write-Host ($jsonRaw -join "`n")
    exit 1
}

try {
    $info = ($jsonRaw -join "`n") | ConvertFrom-Json
} catch {
    Write-Err "Could not parse mkvmerge output: $_"
    exit 1
}

$audioTracks    = @($info.tracks | Where-Object { $_.type -eq 'audio' })
$videoTracks    = @($info.tracks | Where-Object { $_.type -eq 'video' })
$subtitleTracks = @($info.tracks | Where-Object { $_.type -eq 'subtitles' })

if ($audioTracks.Count -eq 0) {
    Write-Err "No audio tracks in this file. Nothing to do."
    exit 1
}

# --- Display tracks ---
Write-Host "Audio tracks:"
foreach ($a in $audioTracks) {
    $codec    = $a.codec
    $ch       = Format-Channels $a.properties.audio_channels
    $lang     = if ($a.properties.language) { $a.properties.language } else { 'und' }
    $title    = if ($a.properties.track_name) { '"' + $a.properties.track_name + '"' } else { '' }
    $default  = if ($a.properties.default_track) { '[DEFAULT]' } else { '' }
    $line = "  [{0,2}] {1,-24} {2,-5} {3,-4} {4,-30} {5}" -f $a.id, $codec, $ch, $lang, $title, $default
    Write-Host $line
}
Write-Host ""

if ($audioTracks.Count -eq 1) {
    Write-Host "Only one audio track present - nothing to reorder."
    exit 0
}

# --- Prompt for selection ---
$validIds = @($audioTracks | ForEach-Object { [int]$_.id })
$chosenId = $null
$attempts = 0
while ($attempts -lt 3) {
    $userInput = Read-Host "Which audio track should be the new default? Enter track ID"
    $parsed = 0
    if ([int]::TryParse($userInput, [ref]$parsed) -and ($validIds -contains $parsed)) {
        $chosenId = $parsed
        break
    }
    Write-Host "  Invalid track ID. Valid IDs: $($validIds -join ', ')" -ForegroundColor Yellow
    $attempts++
}

if ($null -eq $chosenId) {
    Write-Err "Too many invalid attempts. Exiting."
    exit 1
}

$chosen = $audioTracks | Where-Object { [int]$_.id -eq $chosenId } | Select-Object -First 1
$chosenCodec = $chosen.codec
$chosenCh    = Format-Channels $chosen.properties.audio_channels

# --- Summary + confirm ---
Write-Host ""
Write-Host "Will move track [$chosenId] $chosenCodec $chosenCh to be the first audio track and set it as default."
if ($NoBackup) {
    Write-Host "Original will be replaced (no backup)."
} else {
    Write-Host "Original will be backed up to: $($file.Name).bak"
}
Write-Host "This will take 1-3 minutes depending on file size. No re-encoding."
if ($DryRun) { Write-Host "[DRY RUN] No changes will be made." -ForegroundColor Yellow }
Write-Host ""

$response = Read-Host "Proceed? [Y/N]"
if ($response -notmatch '^[Yy]') {
    Write-Host "Cancelled. No changes made."
    exit 0
}

# --- Build track order ---
$orderParts = @()
foreach ($v in $videoTracks)    { $orderParts += "0:$($v.id)" }
$orderParts += "0:$chosenId"
foreach ($a in $audioTracks)    { if ([int]$a.id -ne $chosenId) { $orderParts += "0:$($a.id)" } }
foreach ($s in $subtitleTracks) { $orderParts += "0:$($s.id)" }

$trackOrderArg = $orderParts -join ','

# --- Build default-flag args ---
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

if ($DryRun) {
    Write-Host ""
    Write-Host "[DRY RUN] Would run:"
    Write-Host "  `"$mkvmerge`""
    foreach ($arg in $mkvmergeArgs) {
        Write-Host "    $arg"
    }
    exit 0
}

# --- Pre-flight: temp file collision ---
if (Test-Path -LiteralPath $tempFile) {
    Write-Host "Removing stale temp file: $tempFile" -ForegroundColor Yellow
    Remove-Item -LiteralPath $tempFile -Force
}

# --- Remux ---
Write-Host ""
Write-Host "Remuxing..." -ForegroundColor Cyan
$start = Get-Date

& $mkvmerge @mkvmergeArgs
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Err "mkvmerge failed with exit code $exitCode"
    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
    exit $exitCode
}

if (-not (Test-Path -LiteralPath $tempFile)) {
    Write-Err "mkvmerge reported success but the output file is missing: $tempFile"
    exit 1
}

# --- Swap files ---
try {
    if ($NoBackup) {
        Remove-Item -LiteralPath $file.FullName -Force
    } else {
        if (Test-Path -LiteralPath $backupFile) {
            Remove-Item -LiteralPath $backupFile -Force
        }
        Rename-Item -LiteralPath $file.FullName -NewName ($file.Name + '.bak')
    }
    Rename-Item -LiteralPath $tempFile -NewName $file.Name
} catch {
    Write-Err "Failed to swap files: $_"
    Write-Host "Temp file preserved at: $tempFile"
    exit 1
}

$elapsed = (Get-Date) - $start
$elapsedStr = '{0:D2}:{1:D2}' -f [int]$elapsed.TotalMinutes, $elapsed.Seconds

Write-Host ""
Write-Host "Done in $elapsedStr" -ForegroundColor Green
Write-Host ""
Write-Host "New audio track order:"
$newOrder = @($chosen) + @($audioTracks | Where-Object { [int]$_.id -ne $chosenId })
$pos = 1
foreach ($a in $newOrder) {
    $codec   = $a.codec
    $ch      = Format-Channels $a.properties.audio_channels
    $lang    = if ($a.properties.language) { $a.properties.language } else { 'und' }
    $title   = if ($a.properties.track_name) { '"' + $a.properties.track_name + '"' } else { '' }
    $default = if ([int]$a.id -eq $chosenId) { '[DEFAULT]' } else { '' }
    $line = "  {0}. {1,-24} {2,-5} {3,-4} {4,-30} {5}" -f $pos, $codec, $ch, $lang, $title, $default
    Write-Host $line
    $pos++
}
Write-Host ""

exit 0
