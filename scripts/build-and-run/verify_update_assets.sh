#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ASSET_DIRECTORY="${1:-}"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ -z "$ASSET_DIRECTORY" ]]; then
  echo "Usage: $0 <release-asset-directory>" >&2
  exit 2
fi

ARCHIVE="$ASSET_DIRECTORY/Markdown-Printer.zip"
RELEASE_NOTES="$ASSET_DIRECTORY/Markdown-Printer.md"
APPCAST="$ASSET_DIRECTORY/appcast.xml"

for path in "$ARCHIVE" "$RELEASE_NOTES" "$APPCAST" "$SIGN_UPDATE"; do
  if [[ ! -f "$path" ]]; then
    echo "Required update artifact is missing: $path" >&2
    exit 1
  fi
done

xmllint --noout "$APPCAST"

ARCHIVE_SIGNATURE="$(xmllint --xpath \
  "string(//*[local-name()='enclosure']/@*[local-name()='edSignature'])" \
  "$APPCAST")"
ARCHIVE_LENGTH="$(xmllint --xpath \
  "string(//*[local-name()='enclosure']/@length)" \
  "$APPCAST")"
RELEASE_NOTES_SIGNATURE="$(xmllint --xpath \
  "string(//*[local-name()='releaseNotesLink']/@*[local-name()='edSignature'])" \
  "$APPCAST")"
RELEASE_NOTES_LENGTH="$(xmllint --xpath \
  "string(//*[local-name()='releaseNotesLink']/@*[local-name()='length'])" \
  "$APPCAST")"

if [[ -z "$ARCHIVE_SIGNATURE" || -z "$RELEASE_NOTES_SIGNATURE" ]]; then
  echo "Appcast does not contain EdDSA signatures for both update assets." >&2
  exit 1
fi
if [[ "$ARCHIVE_LENGTH" != "$(stat -f %z "$ARCHIVE")" ]]; then
  echo "Appcast archive length does not match Markdown-Printer.zip." >&2
  exit 1
fi
if [[ "$RELEASE_NOTES_LENGTH" != "$(stat -f %z "$RELEASE_NOTES")" ]]; then
  echo "Appcast release-notes length does not match Markdown-Printer.md." >&2
  exit 1
fi

"$SIGN_UPDATE" --verify "$APPCAST"
"$SIGN_UPDATE" --verify "$ARCHIVE" "$ARCHIVE_SIGNATURE"
"$SIGN_UPDATE" --verify "$RELEASE_NOTES" "$RELEASE_NOTES_SIGNATURE"

echo "Verified signed appcast, archive, and release notes."
shasum -a 256 "$ARCHIVE"
