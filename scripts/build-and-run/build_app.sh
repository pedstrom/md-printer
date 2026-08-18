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
SPARKLE_FRAMEWORK=""
for triple in "${TARGET_TRIPLES[@]}"; do
  BIN_PATH="$(CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
    SWIFTPM_CUSTOM_CACHE_PATH="$ROOT/.build/swiftpm-cache" \
    swift build -c "$CONFIGURATION" --triple "$triple" --show-bin-path)"
  BINARIES+=("$BIN_PATH/MarkdownPrinter")
  if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    SPARKLE_FRAMEWORK="$BIN_PATH/Sparkle.framework"
  fi
done

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle.framework was not produced by SwiftPM: $SPARKLE_FRAMEWORK" >&2
  exit 1
fi

APP_PATH="$ROOT/build/Markdown Printer.app"
STAGING_ROOT="$(mktemp -d /private/tmp/markdown-printer-app.XXXXXX)"
STAGED_APP_PATH="$STAGING_ROOT/Markdown Printer.app"
CONTENTS="$STAGED_APP_PATH/Contents"
trap 'rm -rf "$STAGING_ROOT"' EXIT

rm -rf "$APP_PATH"
mkdir -p "$ROOT/build"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
lipo -create "${BINARIES[@]}" -output "$CONTENTS/MacOS/MarkdownPrinter"
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/MarkdownPrinter"
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
  "$ROOT/scripts/build-and-run/sign_sparkle.sh" "$STAGED_APP_PATH" - >/dev/null
  # The local ad-hoc app cannot satisfy hardened-runtime team-ID library
  # validation. Release packaging re-signs the app and Sparkle with the same
  # Developer ID identity before enabling hardened runtime.
  codesign --force --sign - "$STAGED_APP_PATH" >/dev/null
  codesign --verify --deep --strict "$STAGED_APP_PATH"
fi

mv "$STAGED_APP_PATH" "$APP_PATH"
echo "$APP_PATH"
