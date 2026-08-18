#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE="${1:-$ROOT/build/Markdown-Printer.zip}"
GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Notarized release archive not found: $ARCHIVE" >&2
  exit 1
fi
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "Sparkle's generate_appcast tool is unavailable. Run swift package resolve first." >&2
  exit 1
fi

DISPLAY_VERSION="$(unzip -p "$ARCHIVE" 'Markdown Printer.app/Contents/Info.plist' \
  | plutil -extract CFBundleShortVersionString raw -o - -)"
BUILD_NUMBER="$(unzip -p "$ARCHIVE" 'Markdown Printer.app/Contents/Info.plist' \
  | plutil -extract CFBundleVersion raw -o - -)"
TAG="v$DISPLAY_VERSION"
RELEASE_NOTES_SOURCE="$ROOT/release-notes/$DISPLAY_VERSION.md"
ASSET_DIRECTORY="$ROOT/build/release-assets/$TAG"
TAG_ASSET_URL="https://github.com/pedstrom/md-printer/releases/download/$TAG/"

if [[ ! -f "$RELEASE_NOTES_SOURCE" ]]; then
  echo "Release notes not found: $RELEASE_NOTES_SOURCE" >&2
  exit 1
fi

mkdir -p "$ASSET_DIRECTORY"
rm -f \
  "$ASSET_DIRECTORY/Markdown-Printer.zip" \
  "$ASSET_DIRECTORY/Markdown-Printer.md" \
  "$ASSET_DIRECTORY/appcast.xml"
ditto "$ARCHIVE" "$ASSET_DIRECTORY/Markdown-Printer.zip"
ditto "$RELEASE_NOTES_SOURCE" "$ASSET_DIRECTORY/Markdown-Printer.md"

"$GENERATE_APPCAST" \
  --versions "$BUILD_NUMBER" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  --download-url-prefix "$TAG_ASSET_URL" \
  --release-notes-url-prefix "$TAG_ASSET_URL" \
  --link "https://github.com/pedstrom/md-printer/releases/tag/$TAG" \
  -o "$ASSET_DIRECTORY/appcast.xml" \
  "$ASSET_DIRECTORY"

"$ROOT/scripts/build-and-run/verify_update_assets.sh" "$ASSET_DIRECTORY"

ASSET_ENTRY_COUNT="$(find "$ASSET_DIRECTORY" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
if [[ "$ASSET_ENTRY_COUNT" != "3" ]]; then
  echo "Release asset directory contains unexpected entries: $ASSET_DIRECTORY" >&2
  exit 1
fi

echo "$ASSET_DIRECTORY"
