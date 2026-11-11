#!/bin/bash
# Builds dist/DLLC.app (arm64), signs it ad-hoc, and packages dist/DLLC.dmg + dist/DLLC.zip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="${APP_NAME:-DLLC}"
BUNDLE_ID="${BUNDLE_ID:-com.lencier.dllc}"
VERSION="${VERSION:-$(tr -d "[:space:]" < "$ROOT/VERSION")}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc; set to "Developer ID Application: …" when available

# Always: re-verifies the pinned archives (cached, so it's quick) and re-extracts a clean Vendor/tools.
./scripts/fetch-tools.sh

echo "→ swift build (release, arm64)"
swift build -c release --arch arm64 --scratch-path .build-release --product DLLC
BIN="$(swift build -c release --arch arm64 --scratch-path .build-release --show-bin-path)/DLLC"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Brand/Logo.png Resources/Brand/LogoLight.png "$APP/Contents/Resources/"
ditto Vendor/tools "$APP/Contents/Resources/tools"

YTDLP_LICENSES=Vendor/tools/yt-dlp/_internal/THIRD_PARTY_LICENSES.txt
[[ -f "$YTDLP_LICENSES" ]] || { echo "✗ missing $YTDLP_LICENSES" >&2; exit 1; }
{
  cat Resources/THIRD_PARTY_NOTICES.md
  printf '\n\n==== FFmpeg / ffprobe: GNU General Public License v3 (full text) ====\n\n'
  cat Resources/licenses/FFmpeg-GPL-3.0.txt
  printf '\n\n==== Deno: MIT License ====\n\n'
  cat Resources/licenses/Deno-MIT.txt
  printf '\n\n==== yt-dlp bundled components (THIRD_PARTY_LICENSES.txt) ====\n\n'
  cat "$YTDLP_LICENSES"
} > "$APP/Contents/Resources/THIRD_PARTY_LICENSES.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal utility. Bundled tools: see THIRD_PARTY_LICENSES.txt</string>
</dict></plist>
PLIST

echo "→ codesign ($SIGN_IDENTITY)"
# Bundled tools keep their upstream signatures; only the app itself is (re)signed.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "→ checks"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
for t in ffmpeg ffprobe deno yt-dlp/yt-dlp_macos; do
  f="$APP/Contents/Resources/tools/$t"
  echo "  $t: $(lipo -archs "$f") · $(otool -L "$f" | tail -n +2 | grep -vcE '^\s*/(System|usr/lib)/') non-system dylibs"
done

echo "→ package"
rm -f "$DIST/$APP_NAME.zip" "$DIST/$APP_NAME.dmg" "$DIST/$APP_NAME"-*.dmg
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$APP_NAME.zip"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
# Install window: a background with a "Drag here" arrow (scripts/make-dmg-background.swift), icons placed on it.
mkdir "$STAGE/.background"
cp Resources/DMG/background.tiff "$STAGE/.background/background.tiff"
RW="$(mktemp -d)/rw.dmg"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW"
# Finder lays the window out by volume name, so no other "$APP_NAME" disk may be mounted meanwhile.
if [[ -e "/Volumes/$APP_NAME" ]]; then echo "✗ eject the mounted $APP_NAME disk first" >&2; exit 1; fi
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MNT="/Volumes/$APP_NAME"
if ! osascript <<OSA
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 620}
    set o to the icon view options of container window
    set arrangement of o to not arranged
    set icon size of o to 112
    set text size of o to 13
    set background picture of o to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
then echo "  (Finder layout skipped: allow Terminal to control Finder for the styled window)"; fi
# Finder writes .DS_Store lazily: wait until the layout is on disk.
for _ in $(seq 1 20); do [[ -s "$MNT/.DS_Store" ]] && grep -q "Iloc" "$MNT/.DS_Store" && break; sleep 0.5; done
grep -q "Iloc" "$MNT/.DS_Store" 2>/dev/null && echo "  ✓ install window layout saved" || echo "  ✗ layout not saved"
chflags hidden "$MNT/.background" 2>/dev/null || true
rm -rf "$MNT/.fseventsd"
sync
hdiutil detach -quiet "$DEV" || hdiutil detach -quiet -force "$DEV"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DIST/$APP_NAME.dmg"
rm -rf "$(dirname "$RW")" "$STAGE"
cp "$DIST/$APP_NAME.dmg" "$DIST/$APP_NAME-$VERSION.dmg"
ls -lh "$DIST"
