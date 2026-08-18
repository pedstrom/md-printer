#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <app-path> [--release]" >&2
  exit 2
fi

APP_PATH="$1"
MODE="${2:-}"
if [[ -n "$MODE" && "$MODE" != "--release" ]]; then
  echo "Unknown option: $MODE" >&2
  exit 2
fi

EXTENSION_PATH="$APP_PATH/Contents/PlugIns/MarkdownPrinterQuickLook.appex"
EXTENSION_INFO="$EXTENSION_PATH/Contents/Info.plist"
EXTENSION_EXECUTABLE="$EXTENSION_PATH/Contents/MacOS/MarkdownPrinterQuickLook"
HOST_INFO="$APP_PATH/Contents/Info.plist"

test -d "$EXTENSION_PATH"
test -x "$EXTENSION_EXECUTABLE"
plutil -lint "$EXTENSION_INFO" >/dev/null
[[ "$(plutil -extract CFBundleIdentifier raw "$EXTENSION_INFO")" \
  == "com.peteedstrom.markdown-printer.quicklook" ]]
[[ "$(plutil -extract CFBundleExecutable raw "$EXTENSION_INFO")" \
  == "MarkdownPrinterQuickLook" ]]
[[ "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$EXTENSION_INFO")" \
  == "com.apple.quicklook.preview" ]]
[[ "$(plutil -extract NSExtension.NSExtensionPrincipalClass raw "$EXTENSION_INFO")" \
  == "MarkdownPrinterQuickLook.PreviewViewController" ]]
[[ "$(plutil -extract NSExtension.NSExtensionAttributes.QLIsDataBasedPreview raw "$EXTENSION_INFO")" \
  == "false" ]]
[[ "$(plutil -extract NSExtension.NSExtensionAttributes.QLSupportsSearchableItems raw "$EXTENSION_INFO")" \
  == "false" ]]

EXPECTED_CONTENT_TYPES=(
  net.daringfireball.markdown
  public.markdown
  dyn.ah62d4rv4ge8043a
  dyn.ah62d4rv4ge8042pwrrwg875s
  dyn.ah62d4rv4ge8043dts71a
  dyn.ah62d4rv4ge80445e
)
for index in "${!EXPECTED_CONTENT_TYPES[@]}"; do
  actual="$(plutil -extract \
    "NSExtension.NSExtensionAttributes.QLSupportedContentTypes.$index" \
    raw "$EXTENSION_INFO")"
  [[ "$actual" == "${EXPECTED_CONTENT_TYPES[$index]}" ]]
done
if plutil -extract \
  "NSExtension.NSExtensionAttributes.QLSupportedContentTypes.${#EXPECTED_CONTENT_TYPES[@]}" \
  raw "$EXTENSION_INFO" >/dev/null 2>&1; then
  echo "Quick Look extension declares unexpected additional content types." >&2
  exit 1
fi

HOST_DISPLAY_VERSION="$(plutil -extract CFBundleShortVersionString raw "$HOST_INFO")"
HOST_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$HOST_INFO")"
[[ "$(plutil -extract CFBundleShortVersionString raw "$EXTENSION_INFO")" \
  == "$HOST_DISPLAY_VERSION" ]]
[[ "$(plutil -extract CFBundleVersion raw "$EXTENSION_INFO")" \
  == "$HOST_BUILD_NUMBER" ]]

EXTENSION_ARCHITECTURES="$(lipo -archs "$EXTENSION_EXECUTABLE")"
[[ "$EXTENSION_ARCHITECTURES" == *"arm64"* ]]
[[ "$EXTENSION_ARCHITECTURES" == *"x86_64"* ]]
[[ "$(wc -w <<< "$EXTENSION_ARCHITECTURES" | tr -d ' ')" == "2" ]]

codesign --verify --strict --verbose=2 "$EXTENSION_PATH"
ENTITLEMENTS="$(codesign --display --entitlements :- "$EXTENSION_PATH" 2>/dev/null)"
grep -A1 '<key>com.apple.security.app-sandbox</key>' <<< "$ENTITLEMENTS" \
  | grep -q '<true/>'
grep -A1 '<key>com.apple.security.files.user-selected.read-only</key>' \
  <<< "$ENTITLEMENTS" \
  | grep -q '<true/>'
if grep -q '<key>com.apple.security.network.client</key>' <<< "$ENTITLEMENTS" \
  || grep -q '<key>com.apple.security.network.server</key>' <<< "$ENTITLEMENTS"; then
  echo "Quick Look extension must not have network entitlements." >&2
  exit 1
fi
[[ "$(grep -c '<key>' <<< "$ENTITLEMENTS" | tr -d ' ')" == "2" ]]

if [[ "$MODE" == "--release" ]]; then
  SIGNING_INFORMATION="$(codesign --display --verbose=4 "$EXTENSION_PATH" 2>&1)"
  grep -q '^Authority=Developer ID Application:' <<< "$SIGNING_INFORMATION"
  grep -q 'flags=.*runtime' <<< "$SIGNING_INFORMATION"
  grep -q '^Timestamp=' <<< "$SIGNING_INFORMATION"
fi
