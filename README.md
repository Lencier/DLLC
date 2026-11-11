# DLLC

A native macOS app for saving videos, audio, clips, GIFs and still frames from YouTube, Instagram,
Pinterest (videos, images and carousels) and X. Paste links, choose an output, and the queue does the rest.

- Apple Silicon, macOS 15 or later. SwiftUI + AppKit + AVFoundation, no web views.
- Bundles pinned, checksum-verified copies of yt-dlp, FFmpeg/ffprobe and Deno. It never uses tools from your `PATH`.
- Your queue, settings, caches and logs live outside the app bundle.

## Install

1. Download `DLLC-<version>.dmg` from the [latest release](https://github.com/Lencier/DLLC/releases/latest),
   open it and drag **DLLC** to Applications.
2. The app is **ad-hoc signed and not notarized** (no Apple Developer ID was available), so macOS
   blocks the first launch. Right-click DLLC → **Open** → **Open**. On macOS 15 you may instead need
   System Settings → Privacy & Security → **Open Anyway**. You only do this once.

## Using it

| Task | How |
|---|---|
| Add links | Paste one or more links into the bar (⇧⌘V pastes links from the clipboard, only when you ask). Duplicates show a warning but are still added. A YouTube link that also names a playlist or Mix (`watch?v=…&list=…`) adds just that video; use a `/playlist?list=…` link for the whole playlist. |
| Projects | The sidebar groups links into projects (**New Project**, ⇧⌘N). Links pasted while a project is selected join it and save into a subfolder named after it. Move items with the row menu › Move to Project, or drag rows onto a project. Deleting a project keeps its items (they return to All Downloads) and never deletes files. |
| Choose the output | Each row's chip opens Output: Video (real quality options with size estimates), Audio (original / MP3), Clip, Frame or GIF. "Use as Default" applies it to new links. Next to the chip, the row shows the estimated file size (≈ means it's a guess: the site gave no exact size, or the file is resized, converted or cut). Every Size choice (Original / Smaller / Smallest) and every quality shows its own estimate, and Clip, GIF and Frame show theirs for the current range and settings. |
| Download | The large **Download** button on a row, or **Download All** (⌘↩; inside a project, only that project). Items still being analysed are included and start when ready. The red trash button removes a row (files stay on disk). |
| Multi-item posts | Instagram carousels and playlists ask which items you want. |
| Preview / cut | Click a row (or its thumbnail) — the preview opens beside the list before anything is downloaded. Space plays, ← → step one frame, I / O set In / Out. The timeline shows thumbnails; drag the orange handles to choose the range (they start at the whole video), drag anywhere else to scrub, or type times. **Whole Video** resets the range. For long videos, zoom the timeline (trackpad pinch, ⌘-scroll, the zoom buttons or **Zoom to Range**), swipe sideways or drag the overview bar to move along it, and **Fit** to see it all again. |
| Clip | Precise (frame-accurate, re-encoded H.264 MP4) or Fast (stream copy, snaps to keyframes). |
| Frame | **Snap Frame** (⇧⌘S) saves PNG or JPEG of the exact frame shown, optionally copied to the clipboard. **Copy** (⇧⌘C) only copies it (nothing saved). **Save Cover** / **Copy Cover** take the clip's cover picture from the site, when it has one. |
| GIF | Width, FPS, repeat; palette-based encoding. Warns above 15 s or 960 px. Hard limits: 1920 px, 30 fps. |
| Private / login-only media | Output › Advanced › Browser login, per item. Off by default. DLLC reads the browser's cookies only at download time and never asks for passwords. Settings › Privacy can forget them all. DRM-protected media is not supported. |

Previews start from a low-resolution online stream. For exact frames DLLC loads the full source once
and caches it. This happens automatically for videos up to 10 minutes (configurable). Clips and GIFs
of long online videos read only the selected range.

Closing the window keeps the queue running. Quitting with active work asks first. Interrupted jobs
are kept and can be restarted after relaunch. The app also handles:
- network loss and wake from sleep (automatic retry);
- full disks and unavailable folders (clear messages);
- Light/Dark/System appearance and Reduce Motion.

**Quick Tips:** the **?** beside the DLLC logo (top of the sidebar), ⌘?, or Help › Quick Tips opens short how-to cards for the current
mode beside your work. Click a topic to jump to it; close it any time with ✕ or ⌘? again.

## Song Cues

Switch to **Song Cues** at the top of the window (⌘2; ⌘1 goes back to Download). Songs belong to projects, next to the
reference clips, so deleting a project removes its songs from the list too (the audio files themselves are never deleted).

