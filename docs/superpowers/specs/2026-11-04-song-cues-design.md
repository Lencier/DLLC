# Song Cues: design

Status: approved by the user · 2026-11-04

## Why

DLLC is built for our own MV / production work. On shoot day the AD plays the song from an iPhone and
has to scrub to the right second before every take ("Verse 1 starts at 1:42", "go back to 2:01, three
seconds before Hook 1"), remember which part of the song is which, and sometimes make a special file
with a metronome count before the music for dance takes.

Song Cues moves that work to the night before. On the Mac you mark the song's sections once and export
small, ready-to-play files: one per part you'll shoot, already trimmed, with an optional count-in, named
so the AD can just tap "Hook 2" on the iPhone. The phone stays the playback device on set.

## Goals

- Open a song (MP3, M4A, WAV, AIFF, or the audio of any downloaded item) and see a clear waveform.
- Mark sections freely: pick a common name (Intro, Verse, Pre-hook, Hook, Bridge, Outro…) or type any
  name. Each section can have an optional note / lyrics.
- Export one section, several consecutive sections, or any range dragged on the waveform, as an
  audio file for the iPhone.
- Per export, choose:
  - padding: start exactly at the section, or add N seconds before and/or after;
  - fade out at the end: on or off;
  - count-in: on or off, how many counts, every 1 s or every ½ s, and the sound;
  - speed: normal, fast ×2 / ×3 / ×4, or slow ×0.5 / ×0.33 / ×0.25 (for shooting slow motion or
    fast motion to the song).
- Lyric video: export a section (or several) as a simple video with the lyrics/notes on screen.
- Send the exported files straight to the iPhone with AirDrop.
- Light enough to run smoothly on a base M1 with 8 GB of memory.

## Non-goals (for this version)

- No playback tool for the set itself; the iPhone plays the files.
- No forced scene/shot structure. A typed prefix such as `S5Sh4` is allowed but never required.
- No beat detection or BPM syncing; the count-in is in seconds.
- No editing of the original song file, ever.
- Reference reels (joining clips/GIFs into one overview with remarks) and overlay edits (burned-in
  timecode, text, resize) are separate projects. They get their own design after this one.

## Anti-goals: things that would make this a failure even if it works

- Feeling like a DAW: too many controls before you can export "Hook 2".
- Slowing down the rest of the app, or using noticeable memory or disk.
- Anything that could alter or delete the user's song or downloaded files.

## How it works for the user

1. Open a song: drag a file onto DLLC, use **File › Open Song…**, or choose **Open in Song Cues**
   on a downloaded audio/video item in the queue.
2. The song view shows the waveform full width, with a playhead, time ruler and zoom (same pinch /
   ⌘-scroll / zoom bar as the video timeline).
3. Add a section by dragging across the waveform, or press M at the playhead to start one. Name it from
   a menu of common names or by typing. Sections can be resized by their edges and are listed below
   the waveform with their start time, length and note.
4. Select one section, shift-click to extend over consecutive sections, or drag any range. The export
   bar shows the result live: `Intro+Verse 1 · 1:42 → 2:31 · 49 s`.
5. Export options sit in one compact row, remembered between exports:
   - **Before / After**: 0 (exact), 1, 2, 3, 5, 10 s, or typed.
   - **Fade out**: on/off (default 1.5 s when on).
   - **Count-in**: off, or count 3 / 4 / 5 / 8; every 1 s or ½ s; sound: beep, click or woodblock.
   - **Speed**: a menu reading `×4`, `×3`, `×2`, `×1`, `×0.5 (slow 2×)`, `×0.33 (slow 3×)`,
     `×0.25 (slow 4×)`. The song view's play button follows the same speed, so it can be heard before
     exporting.
   - **As**: Audio (MP3/WAV) or Lyric video (MP4).
6. **Export** writes the file into the song's folder (or the project's save folder) and offers
   **AirDrop** and **Show in Finder**. Several selections can be exported at once.

### Count-in behaviour

- A count of N plays N ticks at the chosen interval, then the audio starts on the next tick:
  "3 · 2 · 1 · song". The first tick is accented (higher pitch). Ticks are generated in code, so there
  are no sound files to ship.
- With **Before** padding on, the count-in leads into the padded start, not the section start.
  The count gets the AD and performers ready; the padding gives the lead-in of the music.

### Speed behaviour

- Pitch is kept (tempo change only), so words stay recognisable for lip sync.
- Padding is measured in song time, then sped up with the music. The count-in is never sped up: its
  ticks stay at the chosen real-time interval so performers get the same count.
