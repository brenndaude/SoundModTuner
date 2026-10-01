# SoundMod Tuner v2 — per-category pitch GUI

Date: 2026-08-14 · Status: implemented (v1.2)

## Goal
Per-category semitone control for the Skater XL sound pack, replacing the single
global `-Semitones` value. Some categories (bearings, shoes, rolling) should stay
unpitched while board-contact sounds go up.

## Form
`SoundModTuner.ps1` — one PowerShell 5.1 script that hosts a single-page browser
UI via `System.Net.HttpListener` on `http://localhost:<port>/` (8977, falls back
to next free port). `Launch SoundModTuner.bat` double-click launcher. The
existing `Process-SoundMod.ps1` (global pitch) stays untouched.

## Categories (assigned by filename prefix at startup; counts computed live)
| category | regex on basename | default st |
|---|---|---|
| board_land | `^board_land` | +2 |
| board_impacts | `^board(_wood)?_impacts` (incl. BOOGIE alternates) | +2 |
| concrete_grind / metal_grind / wood_grind | `^<surface>_grind` (start/end/loop locked) | +2 |
| concrete_powerslide / tarmac_powerslide | `^<surface>_powerslide` | +2 |
| ollie | `^ollie` | +2 |
| shoes_board_back | `^shoes_board_back` | 0 |
| shoes_pivot | `^shoes_pivot` | 0 |
| shoes_movement | `^shoes_movement` | 0 |
| bearing_sounds | `^bearing` | 0 |
| rolling | `^rolling` | 0 |
| other | anything unmatched | 0 |

UI/Ragdoll/`THESE WOULD GO IN RAGDOLL` folders excluded and copied untouched,
same as v1.

## UI
Row per non-empty category: label, file count, slider + number box (−5…+5,
step 0.1), ▶ Preview (random sample rendered through the real ffmpeg pipeline at
the current value, played in-browser), ▶ Orig (same sample unprocessed, 16-bit
transcode for browser compat), ↻ re-roll sample. Global: Normalize checkbox
(−1 dBFS, on by default), Process All with live progress bar + completion
summary (processed / copied / failed list), Reset defaults, Quit.

## Endpoints
`GET /` page · `GET /api/state` categories+saved settings · `GET /api/preview`
(cat, st, norm, roll) → WAV, sample name in `X-Sample` header · `GET /api/orig`
(cat) → WAV · `POST /api/process` settings JSON · `GET /api/progress` ·
`POST /api/quit`.

## Processing
Identical verified v1 pipeline per file: varispeed `asetrate=<sr*2^(st/12)>,
aresample=<sr>`; optional two-pass peak normalize (volumedetect → exact
`volume` gain to −1 dBFS); codec/sample-rate/channels/bit-depth preserved.
Category at 0 st with normalize off ⇒ bit-for-bit copy, no re-encode. Batch
runs in a background runspace with a synchronized hashtable so the listener
keeps serving progress/preview. Per-file failures collected, never fatal.
Output: `Sounds_processed` drop-in pack (848/848 parity).

## Settings persistence
Slider values + normalize flag saved to `tuner-settings.json` next to the
script when Process is clicked; loaded on next launch.

## Error handling
Missing ffmpeg/Source → clear startup error. Port busy → next port. Probe or
render failure → file listed in summary. Second Process while running → 409.

## Testing
Launch server headless, then: `/api/state` counts sum to 582 targets + 266
copies; `/api/preview` returns valid WAV with correct duration ratio; full
`/api/process` run with defaults verified for parity, per-category pitch
ratios (e.g. ollie 0.8909, bearing 1.0), peaks at −1 dBFS where normalized.
