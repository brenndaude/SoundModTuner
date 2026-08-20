<#
.SYNOPSIS
    Shared ffmpeg filter-chain construction for SoundModTuner.

.DESCRIPTION
    Dot-sourced by SoundModTuner.ps1 for the preview path AND from inside the
    batch runspace for the render path, so a preview is guaranteed to be built
    by the same code that builds the file you ship. If these ever drift, what
    you hear stops matching what you get.

    Every number that reaches an ffmpeg filter string is formatted with the
    invariant culture. On a machine with a comma decimal separator (fr-FR and
    friends) "0,7" would silently corrupt the filter graph.
#>

Set-StrictMode -Off

# --- ranges (deliberately narrow: this is a fine-tuning tool) --------------
$script:FxLimits = @{
    st   = @{ min = -5;   max = 5    }
    vol  = @{ min = -18;  max = 6    }
    eqF  = @{ min = 30;   max = 16000 }
    eqG  = @{ min = -12;  max = 12   }
    eqQ  = @{ min = 0.5;  max = 4    }
}

# Band 0 is a low shelf, 1-3 are peaking, 4 is a high shelf - the standard
# 5-point mixer EQ layout.
$script:EqBands = @(
    @{ f = 80;   q = 0.7; kind = 'lowshelf'  }
    @{ f = 250;  q = 1.0; kind = 'peak'      }
    @{ f = 1000; q = 1.0; kind = 'peak'      }
    @{ f = 3500; q = 1.0; kind = 'peak'      }
    @{ f = 9000; q = 0.7; kind = 'highshelf' }
)

$script:ClipCeilingDb = -0.3

