#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="${1:-}"

if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <stable-tag, for example v1.3.0>" >&2
  exit 2
fi

LOCAL_ASSETS="$ROOT/build/release-assets/$TAG"
VALIDATION_ROOT="$(mktemp -d /private/tmp/markdown-printer-public-release.XXXXXX)"
trap 'rm -rf "$VALIDATION_ROOT"' EXIT

RELEASE_JSON="$(gh release view "$TAG" --repo pedstrom/md-printer \
  --json isDraft,isPrerelease,tagName,url)"
if [[ "$(plutil -extract isDraft raw -o - - <<< "$RELEASE_JSON")" != "false" ]]; then
  echo "GitHub release $TAG is still a draft." >&2
  exit 1
fi
if [[ "$(plutil -extract isPrerelease raw -o - - <<< "$RELEASE_JSON")" != "false" ]]; then
  echo "GitHub release $TAG is a prerelease, not a stable release." >&2
  exit 1
fi

TAG_URL="https://github.com/pedstrom/md-printer/releases/download/$TAG"
for asset in Markdown-Printer.zip Markdown-Printer.md appcast.xml; do
  curl --fail --location --silent --show-error \
    "$TAG_URL/$asset" \
    --output "$VALIDATION_ROOT/$asset"
done
curl --fail --location --silent --show-error \
  'https://github.com/pedstrom/md-printer/releases/latest/download/appcast.xml' \
  --output "$VALIDATION_ROOT/latest-appcast.xml"

cmp "$VALIDATION_ROOT/appcast.xml" "$VALIDATION_ROOT/latest-appcast.xml"
"$ROOT/scripts/build-and-run/verify_update_assets.sh" "$VALIDATION_ROOT"

if [[ -f "$LOCAL_ASSETS/Markdown-Printer.zip" ]]; then
  cmp "$LOCAL_ASSETS/Markdown-Printer.zip" "$VALIDATION_ROOT/Markdown-Printer.zip"
fi

ditto -x -k "$VALIDATION_ROOT/Markdown-Printer.zip" "$VALIDATION_ROOT/unpacked"
PUBLIC_APP="$VALIDATION_ROOT/unpacked/Markdown Printer.app"
codesign --verify --deep --strict --verbose=2 "$PUBLIC_APP"
xcrun stapler validate --verbose "$PUBLIC_APP"
spctl --assess --type execute --verbose=4 "$PUBLIC_APP"

echo "Verified published stable release $TAG and latest appcast."
shasum -a 256 "$VALIDATION_ROOT/Markdown-Printer.zip"
