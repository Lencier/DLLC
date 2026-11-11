DLLC bundles the following third-party software, unmodified, as separate executables in
DLLC.app/Contents/Resources/tools. They are invoked as subprocesses.

1. yt-dlp 2026.10.26 — https://github.com/yt-dlp/yt-dlp
   License: The Unlicense (public domain). The official macOS "onedir" build bundles CPython and
   Python packages whose licenses are reproduced below in yt-dlp's THIRD_PARTY_LICENSES section.
   Includes yt-dlp-ejs (Unlicense; bundles astring — MIT, meriyah — ISC).

2. FFmpeg / FFprobe 9.0.2 — https://ffmpeg.org (static arm64 build by Martin Riedl,
   https://ffmpeg.martin-riedl.de). Built with --enable-gpl --enable-version3, therefore distributed
   under the GNU General Public License version 3 (full text below).
   Corresponding source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz and the build scripts at
   https://git.martin-riedl.de/ffmpeg/build-script. Includes libx264, libx265, libvpx, libaom, dav1d,
   SVT-AV1, libmp3lame, libopus, libwebp, zimg and others under their respective licenses.

3. Deno 2.9.8 — https://deno.com — MIT License (full text below), Copyright 2018-2026 the Deno authors.
   Used only as the JavaScript runtime required by yt-dlp for YouTube.

DLLC itself contains no code from these projects.
