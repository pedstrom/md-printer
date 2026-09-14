#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

PROJECT="iOS/MarkdownPrinterIOS.xcodeproj"
SCHEME="MarkdownPrinterIOS"
IOS_TEST_TEMP_ROOT="${TMPDIR:-/private/tmp}"
DERIVED_DATA="${IOS_TEST_TEMP_ROOT%/}/md-printer-ios-verification"
COVERAGE_RUNS="$DERIVED_DATA/coverage-runs"
TEST_RESULTS="$DERIVED_DATA/Results"
SIMULATOR_ID="${MARKDOWN_PRINTER_IOS_SIMULATOR_ID:-}"
IPAD_ID="${MARKDOWN_PRINTER_IPAD_SIMULATOR_ID:-}"
MINI_ID="${MARKDOWN_PRINTER_IPAD_MINI_SIMULATOR_ID:-}"
IPAD_11_ID="${MARKDOWN_PRINTER_IPAD_11_SIMULATOR_ID:-}"

mkdir -p "$DERIVED_DATA"
rm -rf "$DERIVED_DATA/Build" "$DERIVED_DATA/Logs/Test" "$COVERAGE_RUNS" "$TEST_RESULTS"
mkdir -p "$COVERAGE_RUNS" "$TEST_RESULTS"
TEST_RUN=0

DEVICES="$(xcrun simctl list devices available --json)"
select_device() {
  jq -r --arg type "$1" '[.devices[][] | select(.isAvailable and (.deviceTypeIdentifier | contains($type)))] | (map(select(.state == "Booted")) + .) | first | .udid // empty' <<< "$DEVICES"
}
[[ -n "$SIMULATOR_ID" ]] || SIMULATOR_ID="$(select_device 'SimDeviceType.iPhone-')"
[[ -n "$IPAD_ID" ]] || IPAD_ID="$(select_device 'SimDeviceType.iPad-Pro-13-inch-')"
[[ -n "$MINI_ID" ]] || MINI_ID="$(select_device 'SimDeviceType.iPad-mini-')"
[[ -n "$IPAD_11_ID" ]] || IPAD_11_ID="$(select_device 'SimDeviceType.iPad-Pro-11-inch-')"
if [[ -z "$SIMULATOR_ID" || -z "$IPAD_ID" || -z "$MINI_ID" || -z "$IPAD_11_ID" ]]; then
  echo "Verification requires iPhone, 13-inch iPad, iPad mini, and 11-inch iPad simulators. Set the MARKDOWN_PRINTER_*_SIMULATOR_ID overrides if needed." >&2
  exit 1
fi

# Materialize the locked dependencies in a fresh verification directory before
# disabling resolution for every test run. Never update the pinned versions.
xcodebuild -quiet -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA" -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates

run_test_target() {
  local target="$1"
  local device="${2:-$SIMULATOR_ID}"
  TEST_RUN=$((TEST_RUN + 1))
  xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$device" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$TEST_RESULTS/$TEST_RUN.xcresult" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackageUpdates \
    -parallel-testing-enabled NO \
    "-only-testing:$target" \
    test
  # Xcode replaces a device's profile on the next test invocation.
  cp "$DERIVED_DATA/Build/ProfileData/$device/Coverage.profdata" "$COVERAGE_RUNS/$TEST_RUN.profdata"
}

run_test_target MarkdownPrinterIOSTests

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Markdown Printer.app"
bash scripts/build-and-run/validate_ios_bundle.sh "$APP_PATH"

run_test_target MarkdownPrinterIOSUITests "$SIMULATOR_ID"
run_test_target MarkdownPrinterIOSTests "$IPAD_ID"
run_test_target MarkdownPrinterIOSUITests "$IPAD_ID"
run_test_target MarkdownPrinterIOSTests "$MINI_ID"
run_test_target MarkdownPrinterIOSUITests "$MINI_ID"
run_test_target MarkdownPrinterIOSUITests/MarkdownPrinterIOSUITests/testViewerAdaptsToLandscape "$IPAD_11_ID"

MOBILE_SUPPORT_BINARY="$(find \
  "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/PackageFrameworks" \
  -type f \
  -path '*MarkdownPrinterMobileSupport*framework/MarkdownPrinterMobileSupport*' \
  -perm -111 \
  -print \
  | head -n 1)"
PROFILES=()
while IFS= read -r profile; do PROFILES+=("$profile"); done < <(find "$COVERAGE_RUNS" -type f -name '*.profdata' -print)
PROFILE_DATA="$DERIVED_DATA/mobile-coverage.profdata"
if [[ ${#PROFILES[@]} -eq 0 ]]; then
  echo "The iOS coverage profiles were not produced." >&2
  exit 1
fi
xcrun llvm-profdata merge -sparse "${PROFILES[@]}" -o "$PROFILE_DATA"
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

WINDOW_COVERAGE_REPORT="$DERIVED_DATA/window-coverage.json"
xcrun llvm-cov export "$MOBILE_SUPPORT_BINARY" -instr-profile "$PROFILE_DATA" -summary-only > "$WINDOW_COVERAGE_REPORT"
WINDOW_LINE_COVERAGE="$(jq '[.data[0].files[] | select(.filename | test("/(MobileDocumentWindows|MobileFindTextField|MobilePDFPresentation)\\.swift$")) | .summary.lines] | if length == 3 then (map(.covered) | add) * 100 / (map(.count) | add) else 0 end' "$WINDOW_COVERAGE_REPORT")"
awk -v coverage="$WINDOW_LINE_COVERAGE" 'BEGIN { exit(coverage + 0 >= 95 ? 0 : 1) }' || {
  echo "Window routing, restoration, and presentation coverage is ${WINDOW_LINE_COVERAGE}%; expected at least 95%." >&2
  exit 1
}
echo "Window routing, restoration, and presentation line coverage: ${WINDOW_LINE_COVERAGE}%."

echo "iPhone and iPad verification passed with ${LINE_COVERAGE}% mobile-support line coverage."