- **Add a song:** ⌘O, drop an audio/video file on a project, or “Open in Song Cues” on a finished download.
- **Mark sections:** press R (Range) and drag over the song, then pick a name. With V (Select), drag a block to
  move it, drag its edges to resize, or drag a box over empty space in the Sections lane to select several blocks (⇧/⌘ adds); dragging on the waveform moves the playhead. Blocks never overlap; Snap (S) makes edges stick to other
  sections, markers and the playhead.
- **Move around:** pinch or ⌥-scroll to zoom, scroll to pan, Fit (⇧Z) shows the whole song. Space plays, J/L jump
  5 s, ←/→ 0.1 s (⇧ 1 s, ⌥ 0.01 s), C splits at the playhead, M adds a marker, ⌫ deletes, ⌘Z undoes.
- **Lyrics & Times:** paste the lyrics; headings like `[Verse 1] 01:31 - 01:40` mark sections. Times follow the
  blocks, “Sections from Times” builds blocks from the headings, and “Copy Lyrics & Times” copies the whole sheet.
- **Export:** choose sections, Separate or Joined, lead-in 0–5 s (song before the section), count-in
  (3 beats every 1 s, or 4/8 beats every 0.5 s, in front of the file; Beep, Click or Wood, with a preview), speed (÷4…×4, pitch kept; the same setting as the speed menu above the timeline, so the preview plays at the export speed), fade, MP3/WAV,
  then Save to the project folder and/or AirDrop. Files are named after the song, e.g. `TOP 5 - Hook 1 (slow 2x).mp3`,
  and never overwrite an existing file.
- **Saving:** there is no Save button. Songs, sections, lyrics and titles save themselves as you work (within half a
  second, and again on quit); **Saved** beside the song title confirms it, and they're all there after reopening. The
  export settings are remembered too. (Save in the export panel means writing the audio files.)
- **Panel size:** drag the grip above the export panel to give the timeline more room (the panel scrolls);
  double-click it to fit the panel to its contents again. Drag the lines between its columns to make Sections or
  Send To wider or narrower (double-click a line to reset). Sizes are remembered.
- **Small windows:** the export panel rearranges itself (four columns → three → a section strip on top; the options column never shrinks below what it needs), the toolbar
  drops extras, and the lyrics button (top right of the toolbar) hides or shows the lyrics.

## Build from source

```bash
./scripts/fetch-tools.sh      # downloads pinned tools, verifies SHA-256 → Vendor/tools
swift test                    # unit + local FFmpeg tests
DLLC_E2E=1 swift test --filter E2E   # real-network end-to-end tests (needs internet)
./scripts/build-app.sh        # → dist/DLLC.app, dist/DLLC.dmg, dist/DLLC.zip (ad-hoc signed)
```

Needs Xcode with Swift 6 (built and tested with Xcode 27.2 / Swift 6.4.2). To sign with a real identity:
`SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh`. Notarization is not scripted.

Layout:
- `Sources/DLLCCore` holds the engine: queue/state machine, yt-dlp/FFmpeg commands, process supervisor, updater.
- `Sources/DLLC` holds the SwiftUI app.
- `docs/` holds the spec and architecture notes.

Debug builds accept `DLLC_*` environment variables for automated UI snapshots (`DebugHarness.swift`).
Release builds ignore them.

## Bundled tools and licenses

| Tool | Version | License |
|---|---|---|
| yt-dlp (official macOS onedir build) | 2026.10.26 | Unlicense (bundled Python components: their own licenses) |
| FFmpeg / ffprobe (static arm64, martin-riedl.de) | 9.0.2 | GPL v3 |
| Deno (needed by yt-dlp for YouTube) | 2.9.8 | MIT |

Full texts are in `DLLC.app/Contents/Resources/THIRD_PARTY_LICENSES.txt` (Settings › Privacy & Updates
› Show Licenses). FFmpeg source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz.

**yt-dlp updates** (Settings › Privacy & Updates) are user-initiated. Before anything is executed,
the update must pass these checks:
1. The release's `SHA2-256SUMS` must carry a valid OpenPGP signature from yt-dlp's signing key,
   which is pinned in the app (fingerprint `AC0C BBE6 848D 6A87 3464 AF4E 57CF 6593 3B5A 7581`).
2. The download must match that checksum list.
3. The binary must report the expected version.

Updates are installed to Application Support. The signed app bundle is never modified, and
"Use Bundled Version" rolls back.

