#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

MODE="${1:-}"
if [[ -n "$MODE" && "$MODE" != "--install" ]]; then
  echo "Usage: scripts/build-and-run/build_ios_device.sh [--install]" >&2
  exit 2
fi

PROJECT="iOS/MarkdownPrinterIOS.xcodeproj"
SCHEME="MarkdownPrinterIOS"
DERIVED_DATA="$(mktemp -d -t markdown-printer-ios-device)"
TEAM_ID="${MARKDOWN_PRINTER_IOS_TEAM_ID:-}"
DEVICE_ID="${MARKDOWN_PRINTER_IOS_DEVICE_ID:-}"
PROFILE_PLIST=""

cleanup() {
  if [[ -n "$PROFILE_PLIST" ]]; then
    rm -f "$PROFILE_PLIST"
  fi
  if [[ "$MODE" == "--install" ]]; then
    rm -rf "$DERIVED_DATA"
  fi
}
trap cleanup EXIT

if [[ -z "$TEAM_ID" ]]; then
  CERTIFICATE_SUBJECT="$(security find-certificate -c 'Apple Development' -p \
    | openssl x509 -noout -subject 2>/dev/null || true)"
  TEAM_ID="$(sed -nE 's/.*OU=([^, ]+).*/\1/p' <<< "$CERTIFICATE_SUBJECT")"
fi
if [[ -z "$TEAM_ID" ]]; then
  echo "No Apple Development team could be inferred. Set MARKDOWN_PRINTER_IOS_TEAM_ID." >&2
  exit 1
fi

if [[ "$MODE" == "--install" && -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
    | sed -nE 's/.*platform:iOS, arch:[^,]+, id:([^,]+), name:.*/\1/p' \
    | head -n 1)"
fi
if [[ "$MODE" == "--install" && -z "$DEVICE_ID" ]]; then
  echo "No connected iPhone or iPad was found. Connect and trust the device, or set MARKDOWN_PRINTER_IOS_DEVICE_ID." >&2
  exit 1
fi

DESTINATION="generic/platform=iOS"
if [[ -n "$DEVICE_ID" ]]; then
  DESTINATION="id=$DEVICE_ID"
fi

xcodebuild -quiet \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/Markdown Printer.app"
PROFILE_PLIST="$(mktemp -t markdown-printer-ios-profile).plist"

codesign --verify --deep --strict "$APP_PATH"
bash scripts/build-and-run/validate_ios_bundle.sh "$APP_PATH"
security cms -D -i "$APP_PATH/embedded.mobileprovision" > "$PROFILE_PLIST"
PROFILE_TEAM="$(plutil -extract TeamIdentifier.0 raw "$PROFILE_PLIST")"
PROFILE_DAYS="$(plutil -extract TimeToLive raw "$PROFILE_PLIST")"
PROFILE_EXPIRATION="$(plutil -extract ExpirationDate raw "$PROFILE_PLIST")"
if [[ "$PROFILE_TEAM" != "$TEAM_ID" ]]; then
  echo "Provisioning profile team $PROFILE_TEAM does not match requested team $TEAM_ID." >&2
  exit 1
fi
if (( PROFILE_DAYS <= 7 )); then
  echo "Provisioning profile is valid for only $PROFILE_DAYS days; refusing a seven-day Personal Team build." >&2
  exit 1
fi

echo "Built a paid-team iPhone/iPad app signed for team $PROFILE_TEAM."
echo "Provisioning profile expires: $PROFILE_EXPIRATION ($PROFILE_DAYS-day profile)."

if [[ "$MODE" == "--install" ]]; then
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
  echo "Installed Markdown Printer on device $DEVICE_ID."
else
  echo "App: $APP_PATH"
fi
