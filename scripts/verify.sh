#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
MODE="${1:-}"

if [[ -n "$MODE" && "$MODE" != "--staged" ]]; then
  echo "Usage: scripts/verify.sh [--staged]" >&2
  exit 2
fi

required_files=(
  LICENSE
  README.md
  AGENTS.md
  Package.swift
  Package.resolved
  Resources/Info.plist
  Resources/MarkdownDocumentIcon.png
  Resources/MarkdownPrinterIcon.png
  Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
  docs/product-development-log.md
  docs/quick-look-product-contract.md
  QuickLookExtension/MarkdownPrinterQuickLook.xcodeproj/project.pbxproj
  QuickLookExtension/MarkdownPrinterQuickLook.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  QuickLookExtension/MarkdownPrinterQuickLook.xcodeproj/xcshareddata/xcschemes/MarkdownPrinterQuickLook.xcscheme
  QuickLookExtension/MarkdownPrinterQuickLook/Info.plist
  QuickLookExtension/MarkdownPrinterQuickLook/MarkdownPrinterQuickLook.entitlements
  QuickLookExtension/MarkdownPrinterQuickLook/PreviewViewController.swift
  release-notes/1.0.md
  release-notes/1.0.1.md
  release-notes/1.0.2.md
  release-notes/1.0.3.md
  release-notes/1.0.4.md
  release-notes/1.1.0.md
  release-notes/1.2.0.md
  release-notes/1.3.0.md
  scripts/build-and-run/prepare_update_release.sh
  scripts/build-and-run/validate_quicklook_bundle.sh
  scripts/build-and-run/sign_sparkle.sh
  scripts/build-and-run/verify_published_release.sh
  scripts/build-and-run/verify_update_assets.sh
  .codex/skills/md-printer-macos/SKILL.md
  .codex/skills/md-printer-change-gate/SKILL.md
)
for file in "${required_files[@]}"; do
  if [[ ! -s "$file" ]]; then
    echo "Missing or empty required file: $file" >&2
    exit 1
  fi
done

duplicate_copy_files="$({ git ls-files --others --exclude-standard; git ls-files --others -i --exclude-standard; } \
  | grep -E '(^|/)[^/]+ [0-9]+(\.[^/]+)?$' || true)"
if [[ -n "$duplicate_copy_files" ]]; then
  echo "Found Finder/sync duplicate-copy files:"
  echo "$duplicate_copy_files"
  exit 1
fi

if [[ "$MODE" == "--staged" ]]; then
  git diff --check --cached
else
  git diff --check
  git diff --check --cached
fi

while IFS= read -r script; do
  bash -n "$script"
done < <(find scripts -type f -name '*.sh' -print | sort)
plutil -lint Resources/Info.plist >/dev/null
plutil -lint QuickLookExtension/MarkdownPrinterQuickLook/Info.plist >/dev/null
plutil -lint \
  QuickLookExtension/MarkdownPrinterQuickLook/MarkdownPrinterQuickLook.entitlements \
  >/dev/null
[[ "$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)" == "1.3.0" ]]
[[ "$(plutil -extract CFBundleVersion raw Resources/Info.plist)" == "8" ]]
[[ "$(plutil -extract NSHumanReadableCopyright raw Resources/Info.plist)" == *"Peter Edstrom"* ]]
[[ "$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeRole raw Resources/Info.plist)" \
  == "Viewer" ]]
[[ "$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeIconFile raw Resources/Info.plist)" \
  == "MarkdownDocumentIcon" ]]
[[ "$(plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw Resources/Info.plist)" \
  == "Default" ]]
[[ "$(plutil -extract CFBundleDocumentTypes.0.LSItemContentTypes.0 raw \
  Resources/Info.plist)" == "net.daringfireball.markdown" ]]
[[ "$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeExtensions json -o - \
  Resources/Info.plist)" == '["md","markdown","mdown","mkd"]' ]]
[[ "$(plutil -extract UTImportedTypeDeclarations.0.UTTypeIdentifier raw \
  Resources/Info.plist)" == "net.daringfireball.markdown" ]]
[[ "$(plutil -extract \
  'UTImportedTypeDeclarations.0.UTTypeTagSpecification.public\.filename-extension' \
  json -o - Resources/Info.plist)" == '["md","markdown","mdown","mkd"]' ]]
[[ "$(plutil -extract SUFeedURL raw Resources/Info.plist)" == "https://github.com/pedstrom/md-printer/releases/latest/download/appcast.xml" ]]
[[ "$(plutil -extract SUPublicEDKey raw Resources/Info.plist)" == "uJG4sJlofZdkVBe09QbsziY979haWLKCmCidGssas3k=" ]]
[[ "$(plutil -extract SUEnableAutomaticChecks raw Resources/Info.plist)" == "true" ]]
[[ "$(plutil -extract SUScheduledCheckInterval raw Resources/Info.plist)" == "86400" ]]
[[ "$(plutil -extract SUAutomaticallyUpdate raw Resources/Info.plist)" == "false" ]]
[[ "$(plutil -extract SUAllowsAutomaticUpdates raw Resources/Info.plist)" == "false" ]]
[[ "$(plutil -extract SUEnableSystemProfiling raw Resources/Info.plist)" == "false" ]]
[[ "$(plutil -extract SURequireSignedFeed raw Resources/Info.plist)" == "true" ]]
[[ "$(plutil -extract SUVerifyUpdateBeforeExtraction raw Resources/Info.plist)" == "true" ]]
[[ "$(plutil -extract SUShowReleaseNotes raw Resources/Info.plist)" == "true" ]]
if plutil -extract SUSendProfileInfo raw Resources/Info.plist >/dev/null 2>&1; then
  echo "SUSendProfileInfo must not be configured." >&2
  exit 1
