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
  README.md
  AGENTS.md
  Package.swift
  Resources/Info.plist
  Resources/MarkdownPrinterIcon.png
  Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
  docs/product-development-log.md
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
[[ "$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)" == "1.0" ]]
[[ "$(plutil -extract NSHumanReadableCopyright raw Resources/Info.plist)" == *"Peter Edstrom"* ]]

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
  -ignore-filename-regex='(/Tests/|MarkdownPrinterPackageTests.derived|Sources/MarkdownPrinter/MarkdownPrinter.swift|Sources/MarkdownPrinterCLI/MarkdownPrinterCLI.swift|Sources/MarkdownPrinterUI/MarkdownPrinterView.swift|Sources/MarkdownPrinterUI/PDFPreviewView.swift)')"
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
plutil -lint "build/Markdown Printer.app/Contents/Info.plist" >/dev/null
[[ "$(plutil -extract CFBundleIconFile raw "build/Markdown Printer.app/Contents/Info.plist")" == "AppIcon" ]]
[[ "$(plutil -extract CFBundleIconName raw "build/Markdown Printer.app/Contents/Info.plist")" == "AppIcon" ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "build/Markdown Printer.app/Contents/Info.plist")" == "1.0" ]]
[[ "$(plutil -extract NSHumanReadableCopyright raw "build/Markdown Printer.app/Contents/Info.plist")" == *"Peter Edstrom"* ]]

if git ls-files --error-unmatch .DS_Store >/dev/null 2>&1; then
  echo ".DS_Store is tracked; remove it from the repository." >&2
  exit 1
fi

echo "Verification passed with ${LINE_COVERAGE}% testable production line coverage."
