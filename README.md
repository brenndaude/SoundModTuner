# SoundModTuner

Batch pitch-tuning tools for Skater XL sound mod packs, built on ffmpeg.
Pitch board sounds up or down — per category or globally — while leaving
menu (UI) and bail (Ragdoll) sounds untouched, and keeping every file's
format (codec, sample rate, channels, bit depth) and filename intact so the
output is a drop-in replacement mod.

## Requirements

- Windows 10/11 (stock Windows PowerShell 5.1 — nothing to install)
- Your sound pack in a `Sounds` folder next to the scripts
- Internet on first launch: if [ffmpeg](https://ffmpeg.org) isn't already
  installed, the app downloads a portable build automatically (~170 MB, one
  time) into a local `bin` folder — no admin rights, nothing touches your
  system PATH. Already have ffmpeg? It's used as-is and nothing is downloaded.

## SoundModTuner.ps1 — per-category GUI

Double-click `Launch SoundModTuner.bat` (or run
`powershell -ExecutionPolicy Bypass -File .\SoundModTuner.ps1`).
A local browser page opens with a pitch slider per sound category:

- Categories are detected from filename prefixes (lands, impacts,
  concrete/metal/wood grinds, powerslides, ollies, bearings, shoes, rolling).
  Grind start/end/loop files stay locked together per surface.
- **Preview** renders a real sample through the ffmpeg pipeline at your
  current slider value and plays it in the browser; **Orig** plays the same
  sample unprocessed for instant A/B.
- Optional peak normalization to −1 dBFS (dynamics untouched).
- **Process All** builds `Sounds_processed` with live progress. Categories at
  0 st (normalize off) are copied bit-for-bit; excluded folders (`UI`,
  `Ragdoll`) are always copied untouched.
- Slider values persist to `tuner-settings.json` between sessions.

The server listens on `http://localhost:8977` (falls back to the next free
port) and only accepts local connections. Close the terminal window or use
the Quit button to stop it.

## Process-SoundMod.ps1 — global CLI

One pitch value for every board sound:

```powershell
.\Process-SoundMod.ps1 -Semitones 2             # +2 st, pitch only
.\Process-SoundMod.ps1 -Semitones 1.5 -Normalize # + peak normalize to -1 dBFS
.\Process-SoundMod.ps1 -Semitones 2 -Limit 1     # quick single-file test
```

`-Semitones` accepts −5 to +5 (decimals allowed).

## How the pitch shift works

Varispeed via ffmpeg `asetrate`/`aresample` — pitch and length change
together, which sounds natural on percussive one-shots (+2 st shortens a
sample ~11%). Originals are never modified; everything is written to
`Sounds_processed`.
