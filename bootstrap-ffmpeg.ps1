<#
.SYNOPSIS
    Makes ffmpeg/ffprobe available, downloading a portable build if needed.

.DESCRIPTION
    Dot-source this file, then call Initialize-FFmpeg. Resolution order:
      1. <script folder>\bin\ffmpeg.exe (previously downloaded) - prepended to PATH
      2. ffmpeg/ffprobe already on PATH - used as-is
      3. Neither: downloads the latest static win64 build (~170 MB, one time)
         from BtbN/FFmpeg-Builds GitHub releases into <script folder>\bin

    Windows PowerShell 5.1 compatible.
#>

$script:FFmpegZipUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip"

function Initialize-FFmpeg {
    $binDir       = Join-Path $PSScriptRoot "bin"
    $localFFmpeg  = Join-Path $binDir "ffmpeg.exe"
    $localFFprobe = Join-Path $binDir "ffprobe.exe"

    if ((Test-Path $localFFmpeg) -and (Test-Path $localFFprobe)) {
        $env:PATH = "$binDir;$env:PATH"
        return
    }
    if ((Get-Command ffmpeg -ErrorAction SilentlyContinue) -and
        (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
        return
    }

    Write-Host ""
    Write-Host "ffmpeg not found - downloading a portable build (~170 MB, one time only)..."
    Write-Host "This can take a few minutes depending on your connection."

    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $oldPP = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    $tmpZip = Join-Path $env:TEMP "ffmpeg-download.zip"
    $tmpDir = Join-Path $env:TEMP "ffmpeg-extract"
    try {
        Invoke-WebRequest -Uri $script:FFmpegZipUrl -OutFile $tmpZip -UseBasicParsing
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
        Write-Host "Extracting..."
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        foreach ($exe in "ffmpeg.exe", "ffprobe.exe") {
            $found = Get-ChildItem $tmpDir -Recurse -Filter $exe | Select-Object -First 1
            if (-not $found) { throw "$exe missing from downloaded archive" }
            Copy-Item $found.FullName (Join-Path $binDir $exe) -Force
        }
        $lic = Get-ChildItem $tmpDir -Recurse -Include "LICENSE*" -File | Select-Object -First 1
        if ($lic) { Copy-Item $lic.FullName (Join-Path $binDir "FFMPEG-LICENSE.txt") -Force }
        $env:PATH = "$binDir;$env:PATH"
        Write-Host "ffmpeg ready in $binDir"
        Write-Host ""
    } catch {
        throw ("Automatic ffmpeg download failed: $($_.Exception.Message). " +
               "Install it manually instead (winget install ffmpeg) and relaunch.")
    } finally {
        $ProgressPreference = $oldPP
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
