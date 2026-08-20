<#
.SYNOPSIS
    Batch-processes a Skater XL SoundMod folder with ffmpeg.

.DESCRIPTION
    Applies one varispeed pitch shift (-Semitones) to every audio file under
    -Source, excluding UI and Ragdoll subfolders. Resample-based, so it stays
    natural on transients.

    There is no loudness normalization: the game's mix relies on categories
    sitting at deliberately different levels (bearings under rolling, and so
    on), and flattening them destroys that. Use SoundModTuner.ps1 if you want
    per-category level and EQ control.

    Originals are never modified. Output mirrors the folder structure into
    <Source>_processed. Files in excluded folders and non-audio files are
    copied over unchanged, so the output folder is a complete drop-in mod.

    Sample rate, bit depth, channel count, and filenames are preserved.

.PARAMETER Semitones
    Pitch shift in semitones, -5 to +5. Positive = up.

.PARAMETER Limit
    Process only the first N files (for a quick A/B test). 0 = all files.

.EXAMPLE
    .\Process-SoundMod.ps1 -Semitones 1
    .\Process-SoundMod.ps1 -Semitones 1 -Source "C:\Mods\Sounds" -Limit 1
    .\Process-SoundMod.ps1 -Semitones -1.5

.NOTES
    Requires ffmpeg and ffprobe on PATH (https://ffmpeg.org or `winget install ffmpeg`).
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(-5.0, 5.0)]
    [double]$Semitones,

    [string]$Source = "",
    [string]$Dest   = "",

    [string[]]$ExcludeDirs = @("UI", "Ragdoll", "THESE WOULD GO IN RAGDOLL"),
    [int]$Limit = 0
)

function Write-Fatal {
    param([string]$Title, [string[]]$Detail)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Red
    Write-Host ""
    foreach ($line in $Detail) { Write-Host "  $line" -ForegroundColor Gray }
    Write-Host ""
    exit 1
}

# --- sanity checks --------------------------------------------------------
# Default pack sits next to the script, not in the current working directory.
if (-not $Source) { $Source = Join-Path $PSScriptRoot "Sounds" }

# Pack first: ffmpeg bootstrapping can pull a ~170 MB download, and it should
# not happen before we know there is anything to process.
if (-not (Test-Path $Source -PathType Container)) {
    Write-Fatal "No sound pack found." @(
        "Looked for: $Source"
        ""
        "Put your Skater XL sound pack in a folder named 'Sounds' next to this"
        "script, or pass -Source ""C:\path\to\Sounds"". Sound packs are not"
        "included in this repo."
    )
}
$Source = (Resolve-Path $Source).Path.TrimEnd('\')

$bootstrap = Join-Path $PSScriptRoot "bootstrap-ffmpeg.ps1"
if (Test-Path $bootstrap) { . $bootstrap; Initialize-FFmpeg }
foreach ($tool in "ffmpeg", "ffprobe") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Fatal "$tool not found." @(
            "The automatic download did not leave a working ffmpeg behind."
            "Install it manually and rerun:  winget install ffmpeg"
        )
    }
}
if (-not $Dest) { $Dest = $Source + "_processed" }

# --- collect files --------------------------------------------------------
$audioExt = ".wav", ".ogg", ".mp3", ".flac", ".aif", ".aiff"
$excludeRegex = "(^|\\)(" + (($ExcludeDirs | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")(\\|$)"

$allFiles = Get-ChildItem -Path $Source -Recurse -File
$targets = $allFiles | Where-Object {
    $rel = $_.FullName.Substring($Source.Length + 1)
    ($audioExt -contains $_.Extension.ToLower()) -and ($rel -notmatch $excludeRegex)
}
if ($Limit -gt 0) { $targets = @($targets | Select-Object -First $Limit) }
if (@($targets).Count -eq 0) { throw "No audio files to process under $Source" }

$ratio = [math]::Pow(2, $Semitones / 12)
Write-Host ""
Write-Host "Files to process : $(@($targets).Count)"
Write-Host "Pitch shift      : $Semitones st (rate x $([math]::Round($ratio, 4)))"
Write-Host "Output           : $Dest"
Write-Host ""

function Get-CodecArgs([string]$codec, [string]$ext) {
    if ($codec -like "pcm_*") { return @("-c:a", $codec) }   # keep exact bit depth
    switch ($ext) {
        ".ogg"  { return @("-c:a", "libvorbis", "-q:a", "6") }
        ".mp3"  { return @("-c:a", "libmp3lame", "-q:a", "2") }
        ".flac" { return @("-c:a", "flac") }
        default { return @("-c:a", "pcm_s16le") }
    }
}

# --- process --------------------------------------------------------------
$done = 0
$failed = @()
$processed = @{}

foreach ($f in $targets) {
    $rel = $f.FullName.Substring($Source.Length + 1)
    $outPath = Join-Path $Dest $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null

    # probe original format
    $probe = (& ffprobe -v error -select_streams a:0 `
        -show_entries stream=codec_name,sample_rate `
        -of csv=p=0 -- $f.FullName) -join ""
    $parts = $probe.Trim() -split ","
    if ($parts.Count -lt 2) { $failed += $rel; Write-Host "FAIL (probe) $rel"; continue }
    $codec = $parts[0]
    $sr    = [int]$parts[1]

    # build filter chain (pitch only)
    $chain = @()
    if ($Semitones -ne 0) {
        $newRate = [int][math]::Round($sr * $ratio)
        $chain += "asetrate=$newRate"
        $chain += "aresample=$sr"
    }
    if (@($chain).Count -eq 0) { $chain += "anull" }   # 0 st: pass-through
    $af = $chain -join ","

    $codecArgs = Get-CodecArgs $codec $f.Extension.ToLower()
    & ffmpeg -hide_banner -loglevel error -y -i $f.FullName `
        -af $af -ar $sr @codecArgs -- $outPath 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0 -and (Test-Path $outPath)) {
        $done++
        $processed[$f.FullName] = $true
        Write-Host "ok   $rel"
    } else {
        $failed += $rel
        Write-Host "FAIL $rel" -ForegroundColor Red
    }
}

# --- copy untouched files (excluded folders, non-audio) so Dest is drop-in
$copied = 0
if ($Limit -eq 0) {
    foreach ($f in $allFiles) {
        if ($processed.ContainsKey($f.FullName)) { continue }
        $rel = $f.FullName.Substring($Source.Length + 1)
        $outPath = Join-Path $Dest $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
        Copy-Item -Path $f.FullName -Destination $outPath -Force
        $copied++
    }
}

# --- summary --------------------------------------------------------------
Write-Host ""
Write-Host "Processed : $done"
Write-Host "Copied untouched (UI/Ragdoll/non-audio) : $copied"
if ($failed.Count -gt 0) {
    Write-Host "Failed    : $($failed.Count)" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}
Write-Host "Done -> $Dest"
