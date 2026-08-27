#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

PROJECT="iOS/MarkdownPrinterIOS.xcodeproj"
SCHEME="MarkdownPrinterIOS"
DERIVED_DATA="$ROOT/.build/ios-verification"
SIMULATOR_ID="${MARKDOWN_PRINTER_IOS_SIMULATOR_ID:-}"

if [[ -z "$SIMULATOR_ID" ]]; then
  SIMULATOR_ID="$(xcrun simctl list devices available --json \
    | jq -r '[.devices[][] | select(.isAvailable == true and (.name | startswith("iPhone")))] | (map(select(.state == "Booted")) + .) | first | .udid // empty')"
fi
if [[ -z "$SIMULATOR_ID" ]]; then
  echo "No available iPhone simulator was found." >&2
  exit 1
fi

rm -rf "$DERIVED_DATA"
xcodebuild -quiet \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test

MOBILE_SUPPORT_BINARY="$(find \
  "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/PackageFrameworks" \
  -type f \
  -path '*MarkdownPrinterMobileSupport*framework/MarkdownPrinterMobileSupport*' \
  -perm -111 \
  -print \
  | head -n 1)"
PROFILE_DATA="$(find "$DERIVED_DATA/Build/ProfileData" -type f -name Coverage.profdata -print | head -n 1)"
if [[ -z "$MOBILE_SUPPORT_BINARY" || -z "$PROFILE_DATA" ]]; then
  echo "The iOS coverage artifacts were not produced." >&2
  exit 1
fi

COVERAGE_REPORT="$(xcrun llvm-cov report \
  "$MOBILE_SUPPORT_BINARY" \
  -instr-profile "$PROFILE_DATA")"
echo "$COVERAGE_REPORT"
LINE_COVERAGE="$(awk '/^TOTAL/ { gsub("%", "", $10); print $10 }' <<< "$COVERAGE_REPORT")"
awk -v coverage="$LINE_COVERAGE" 'BEGIN { exit(coverage + 0 >= 95 ? 0 : 1) }' || {
  echo "Mobile-support Swift line coverage is ${LINE_COVERAGE:-unknown}%; expected at least 95%." >&2
  exit 1
}

echo "iOS verification passed on simulator $SIMULATOR_ID with ${LINE_COVERAGE}% mobile-support line coverage."
