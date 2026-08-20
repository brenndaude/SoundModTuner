<#
.SYNOPSIS
    SoundMod Tuner - per-category mixing GUI for a Skater XL sound pack.

.DESCRIPTION
    Hosts a local browser UI (http://localhost:<port>/) with a pitch slider per
    sound category, plus an expandable FX box holding a 5-band EQ and a volume
    trim. Preview renders a real sample through the ffmpeg pipeline and plays it
    in the browser; Process All builds the full drop-in pack into
    <Source>_processed using the same chain builder, so what you hear is what
    you ship. UI/Ragdoll folders are excluded and copied untouched.

    There is deliberately no loudness normalization. The game's mix relies on
    categories sitting at different levels - bearings under rolling, and so on -
    so levels are set by hand with the volume trim. The only automatic gain is
    the clip guard, which attenuates and never boosts.

    Settings persist to tuner-settings.json next to this script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\SoundModTuner.ps1

.NOTES
    v1.2. Requires ffmpeg and ffprobe on PATH. Windows PowerShell 5.1 compatible.
#>

param(
    [string]$Source = "",
    [string]$Dest   = "",
    [int]$Port      = 8977,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Continue'
$AppVersion = "1.2"

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
# The default pack sits next to the script, NOT in whatever directory you
# happened to launch from. A bare ".\Sounds" default silently picks up an
# unrelated Sounds folder when the script is run from elsewhere.
if (-not $Source) { $Source = Join-Path $PSScriptRoot "Sounds" }

# The sound pack is checked FIRST, on purpose. ffmpeg bootstrapping can pull a
# ~170 MB download, and making someone wait through that only to be told their
# pack is missing is a rotten first run.
if (-not (Test-Path $Source -PathType Container)) {
    Write-Fatal "No sound pack found." @(
        "Looked for: $Source"
        ""
        "Put your Skater XL sound pack in a folder named 'Sounds' next to"
        "SoundModTuner.ps1, so you end up with:"
        ""
        "    $PSScriptRoot\Sounds\board_land0.wav"
        "    $PSScriptRoot\Sounds\ollie_fast0.wav"
        "    ..."
        ""
        "Or point the tuner at a pack somewhere else:"
        ""
        "    powershell -ExecutionPolicy Bypass -File .\SoundModTuner.ps1 -Source ""C:\path\to\Sounds"""
        ""
        "Sound packs are not included in this repo."
    )
}
$Source = (Resolve-Path $Source).Path.TrimEnd('\')
if (-not $Dest) { $Dest = $Source + "_processed" }

$ChainModule = Join-Path $PSScriptRoot "AudioChain.ps1"
if (-not (Test-Path $ChainModule)) {
    Write-Fatal "AudioChain.ps1 is missing." @(
        "It should sit next to SoundModTuner.ps1 in $PSScriptRoot."
        "If you copied only the one script out of the repo, grab the whole folder instead."
    )
}
. $ChainModule

$bootstrap = Join-Path $PSScriptRoot "bootstrap-ffmpeg.ps1"
if (Test-Path $bootstrap) { . $bootstrap; Initialize-FFmpeg }
foreach ($tool in "ffmpeg", "ffprobe") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Fatal "$tool not found." @(
            "The automatic download did not leave a working ffmpeg behind."
            "Install it manually and relaunch:"
            ""
            "    winget install ffmpeg"
        )
    }
}
$SettingsPath = Join-Path $PSScriptRoot "tuner-settings.json"
$PreviewDir   = Join-Path $env:TEMP "SoundModTuner"
New-Item -ItemType Directory -Force -Path $PreviewDir | Out-Null

# --- categories (order matters: first regex match wins) -------------------
$Categories = @(
    @{ name='board_land';          label='Board lands';          regex='^board_land';            default=2 }
    @{ name='board_impacts';       label='Board impacts';        regex='^board(_wood)?_impacts'; default=2 }
    @{ name='concrete_grind';      label='Concrete grinds';      regex='^concrete_grind';        default=2 }
    @{ name='metal_grind';         label='Metal grinds';         regex='^metal_grind';           default=2 }
    @{ name='wood_grind';          label='Wood grinds';          regex='^wood_grind';            default=2 }
    @{ name='concrete_powerslide'; label='Concrete powerslides'; regex='^concrete_powerslide';   default=2 }
    @{ name='tarmac_powerslide';   label='Tarmac powerslides';   regex='^tarmac_powerslide';     default=2 }
    @{ name='ollie';               label='Ollies';               regex='^ollie';                 default=2 }
    @{ name='shoes_board_back';    label='Shoes: board catch';   regex='^shoes_board_back';      default=0 }
    @{ name='shoes_pivot';         label='Shoes: pivots';        regex='^shoes_pivot';           default=0 }
    @{ name='shoes_movement';      label='Shoes: movement';      regex='^shoes_movement';        default=0 }
    @{ name='bearing_sounds';      label='Bearings';             regex='^bearing';               default=0 }
    @{ name='rolling';             label='Rolling';              regex='^rolling';               default=0 }
    @{ name='other';               label='Other (unmatched)';    regex=$null;                    default=0 }
)

$audioExt = ".wav", ".ogg", ".mp3", ".flac", ".aif", ".aiff"
$ExcludeDirs = @("UI", "Ragdoll", "THESE WOULD GO IN RAGDOLL")
$excludeRegex = "(^|\\)(" + (($ExcludeDirs | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")(\\|$)"

# --- scan files into categories ------------------------------------------
$AllFiles  = Get-ChildItem -Path $Source -Recurse -File
$CatFiles  = @{}                 # category name -> List of entries
$CopyFiles = New-Object System.Collections.Generic.List[object]   # excluded / non-audio
foreach ($c in $Categories) {
    $CatFiles[$c.name] = New-Object System.Collections.Generic.List[object]
}

foreach ($f in $AllFiles) {
    $rel = $f.FullName.Substring($Source.Length + 1)
    if (($audioExt -notcontains $f.Extension.ToLower()) -or ($rel -match $excludeRegex)) {
        $CopyFiles.Add($f); continue
    }
    $cat = 'other'
    foreach ($c in $Categories) {
        if ($c.regex -and $f.BaseName -match $c.regex) { $cat = $c.name; break }
    }
    $CatFiles[$cat].Add([pscustomobject]@{ file = $f; rel = $rel; cat = $cat })
}

# --- settings load --------------------------------------------------------
# v1 files stored a bare semitone number per category; ConvertTo-Fx migrates
# them into the full fx object so an existing tuning survives the upgrade.
$Settings = @{ clipGuard = $true; fx = @{} }
foreach ($c in $Categories) { $Settings.fx[$c.name] = New-Fx ([double]$c.default) }

if (Test-Path $SettingsPath) {
    try {
        $saved = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        if ($null -ne $saved.PSObject.Properties['clipGuard']) {
            $Settings.clipGuard = [bool]$saved.clipGuard
        }
        foreach ($c in $Categories) {
            $v = $null
            if ($saved.values) { $p = $saved.values.PSObject.Properties[$c.name]; if ($p) { $v = $p.Value } }
            $Settings.fx[$c.name] = ConvertTo-Fx $v ([double]$c.default)
        }
        $migrated = ($null -eq $saved.PSObject.Properties['version'])
        if ($migrated) { Write-Host "Migrated tuner-settings.json from v1 (pitch values kept)." }
    } catch { Write-Host "Warning: could not read $SettingsPath, using defaults." }
}

function Save-Settings {
    ([ordered]@{
        version   = 2
        clipGuard = $Settings.clipGuard
        values    = $Settings.fx
    }) | ConvertTo-Json -Depth 8 | Set-Content -Path $SettingsPath -Encoding utf8
}

# --- shared progress state ------------------------------------------------
$Sync = [hashtable]::Synchronized(@{
    running = $false; started = $false
    total = 0; done = 0; ok = 0; copied = 0; guarded = 0
    failed = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
})
$script:BatchPS = $null

# --- batch scriptblock (runs in background runspace) ----------------------
# Dot-sources the same AudioChain.ps1 the preview path uses, so a rendered file
# cannot drift from what the preview played.
$BatchScript = {
    param($sync, $items, $chainModule, $clipGuard)

    . $chainModule

    foreach ($it in $items) {
        try {
            $outDir = Split-Path $it.out
            if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

            if ($it.action -eq 'copy') {
                Copy-Item -Path $it.src -Destination $it.out -Force
                $sync.copied++
            } else {
                $info = Get-AudioInfo $it.src
                if ($null -eq $info) { [void]$sync.failed.Add("$($it.rel) (probe)"); $sync.done++; continue }

                $af = Get-FxChain $it.fx $info.sampleRate

                if ($clipGuard) {
                    $guard = Add-ClipGuard -Path $it.src -Af $af -Fx $it.fx
                    $af = $guard.af
                    if ($guard.trimDb -lt 0) { $sync.guarded++ }
                }

                $codecArgs = Get-CodecArgs $info.codec ([IO.Path]::GetExtension($it.src))

                & ffmpeg -hide_banner -loglevel error -y -i $it.src `
                    -af $af -ar $info.sampleRate @codecArgs -- $it.out 2>&1 | Out-Null

                if ($LASTEXITCODE -eq 0 -and (Test-Path $it.out)) { $sync.ok++ }
                else { [void]$sync.failed.Add($it.rel) }
            }
        } catch {
            [void]$sync.failed.Add("$($it.rel) ($($_.Exception.Message))")
        }
        $sync.done++
    }
    $sync.running = $false
}

function Start-Batch([int]$limit) {
    Write-Host "[batch] start: clipGuard=$($Settings.clipGuard) limit=$limit"
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Categories) {
        $fx = $Settings.fx[$c.name]
        $isDefault = Test-FxIsDefault $fx
        foreach ($e in $CatFiles[$c.name]) {
            # Nothing to apply anywhere in the chain: copy bit-for-bit rather
            # than round-tripping the file through a decode/encode.
            $action = if ($isDefault) { 'copy' } else { 'proc' }
            $items.Add([pscustomobject]@{
                rel = $e.rel; src = $e.file.FullName; out = (Join-Path $Dest $e.rel)
                fx = $fx; action = $action
            })
        }
    }
    if ($limit -gt 0) {
        # NB: List[object] + @(...).Count triggers a PS 5.1 binder bug; use ToArray()
        $work = @($items.ToArray() | Where-Object { $_.action -eq 'proc' } | Select-Object -First $limit)
        if ($work.Count -eq 0) { $work = @($items.ToArray() | Select-Object -First $limit) }
    } else {
        foreach ($f in $CopyFiles) {
            $rel = $f.FullName.Substring($Source.Length + 1)
            $items.Add([pscustomobject]@{
                rel = $rel; src = $f.FullName; out = (Join-Path $Dest $rel)
                fx = $null; action = 'copy'
            })
        }
        $work = $items.ToArray()
    }

    Write-Host "[batch] built $($work.Count) work items"
    $Sync.running = $true; $Sync.started = $true
    $Sync.total = $work.Count; $Sync.done = 0; $Sync.ok = 0; $Sync.copied = 0; $Sync.guarded = 0
    $Sync.failed.Clear()

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $script:BatchPS = [powershell]::Create()
    $script:BatchPS.Runspace = $rs
    [void]$script:BatchPS.AddScript($BatchScript).AddArgument($Sync).AddArgument($work).
        AddArgument($ChainModule).AddArgument($Settings.clipGuard)
    [void]$script:BatchPS.BeginInvoke()
    Write-Host "[batch] runspace launched, total=$($Sync.total)"
}

# --- preview --------------------------------------------------------------
$PreviewPick = @{}   # category -> entry currently used for preview

# Rolling and bearings run 10-32 s. Auditioning those in full is a chore, so
# anything long is previewed as a 4 s excerpt from the middle.
function Get-PreviewWindow([double]$duration) {
    if ($duration -le 6) { return @{ ss = ""; t = ""; excerpt = $false; len = $duration } }
    $len = 4.0
    $start = [math]::Round(($duration - $len) / 2, 2)
    return @{ ss = (Format-Num $start); t = (Format-Num $len); excerpt = $true; len = $len }
}

function Get-PreviewEntry([string]$cat, [bool]$roll) {
    $files = $CatFiles[$cat]
    if (-not $files -or $files.Count -eq 0) { return $null }
    if ($roll -or -not $PreviewPick.ContainsKey($cat)) { $PreviewPick[$cat] = $files | Get-Random }
    return $PreviewPick[$cat]
}

function Render-Preview([string]$cat, $fx, [bool]$roll) {
    $e = Get-PreviewEntry $cat $roll
    if ($null -eq $e) { return $null }
    $path = $e.file.FullName

    $info = Get-AudioInfo $path
    if ($null -eq $info) { return $null }

    $af = Get-FxChain $fx $info.sampleRate

    # The clip guard is measured over the WHOLE file even when rendering an
    # excerpt, so the trim shown here is the trim the batch will apply.
    $trim = 0.0
    if ($Settings.clipGuard) {
        $guard = Add-ClipGuard -Path $path -Af $af -Fx $fx
        $af = $guard.af
        $trim = $guard.trimDb
    }

    $win = Get-PreviewWindow $info.duration
    $out = Join-Path $PreviewDir "preview.wav"

    $ffArgs = @("-hide_banner", "-loglevel", "error", "-y")
    if ($win.ss) { $ffArgs += @("-ss", $win.ss, "-t", $win.t) }
    $ffArgs += @("-i", $path, "-af", $af, "-c:a", "pcm_s16le", "--", $out)
    & ffmpeg @ffArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { return $null }

    $peak = Get-ChainPeakDb -Path $path -Af $af -Seek $win.ss -Duration $win.t

    return @{
        path = $out; name = $e.file.Name
        excerpt = $win.excerpt; duration = $info.duration
        peak = $peak; trim = $trim
    }
}

function Render-Orig([string]$cat) {
    $e = Get-PreviewEntry $cat $false
    if ($null -eq $e) { return $null }
    $path = $e.file.FullName

    $info = Get-AudioInfo $path
    if ($null -eq $info) { return $null }
    $win = Get-PreviewWindow $info.duration
    $out = Join-Path $PreviewDir "orig.wav"

    $ffArgs = @("-hide_banner", "-loglevel", "error", "-y")
    if ($win.ss) { $ffArgs += @("-ss", $win.ss, "-t", $win.t) }
    $ffArgs += @("-i", $path, "-c:a", "pcm_s16le", "--", $out)
    & ffmpeg @ffArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { return $null }

    $peak = Get-ChainPeakDb -Path $path -Af "anull" -Seek $win.ss -Duration $win.t
    return @{ path = $out; name = $e.file.Name; peak = $peak }
}

# --- json builders --------------------------------------------------------
function Get-StateJson {
    $cats = @()
    foreach ($c in $Categories) {
        $cats += [ordered]@{
            name      = $c.name
            label     = $c.label
            count     = $CatFiles[$c.name].Count
            defaultSt = [double]$c.default
            fx        = $Settings.fx[$c.name]
        }
    }
    ([ordered]@{
        version    = $AppVersion
        categories = $cats
        bands      = $script:EqBands
        limits     = $script:FxLimits
        clipGuard  = $Settings.clipGuard
        ceiling    = $script:ClipCeilingDb
        running    = $Sync.running
        dest       = $Dest
    }) | ConvertTo-Json -Depth 8
}

function Get-ProgressJson {
    ([ordered]@{
        running = $Sync.running
        started = $Sync.started
        total   = $Sync.total
        done    = $Sync.done
        ok      = $Sync.ok
        copied  = $Sync.copied
        guarded = $Sync.guarded
        failed  = @($Sync.failed)
    }) | ConvertTo-Json -Depth 4
}

# --- http helpers ---------------------------------------------------------
function Send-Text($ctx, [string]$text, [string]$type, [int]$status = 200) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Send-File($ctx, [string]$path, [string]$type, $headers) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = $type
    if ($headers) {
        foreach ($k in $headers.Keys) {
            if ($null -ne $headers[$k]) { $ctx.Response.Headers.Add($k, [string]$headers[$k]) }
        }
    }
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Read-Body($ctx) {
    $reader = New-Object IO.StreamReader($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
    return $reader.ReadToEnd()
}

# --- UI page --------------------------------------------------------------
$Html = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SoundMod Tuner</title>
<style>
  :root { --bg:#14161a; --panel:#1d2026; --sunk:#12141a; --line:#2b2f37; --fg:#e8e6e0;
          --dim:#8b8f98; --accent:#f5a524; --ok:#4ade80; --bad:#f87171; --cool:#60a5fa; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg);
         font:14px/1.5 "Segoe UI", system-ui, sans-serif; }
  .wrap { max-width:960px; margin:0 auto; padding:24px 20px 60px; }
  header { display:flex; align-items:baseline; gap:14px; margin-bottom:6px; }
  h1 { font-size:20px; margin:0; letter-spacing:.5px; }
  h1 span { color:var(--accent); }
  .sub { color:var(--dim); font-size:12.5px; }
  .globals { display:flex; align-items:center; gap:18px; flex-wrap:wrap;
             background:var(--panel); border:1px solid var(--line); border-radius:10px;
             padding:12px 16px; margin:14px 0 18px; }
  .globals label { display:flex; align-items:center; gap:7px; cursor:pointer; }
  button { background:#262a32; color:var(--fg); border:1px solid var(--line);
           border-radius:7px; padding:6px 13px; cursor:pointer; font:inherit; }
  button:hover { border-color:var(--accent); }
  button:disabled { opacity:.45; cursor:default; }
  button.primary { background:var(--accent); color:#181818; font-weight:600; border:none; padding:7px 18px; }
  button.primary:hover { filter:brightness(1.1); }
  .spacer { flex:1; }
  select { background:var(--sunk); color:var(--fg); border:1px solid var(--line);
           border-radius:6px; padding:5px 7px; font:inherit; }

  .row { display:grid; grid-template-columns: 22px 180px 40px 1fr 68px auto;
         gap:12px; align-items:center; background:var(--panel); border:1px solid var(--line);
         border-radius:10px; padding:10px 16px; margin-bottom:8px; }
  .row .caret { cursor:pointer; color:var(--dim); user-select:none; text-align:center;
                transition:transform .15s; font-size:11px; }
  .row.open .caret { transform:rotate(90deg); }
  .row .name { font-weight:600; display:flex; align-items:center; gap:7px; }
  .row .cnt { color:var(--dim); font-size:12px; text-align:right; }
  .badge { font-size:9.5px; letter-spacing:.6px; background:var(--accent); color:#181818;
           border-radius:4px; padding:1px 5px; font-weight:700; }
  .badge.hide { display:none; }
  input[type=range] { width:100%; accent-color:var(--accent); }
  input[type=number] { width:64px; background:var(--sunk); color:var(--fg);
                       border:1px solid var(--line); border-radius:6px; padding:5px 6px; font:inherit; }
  .btns { display:flex; gap:6px; }
  .btns button { padding:5px 10px; font-size:12.5px; }
  .sample { grid-column: 1 / -1; color:var(--dim); font-size:11.5px; display:none; }
  .sample.show { display:block; }
  .sample b { color:var(--fg); font-weight:600; }
  .sample .warn { color:var(--accent); }
  .sample .trim { color:var(--bad); }

  .fx { grid-column:1 / -1; display:none; border-top:1px solid var(--line);
        margin-top:4px; padding-top:14px; }
  .row.open .fx { display:block; }
  .fxgrid { display:grid; grid-template-columns: 1fr 240px; gap:22px; align-items:start; }
  @media (max-width:760px) { .fxgrid { grid-template-columns:1fr; } }
  .eqwrap { background:var(--sunk); border:1px solid var(--line); border-radius:8px; padding:6px; }
  .eqwrap svg { display:block; width:100%; height:auto; touch-action:none; }
  .eqhint { color:var(--dim); font-size:11px; margin-top:5px; display:flex; gap:12px; }
  .eqhint .live { color:var(--fg); font-variant-numeric:tabular-nums; }
  .knob { margin-bottom:16px; }
  .knob .lbl { display:flex; justify-content:space-between; font-size:12px;
               color:var(--dim); margin-bottom:3px; }
  .knob .lbl b { color:var(--fg); font-weight:600; font-variant-numeric:tabular-nums; }
  .note { color:var(--dim); font-size:11px; margin-top:6px; line-height:1.45; }
  .fxside { display:flex; flex-direction:column; height:100%; }
  .fxside .tools { margin-top:auto; padding-top:14px; border-top:1px solid var(--line); }
  .fxside .tools label { display:block; color:var(--dim); font-size:12px; margin-bottom:5px; }
  .fxside .tools select { width:100%; margin-bottom:8px; }
  .fxside .tools button { width:100%; }

  .progress { display:none; background:var(--panel); border:1px solid var(--line);
              border-radius:10px; padding:14px 16px; margin-top:16px; }
  .progress.show { display:block; }
  .bar { height:10px; background:var(--sunk); border-radius:6px; overflow:hidden; margin:8px 0; }
  .bar div { height:100%; width:0%; background:var(--accent); transition:width .3s; }
  .failed { color:var(--bad); white-space:pre-wrap; font-size:12px; }
  .okmsg { color:var(--ok); }
  footer { margin-top:22px; color:var(--dim); font-size:12px; display:flex; gap:16px; align-items:center; }
  footer button { font-size:12px; padding:4px 10px; }
</style>
</head>
<body>
<div class="wrap">
  <header><h1>SoundMod <span>Tuner</span></h1>
    <div class="sub">pitch &middot; EQ &middot; level &nbsp;&rarr;&nbsp; <span id="dest"></span></div>
  </header>

  <div class="globals">
    <label title="Attenuate-only. Never boosts, never levels categories against each other.">
      <input type="checkbox" id="clipguard"> Clip guard <span class="sub" id="ceiling"></span>
    </label>
    <label title="Loop preview playback"><input type="checkbox" id="loopplay"> Loop preview</label>
    <div class="spacer"></div>
    <button id="reset">Reset all</button>
    <button class="primary" id="process">Process All</button>
  </div>

  <div id="rows"></div>

  <div class="progress" id="progress">
    <div id="ptext">Processing&hellip;</div>
    <div class="bar"><div id="pbar"></div></div>
    <div id="psummary"></div>
  </div>

  <footer>
    <span>Settings save when you process.</span>
    <span class="spacer"></span>
    <span id="ver"></span>
    <button id="quit">Quit server</button>
  </footer>
</div>

<script>
let state = null, L = null, BANDS = null;
const FS = 44100;                 // display-only reference rate for the EQ curve
const player = new Audio();
const ab = {};                    // category -> {proc, orig, showing}

function esc(s){ const d=document.createElement('div'); d.textContent=s; return d.innerHTML; }
function clamp(v,a,b){ return Math.max(a, Math.min(b, v)); }
function fmtHz(f){ return f >= 1000 ? (f/1000).toFixed(f>=10000?1:2)+' kHz' : Math.round(f)+' Hz'; }
function fmtDb(v){ return (v>0?'+':'') + v.toFixed(1) + ' dB'; }

/* ---- EQ curve maths ---------------------------------------------------
   RBJ biquads matching ffmpeg's bass / equalizer / treble with width_type=q,
   so the drawn curve is the response you will actually render.            */
function coeffs(kind, f, g, q){
  const A = Math.pow(10, g/40), w0 = 2*Math.PI*f/FS;
  const cw = Math.cos(w0), sw = Math.sin(w0), al = sw/(2*q), sq = 2*Math.sqrt(A)*al;
  if (kind === 'peak')
    return [1+al*A, -2*cw, 1-al*A, 1+al/A, -2*cw, 1-al/A];
  if (kind === 'lowshelf')
    return [A*((A+1)-(A-1)*cw+sq), 2*A*((A-1)-(A+1)*cw), A*((A+1)-(A-1)*cw-sq),
            (A+1)+(A-1)*cw+sq,    -2*((A-1)+(A+1)*cw),   (A+1)+(A-1)*cw-sq];
  return [A*((A+1)+(A-1)*cw+sq), -2*A*((A-1)+(A+1)*cw), A*((A+1)+(A-1)*cw-sq),
          (A+1)-(A-1)*cw+sq,      2*((A-1)-(A+1)*cw),   (A+1)-(A-1)*cw-sq];
}
function bandDb(kind, f, g, q, at){
  if (g === 0) return 0;
  const [b0,b1,b2,a0,a1,a2] = coeffs(kind, f, g, q);
  const w = 2*Math.PI*at/FS, cw=Math.cos(w), sw=Math.sin(w), c2=Math.cos(2*w), s2=Math.sin(2*w);
  const nr=b0+b1*cw+b2*c2, ni=-(b1*sw+b2*s2), dr=a0+a1*cw+a2*c2, di=-(a1*sw+a2*s2);
  const m2 = (nr*nr+ni*ni)/(dr*dr+di*di);
  return 10*Math.log10(m2);
}

const EQW = 620, EQH = 210, FMIN = 30, FMAX = 16000;
function fToX(f){ return (Math.log(f/FMIN)/Math.log(FMAX/FMIN)) * EQW; }
function xToF(x){ return FMIN * Math.pow(FMAX/FMIN, clamp(x,0,EQW)/EQW); }
function gToY(g){ return EQH/2 - (g/L.eqG.max) * (EQH/2 - 10); }
function yToG(y){ return clamp((EQH/2 - y) / (EQH/2 - 10) * L.eqG.max, L.eqG.min, L.eqG.max); }

function curvePath(fx){
  let d = '';
  for (let x = 0; x <= EQW; x += 4){
    const f = xToF(x);
    let g = 0;
    for (let i = 0; i < BANDS.length; i++)
      g += bandDb(BANDS[i].kind, fx.eq[i].f, fx.eq[i].g, fx.eq[i].q, f);
    d += (x === 0 ? 'M' : 'L') + x.toFixed(1) + ',' + gToY(clamp(g,-40,40)).toFixed(1);
  }
  return d;
}

function eqSvg(name){
  const gr = [];
  [50,100,200,500,1000,2000,5000,10000].forEach(f => {
    gr.push('<line x1="'+fToX(f).toFixed(1)+'" y1="0" x2="'+fToX(f).toFixed(1)+'" y2="'+EQH+'" stroke="#252932"/>');
    gr.push('<text x="'+(fToX(f)+3).toFixed(1)+'" y="'+(EQH-4)+'" fill="#5c616b" font-size="9">'+
            (f>=1000?(f/1000)+'k':f)+'</text>');
  });
  [-12,-6,0,6,12].forEach(g => {
    gr.push('<line x1="0" y1="'+gToY(g).toFixed(1)+'" x2="'+EQW+'" y2="'+gToY(g).toFixed(1)+
            '" stroke="'+(g===0?'#39404d':'#252932')+'"/>');
    gr.push('<text x="3" y="'+(gToY(g)-3).toFixed(1)+'" fill="#5c616b" font-size="9">'+
            (g>0?'+':'')+g+'</text>');
  });
  let pts = '';
  for (let i = 0; i < BANDS.length; i++)
    // The visible dot is small, but a transparent r=14 disc carries the pointer
    // events - a 6px grab target is miserable to hit, especially after a drag.
    pts += '<g class="pt" data-b="'+i+'" style="cursor:grab">' +
             '<circle r="14" fill="transparent"/>' +
             '<circle class="dot" r="6" fill="var(--accent)" stroke="#181818" stroke-width="1.5"/>' +
           '</g>';
  return '<svg viewBox="0 0 '+EQW+' '+EQH+'" id="eq-'+name+'">' + gr.join('') +
         '<path id="eqc-'+name+'" fill="none" stroke="var(--cool)" stroke-width="2"/>' + pts + '</svg>';
}

function drawEq(name){
  const fx = fxOf(name);
  document.getElementById('eqc-'+name).setAttribute('d', curvePath(fx));
  const svg = document.getElementById('eq-'+name);
  svg.querySelectorAll('.pt').forEach(g => {
    const i = +g.dataset.b;
    g.setAttribute('transform', 'translate(' + fToX(fx.eq[i].f).toFixed(1) + ',' + gToY(fx.eq[i].g).toFixed(1) + ')');
    g.querySelector('.dot').setAttribute('fill', fx.eq[i].g === 0 ? '#4a5160' : 'var(--accent)');
  });
}

// Nearest band to a horizontal position, so Q-scroll works anywhere on the
// curve rather than only when the cursor is exactly over a dot.
function nearestBand(name, x){
  const fx = fxOf(name);
  let best = 0, bd = Infinity;
  for (let i = 0; i < BANDS.length; i++){
    const d = Math.abs(fToX(fx.eq[i].f) - x);
    if (d < bd) { bd = d; best = i; }
  }
  return best;
}

function eqReadout(name, i){
  const fx = fxOf(name), b = fx.eq[i];
  document.getElementById('eqlive-'+name).textContent =
    (BANDS[i].kind === 'lowshelf' ? 'Low shelf' : BANDS[i].kind === 'highshelf' ? 'High shelf' : 'Band '+i) +
    '  ' + fmtHz(b.f) + '   ' + fmtDb(b.g) + '   Q ' + b.q.toFixed(2);
}

/* ---- state ------------------------------------------------------------ */
function fxOf(name){ return state.categories.find(c => c.name === name).fx; }
function catOf(name){ return state.categories.find(c => c.name === name); }

function markDirty(name){
  const fx = fxOf(name), c = catOf(name);
  const dirty = fx.vol !== 0 || fx.eq.some(b => b.g !== 0);
  document.getElementById('badge-'+name).classList.toggle('hide', !dirty);
  document.getElementById('sl-'+name).value = fx.st;
  document.getElementById('nb-'+name).value = fx.st;
  if (c) c.dirty = dirty;
}

/* ---- rows ------------------------------------------------------------- */
function rowHtml(c){
  return ''+
  '<div class="caret" onclick="toggle(\''+c.name+'\')">&#9654;</div>'+
  '<div class="name">'+esc(c.label)+'<span class="badge hide" id="badge-'+c.name+'">FX</span></div>'+
  '<div class="cnt">'+c.count+'</div>'+
  '<input type="range" min="'+L.st.min+'" max="'+L.st.max+'" step="0.1" value="'+c.fx.st+'" id="sl-'+c.name+'">'+
  '<input type="number" min="'+L.st.min+'" max="'+L.st.max+'" step="0.1" value="'+c.fx.st+'" id="nb-'+c.name+'">'+
  '<div class="btns">'+
    '<button onclick="preview(\''+c.name+'\',false)" title="Render and play this category">&#9654; Preview</button>'+
    '<button onclick="flip(\''+c.name+'\')" id="ab-'+c.name+'" title="Switch between processed and original" disabled>A/B</button>'+
    '<button onclick="preview(\''+c.name+'\',true)" title="Pick a different sample">&#8635;</button>'+
  '</div>'+
  '<div class="sample" id="smp-'+c.name+'"></div>'+
  '<div class="fx">'+
    '<div class="fxgrid">'+
      '<div>'+
        '<div class="eqwrap">'+eqSvg(c.name)+'</div>'+
        '<div class="eqhint"><span class="live" id="eqlive-'+c.name+'">drag a point &middot; scroll for Q &middot; double-click a point to flatten it</span></div>'+
      '</div>'+
      '<div class="fxside">'+
        '<div class="knob">'+
          '<div class="lbl"><span>Volume</span><b id="voll-'+c.name+'"></b></div>'+
          '<input type="range" id="vol-'+c.name+'" min="'+L.vol.min+'" max="'+L.vol.max+'" step="0.5" value="'+c.fx.vol+'">'+
        '</div>'+
        '<div class="note">Applies to all '+c.count+' files. Neither EQ nor volume '+
          'changes file length, so looping sounds stay seamless.</div>'+
        '<div class="tools">'+
          '<label for="copy-'+c.name+'">Copy FX from</label>'+
          '<select id="copy-'+c.name+'"><option value="">&mdash;</option></select>'+
          '<button onclick="resetCat(\''+c.name+'\')">Reset this category</button>'+
        '</div>'+
      '</div>'+
    '</div>'+
  '</div>';
}

function toggle(name){
  const row = document.getElementById('row-'+name);
  row.classList.toggle('open');
  if (row.classList.contains('open')) drawEq(name);
}

function wire(c){
  const n = c.name, fx = c.fx;
  const sl = document.getElementById('sl-'+n), nb = document.getElementById('nb-'+n);
  const setSt = v => { fx.st = clamp(parseFloat(v)||0, L.st.min, L.st.max); markDirty(n); };
  sl.addEventListener('input', () => setSt(sl.value));
  nb.addEventListener('input', () => setSt(nb.value));

  const vol = document.getElementById('vol-'+n);
  const volLbl = () => document.getElementById('voll-'+n).textContent = fmtDb(fx.vol);
  vol.addEventListener('input', () => { fx.vol = parseFloat(vol.value); volLbl(); markDirty(n); });
  volLbl();

  const sel = document.getElementById('copy-'+n);
  state.categories.filter(o => o.count > 0 && o.name !== n).forEach(o => {
    const opt = document.createElement('option'); opt.value = o.name; opt.textContent = o.label;
    sel.appendChild(opt);
  });
  sel.addEventListener('change', () => {
    if (!sel.value) return;
    const src = fxOf(sel.value);
    fx.vol = src.vol;
    fx.eq = src.eq.map(b => ({ f: b.f, g: b.g, q: b.q }));   // copy, never share the ref
    sel.value = '';
    refreshControls(n);
  });

  wireEq(n);
  markDirty(n);
}

function wireEq(n){
  const svg = document.getElementById('eq-'+n);
  let drag = null;

  const pos = ev => {
    const r = svg.getBoundingClientRect();
    return { x: (ev.clientX - r.left) / r.width * EQW, y: (ev.clientY - r.top) / r.height * EQH };
  };

  svg.querySelectorAll('.pt').forEach(pt => {
    pt.addEventListener('pointerdown', ev => {
      drag = +pt.dataset.b; pt.setPointerCapture(ev.pointerId); ev.preventDefault();
      eqReadout(n, drag);
    });
    pt.addEventListener('pointermove', ev => {
      if (drag === null) return;
      const fx = fxOf(n), p = pos(ev), i = drag;
      // Keep bands in order so the curve stays readable; endpoints hit the rails.
      const lo = i === 0 ? FMIN : fx.eq[i-1].f * 1.05;
      const hi = i === BANDS.length-1 ? FMAX : fx.eq[i+1].f / 1.05;
      fx.eq[i].f = clamp(xToF(p.x), Math.max(FMIN, lo), Math.min(FMAX, hi));
      fx.eq[i].g = Math.round(yToG(p.y) * 10) / 10;
      drawEq(n); eqReadout(n, i); markDirty(n);
    });
    const stop = ev => { if (drag !== null) { drag = null; } };
    pt.addEventListener('pointerup', stop);
    pt.addEventListener('pointercancel', stop);
    pt.addEventListener('dblclick', ev => {
      const fx = fxOf(n), i = +pt.dataset.b;
      fx.eq[i] = { f: BANDS[i].f, g: 0, q: BANDS[i].q };
      drawEq(n); eqReadout(n, i); markDirty(n);
    });
  });

  // Q lives on the whole plot, not just the dots: scroll near a band to widen
  // or narrow it. Anchored to the dots it was unusable once a point had moved.
  svg.addEventListener('wheel', ev => {
    ev.preventDefault();
    const fx = fxOf(n), i = nearestBand(n, pos(ev).x);
    fx.eq[i].q = clamp(fx.eq[i].q * (ev.deltaY > 0 ? 0.88 : 1.14), L.eqQ.min, L.eqQ.max);
    drawEq(n); eqReadout(n, i);
  }, { passive:false });

  svg.addEventListener('pointermove', ev => {
    if (drag === null) eqReadout(n, nearestBand(n, pos(ev).x));
  });
}

function refreshControls(n){
  const fx = fxOf(n);
  document.getElementById('vol-'+n).value = fx.vol;
  document.getElementById('voll-'+n).textContent = fmtDb(fx.vol);
  drawEq(n); markDirty(n);
}

function resetCat(n){
  const c = catOf(n);
  c.fx.st = c.defaultSt;
  c.fx.vol = 0;
  c.fx.eq = BANDS.map(b => ({ f:b.f, g:0, q:b.q }));
  refreshControls(n);
}

/* ---- preview / A B ---------------------------------------------------- */
async function preview(name, roll){
  const btn = document.getElementById('ab-'+name);
  btn.disabled = true;
  const r = await fetch('/api/preview', { method:'POST', headers:{'Content-Type':'application/json'},
                                          body: JSON.stringify({ cat:name, roll:!!roll, fx:fxOf(name) }) });
  if (!r.ok) { showSample(name, { err:true }); return; }
  const h = n => r.headers.get(n);
  const meta = { file:h('X-Sample'), peak:h('X-Peak'), trim:h('X-Trim'),
                 excerpt:h('X-Excerpt'), dur:h('X-Duration') };
  ab[name] = { proc: URL.createObjectURL(await r.blob()), orig: null, showing:'proc', meta };
  showSample(name, meta, 'proc');
  play(ab[name].proc, 0);

  // Fetch the dry version in the background so A/B is instant when you hit it.
  const o = await fetch('/api/orig?cat=' + encodeURIComponent(name));
  if (o.ok) {
    ab[name].orig = URL.createObjectURL(await o.blob());
    ab[name].meta.origPeak = o.headers.get('X-Peak');
    btn.disabled = false;
    showSample(name, ab[name].meta, ab[name].showing);
  }
}

function play(src, frac){
  player.loop = document.getElementById('loopplay').checked;
  player.src = src;
  player.play().then(() => {
    if (frac > 0 && isFinite(player.duration)) player.currentTime = frac * player.duration;
  }).catch(()=>{});
}

// Swap keeps the proportional position, so a pitched (and therefore shorter)
// render lines up with the original instead of jumping.
function flip(name){
  const s = ab[name];
  if (!s || !s.orig) return;
  const frac = (player.duration && isFinite(player.duration)) ? player.currentTime / player.duration : 0;
  s.showing = s.showing === 'proc' ? 'orig' : 'proc';
  play(s[s.showing], frac);
  showSample(name, s.meta, s.showing);
}

async function playOrig(name){ flip(name); }

function showSample(name, m, which){
  const el = document.getElementById('smp-'+name);
  el.classList.add('show');
  if (m.err) { el.innerHTML = '<span class="trim">preview failed</span>'; return; }
  const parts = [];
  parts.push('<b>'+esc(m.file)+'</b>');
  parts.push(which === 'orig' ? 'ORIGINAL' : 'processed');
  const pk = which === 'orig' ? m.origPeak : m.peak;
  if (pk) parts.push('peak ' + (parseFloat(pk)>0?'+':'') + parseFloat(pk).toFixed(1) + ' dBFS');
  if (m.excerpt === '1') parts.push('excerpt 4.0 s of ' + parseFloat(m.dur).toFixed(1) + ' s');
  let html = parts.join(' &middot; ');
  if (which !== 'orig' && m.trim && parseFloat(m.trim) < 0)
    html += ' &middot; <span class="trim">clip guard ' + parseFloat(m.trim).toFixed(1) + ' dB</span>';
  el.innerHTML = html;
}

/* ---- process ---------------------------------------------------------- */
function gather(){
  const values = {};
  state.categories.filter(c => c.count > 0).forEach(c => { values[c.name] = c.fx; });
  return { clipGuard: document.getElementById('clipguard').checked, values: values };
}

function showProgress(){
  document.getElementById('progress').classList.add('show');
  document.getElementById('process').disabled = true;
  document.getElementById('psummary').innerHTML = '';
}

async function processAll(){
  showProgress();
  const r = await fetch('/api/process', { method:'POST', headers:{'Content-Type':'application/json'},
                                          body: JSON.stringify(gather()) });
  if (!r.ok) { document.getElementById('ptext').textContent = 'Could not start (already running?)'; return; }
  poll();
}

async function poll(){
  const p = await (await fetch('/api/progress')).json();
  const pct = p.total ? Math.round(100 * p.done / p.total) : 0;
  document.getElementById('pbar').style.width = pct + '%';
  document.getElementById('ptext').textContent =
    p.running ? ('Processing ' + p.done + ' / ' + p.total + ' (' + pct + '%)') : 'Finished';
  if (p.running) { setTimeout(poll, 500); return; }
  document.getElementById('process').disabled = false;
  let html = '<span class="okmsg">Done &ndash; ' + p.ok + ' processed, ' + p.copied + ' copied untouched</span>';
  if (p.guarded) html += '<div class="note">Clip guard pulled back ' + p.guarded +
                         ' file' + (p.guarded===1?'':'s') + ' that would have clipped.</div>';
  if (p.failed.length) html += '<div class="failed">Failed (' + p.failed.length + '):\n' +
                               p.failed.map(esc).join('\n') + '</div>';
  document.getElementById('psummary').innerHTML = html;
}

/* ---- boot ------------------------------------------------------------- */
async function load(){
  state = await (await fetch('/api/state')).json();
  L = state.limits; BANDS = state.bands;
  document.getElementById('dest').textContent = state.dest;
  document.getElementById('ver').textContent = 'v' + state.version;
  document.getElementById('ceiling').textContent = '(' + state.ceiling + ' dBFS)';
  document.getElementById('clipguard').checked = state.clipGuard;

  const rows = document.getElementById('rows');
  rows.innerHTML = '';
  state.categories.filter(c => c.count > 0).forEach(c => {
    const row = document.createElement('div');
    row.className = 'row';
    row.id = 'row-' + c.name;
    row.innerHTML = rowHtml(c);
    rows.appendChild(row);
    wire(c);
  });
  if (state.running) { showProgress(); poll(); }
}

document.getElementById('process').addEventListener('click', processAll);
document.getElementById('reset').addEventListener('click', () => {
  state.categories.filter(c => c.count > 0).forEach(c => resetCat(c.name));
});
document.getElementById('loopplay').addEventListener('change', e => { player.loop = e.target.checked; });
document.getElementById('quit').addEventListener('click', async () => {
  await fetch('/api/quit', { method:'POST' });
  document.body.innerHTML = '<div style="padding:40px;font:15px Segoe UI;color:#e8e6e0">' +
    'Server stopped. You can close this tab.</div>';
});

load();
</script>
</body>
</html>
'@

# --- server ---------------------------------------------------------------
$listener = $null
$boundPort = 0
foreach ($p in $Port..($Port + 9)) {
    # a failed Start() leaves an HttpListener unusable - fresh object per attempt
    $attempt = New-Object System.Net.HttpListener
    $attempt.Prefixes.Add("http://localhost:$p/")
    try {
        $attempt.Start()
        $listener = $attempt
        $boundPort = $p
        break
    } catch { $attempt.Close() }
}
if ($boundPort -eq 0) { throw "Could not bind a port in range $Port-$($Port+9)." }

$targetCount = 0
foreach ($c in $Categories) { $targetCount += $CatFiles[$c.name].Count }
Write-Host ""
Write-Host "SoundMod Tuner v$AppVersion running at http://localhost:$boundPort/"
Write-Host "Source : $Source  ($targetCount tunable files, $($CopyFiles.Count) copied untouched)"
Write-Host "Output : $Dest"
Write-Host "Close this window (or use the Quit button in the page) to stop."
Write-Host ""

if (-not $NoBrowser) { Start-Process "http://localhost:$boundPort/" }

$quit = $false
while (-not $quit) {
    $ctx = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath
    if ($path -notmatch '^/api/(progress|debug)$') {
        Write-Host "[req] $(Get-Date -Format HH:mm:ss.fff) $($ctx.Request.HttpMethod) $($ctx.Request.Url.PathAndQuery)"
    }
    try {
        switch -Regex ($path) {
            '^/$' { Send-Text $ctx $Html "text/html; charset=utf-8" }

            '^/api/state$' { Send-Text $ctx (Get-StateJson) "application/json" }

            '^/api/progress$' { Send-Text $ctx (Get-ProgressJson) "application/json" }

            '^/api/debug$' {
                $bstate = 'none'; $reason = ''; $errs = @()
                if ($script:BatchPS) {
                    $bstate = [string]$script:BatchPS.InvocationStateInfo.State
                    $reason = [string]$script:BatchPS.InvocationStateInfo.Reason
                    $errs   = @($script:BatchPS.Streams.Error | ForEach-Object { $_.ToString() })
                }
                ([ordered]@{ psState = $bstate; reason = $reason; errors = $errs
                             sync = [ordered]@{ running=$Sync.running; total=$Sync.total; done=$Sync.done
                                                ok=$Sync.ok; copied=$Sync.copied; guarded=$Sync.guarded
                                                failed=@($Sync.failed) }
                }) | ConvertTo-Json -Depth 5 | ForEach-Object { Send-Text $ctx $_ "application/json" }
            }

            '^/api/preview$' {
                $req = Read-Body $ctx | ConvertFrom-Json
                $cat = [string]$req.cat
                if (-not $CatFiles.ContainsKey($cat)) {
                    Send-Text $ctx '{"error":"unknown category"}' "application/json" 404
                } else {
                    $fx = ConvertTo-Fx $req.fx
                    $Settings.fx[$cat] = $fx        # keep server state in step with the page
                    $res = Render-Preview $cat $fx ([bool]$req.roll)
                    if ($res) {
                        Send-File $ctx $res.path "audio/wav" @{
                            "X-Sample"   = $res.name
                            "X-Peak"     = $(if ($null -ne $res.peak) { Format-Num $res.peak "0.##" } else { $null })
                            "X-Trim"     = (Format-Num $res.trim "0.##")
                            "X-Excerpt"  = $(if ($res.excerpt) { "1" } else { "0" })
                            "X-Duration" = (Format-Num $res.duration "0.##")
                        }
                    } else { Send-Text $ctx '{"error":"preview failed"}' "application/json" 500 }
                }
            }

            '^/api/orig$' {
                $res = Render-Orig $ctx.Request.QueryString["cat"]
                if ($res) {
                    Send-File $ctx $res.path "audio/wav" @{
                        "X-Sample" = $res.name
                        "X-Peak"   = $(if ($null -ne $res.peak) { Format-Num $res.peak "0.##" } else { $null })
                    }
                } else { Send-Text $ctx '{"error":"orig failed"}' "application/json" 500 }
            }

            '^/api/process$' {
                if ($Sync.running) { Send-Text $ctx '{"error":"already running"}' "application/json" 409 }
                else {
                    $req = Read-Body $ctx | ConvertFrom-Json
                    if ($null -ne $req.clipGuard) { $Settings.clipGuard = [bool]$req.clipGuard }
                    foreach ($c in $Categories) {
                        $v = $null
                        if ($req.values) { $p = $req.values.PSObject.Properties[$c.name]; if ($p) { $v = $p.Value } }
                        if ($null -ne $v) { $Settings.fx[$c.name] = ConvertTo-Fx $v ([double]$c.default) }
                    }
                    Save-Settings
                    $limit = 0
                    if ($null -ne $req.limit) { $limit = [int]$req.limit }
                    Start-Batch $limit
                    Send-Text $ctx '{"ok":true}' "application/json"
                }
            }

            '^/api/quit$' {
                Send-Text $ctx '{"ok":true}' "application/json"
                $quit = $true
            }

            default { Send-Text $ctx "not found" "text/plain" 404 }
        }
    } catch {
        Write-Host "[err] $($_.Exception.Message)"
        Write-Host $_.InvocationInfo.PositionMessage
        Write-Host $_.ScriptStackTrace
        try { Send-Text $ctx ('{"error":' + ('"' + $_.Exception.Message.Replace('"','\"') + '"') + '}') "application/json" 500 } catch { }
    }
}

$listener.Stop()
Write-Host "Server stopped."