- The file name gets the speed: `Hook 2 x2.mp3`, `Hook 2 x0.5.mp3`.

### Lyric video

- Each section's note/lyrics shows as large centred text for that section's duration, over a plain dark
  background, with the section name and a running timecode small at the top. The count-in shows as a
  big "3 · 2 · 1".
- Lyrics can be timed line by line: in the section's lyrics, play the song and press Space at each line
  ("tap to time"); untimed lines share the section's time evenly.
- 1280×720, 30 fps, H.264 + AAC, rendered with ffmpeg's text drawing. Speed and padding apply as for
  audio.

### File names

- One section: its name, e.g. `Hook 2.mp3`.
- Consecutive sections: names joined with `+`, e.g. `Intro+Verse 1.mp3`. Past three sections, it's
  `first→last`, e.g. `Intro→Hook 1.mp3`.
- A free range with no section: `Song name 1m42s-2m31s.mp3`.
- Optional prefix field (empty by default): `S5Sh4 Hook 2.mp3`.
- If the name already exists, a number is added: `Hook 2 (2).mp3`. Nothing is ever overwritten.

### Format

- MP3 by default (plays everywhere: iPhone Files, WhatsApp, LINE, any laptop), 256 kbps.
- WAV can be chosen for maximum quality.
- MP3 encoding cuts the first few milliseconds when exported without padding. Any encoder delay must be
  trimmed so "start exactly at the section" really is exact (verify by test).

## Where it lives in the app (builder's call, open to change)

- A **Songs** entry in the sidebar under All Downloads, listing opened songs. Selecting a song replaces
  the queue/preview area with the song view.
- A song and its sections are stored as a small JSON document in Application Support, keyed by the
  song file's bookmark. The song file itself stays where it is.
- Songs can belong to a project like downloads do, so its exports go to that project's folder.

## Performance and resources

- The waveform is computed once in the background (AVAssetReader → 16-bit mono at a low rate →
  peaks), then cached as a small peaks file of a few hundred KB per song in the app's cache. It falls
  under the existing cache limits and can always be rebuilt.
- Drawing uses the precomputed peaks with a level of detail that fits the zoom, never raw samples.
- Playback uses AVAudioPlayer / AVPlayer, which is near-zero cost.
- Export runs the bundled ffmpeg once per file (trim, padding, fade, mixing in the generated count-in).
  It takes well under a second for a typical section.

## Constraints

- Swift 6 / SwiftUI, macOS 15+, Apple Silicon only; the same project and style as the rest of DLLC.
- Uses only the bundled ffmpeg. No new dependencies, no network.
- Subprocess arguments are passed as arrays.
- Respect existing rules: ask where to save the first time per project, never overwrite, never
  delete user files.

## Decided by the user

- Section names are free; common names are suggestions only.
- Exported file names are the section names (`Hook 2`, `Intro+Verse 1`).
- Fade out is optional.
- Count-in: the user chooses how many seconds/counts and the style; the feel is "3, 2, 1, song".
- Padding before/after is optional; the default is exact.
- Playback on set stays on the iPhone.

## Builder's calls (marked so they can be challenged)

- MP3 256 kbps default, WAV optional (user asked whether MP3 is more universal: yes).
- Speed keeps pitch; the count-in isn't sped up; the speed goes in the file name.
- Lyric video look (dark background, centred text, small section name and timecode) and tap-to-time.
- Count-in leads into the padded start.
- Accent on the first tick; tick sounds are generated in code.
- The Songs sidebar entry and JSON storage.
- Max three names joined before switching to `first→last`.
- Default fade length 1.5 s.
- Sections don't overlap; dragged edges snap to a neighbour's edge. "Consecutive sections" means
  adjacent in time; the export runs from the first one's start to the last one's end.
- Section edits support Undo/Redo.
- The filename prefix is stored per song.
- Song exports run directly from the song view with their own progress, not through the download
  queue (they are local, fast and need no retry logic).
- AirDrop uses the system share service; nothing is uploaded anywhere else.

## Next project: Reel (not part of this one)

Arrange clips/GIF ranges from several downloads in one track, in order, with a remark and length per
shot, plus **one music track under them** (a song or a Song Cues section), so a shot's length can be
checked against the hook. Clips are silent by default; any clip's own sound can be switched on.
Export as video/GIF, or as a timeline file for Premiere/DaVinci. It reuses this project's waveform and
timeline pieces. It gets its own design.

## Left for later

- Optional click track through the whole file (for dance), and a "repeat with gap" file for
  back-to-back takes.
- A printable cue sheet (PDF) listing sections, times and lyrics.
- BPM-synced counting.
