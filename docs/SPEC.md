# DLLC — Product Specification (original handoff, verbatim intent)

Build a production-quality, standalone macOS application for downloading reference media and extracting useful clips, frames, and GIFs. Working name: DLLC (keep the name easy to change). Deliver a usable application bundle, tested — not just a plan or scaffold.

## 1. Product goal
Personal utility for a filmmaker collecting visual/audio references. Primary workflow: **Paste links → choose output → queue → save.**
Priorities: (1) reliable real-world use, (2) clear smooth UX, minimal friction, (3) preserve highest available source quality when requested, (4) fast + low resources, (5) clean polished design.
Not a full video editor. Primary machine: MacBook Pro M5 Pro, 48 GB. Target: Apple Silicon macOS only. No cloud server, subscription, accounts, telemetry, AI API.

## 2. Prior prototype
An Electron prototype ("Framegrab") is NOT supplied. Build independently.

## 3. Architecture & standalone delivery
Prefer SwiftUI + selective AppKit + AVFoundation with bundled media tools. yt-dlp for extraction, FFmpeg/ffprobe for processing.
- End users must not install Homebrew/Python/Node/FFmpeg/yt-dlp. Bundle everything; resolve tools from app paths, never PATH.
- Validate ARM64 + dylib deps. Pin versions, include licenses. User data outside the bundle.
- Separate UI, persistent job state, downloading, preview, media processing. Off the main thread. No unauthenticated network service.
- Produce .app and .dmg/ZIP. Don't claim ready until packaged app launches and bundled tools run.

## 4. Sources & quality
YouTube, Instagram, Pinterest, X (where yt-dlp supports). Short links/redirects safely. Multi-item posts → selection UI.
After analysis show: title, thumbnail, platform, creator, duration, available resolution+FPS combos (real combos only), audio availability, estimated size only when derivable (labelled).
Default: best video+audio, preserve resolution/FPS, no unnecessary re-encode. Small quality selector from actual formats; codec detail in Advanced.
Export: "Best quality" (preserve streams, compatible container) / "Compatible MP4" (explain when conversion/compromise needed). Never silently force MP4, downscale 4K60, mangle HDR, or claim success with missing audio.
Audio-only: MP3 default; optional original stream no re-encode; handle silent videos clearly.

## 5. Queue (core)
Many links pasted at once; add during active work; per-job output choices; Download one / Download All; reorder pending; cancel/retry; remove (keeps files); reveal/open; clear completed (keeps files). Duplicate link → warning not prohibition.
Persist queue + params; restart loses nothing. Explicit state machine: analyzing, ready, queued, downloading, processing, completed, failed, cancelled, interrupted.
- Download All includes items still analyzing.
- Failure doesn't block others.
- Cancel kills child processes; stale callbacks can't corrupt retried jobs (generation tokens).
- Restart → interrupted jobs recoverable. Distinguish restart vs byte resume. No universal pause promise.
- Deliberate close/quit behavior; warn on quit with active work.
- Handle sleep/wake, network loss, disk full, unavailable folders, crashes.
Default concurrency ~2 downloads + 1 heavy processing; adjustable. Stage-based progress; no fake %, no stuck 99%.

## 6. Player & range selection
Shared preview workspace for Clip / Frame / GIF: play/pause, seek, playhead, timeline, draggable In/Out, editable time fields, duration, loop range, prev/next frame (paused), shortcuts Space/I/O/←/→ (not while editing text).
Frame stepping on real decoded frames/PTS (VFR-safe). Consistent range semantics: preview, snapshot, export refer to same source frames.
Validate empty/malformed/start>=end/negative/out-of-bounds/very short/long/fractional+VFR.
Preview vs export separate: proxy when source heavy/unsupported, keep time mapping, export from source not proxy, honest prep time, don't download a full multi-hour 4K just for metadata, reuse cached source.
Clips: Precise cut (re-encode) vs Fast cut (stream copy, approximate). No false "lossless frame-accurate" claims.

## 7. Snap Frame
Current source frame → PNG/JPG, source dimensions, copy to clipboard, collision-safe filename with title + source time, multiple without closing, correct orientation/color.

## 8. GIF
Same In/Out. Width (aspect kept), FPS, loop, preview, export. Palette pipeline (palettegen/paletteuse). Default limits + warnings; no 4K GIF by default. Cancelable, responsive. Optional looping MP4/WebP only if valuable.

## 9. UX/UI
Restrained native macOS utility. Light/Dark/System. Muted sky-blue accent. Small purposeful animation. No dashboards/hero text.
Layout: prominent URL input; queue primary; preview/details panel when needed; compact output controls; secondary settings + history.
States: empty, loading, ready, downloading, processing, completed, recoverable error, unsupported, auth required.
Remember destination/theme/output choice. Keyboard nav, focus, a11y labels, contrast, resizing, Reduce Motion.
No automatic clipboard monitoring; explicit paste only. Friendly errors + next action; technical log behind disclosure, redacted.

## 10. Performance
Stream to disk; no continuous full-res decode; bound subprocesses/thumbnails/caches/jobs; cancel obsolete seeks; throttle progress; no unbounded FFmpeg on scrubbing; prefer stream copy; hardware accel only when measured beneficial; idle = no polling. Measure startup, idle, responsiveness, processing perf.

## 11. Storage/privacy/reliability
User-chosen destination; handle revoked permission/disconnected drives; no silent overwrite; per-job temp workspace; free-space checks; safe cleanup of app temp only; never delete user files.
Cookies: opt-in, authorized content only, never ask passwords, local only, excluded from logs, "forget" control, no global leakage across jobs, explain browser/Keychain access. No DRM bypass.
Argument arrays not shell. Validate URLs/filenames/params.
yt-dlp updates: verify via documented trust mechanism, rollback, never mutate signed .app; else whole-app updates; no unverified code.

## 12. Testing
Automated tests + real E2E: public video, 4K60, audio-only, silent, each platform, short links, multi-item, invalid/deleted/unsupported/auth-required, multi-paste, Download All during analysis, add during work, duplicates w/ different ranges, cancel at each stage, retry, quit/relaunch recovery, network loss, sleep/wake, disk full, permissions, Unicode/Thai/long names/collisions, VFR + 23.976/29.97/59.94, unsupported codecs → proxy, frame/snapshot/clip accuracy, light/dark, keyboard-only, small windows, rapid actions.
Verify outputs with ffprobe (dims, fps, duration, audio, codec/container, decodes).
Report honestly what passed/failed/unverified.

## 13. Delivery
.app (arm64), .dmg/ZIP, source + reproducible build, usage, test results + limitations, bundled versions + licenses. Honest signing/notarization status.
