#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
TARGET_TRIPLES=(
  arm64-apple-macosx14.0
  x86_64-apple-macosx14.0
)
if [[ "${1:-}" != "--skip-build" ]]; then
  mkdir -p .build/module-cache .build/swiftpm-cache
  for triple in "${TARGET_TRIPLES[@]}"; do
    CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
      SWIFTPM_CUSTOM_CACHE_PATH="$ROOT/.build/swiftpm-cache" \
      swift build -c "$CONFIGURATION" --triple "$triple" --product MarkdownPrinter
  done
fi

BINARIES=()
for triple in "${TARGET_TRIPLES[@]}"; do
  BIN_PATH="$(CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
    SWIFTPM_CUSTOM_CACHE_PATH="$ROOT/.build/swiftpm-cache" \
    swift build -c "$CONFIGURATION" --triple "$triple" --show-bin-path)"
  BINARIES+=("$BIN_PATH/MarkdownPrinter")
done

APP_PATH="$ROOT/build/Markdown Printer.app"
STAGING_ROOT="$(mktemp -d /private/tmp/markdown-printer-app.XXXXXX)"
STAGED_APP_PATH="$STAGING_ROOT/Markdown Printer.app"
CONTENTS="$STAGED_APP_PATH/Contents"
trap 'rm -rf "$STAGING_ROOT"' EXIT

rm -rf "$APP_PATH"
mkdir -p "$ROOT/build"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
lipo -create "${BINARIES[@]}" -output "$CONTENTS/MacOS/MarkdownPrinter"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
xcrun actool "$ROOT/Resources/Assets.xcassets" \
  --compile "$CONTENTS/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ROOT/build/asset-catalog-info.plist" \
  >/dev/null
chmod +x "$CONTENTS/MacOS/MarkdownPrinter"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

if command -v codesign >/dev/null 2>&1; then
  xattr -cr "$STAGED_APP_PATH"
  codesign --force --sign - "$STAGED_APP_PATH" >/dev/null
fi

mv "$STAGED_APP_PATH" "$APP_PATH"
echo "$APP_PATH"
