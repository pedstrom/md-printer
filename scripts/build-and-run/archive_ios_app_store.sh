#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

MODE="${1:---archive}"
if [[ "$MODE" != "--archive" && "$MODE" != "--export" ]]; then
  echo "Usage: scripts/build-and-run/archive_ios_app_store.sh [--archive|--export]" >&2
  exit 2
fi

PROJECT="iOS/MarkdownPrinterIOS.xcodeproj"
SCHEME="MarkdownPrinterIOS"
TEAM_ID="${MARKDOWN_PRINTER_IOS_TEAM_ID:-}"
ARCHIVE_PATH="${MARKDOWN_PRINTER_IOS_ARCHIVE_PATH:-$ROOT/build/app-store/MarkdownPrinterIOS.xcarchive}"
EXPORT_PATH="${MARKDOWN_PRINTER_IOS_EXPORT_PATH:-$ROOT/build/app-store/export}"
EXPORT_OPTIONS="$ROOT/scripts/build-and-run/ExportOptions-AppStore.plist"
EXPECTED_BUNDLE_ID="com.peteedstrom.markdown-printer.ios"

if [[ -z "$TEAM_ID" ]]; then
  echo "Set MARKDOWN_PRINTER_IOS_TEAM_ID to the paid Apple Developer team ID." >&2
  exit 1
fi
if [[ -e "$ARCHIVE_PATH" ]]; then
  echo "Archive already exists: $ARCHIVE_PATH" >&2
  echo "Move it aside or set MARKDOWN_PRINTER_IOS_ARCHIVE_PATH to a new path." >&2
  exit 1
fi
if [[ "$MODE" == "--export" && -e "$EXPORT_PATH" ]]; then
  echo "Export directory already exists: $EXPORT_PATH" >&2
  echo "Move it aside or set MARKDOWN_PRINTER_IOS_EXPORT_PATH to a new path." >&2
  exit 1
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")"
xcodebuild -quiet \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/Markdown Printer.app"
test -x "$APP_PATH/Markdown Printer"
test -s "$APP_PATH/PrivacyInfo.xcprivacy"
codesign --verify --deep --strict "$APP_PATH"
bash scripts/build-and-run/validate_ios_bundle.sh "$APP_PATH"
[[ "$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist")" == "$EXPECTED_BUNDLE_ID" ]]
[[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$APP_PATH/Info.plist")" == "false" ]]

echo "Validated App Store archive: $ARCHIVE_PATH"

if [[ "$MODE" == "--export" ]]; then
  xcodebuild -quiet \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates
  IPA_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
  if [[ -z "$IPA_PATH" ]]; then
    echo "App Store export did not produce an IPA." >&2
    exit 1
  fi
  echo "Validated App Store IPA: $IPA_PATH"
fi
