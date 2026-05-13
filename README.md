# mkv-audio-reorder

<img width="1118" height="630" alt="image" src="https://github.com/user-attachments/assets/2f193d94-670d-4966-b4f6-20fbb461caad" />
<img width="1117" height="623" alt="image" src="https://github.com/user-attachments/assets/2804f3c7-d4ae-44b4-8c43-46da9555ba38" />

Windows drag-and-drop tools for losslessly reordering audio tracks in MKV files.

Built for prepping Plex libraries: a lot of remote clients can direct-play AC-3 / E-AC-3 but transcode TrueHD/Atmos. Moving the compressed core track to position 1 and marking it default fixes that without re-encoding anything.

- No re-encoding. mkvmerge remuxes existing streams.
- Safe by default: keeps a `.bak` of the original until you delete it.
- Two modes: single-file interactive, or batch over a folder.

## Requirements

- Windows 10 / 11
- [MKVToolNix](https://mkvtoolnix.download/) — the batch file will offer to install it via `winget` if missing.
- PowerShell 5.1 (ships with Windows) or PowerShell 7+.

## Install

1. Download or clone this repo.
2. Drop the four files anywhere — they only need to sit next to each other:
   ```
   mkv-reorder.bat
   mkv-reorder.ps1
   mkv-batch-reorder.bat
   mkv-batch-reorder.ps1
   ```
3. On first run, accept the prompt to install MKVToolNix (or install it manually from the link above).

That's it — no PATH setup, no PowerShell execution-policy changes required (the bats pass `-ExecutionPolicy Bypass`).

## Usage: single file

Drag any `.mkv` onto **`mkv-reorder.bat`**.

```
File: Movie Name (2024).mkv

Audio tracks:
  [ 1] TrueHD Atmos             7.1   eng  "Surround 7.1"                 [DEFAULT]
  [ 2] AC-3                     5.1   eng  "Surround 5.1"
  [ 3] AC-3                     2.0   eng  "Commentary"

Which audio track should be the new default? Enter track ID: 2

Will move track [2] AC-3 5.1 to be the first audio track and set it as default.
Original will be backed up to: Movie Name (2024).mkv.bak
This will take 1-3 minutes depending on file size. No re-encoding.

Proceed? [Y/N]: y
Remuxing...
Done in 01:23
```

From the command line:

```
mkv-reorder.bat "D:\Movies\Movie Name (2024)\Movie Name (2024).mkv"
```

## Usage: batch over a folder

Drag a folder onto **`mkv-batch-reorder.bat`**.

It will:

1. Recursively scan every `.mkv` under the folder.
2. Filter to files whose **first audio track** matches the codec filter (default: `TrueHD Atmos`).
3. Walk you through each match one at a time — pick the new first track, skip, stop reviewing, or cancel.
4. Show the queue and ask once to confirm.
5. Process the queue sequentially. Failures are reported but don't stop the run.
6. Write a CSV log next to the folder.

```
mkv-batch-reorder.bat "D:\Plex\Movies"
```

### Per-movie prompt

```
[5 of 84] Movie Name (2024)/Movie Name (2024).mkv

Audio tracks:
  [ 1] TrueHD Atmos             7.1   eng  "Surround 7.1"                 [DEFAULT]
  [ 2] AC-3                     5.1   eng  "Surround 5.1"
  [ 3] AC-3                     2.0   eng  "Commentary"

Track ID for new default, [s]kip, [q]uit review, [c]ancel all: 2
  Queued: move [2] AC-3 5.1 to first.
```

### Flags

All flags can follow the file or folder argument.

| Flag | Applies to | Effect |
|---|---|---|
| `--no-backup` | both | Replace the original instead of keeping `.bak`. |
| `--dry-run` | both | Print what would happen; don't touch any file. |
| `--filter "<regex>"` | batch | Override the codec filter. Default: `TrueHD Atmos`. Use `.` to match everything. |
| `--no-log` | batch | Disable CSV logging. |
| `--log-path "<file>"` | batch | Override the CSV log location. |

Examples:

```
mkv-batch-reorder.bat "D:\Plex\Movies" --dry-run
mkv-batch-reorder.bat "D:\Plex\Movies" --filter "TrueHD"
mkv-batch-reorder.bat "D:\Plex\Movies" --no-backup --filter "DTS-HD"
mkv-reorder.bat "D:\Movies\Foo.mkv" --no-backup
```

## How it works

The remux step builds an mkvmerge command of the form:

```
mkvmerge --output file.mkv.tmp \
         --track-order 0:0,0:2,0:1,0:3,0:4 \
         --default-track-flag 1:0 \
         --default-track-flag 2:1 \
         --default-track-flag 3:0 \
         file.mkv
```

- `--track-order` puts video first, then the chosen audio, then remaining audio in original order, then subtitles.
- `--default-track-flag` sets the chosen audio to default and clears the flag on every other audio track.
- Output goes to `file.mkv.tmp`. On success: original is renamed to `file.mkv.bak`, temp is renamed to `file.mkv`. On failure: temp is deleted; original is untouched.

No streams are decoded or re-encoded. Output file size typically differs by ~0.05-0.1% — mkvmerge regenerates cluster boundaries and the cue (seek) index. This is expected.

## CSV log (batch mode)

A timestamped CSV is written next to the target folder by default, e.g. `mkv-batch-reorder-Movies-20260512-142301.csv`.

```csv
timestamp,relative_path,chosen_track_id,chosen_codec,chosen_channels,status,elapsed_seconds,error
2026-05-12 14:23:01,Movie A (2024)/Movie A (2024).mkv,2,AC-3,5.1,ok,87,
2026-05-12 14:24:33,Movie B (2024)/Movie B (2024).mkv,3,AC-3,5.1,failed,12,mkvmerge exit 2
```

Rows are appended as each file finishes, so a partial log survives a crash or interrupt.

## Safety

- Original is preserved as `<name>.mkv.bak` unless you pass `--no-backup`.
- The remux is atomic from your point of view: either the new file is in place, or the original is still there. Temp output is cleaned up on any failure.
- Streams are copied bit-for-bit. To verify a remux, compare `mkvmerge --identify` output on the original `.bak` and the new file — only track order and default flags should differ.

## Troubleshooting

**"mkvmerge.exe not found"** — install MKVToolNix from <https://mkvtoolnix.download/>, or accept the winget install prompt in the .bat.

**"`GetRelativePath` does not exist" or similar PowerShell errors** — make sure you're running the current `mkv-batch-reorder.ps1`. Windows PowerShell 5.1 is supported; the script avoids .NET 5+ APIs.

**The script seems to do nothing on drag-drop** — open `cmd`, run the .bat with the path in quotes, and read the output. The drag-drop window auto-closes only after `pause`, so an early-exit error would normally be visible.

**A file failed mid-batch** — the original is intact, the temp file was deleted, and the CSV log has the error message. Subsequent files in the queue still ran.

## Out of scope

These intentionally aren't features:

- Re-encoding audio (e.g. TrueHD → EAC-3 conversion)
- Adding new audio tracks
- Subtitle reordering
- A GUI
- macOS / Linux ports

## License

MIT