function Format-Num {
    param([double]$Value, [string]$Fmt = "0.####")
    return $Value.ToString($Fmt, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Parse-Num {
    param([string]$Text)
    $v = 0.0
    $ok = [double]::TryParse($Text, [System.Globalization.NumberStyles]::Float,
                             [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)
    if ($ok) { return $v }
    return $null
}

function Clamp-Num {
    param([double]$Value, [double]$Min, [double]$Max)
    return [math]::Max($Min, [math]::Min($Max, $Value))
}

# --- fx settings objects --------------------------------------------------

function New-Fx {
    param([double]$St = 0)
    $eq = @()
    foreach ($b in $script:EqBands) {
        $eq += @{ f = [double]$b.f; g = 0.0; q = [double]$b.q }
    }
    return @{
        st  = [double]$St
        vol = 0.0
        eq  = $eq
    }
}

<#
    Accepts anything that came out of ConvertFrom-Json (or a bare number from a
    v1 settings file) and returns a clean, clamped hashtable. Unknown or missing
    fields fall back to defaults rather than throwing - a hand-edited settings
    file should degrade, not break the app.
#>
function ConvertTo-Fx {
    param($Raw, [double]$Default = 0)

    $fx = New-Fx $Default
    if ($null -eq $Raw) { return $fx }

    # v1 schema: the whole per-category value was just the semitone number.
    if ($Raw -is [double] -or $Raw -is [int] -or $Raw -is [long] -or $Raw -is [decimal]) {
        $fx.st = Clamp-Num ([double]$Raw) $script:FxLimits.st.min $script:FxLimits.st.max
        return $fx
    }

    $get = {
        param($obj, $name)
        if ($null -eq $obj) { return $null }
        if ($obj -is [hashtable]) { if ($obj.ContainsKey($name)) { return $obj[$name] } return $null }
        $p = $obj.PSObject.Properties[$name]
        if ($p) { return $p.Value }
        return $null
    }

    $st = & $get $Raw 'st'
    if ($null -ne $st) { $fx.st = Clamp-Num ([double]$st) $script:FxLimits.st.min $script:FxLimits.st.max }

    $vol = & $get $Raw 'vol'
    if ($null -ne $vol) { $fx.vol = Clamp-Num ([double]$vol) $script:FxLimits.vol.min $script:FxLimits.vol.max }

    $eq = & $get $Raw 'eq'
    if ($eq) {
        $arr = @($eq)
        for ($i = 0; $i -lt $script:EqBands.Count -and $i -lt $arr.Count; $i++) {
            $b = $arr[$i]
            if ($null -eq $b) { continue }
            $f = & $get $b 'f'; $g = & $get $b 'g'; $q = & $get $b 'q'
            if ($null -ne $f) { $fx.eq[$i].f = Clamp-Num ([double]$f) $script:FxLimits.eqF.min $script:FxLimits.eqF.max }
            if ($null -ne $g) { $fx.eq[$i].g = Clamp-Num ([double]$g) $script:FxLimits.eqG.min $script:FxLimits.eqG.max }
            if ($null -ne $q) { $fx.eq[$i].q = Clamp-Num ([double]$q) $script:FxLimits.eqQ.min $script:FxLimits.eqQ.max }
        }
    }

    return $fx
}

function Test-FxIsDefault {
    param($Fx)
    if ($Fx.st -ne 0)  { return $false }
    if ($Fx.vol -ne 0) { return $false }
    foreach ($b in $Fx.eq) { if ($b.g -ne 0) { return $false } }
    return $true
}

# Only these can push the peak up, so the clip-guard pass is skipped otherwise.
function Test-FxCanBoost {
    param($Fx)
    if ($Fx.vol -gt 0) { return $true }
    foreach ($b in $Fx.eq) { if ($b.g -gt 0) { return $true } }
    return $false
}

# --- filter chain ---------------------------------------------------------

function Get-EqFilters {
    param($Fx)
    $out = @()
    for ($i = 0; $i -lt $script:EqBands.Count; $i++) {
        $b = $Fx.eq[$i]
        if ($b.g -eq 0) { continue }
        $f = Format-Num $b.f
        $q = Format-Num $b.q
        $g = Format-Num $b.g
        switch ($script:EqBands[$i].kind) {
            'lowshelf'  { $out += "bass=f=${f}:width_type=q:w=${q}:g=${g}" }
            'highshelf' { $out += "treble=f=${f}:width_type=q:w=${q}:g=${g}" }
            default     { $out += "equalizer=f=${f}:width_type=q:w=${q}:g=${g}" }
        }
    }
    return $out
}

<#
    Signal order: pitch -> EQ -> volume. Volume sits last so the slider is a
    true output trim.

    Nothing here changes the length of a file: varispeed scales it uniformly
    and EQ/volume are sample-for-sample. That matters because the pack has 35
    looping files (*_loop*, rolling, bearings) which the game loops itself -
    anything appending a tail would put a discontinuity at the loop point.
#>
function Get-FxChain {
    param($Fx, [int]$SampleRate)

    $chain = @()

    if ($Fx.st -ne 0) {
        $newRate = [int][math]::Round($SampleRate * [math]::Pow(2, $Fx.st / 12))
        $chain += "asetrate=$newRate"
        $chain += "aresample=$SampleRate"
    }

    $chain += Get-EqFilters $Fx

    if ($Fx.vol -ne 0) {
        $chain += "volume=$(Format-Num $Fx.vol)dB"
    }

    if ($chain.Count -eq 0) { $chain += "anull" }
    return ($chain -join ",")
}

# --- measurement ----------------------------------------------------------

<#
    volumedetect is not usable here: it clamps at 0 dBFS, so a chain overshooting
    by 3 dB reports a reassuring "0.0". astats in float reports the real peak.
    Returns $null when the peak can't be read (silence reports -inf).
#>
function Get-ChainPeakDb {
    param([string]$Path, [string]$Af, [string]$Seek = "", [string]$Duration = "")

    # NB: not $args - that is an automatic variable and shadowing it here bites.
    $ffArgs = @("-hide_banner", "-nostats")
    if ($Seek)     { $ffArgs += @("-ss", $Seek) }
    if ($Duration) { $ffArgs += @("-t", $Duration) }
    $ffArgs += @("-i", $Path, "-af", "aformat=sample_fmts=fltp,$Af,astats=metadata=1:reset=0", "-f", "null", "-")

    $out = (& ffmpeg @ffArgs 2>&1) | Out-String
    $ms = [regex]::Matches($out, "Peak level dB:\s*(-?[\d.]+)")
    if ($ms.Count -eq 0) { return $null }
    return (Parse-Num $ms[$ms.Count - 1].Groups[1].Value)
}

<#
    Attenuate-only safety net. It never boosts and never moves categories toward
    a common level, so the intended mix - bearings sitting under rolling - is
    preserved exactly. It only pulls back files that would otherwise clip.
    Returns the chain to render plus the trim it applied, so the UI can say so.
#>
function Add-ClipGuard {
    param([string]$Path, [string]$Af, $Fx, [string]$Seek = "", [string]$Duration = "")

    $result = @{ af = $Af; trimDb = 0.0; peakDb = $null }
    if (-not (Test-FxCanBoost $Fx)) { return $result }

    $peak = Get-ChainPeakDb -Path $Path -Af $Af -Seek $Seek -Duration $Duration
    if ($null -eq $peak) { return $result }

    $result.peakDb = $peak
    if ($peak -gt $script:ClipCeilingDb) {
        $trim = [math]::Round($script:ClipCeilingDb - $peak, 2)
        $result.af = "$Af,volume=$(Format-Num $trim)dB"
        $result.trimDb = $trim
        $result.peakDb = [double]$script:ClipCeilingDb
    }
    return $result
}

# --- encoding -------------------------------------------------------------

function Get-CodecArgs {
    param([string]$Codec, [string]$Extension)
    if ($Codec -like "pcm_*") { return @("-c:a", $Codec) }   # keep exact bit depth
    switch ($Extension.ToLower()) {
        ".ogg"  { return @("-c:a", "libvorbis", "-q:a", "6") }
        ".mp3"  { return @("-c:a", "libmp3lame", "-q:a", "2") }
        ".flac" { return @("-c:a", "flac") }
        default { return @("-c:a", "pcm_s16le") }
    }
}

function Get-AudioInfo {
    param([string]$Path)
    $probe = (& ffprobe -v error -select_streams a:0 `
        -show_entries stream=codec_name,sample_rate `
        -show_entries format=duration -of csv=p=0 -- $Path)
    $lines = @($probe | Where-Object { $_ -and $_.Trim() })
    if ($lines.Count -eq 0) { return $null }

    $parts = $lines[0].Trim() -split ","
    if ($parts.Count -lt 2) { return $null }
    $dur = 0.0
    if ($lines.Count -gt 1) {
        $d = Parse-Num $lines[1].Trim()
        if ($null -ne $d) { $dur = $d }
    }
    return @{ codec = $parts[0]; sampleRate = [int]$parts[1]; duration = $dur }
}
