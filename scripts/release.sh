#!/bin/bash
# Publishes the version in VERSION as a GitHub release that DLLC's in-app updater can install.
#   1. builds dist/DLLC.app, the DMG and the zip (scripts/build-app.sh)
#   2. signs the zip with the private update key (never committed): ~/.config/dllc/update-signing-key
#   3. uploads DLLC-<v>.zip, DLLC-<v>.zip.sig and DLLC-<v>.dmg to github.com/Lencier/DLLC as tag v<v>
# Usage: scripts/release.sh ["release notes"]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
REPO="Lencier/DLLC"
KEY="${DLLC_UPDATE_KEY:-$HOME/.config/dllc/update-signing-key}"
VERSION="$(tr -d '[:space:]' < VERSION)"
NOTES="${1:-DLLC $VERSION}"

[[ -f "$KEY" ]] || { echo "✗ signing key not found at $KEY" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ commit your changes first" >&2; exit 1; }
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then echo "✗ v$VERSION is already released — bump VERSION" >&2; exit 1; fi

./scripts/build-app.sh
cp dist/DLLC.zip "dist/DLLC-$VERSION.zip"
swift scripts/sign-update.swift "$KEY" "dist/DLLC-$VERSION.zip" > "dist/DLLC-$VERSION.zip.sig"
echo "✓ signed DLLC-$VERSION.zip"

git push origin HEAD
gh release create "v$VERSION" --repo "$REPO" --target "$(git rev-parse HEAD)" --title "DLLC $VERSION" --notes "$NOTES" \
  "dist/DLLC-$VERSION.zip" "dist/DLLC-$VERSION.zip.sig" "dist/DLLC-$VERSION.dmg"
echo "✓ released v$VERSION — friends' DLLC will offer it within a day (or via Settings › Check Now)"
