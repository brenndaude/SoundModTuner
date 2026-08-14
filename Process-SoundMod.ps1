<#
.SYNOPSIS
    Batch-processes a Skater XL SoundMod folder with ffmpeg.

.DESCRIPTION
    For every audio file under -Source (excluding UI and Ragdoll subfolders):
      1. Varispeed pitch shift (-Semitones arg)   - resample-based, natural on transients
      2. Optional peak normalize (-Normalize)     - uniform -1 dBFS ceiling, off by default

    Originals are never modified. Output mirrors the folder structure into
    <Source>_processed. Files in excluded folders and non-audio files are
    copied over unchanged, so the output folder is a complete drop-in mod.

    Sample rate, bit depth, channel count, and filenames are preserved.

.PARAMETER Semitones
    Pitch shift in semitones, -5 to +5. Positive = up.

.PARAMETER Normalize
    Opt-in: peak-normalize each file to -TargetPeakDb (default -1 dBFS) after pitching.

.PARAMETER Limit
    Process only the first N files (for a quick A/B test). 0 = all files.

.EXAMPLE
    .\Process-SoundMod.ps1 -Semitones 1
    .\Process-SoundMod.ps1 -Semitones 1 -Source "C:\Mods\Sounds" -Limit 1
    .\Process-SoundMod.ps1 -Semitones -1.5 -Normalize

.NOTES
    Requires ffmpeg and ffprobe on PATH (https://ffmpeg.org or `winget install ffmpeg`).
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(-5.0, 5.0)]
    [double]$Semitones,

    [string]$Source = ".\Sounds",
    [string]$Dest   = "",

    [switch]$Normalize,
    [double]$TargetPeakDb = -1,

    [string[]]$ExcludeDirs = @("UI", "Ragdoll", "THESE WOULD GO IN RAGDOLL"),
    [int]$Limit = 0
)

# --- sanity checks --------------------------------------------------------
$bootstrap = Join-Path $PSScriptRoot "bootstrap-ffmpeg.ps1"
if (Test-Path $bootstrap) { . $bootstrap; Initialize-FFmpeg }
foreach ($tool in "ffmpeg", "ffprobe") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found on PATH. Install ffmpeg first."
    }
}
if (-not (Test-Path $Source -PathType Container)) {
    throw "Source folder not found: $Source"
}
$Source = (Resolve-Path $Source).Path.TrimEnd('\')
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
Write-Host "Normalize        : $(if ($Normalize) { "$TargetPeakDb dBFS peak" } else { 'off' })"
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
    if (@($chain).Count -eq 0) { $chain += "anull" }   # 0 st, no normalize: pass-through
    $af = $chain -join ","

    $afFinal = $af
    if ($Normalize) {
        # extra pass: measure post-pitch peak, then apply exact gain to hit target
        $detect = (& ffmpeg -hide_banner -nostats -i $f.FullName `
            -af "$af,volumedetect" -f null - 2>&1) | Out-String
        $m = [regex]::Match($detect, "max_volume:\s*(-?[\d.]+)\s*dB")
        if ($m.Success) {
            $gain = [math]::Round($TargetPeakDb - [double]$m.Groups[1].Value, 2)
            $afFinal = "$af,volume=${gain}dB"
        }
    }

    # pass 2: render
    $codecArgs = Get-CodecArgs $codec $f.Extension.ToLower()
    & ffmpeg -hide_banner -loglevel error -y -i $f.FullName `
        -af $afFinal -ar $sr @codecArgs -- $outPath 2>&1 | Out-Null

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