**DLLC updates** come from this repository's [releases](https://github.com/Lencier/DLLC/releases).
DLLC checks once a day at launch (turn it off in Settings › Privacy & Updates, or press Check Now there).
The check is one request to the GitHub API and sends nothing about you or your downloads. When a newer
version is out, **Install and Restart** downloads `DLLC-<version>.zip` and installs it only when:
1. its SHA-256 carries a valid Ed25519 signature from the release key pinned in the app;
2. the app inside is DLLC (`com.lencier.dllc`) with the announced version, and its code signature is intact.

A small helper then swaps the new app in after DLLC quits (the old copy is restored if that fails) and
reopens it. DLLC must be in a folder you can write to, such as Applications.

### Publishing a release (maintainer)

1. Bump `VERSION`, commit.
2. `scripts/release.sh "What changed"` builds, signs the zip with the private key at
   `~/.config/dllc/update-signing-key` (never committed; keep a backup) and uploads the zip, its `.sig`
   and the DMG as release `v<version>`.

Without that key no update can be published that existing copies will accept.

## Test results (2026-11-04, Apple M5 Pro, macOS 26.6.2, Swift 6.4.2)

- **68 unit/integration tests pass.** They cover:
  - the queue state machine: Download All during analysis, limits, cancel/retry with stale callbacks, restore after relaunch, duplicates, multi-item selection;
  - projects: jobs keep their project through clips and split posts, moving between projects, old queues without projects still load, safe folder names, project folders created only inside an existing folder;
  - YouTube Mix / playlist-in-watch links analysed as one video;
  - process-group cancellation including grandchildren;
  - real FFmpeg frame accuracy at 23.976/29.97/59.94 fps and on VFR/sparse sources, plus a non-zero start-time file;
  - precise clip boundaries;
  - log redaction, file naming (emoji, Thai, collisions);
  - OpenPGP verification against a real yt-dlp release;
  - HDR (PQ/HLG) tone-mapped to SDR BT.709 by real FFmpeg.
- **5 real-network end-to-end tests pass**, through the same worker the app uses, with outputs checked by ffprobe:
  - YouTube, Instagram (3-item carousel), Pinterest and X analyse without login; a removed video gives a friendly error;
  - MP3, original audio and Compatible MP4 (H.264 + AAC, 19.0 s) save into a folder with a Thai name;
  - from a 4K60 YouTube video, read online, only the selected range:
    - a precise 2 s clip at 3840×2160, 59.94 fps, with audio, takes about 7–10 s depending on the network;
    - a fast 3 s clip;
    - a 480 px GIF;
    - a 4K PNG frame;
  - a cancelled 4K download stops promptly and leaves no child processes;
  - X and Pinterest downloads work; one carousel item downloads alone.
- **Packaged app**: settles about 1.5 s after launch. At idle it uses 0–0.1 % CPU and about 84 MB resident (28 MB physical footprint), with no child processes. Bundled tools run with an empty `PATH`.
- **Reviews**: two independent review rounds before release. The first had two Claude reviewers (engine correctness; security, privacy and spec). The second used GPT Codex "Astra" (engine and UI/accessibility). Their findings were checked against the code and fixed, with regression tests where testable.
- **UI**: checked through offscreen window renders in light and dark, at 1180×760 and 800×600 (single-pane layout). States checked: queue, saved, failed, downloading with progress and speed, Clip/GIF workspace with exact-frame source.

## Known limitations

- Not notarized: Gatekeeper asks once (see Install). Later versions install from inside the app.
- Not verified on screen:
  - Keyboard handling while a time field is being edited (the automation tool couldn't type into the field). Playback keys and Esc are guarded in code.
  - Dragging rows onto a project in the sidebar (synthetic drags were too fast to start a drag session). Moving via the row menu uses the same code path, which is unit-tested.
- Many Instagram/X posts need a browser login; reading Safari cookies needs Full Disk Access. Sites change often, so yt-dlp updates may be needed.
- An updated yt-dlp lives in your user folder. Software already running as your user could tamper with it. "Use Bundled Version" always returns to the signed copy.
- These are not covered by the processing limit:
  - snapshots and preview proxies;
  - yt-dlp's own audio conversion (MP3).
- The saved queue (`~/Library/Application Support/DLLC/queue.json`) contains the media links' metadata, including temporary stream URLs.
- Live streams and DRM-protected media are not supported.
- Not every bug has been found. Please report what you hit; technical details in error disclosures are redacted.

## Version

DLLC 1.3.25 — developed by Lencier, from an idea by Kannnap. The version lives in `VERSION` and is read by `scripts/build-app.sh`.

- **1**.x.x: changes rarely (a whole new generation of the app).
- x.**3**.x: big updates or new features.
- x.x.**0**: small fixes and tweaks.
