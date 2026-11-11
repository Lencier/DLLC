# DLLC — Architecture decisions

Synthesised from the implementation plan and a design review.

## Stack
- Swift 6.4 / SwiftUI + AppKit + AVFoundation, macOS 26 SDK, arm64 only.
- SwiftPM (`Package.swift`), no .xcodeproj. `scripts/build-app.sh` assembles `DLLC.app`.
- Targets: `DLLCCore` (Foundation only: models, persistence, process supervision, yt-dlp/ffmpeg
  command building + parsing, naming, timecode, queue engine) · `DLLC` (SwiftUI app, AVFoundation preview)
  · `DLLCCoreTests`.
- App name lives in one place: `AppIdentity` (core) + `Info.plist` template variables in the build script.

## Bundled tools (Contents/Resources/tools, resolved by absolute path, never PATH)
| Tool | Version | Source |
|---|---|---|
| yt-dlp | 2026.10.26 onedir (`yt-dlp_macos.zip`) | GitHub release, SHA-256 pinned |
| ffmpeg / ffprobe | 9.0.2 static arm64 | ffmpeg.martin-riedl.de, SHA-256 pinned |
| deno | 2.9.8 aarch64 | GitHub release, SHA-256 pinned — required by yt-dlp EJS for full YouTube support |

yt-dlp always runs with: `--ignore-config --no-plugin-dirs --no-update --no-remote-components
--ffmpeg-location <tools> --no-js-runtimes --js-runtimes deno:<tools>/deno`.

Optional user-initiated yt-dlp update: downloads the official release zip into
`~/Library/Application Support/DLLC/tools/yt-dlp/<version>/`, verifies SHA-256 against the release's
`SHA2-256SUMS` (fetched over HTTPS from the official repo only), keeps the bundled copy as rollback,
never touches the signed bundle.

## Job model
`Job` (Codable value) = id, URL, kind (video/audio/clip/gif), output options, optional range,
analysis snapshot, state, stage, progress, generation, result files, error, cookie choice.

States: `analyzing, needsSelection, ready, queued, downloading, processing, completed, failed,
cancelled, interrupted`. `enqueueWhenReady` flag implements Download All for analyzing items.

Every async operation carries `(jobID, generation)`. Cancel/retry bump `generation` first; any callback
whose generation differs is dropped. On relaunch, analyzing → re-analyze automatically;
downloading/processing → `interrupted` (user resumes; yt-dlp may continue `.part` files = restart with
possible byte reuse, never promised).

Persistence: `queue.json` in Application Support, schema-versioned, atomic write, debounced.

## Concurrency
`QueueEngine` (@MainActor, owns state) + `ProcessSupervisor` (posix_spawn, own process group,
SIGINT → SIGTERM → SIGKILL on the group, reaped). Limits: analysis 3, downloads 2, processing 1
(adjustable). Progress throttled to ≤ 4 updates/s per job.

## Source, preview, export
- Range semantics: In inclusive, Out exclusive, in source seconds (rational where known).
- Selected frame = source frame whose presentation interval contains the playhead.
- **Local source** (cached full download at chosen quality, or a completed video output) gives exact PTS
  frame index (ffprobe packets), exact snapshots/clips/GIFs. Auto-fetched for short videos.
- **Streamed preview** (low-res AVPlayer-playable rendition URL) for instant scrubbing without
  downloading; frame grid = nominal FPS, labelled approximate. Exports then use ffmpeg on the remote
  high-quality stream URLs for the range only (never a proxy).
- **Local proxy** (H.264, timestamps passed through) only when the source codec/container isn't
  AVPlayer-playable.
- Clip: Precise (re-encode, trim filters) / Fast (stream copy, keyframe-approximate).
- GIF: fps+scale → palettegen(stats_mode=diff) → paletteuse; default 640px/12fps, warn > 15 s or > 960px.

## Files
Per-job workspace in `~/Library/Caches/DLLC/jobs/<id>/<generation>/`. Final files are moved into the
destination with collision-safe names (`Title (2).mp4`), never overwritten. Cleanup only touches
app-owned caches.
