#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Resources/MarkdownPrinterIcon.png"
ICONSET="$ROOT/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -s "$SOURCE" ]]; then
  echo "Missing icon source: $SOURCE" >&2
  exit 1
fi

WIDTH="$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ { print $2 }')"
HEIGHT="$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ { print $2 }')"
if [[ "$WIDTH" != "1024" || "$HEIGHT" != "1024" ]]; then
  echo "Icon source must be 1024 x 1024 pixels; found ${WIDTH:-unknown} x ${HEIGHT:-unknown}." >&2
  exit 1
fi

mkdir -p "$ICONSET"

make_icon() {
  local size="$1"
  local filename="$2"
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

echo "$ICONSET"