fi
grep -q '"identity" : "sparkle"' Package.resolved
grep -q '"version" : "2.9.2"' Package.resolved

mkdir -p .build/module-cache .build/swiftpm-cache
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_CUSTOM_CACHE_PATH="$ROOT/.build/swiftpm-cache"
swift test --enable-code-coverage

TEST_BINARY="$(find .build -type f -path '*MarkdownPrinterPackageTests.xctest/Contents/MacOS/MarkdownPrinterPackageTests' | head -n 1)"
PROFDATA="$(find .build -type f -path '*/codecov/default.profdata' | head -n 1)"
if [[ -z "$TEST_BINARY" || -z "$PROFDATA" ]]; then
  echo "Coverage artifacts were not produced." >&2
  exit 1
fi

COVERAGE_REPORT="$(xcrun llvm-cov report "$TEST_BINARY" \
  -instr-profile "$PROFDATA" \
  -ignore-filename-regex='(/Tests/|MarkdownPrinterPackageTests.derived|Sources/MarkdownPrinter/MarkdownPrinter.swift|Sources/MarkdownPrinterCLI/MarkdownPrinterCLI.swift|Sources/MarkdownPrinterUI/MarkdownPrinterView.swift|Sources/MarkdownPrinterUI/PDFPreviewView.swift|Sources/MarkdownPrinterUI/ExportSettingsView.swift)')"
echo "$COVERAGE_REPORT"
LINE_COVERAGE="$(awk '/^TOTAL/ { gsub("%", "", $10); print $10 }' <<< "$COVERAGE_REPORT")"
awk -v coverage="$LINE_COVERAGE" 'BEGIN { exit(coverage + 0 >= 95 ? 0 : 1) }' || {
  echo "Testable production Swift line coverage is ${LINE_COVERAGE:-unknown}%; expected at least 95%." >&2
  exit 1
}

scripts/build-and-run/build_app.sh >/dev/null
test -x "build/Markdown Printer.app/Contents/MacOS/MarkdownPrinter"
APP_ARCHITECTURES="$(lipo -archs "build/Markdown Printer.app/Contents/MacOS/MarkdownPrinter")"
[[ "$APP_ARCHITECTURES" == *"arm64"* ]]
[[ "$APP_ARCHITECTURES" == *"x86_64"* ]]
test -s "build/Markdown Printer.app/Contents/Resources/Assets.car"
test -s "build/Markdown Printer.app/Contents/Resources/AppIcon.icns"
test -s "build/Markdown Printer.app/Contents/Resources/MarkdownDocumentIcon.icns"
plutil -lint "build/Markdown Printer.app/Contents/Info.plist" >/dev/null
[[ "$(plutil -extract CFBundleIconFile raw "build/Markdown Printer.app/Contents/Info.plist")" == "AppIcon" ]]
[[ "$(plutil -extract CFBundleIconName raw "build/Markdown Printer.app/Contents/Info.plist")" == "AppIcon" ]]
[[ "$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeIconFile raw \
  "build/Markdown Printer.app/Contents/Info.plist")" == "MarkdownDocumentIcon" ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "build/Markdown Printer.app/Contents/Info.plist")" == "1.3.0" ]]
[[ "$(plutil -extract CFBundleVersion raw "build/Markdown Printer.app/Contents/Info.plist")" == "8" ]]
[[ "$(plutil -extract NSHumanReadableCopyright raw "build/Markdown Printer.app/Contents/Info.plist")" == *"Peter Edstrom"* ]]
scripts/build-and-run/validate_quicklook_bundle.sh "build/Markdown Printer.app"

SPARKLE_FRAMEWORK="build/Markdown Printer.app/Contents/Frameworks/Sparkle.framework"
test -L "$SPARKLE_FRAMEWORK/Versions/Current"
test -x "$SPARKLE_FRAMEWORK/Versions/B/Sparkle"
test -x "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
test -x "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
test -x "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
test -x "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"

ARCHITECTURE_TARGETS=(
  "build/Markdown Printer.app/Contents/MacOS/MarkdownPrinter"
  "build/Markdown Printer.app/Contents/PlugIns/MarkdownPrinterQuickLook.appex/Contents/MacOS/MarkdownPrinterQuickLook"
  "$SPARKLE_FRAMEWORK/Versions/B/Sparkle"
  "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
  "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
  "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
)
for executable_path in "${ARCHITECTURE_TARGETS[@]}"; do
  EXECUTABLE_ARCHITECTURES="$(lipo -archs "$executable_path")"
  [[ "$EXECUTABLE_ARCHITECTURES" == *"arm64"* ]]
  [[ "$EXECUTABLE_ARCHITECTURES" == *"x86_64"* ]]
done
APP_LINKED_LIBRARIES="$(otool -L \
  "build/Markdown Printer.app/Contents/MacOS/MarkdownPrinter")"
grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' <<< "$APP_LINKED_LIBRARIES"
APP_LOAD_COMMANDS="$(otool -l \
  "build/Markdown Printer.app/Contents/MacOS/MarkdownPrinter")"
grep -Fq '@executable_path/../Frameworks' <<< "$APP_LOAD_COMMANDS"

DEVELOPMENT_SIGNING_INFORMATION="$(codesign --display --verbose=4 \
  "build/Markdown Printer.app" 2>&1)"
if grep -q 'flags=.*runtime' <<< "$DEVELOPMENT_SIGNING_INFORMATION"; then
  echo "Ad-hoc development app must not enable same-team library validation." >&2
  exit 1
fi

if git ls-files --error-unmatch .DS_Store >/dev/null 2>&1; then
  echo ".DS_Store is tracked; remove it from the repository." >&2
  exit 1
fi

echo "Verification passed with ${LINE_COVERAGE}% testable production line coverage."
