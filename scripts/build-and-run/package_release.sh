#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_PATH="$ROOT/build/Markdown Printer.app"
ARCHIVE_PATH="${1:-$ROOT/build/Markdown-Printer.zip}"
SIGNING_IDENTITY="${MARKDOWN_PRINTER_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${MARKDOWN_PRINTER_NOTARY_PROFILE:-}"
STAGING_ROOT="$(mktemp -d /private/tmp/markdown-printer-release.XXXXXX)"
STAGED_APP_PATH="$STAGING_ROOT/Markdown Printer.app"
SUBMISSION_ARCHIVE_PATH="$STAGING_ROOT/Markdown-Printer-submission.zip"
VALIDATION_ROOT="$(mktemp -d /private/tmp/markdown-printer-release-check.XXXXXX)"
trap 'rm -rf "$STAGING_ROOT" "$VALIDATION_ROOT"' EXIT

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "Set MARKDOWN_PRINTER_SIGNING_IDENTITY to the full Developer ID Application identity." >&2
  exit 2
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Set MARKDOWN_PRINTER_NOTARY_PROFILE to a notarytool Keychain profile name." >&2
  exit 2
fi

"$ROOT/scripts/build-and-run/build_app.sh" >/dev/null
ditto "$APP_PATH" "$STAGED_APP_PATH"
xattr -cr "$STAGED_APP_PATH"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$STAGED_APP_PATH"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP_PATH"

SIGNING_INFORMATION="$(codesign --display --verbose=4 "$STAGED_APP_PATH" 2>&1)"
if ! grep -q '^Authority=Developer ID Application:' <<< "$SIGNING_INFORMATION"; then
  echo "Release app is not signed with a Developer ID Application certificate." >&2
  exit 1
fi
if ! grep -q 'flags=.*runtime' <<< "$SIGNING_INFORMATION"; then
  echo "Release app does not have the hardened runtime enabled." >&2
  exit 1
fi
if ! grep -q '^Timestamp=' <<< "$SIGNING_INFORMATION"; then
  echo "Release app does not have a secure signing timestamp." >&2
  exit 1
fi

ditto -c -k --keepParent --norsrc --noextattr "$STAGED_APP_PATH" "$SUBMISSION_ARCHIVE_PATH"
NOTARY_RESULT="$(xcrun notarytool submit "$SUBMISSION_ARCHIVE_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json)"
echo "$NOTARY_RESULT"
NOTARY_STATUS="$(printf '%s' "$NOTARY_RESULT" | plutil -extract status raw -o - -)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  NOTARY_ID="$(printf '%s' "$NOTARY_RESULT" | plutil -extract id raw -o - -)"
  xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" || true
  echo "Apple notarization ended with status: $NOTARY_STATUS" >&2
  exit 1
fi

xcrun stapler staple --verbose "$STAGED_APP_PATH"
xcrun stapler validate --verbose "$STAGED_APP_PATH"

mkdir -p "$(dirname "$ARCHIVE_PATH")"
rm -f "$ARCHIVE_PATH"
ditto -c -k --keepParent --norsrc --noextattr "$STAGED_APP_PATH" "$ARCHIVE_PATH"
unzip -tq "$ARCHIVE_PATH" >/dev/null
if unzip -Z1 "$ARCHIVE_PATH" | grep -q '^__MACOSX/'; then
  echo "Release archive contains macOS metadata entries." >&2
  exit 1
fi

ditto -x -k "$ARCHIVE_PATH" "$VALIDATION_ROOT"
VALIDATED_APP_PATH="$VALIDATION_ROOT/Markdown Printer.app"
codesign --verify --deep --strict --verbose=2 "$VALIDATED_APP_PATH"
xcrun stapler validate --verbose "$VALIDATED_APP_PATH"
spctl --assess --type execute --verbose=4 "$VALIDATED_APP_PATH"

echo "$ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH"
