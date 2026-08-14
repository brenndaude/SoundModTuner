<#
.SYNOPSIS
    SoundMod Tuner - per-category pitch GUI for a Skater XL sound pack.

.DESCRIPTION
    Hosts a local browser UI (http://localhost:<port>/) with a pitch slider per
    sound category. Preview renders a real sample through the ffmpeg pipeline
    and plays it in the browser; Process All builds the full drop-in pack into
    <Source>_processed using the same verified varispeed pipeline as
    Process-SoundMod.ps1. UI/Ragdoll folders are excluded and copied untouched.

    Settings persist to tuner-settings.json next to this script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\SoundModTuner.ps1

.NOTES
    Requires ffmpeg and ffprobe on PATH. Windows PowerShell 5.1 compatible.
#>

param(
    [string]$Source = ".\Sounds",
    [string]$Dest   = "",
    [int]$Port      = 8977,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Continue'

# --- sanity checks --------------------------------------------------------
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
$CatFiles  = @{}                 # category name -> List of FileInfo
$CopyFiles = New-Object System.Collections.Generic.List[object]   # excluded / non-audio
foreach ($c in $Categories) { $CatFiles[$c.name] = New-Object System.Collections.Generic.List[object] }

foreach ($f in $AllFiles) {
    $rel = $f.FullName.Substring($Source.Length + 1)
    if (($audioExt -notcontains $f.Extension.ToLower()) -or ($rel -match $excludeRegex)) {
        $CopyFiles.Add($f); continue
    }
    $matched = $false
    foreach ($c in $Categories) {
        if ($c.regex -and $f.BaseName -match $c.regex) { $CatFiles[$c.name].Add($f); $matched = $true; break }
    }
    if (-not $matched) { $CatFiles['other'].Add($f) }
}

# --- settings load --------------------------------------------------------
$Settings = @{ normalize = $true; values = @{} }
foreach ($c in $Categories) { $Settings.values[$c.name] = [double]$c.default }
if (Test-Path $SettingsPath) {
    try {
        $saved = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        if ($null -ne $saved.normalize) { $Settings.normalize = [bool]$saved.normalize }
        foreach ($c in $Categories) {
            $v = $saved.values.PSObject.Properties[$c.name]
            if ($v) { $Settings.values[$c.name] = [math]::Max(-5, [math]::Min(5, [double]$v.Value)) }
        }
    } catch { Write-Host "Warning: could not read $SettingsPath, using defaults." }
}

function Save-Settings {
    $obj = @{ normalize = $Settings.normalize; values = $Settings.values }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $SettingsPath -Encoding utf8
}

# --- shared progress state ------------------------------------------------
$Sync = [hashtable]::Synchronized(@{
    running = $false; started = $false
    total = 0; done = 0; ok = 0; copied = 0
    failed = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
})
$script:BatchPS = $null

# --- batch scriptblock (runs in background runspace) ----------------------
$BatchScript = {
    param($sync, $items, $norm, $targetDb)
    foreach ($it in $items) {
        try {
            $outDir = Split-Path $it.out
            if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

            if ($it.action -eq 'copy') {
                Copy-Item -Path $it.src -Destination $it.out -Force
                $sync.copied++
            } else {
                $probe = (& ffprobe -v error -select_streams a:0 `
                    -show_entries stream=codec_name,sample_rate -of csv=p=0 -- $it.src) -join ""
                $parts = $probe.Trim() -split ","
                if ($parts.Count -lt 2) { [void]$sync.failed.Add("$($it.rel) (probe)"); $sync.done++; continue }
                $codec = $parts[0]
                $sr    = [int]$parts[1]

                $chain = @()
                if ($it.st -ne 0) {
                    $newRate = [int][math]::Round($sr * [math]::Pow(2, $it.st / 12))
                    $chain += "asetrate=$newRate"
                    $chain += "aresample=$sr"
                }
                if (@($chain).Count -eq 0) { $chain += "anull" }
                $af = $chain -join ","

                $afFinal = $af
                if ($norm) {
                    $detect = (& ffmpeg -hide_banner -nostats -i $it.src `
                        -af "$af,volumedetect" -f null - 2>&1) | Out-String
                    $m = [regex]::Match($detect, "max_volume:\s*(-?[\d.]+)\s*dB")
                    if ($m.Success) {
                        $gain = [math]::Round($targetDb - [double]$m.Groups[1].Value, 2)
                        $afFinal = "$af,volume=${gain}dB"
                    }
                }

                if ($codec -like "pcm_*") { $codecArgs = @("-c:a", $codec) }
                else {
                    switch ([IO.Path]::GetExtension($it.src).ToLower()) {
                        ".ogg"  { $codecArgs = @("-c:a", "libvorbis", "-q:a", "6") }
                        ".mp3"  { $codecArgs = @("-c:a", "libmp3lame", "-q:a", "2") }
                        ".flac" { $codecArgs = @("-c:a", "flac") }
                        default { $codecArgs = @("-c:a", "pcm_s16le") }
                    }
                }

                & ffmpeg -hide_banner -loglevel error -y -i $it.src `
                    -af $afFinal -ar $sr @codecArgs -- $it.out 2>&1 | Out-Null

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

function Start-Batch([bool]$norm, [double]$targetDb, [int]$limit) {
    Write-Host "[batch] start: norm=$norm target=$targetDb limit=$limit"
    # build work list from current settings
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Categories) {
        $st = [double]$Settings.values[$c.name]
        foreach ($f in $CatFiles[$c.name]) {
            $rel = $f.FullName.Substring($Source.Length + 1)
            $action = 'proc'
            if ($st -eq 0 -and -not $norm) { $action = 'copy' }   # untouched: exact copy
            $items.Add([pscustomobject]@{ rel=$rel; src=$f.FullName; out=(Join-Path $Dest $rel); st=$st; action=$action })
        }
    }
    if ($limit -gt 0) {
        # NB: List[object] + @(...).Count triggers a PS 5.1 binder bug; use ToArray()
        $work = @($items.ToArray() | Select-Object -First $limit)
    } else {
        foreach ($f in $CopyFiles) {
            $rel = $f.FullName.Substring($Source.Length + 1)
            $items.Add([pscustomobject]@{ rel=$rel; src=$f.FullName; out=(Join-Path $Dest $rel); st=0; action='copy' })
        }
        $work = $items.ToArray()
    }

    Write-Host "[batch] built $($work.Count) work items"
    $Sync.running = $true; $Sync.started = $true
    $Sync.total = $work.Count; $Sync.done = 0; $Sync.ok = 0; $Sync.copied = 0
    $Sync.failed.Clear()

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $script:BatchPS = [powershell]::Create()
    $script:BatchPS.Runspace = $rs
    [void]$script:BatchPS.AddScript($BatchScript).AddArgument($Sync).AddArgument($work).AddArgument($norm).AddArgument($targetDb)
    [void]$script:BatchPS.BeginInvoke()
    Write-Host "[batch] runspace launched, total=$($Sync.total)"
}

# --- preview --------------------------------------------------------------
$PreviewPick = @{}   # category -> FileInfo currently used for preview

function Render-Preview([string]$cat, [double]$st, [bool]$norm, [bool]$roll) {
    $files = $CatFiles[$cat]
    if (-not $files -or $files.Count -eq 0) { return $null }
    if ($roll -or -not $PreviewPick.ContainsKey($cat)) { $PreviewPick[$cat] = $files | Get-Random }
    $f = $PreviewPick[$cat]

    $chain = @()
    if ($st -ne 0) {
        $sr = [int]((& ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of csv=p=0 -- $f.FullName) -join "").Trim()
        $newRate = [int][math]::Round($sr * [math]::Pow(2, $st / 12))
        $chain += "asetrate=$newRate"
        $chain += "aresample=$sr"
    }
    if (@($chain).Count -eq 0) { $chain += "anull" }
    $af = $chain -join ","

    if ($norm) {
        $detect = (& ffmpeg -hide_banner -nostats -i $f.FullName -af "$af,volumedetect" -f null - 2>&1) | Out-String
        $m = [regex]::Match($detect, "max_volume:\s*(-?[\d.]+)\s*dB")
        if ($m.Success) {
            $gain = [math]::Round(-1 - [double]$m.Groups[1].Value, 2)
            $af = "$af,volume=${gain}dB"
        }
    }

    $out = Join-Path $PreviewDir "preview.wav"
    & ffmpeg -hide_banner -loglevel error -y -i $f.FullName -af $af -c:a pcm_s16le -- $out 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { return $null }
    return @{ path = $out; name = $f.Name }
}

function Render-Orig([string]$cat) {
    $files = $CatFiles[$cat]
    if (-not $files -or $files.Count -eq 0) { return $null }
    if (-not $PreviewPick.ContainsKey($cat)) { $PreviewPick[$cat] = $files | Get-Random }
    $f = $PreviewPick[$cat]
    $out = Join-Path $PreviewDir "orig.wav"
    & ffmpeg -hide_banner -loglevel error -y -i $f.FullName -c:a pcm_s16le -- $out 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { return $null }
    return @{ path = $out; name = $f.Name }
}

# --- json builders --------------------------------------------------------
function Get-StateJson {
    $cats = @()
    foreach ($c in $Categories) {
        $cats += [ordered]@{
            name    = $c.name
            label   = $c.label
            count   = $CatFiles[$c.name].Count
            value   = [double]$Settings.values[$c.name]
            default = [double]$c.default
        }
    }
    ([ordered]@{
        categories = $cats
        normalize  = $Settings.normalize
        running    = $Sync.running
        dest       = $Dest
    }) | ConvertTo-Json -Depth 5
}

function Get-ProgressJson {
    ([ordered]@{
        running = $Sync.running
        started = $Sync.started
        total   = $Sync.total
        done    = $Sync.done
        ok      = $Sync.ok
        copied  = $Sync.copied
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

function Send-File($ctx, [string]$path, [string]$type, [string]$sampleName) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = $type
    if ($sampleName) { $ctx.Response.Headers.Add("X-Sample", $sampleName) }
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

# --- UI page --------------------------------------------------------------
$Html = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>SoundMod Tuner</title>
<style>
  :root { --bg:#14161a; --panel:#1d2026; --line:#2b2f37; --fg:#e8e6e0; --dim:#8b8f98;
          --accent:#f5a524; --ok:#4ade80; --bad:#f87171; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg);
         font:14px/1.5 "Segoe UI", system-ui, sans-serif; }
  .wrap { max-width:880px; margin:0 auto; padding:24px 20px 60px; }
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
  .row { display:grid; grid-template-columns: 190px 46px 1fr 74px auto; gap:12px;
         align-items:center; background:var(--panel); border:1px solid var(--line);
         border-radius:10px; padding:10px 16px; margin-bottom:8px; }
  .row .name { font-weight:600; }
  .row .cnt { color:var(--dim); font-size:12px; text-align:right; }
  .row.zeroed { opacity:.92; }
  input[type=range] { width:100%; accent-color:var(--accent); }
  input[type=number] { width:70px; background:#12141a; color:var(--fg);
                       border:1px solid var(--line); border-radius:6px; padding:5px 6px; font:inherit; }
  .btns { display:flex; gap:6px; }
  .btns button { padding:5px 10px; font-size:12.5px; }
  .sample { grid-column: 1 / -1; color:var(--dim); font-size:11.5px; margin-top:-4px;
            min-height:0; display:none; }
  .sample.show { display:block; }
  .progress { display:none; background:var(--panel); border:1px solid var(--line);
              border-radius:10px; padding:14px 16px; margin-top:16px; }
  .progress.show { display:block; }
  .bar { height:10px; background:#12141a; border-radius:6px; overflow:hidden; margin:8px 0; }
  .bar div { height:100%; width:0%; background:var(--accent); transition:width .3s; }
  .failed { color:var(--bad); white-space:pre-wrap; font-size:12px; }
  .okmsg { color:var(--ok); }
  footer { margin-top:22px; color:var(--dim); font-size:12px; display:flex; gap:16px; }
  footer button { font-size:12px; padding:4px 10px; }
</style>
</head>
<body>
<div class="wrap">
  <header><h1>SoundMod <span>Tuner</span></h1>
    <div class="sub">per-category pitch &middot; output &rarr; <span id="dest"></span></div>
  </header>

  <div class="globals">
    <label><input type="checkbox" id="normalize"> Normalize to &minus;1 dBFS</label>
    <div class="spacer"></div>
    <button id="reset">Reset defaults</button>
    <button class="primary" id="process">Process All</button>
  </div>

  <div id="rows"></div>

  <div class="progress" id="progress">
    <div id="ptext">Processing&hellip;</div>
    <div class="bar"><div id="pbar"></div></div>
    <div id="psummary"></div>
  </div>

  <footer>
    <span>Settings save automatically when you process.</span>
    <span class="spacer"></span>
    <button id="quit">Quit server</button>
  </footer>
</div>

<script>
let state = null;
const player = new Audio();

function esc(s){ const d=document.createElement('div'); d.textContent=s; return d.innerHTML; }

async function load(){
  state = await (await fetch('/api/state')).json();
  document.getElementById('dest').textContent = state.dest;
  document.getElementById('normalize').checked = state.normalize;
  const rows = document.getElementById('rows');
  rows.innerHTML = '';
  state.categories.filter(c => c.count > 0).forEach(c => {
    const row = document.createElement('div');
    row.className = 'row' + (c.value === 0 ? ' zeroed' : '');
    row.id = 'row-' + c.name;
    row.innerHTML =
      '<div class="name">' + esc(c.label) + '</div>' +
      '<div class="cnt">' + c.count + '</div>' +
      '<input type="range" min="-5" max="5" step="0.1" value="' + c.value + '" id="sl-' + c.name + '">' +
      '<input type="number" min="-5" max="5" step="0.1" value="' + c.value + '" id="nb-' + c.name + '">' +
      '<div class="btns">' +
        '<button onclick="preview(\'' + c.name + '\',false)" title="Play processed sample">&#9654; Preview</button>' +
        '<button onclick="playOrig(\'' + c.name + '\')" title="Play original sample">Orig</button>' +
        '<button onclick="preview(\'' + c.name + '\',true)" title="Pick a different sample">&#8635;</button>' +
      '</div>' +
      '<div class="sample" id="smp-' + c.name + '"></div>';
    rows.appendChild(row);
    const sl = document.getElementById('sl-' + c.name);
    const nb = document.getElementById('nb-' + c.name);
    sl.addEventListener('input', () => { nb.value = sl.value; mark(c.name); });
    nb.addEventListener('input', () => { sl.value = nb.value; mark(c.name); });
  });
  if (state.running) { showProgress(); poll(); }
}

function mark(name){
  const v = parseFloat(document.getElementById('nb-' + name).value) || 0;
  document.getElementById('row-' + name).classList.toggle('zeroed', v === 0);
}

function val(name){
  let v = parseFloat(document.getElementById('nb-' + name).value);
  if (isNaN(v)) v = 0;
  return Math.max(-5, Math.min(5, v));
}

function gather(){
  const values = {};
  state.categories.filter(c => c.count > 0).forEach(c => { values[c.name] = val(c.name); });
  return { normalize: document.getElementById('normalize').checked, values: values };
}

async function preview(name, roll){
  const norm = document.getElementById('normalize').checked ? 1 : 0;
  const r = await fetch('/api/preview?cat=' + encodeURIComponent(name) +
                        '&st=' + val(name) + '&norm=' + norm + '&roll=' + (roll ? 1 : 0));
  if (!r.ok) return;
  showSample(name, r.headers.get('X-Sample'), val(name));
  player.src = URL.createObjectURL(await r.blob());
  player.play();
}

async function playOrig(name){
  const r = await fetch('/api/orig?cat=' + encodeURIComponent(name));
  if (!r.ok) return;
  showSample(name, r.headers.get('X-Sample'), 'orig');
  player.src = URL.createObjectURL(await r.blob());
  player.play();
}

function showSample(name, file, st){
  const el = document.getElementById('smp-' + name);
  el.textContent = file + (st === 'orig' ? '  (original)' : '  @ ' + st + ' st');
  el.classList.add('show');
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
  let html = '<span class="okmsg">Done - ' + p.ok + ' processed, ' + p.copied + ' copied untouched</span>';
  if (p.failed.length) html += '<div class="failed">Failed (' + p.failed.length + '):\n' +
                               p.failed.map(esc).join('\n') + '</div>';
  document.getElementById('psummary').innerHTML = html;
}

document.getElementById('process').addEventListener('click', processAll);
document.getElementById('reset').addEventListener('click', () => {
  state.categories.filter(c => c.count > 0).forEach(c => {
    document.getElementById('sl-' + c.name).value = c.default;
    document.getElementById('nb-' + c.name).value = c.default;
    mark(c.name);
  });
});
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
$listener = New-Object System.Net.HttpListener
$boundPort = 0
foreach ($p in $Port..($Port + 9)) {
    try {
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add("http://localhost:$p/")
        $listener.Start()
        $boundPort = $p
        break
    } catch { }
}
if ($boundPort -eq 0) { throw "Could not bind a port in range $Port-$($Port+9)." }

$targetCount = 0
foreach ($c in $Categories) { $targetCount += $CatFiles[$c.name].Count }
Write-Host ""
Write-Host "SoundMod Tuner running at http://localhost:$boundPort/"
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
                $state = 'none'; $reason = ''; $errs = @()
                if ($script:BatchPS) {
                    $state  = [string]$script:BatchPS.InvocationStateInfo.State
                    $reason = [string]$script:BatchPS.InvocationStateInfo.Reason
                    $errs   = @($script:BatchPS.Streams.Error | ForEach-Object { $_.ToString() })
                }
                ([ordered]@{ psState = $state; reason = $reason; errors = $errs
                             sync = [ordered]@{ running=$Sync.running; total=$Sync.total; done=$Sync.done
                                                ok=$Sync.ok; copied=$Sync.copied; failed=@($Sync.failed) }
                }) | ConvertTo-Json -Depth 5 | ForEach-Object { Send-Text $ctx $_ "application/json" }
            }

            '^/api/preview$' {
                $q = $ctx.Request.QueryString
                $st = 0.0; [void][double]::TryParse($q["st"], [ref]$st)
                $st = [math]::Max(-5, [math]::Min(5, $st))
                $res = Render-Preview $q["cat"] $st ($q["norm"] -eq "1") ($q["roll"] -eq "1")
                if ($res) { Send-File $ctx $res.path "audio/wav" $res.name }
                else      { Send-Text $ctx '{"error":"preview failed"}' "application/json" 500 }
            }

            '^/api/orig$' {
                $res = Render-Orig $ctx.Request.QueryString["cat"]
                if ($res) { Send-File $ctx $res.path "audio/wav" $res.name }
                else      { Send-Text $ctx '{"error":"orig failed"}' "application/json" 500 }
            }

            '^/api/process$' {
                if ($Sync.running) { Send-Text $ctx '{"error":"already running"}' "application/json" 409 }
                else {
                    $body = (New-Object IO.StreamReader($ctx.Request.InputStream, $ctx.Request.ContentEncoding)).ReadToEnd()
                    $req = $body | ConvertFrom-Json
                    if ($null -ne $req.normalize) { $Settings.normalize = [bool]$req.normalize }
                    foreach ($c in $Categories) {
                        $v = $req.values.PSObject.Properties[$c.name]
                        if ($v) { $Settings.values[$c.name] = [math]::Max(-5, [math]::Min(5, [double]$v.Value)) }
                    }
                    Save-Settings
                    $limit = 0
                    if ($null -ne $req.limit) { $limit = [int]$req.limit }
                    Start-Batch $Settings.normalize -1 $limit
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
