#!/bin/bash
# Downloads the pinned third-party tools bundled into DLLC.app and verifies
# each archive against a SHA-256 pinned in this file. Bump versions here only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
CACHE="$VENDOR/.downloads"
mkdir -p "$CACHE"

YTDLP_VERSION="2026.10.26"
YTDLP_SHA256="20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1"   # yt-dlp_macos.zip
FFMPEG_VERSION="9.0.2"
FFMPEG_BASE="https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2"
FFMPEG_SHA256="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"
FFPROBE_SHA256="fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6"
DENO_VERSION="2.9.8"
DENO_SHA256="9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e"

fetch() { # url dest sha256
  local url="$1" dest="$2" sum="$3"
  if [[ ! -f "$dest" ]] || [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" != "$sum" ]]; then
    echo "→ downloading $(basename "$dest")"
    curl -fL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  local got; got="$(shasum -a 256 "$dest" | cut -d' ' -f1)"
  if [[ "$got" != "$sum" ]]; then
    echo "✗ checksum mismatch for $dest (got $got)" >&2; rm -f "$dest"; exit 1
  fi
  echo "✓ $(basename "$dest") verified"
}

fetch "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos.zip" "$CACHE/yt-dlp_macos-$YTDLP_VERSION.zip" "$YTDLP_SHA256"
fetch "$FFMPEG_BASE/ffmpeg.zip" "$CACHE/ffmpeg-$FFMPEG_VERSION.zip" "$FFMPEG_SHA256"
fetch "$FFMPEG_BASE/ffprobe.zip" "$CACHE/ffprobe-$FFMPEG_VERSION.zip" "$FFPROBE_SHA256"
fetch "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-aarch64-apple-darwin.zip" "$CACHE/deno-$DENO_VERSION.zip" "$DENO_SHA256"

OUT="$VENDOR/tools"
rm -rf "$OUT" && mkdir -p "$OUT/yt-dlp"
ditto -x -k "$CACHE/yt-dlp_macos-$YTDLP_VERSION.zip" "$OUT/yt-dlp"
ditto -x -k "$CACHE/ffmpeg-$FFMPEG_VERSION.zip" "$OUT"
ditto -x -k "$CACHE/ffprobe-$FFMPEG_VERSION.zip" "$OUT"
ditto -x -k "$CACHE/deno-$DENO_VERSION.zip" "$OUT"
chmod +x "$OUT/ffmpeg" "$OUT/ffprobe" "$OUT/deno"
find "$OUT/yt-dlp" -maxdepth 1 -name 'yt-dlp_macos' -exec chmod +x {} \;
xattr -cr "$OUT"

cat > "$OUT/VERSIONS.txt" <<EOF
yt-dlp $YTDLP_VERSION (yt-dlp_macos.zip, sha256 $YTDLP_SHA256)
ffmpeg/ffprobe $FFMPEG_VERSION (static arm64, ffmpeg.martin-riedl.de)
deno $DENO_VERSION (deno-aarch64-apple-darwin)
EOF
echo "Tools ready in $OUT"
