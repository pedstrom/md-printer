#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_PATH="$ROOT/build/Markdown Printer.app"
ARCHIVE_PATH="${1:-$ROOT/build/Markdown-Printer.zip}"
STAGING_ROOT="$(mktemp -d /private/tmp/markdown-printer-release.XXXXXX)"
STAGED_APP_PATH="$STAGING_ROOT/Markdown Printer.app"
VALIDATION_ROOT="$(mktemp -d /private/tmp/markdown-printer-release-check.XXXXXX)"
trap 'rm -rf "$STAGING_ROOT" "$VALIDATION_ROOT"' EXIT

"$ROOT/scripts/build-and-run/build_app.sh" >/dev/null
ditto "$APP_PATH" "$STAGED_APP_PATH"
xattr -cr "$STAGED_APP_PATH"
codesign --force --sign - "$STAGED_APP_PATH" >/dev/null

mkdir -p "$(dirname "$ARCHIVE_PATH")"
rm -f "$ARCHIVE_PATH"
ditto -c -k --keepParent --norsrc --noextattr "$STAGED_APP_PATH" "$ARCHIVE_PATH"
unzip -tq "$ARCHIVE_PATH" >/dev/null
if unzip -Z1 "$ARCHIVE_PATH" | grep -q '^__MACOSX/'; then
  echo "Release archive contains macOS metadata entries." >&2
  exit 1
fi

ditto -x -k "$ARCHIVE_PATH" "$VALIDATION_ROOT"
codesign --verify --deep --strict "$VALIDATION_ROOT/Markdown Printer.app"

echo "$ARCHIVE_PATH"
