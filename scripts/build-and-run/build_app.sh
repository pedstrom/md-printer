#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
case "$CONFIGURATION" in
  debug) XCODE_CONFIGURATION="Debug" ;;
  release) XCODE_CONFIGURATION="Release" ;;
  *)
    echo "Unsupported configuration: $CONFIGURATION" >&2
    exit 2
    ;;
esac
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

DISPLAY_VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
QUICK_LOOK_DERIVED_DATA="$ROOT/build/QuickLookDerivedData"
xcodebuild \
  -project "$ROOT/QuickLookExtension/MarkdownPrinterQuickLook.xcodeproj" \
  -scheme MarkdownPrinterQuickLook \
  -configuration "$XCODE_CONFIGURATION" \
  -derivedDataPath "$QUICK_LOOK_DERIVED_DATA" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$DISPLAY_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build \
  >/dev/null
QUICK_LOOK_PRODUCT="$QUICK_LOOK_DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/MarkdownPrinterQuickLook.appex"
if [[ ! -d "$QUICK_LOOK_PRODUCT" ]]; then
  echo "Quick Look extension was not produced: $QUICK_LOOK_PRODUCT" >&2
  exit 1
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
mkdir -p \
  "$CONTENTS/MacOS" \
  "$CONTENTS/Resources" \
  "$CONTENTS/Frameworks" \
  "$CONTENTS/PlugIns"

DOCUMENT_ICON_SOURCE="$ROOT/Resources/MarkdownDocumentIcon.png"
DOCUMENT_ICONSET="$STAGING_ROOT/MarkdownDocumentIcon.iconset"
if [[ ! -s "$DOCUMENT_ICON_SOURCE" ]]; then
  echo "Missing document icon source: $DOCUMENT_ICON_SOURCE" >&2
  exit 1
fi
mkdir -p "$DOCUMENT_ICONSET"

make_document_icon() {
  local size="$1"
  local filename="$2"
  local working_png="$STAGING_ROOT/document-icon-${size}.png"
  sips -Z "$size" "$DOCUMENT_ICON_SOURCE" --out "$working_png" >/dev/null
  sips -p "$size" "$size" "$working_png" \
    --out "$DOCUMENT_ICONSET/$filename" >/dev/null
}

make_document_icon 16 icon_16x16.png
make_document_icon 32 icon_16x16@2x.png
make_document_icon 32 icon_32x32.png
make_document_icon 64 icon_32x32@2x.png
make_document_icon 128 icon_128x128.png
make_document_icon 256 icon_128x128@2x.png
make_document_icon 256 icon_256x256.png
make_document_icon 512 icon_256x256@2x.png
make_document_icon 512 icon_512x512.png
make_document_icon 1024 icon_512x512@2x.png
iconutil -c icns "$DOCUMENT_ICONSET" \
  -o "$CONTENTS/Resources/MarkdownDocumentIcon.icns"

lipo -create "${BINARIES[@]}" -output "$CONTENTS/MacOS/MarkdownPrinter"
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"
ditto "$QUICK_LOOK_PRODUCT" "$CONTENTS/PlugIns/MarkdownPrinterQuickLook.appex"
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
  codesign \
    --force \
    --sign - \
    --entitlements \
      "$ROOT/QuickLookExtension/MarkdownPrinterQuickLook/MarkdownPrinterQuickLook.entitlements" \
    "$CONTENTS/PlugIns/MarkdownPrinterQuickLook.appex" \
    >/dev/null
  "$ROOT/scripts/build-and-run/sign_sparkle.sh" "$STAGED_APP_PATH" - >/dev/null
  # The local ad-hoc app cannot satisfy hardened-runtime team-ID library
  # validation. Release packaging re-signs the app and Sparkle with the same
  # Developer ID identity before enabling hardened runtime.
  codesign --force --sign - "$STAGED_APP_PATH" >/dev/null
  codesign --verify --deep --strict "$STAGED_APP_PATH"
fi

"$ROOT/scripts/build-and-run/validate_quicklook_bundle.sh" "$STAGED_APP_PATH"

mv "$STAGED_APP_PATH" "$APP_PATH"
echo "$APP_PATH"
