# CLAUDE.md

Guidance for Claude when working on this project.

## What this project is

Windows tools for losslessly reordering audio tracks in MKV files. Built primarily for Plex library prep — so remote streams direct-play AC-3/E-AC-3 instead of forcing TrueHD/Atmos transcodes.

Two tool pairs, each a `.bat` launcher + `.ps1` worker:

- `mkv-reorder.bat` / `mkv-reorder.ps1` — interactive, single file. Drag one MKV onto it.
- `mkv-batch-reorder.bat` / `mkv-batch-reorder.ps1` — batch mode. Drag a folder onto it, review per-movie, run queue.

## Hard constraints

- **Target shell is Windows PowerShell 5.1** (the version that ships with Windows). Do not use APIs that only exist in PowerShell 7 / .NET 5+:
  - `[System.IO.Path]::GetRelativePath` — does not exist on 5.1. Use the local `Get-RelativePath` helper.
  - `ForEach-Object -Parallel` — 7+ only.
  - `??` / `?.` null-coalescing — 7+ only.
- **No re-encoding, ever.** mkvmerge `--track-order` reorders existing tracks; that's the entire point. No `--audio-tracks`-style stream selection, no codec conversion.
- **Always write to a temp file and swap.** Never write over the original in place. Pattern: `file.mkv.tmp` → rename original to `file.mkv.bak` → rename temp to `file.mkv`. On mkvmerge failure, delete temp and leave original untouched.
- **mkvmerge track IDs are global and 0-based across track types.** A typical MKV is video=0, audio=1..N, subtitles=N+1.. — do not renumber them when displaying or building `--track-order`.

## Architecture

- The `.bat` exists for two reasons only: drag-and-drop targets on Windows, and dependency bootstrap (`winget install MoritzBunkus.MKVToolNix`). All real logic lives in the `.ps1`.
- The `.bat` looks for `mkvmerge.exe` at `C:\Program Files\MKVToolNix\`, then `C:\Program Files (x86)\MKVToolNix\`, then PATH. The PS1 repeats the same check (don't assume the bat ran first — someone may invoke the PS1 directly).
- Track-order convention when remuxing: **video tracks → chosen audio → remaining audio in original order → subtitles in original order.** Always one input file, so every entry is `0:<track_id>`.
- Default-flag handling: explicitly set `--default-track-flag <id>:1` on the chosen audio and `:0` on every other audio track. Don't touch video/subtitle default flags.

## Codec filter (batch tool)

The batch tool filters by **first audio track codec** using a regex against mkvmerge's `codec` field. mkvmerge emits human-readable names:
- TrueHD with Atmos → `"TrueHD Atmos"`
- TrueHD without Atmos → `"TrueHD"`
- DTS-HD MA → `"DTS-HD Master Audio"`
- AC-3 → `"AC-3"`, E-AC-3 → `"E-AC-3"`

Default filter is `TrueHD Atmos`. The `-Filter` param overrides — pass `.` to match everything.

## Shared helpers (duplicated across the two PS1s, intentionally)

- `Find-Mkvmerge` — locates the binary
- `Format-Channels` — maps integer channel count to dot notation (6→5.1, 8→7.1, etc.)
- `Get-RelativePath` — PS 5.1-safe relative-path helper (batch tool only)
- `Invoke-Remux` (batch tool) — the remux core

The two scripts are intentionally independent — no shared module. If you fix a bug in one, check whether the other needs the same fix.

## Things to leave alone

- Don't add parallelism to the batch scan. mkvmerge `--identify` is already fast (~50-200ms/file) and sequential keeps progress output sane on PS 5.1.
- Don't switch to ffprobe. Single-dependency (MKVToolNix) is a feature.
- Don't add a GUI or remove the drag-and-drop bat. Drag-drop is the primary entry point.
- Don't add features called out as out-of-scope in the original spec: multi-file in the single tool, re-encoding, adding new tracks, subtitle reordering.

## Common edits

- Adding a new flag: declare in PS1 `param()` block, forward through the `.bat` (the bats already pass `%2 %3 %4 ...`, so most flags work without bat changes).
- Adding a new codec to channel mapping: extend `Format-Channels`.
- Changing the swap behavior: touch the file-rename block at the end of `Invoke-Remux` (batch) or the equivalent in the single-file script.

## Testing

No automated tests. Manual verification:
1. Normal MKV (TrueHD track 1, AC-3 5.1 track 2) — confirm AC-3 ends up first and flagged default
2. Single-audio MKV — should bail with "nothing to reorder"
3. Non-MKV — should reject cleanly
4. Confirm-prompt cancel — original untouched
5. Forced mkvmerge failure (e.g., point at a corrupt MKV) — temp file removed, original intact

A normal remux of a ~70 GB file finishes in 1-3 minutes on local SSDs. File size grows ~0.05-0.1% (mkvmerge regenerates cluster boundaries and the cue index) — expected, not a bug.
