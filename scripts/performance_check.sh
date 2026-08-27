#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--skip-build" ]]; then
  SKIP_BUILD=1
elif [[ -n "${1:-}" ]]; then
  echo "Usage: scripts/performance_check.sh [--skip-build]" >&2
  exit 2
else
  SKIP_BUILD=0
fi

mkdir -p .build/module-cache .build/swiftpm-cache
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_CUSTOM_CACHE_PATH="$ROOT/.build/swiftpm-cache"

if [[ "$SKIP_BUILD" == "0" ]]; then
  swift build -c release --product MarkdownPrinterCLI >/dev/null
fi

BINARY="$ROOT/.build/release/MarkdownPrinterCLI"
if [[ ! -x "$BINARY" ]]; then
  echo "Missing release benchmark executable: $BINARY" >&2
  exit 1
fi

RESULTS_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/markdown-printer-performance.XXXXXX")"
trap 'rm -rf "$RESULTS_DIRECTORY"' EXIT

run_benchmark() {
  local label="$1"
  local bytes="$2"
  local maximum_parse="$3"
  local maximum_attributed="$4"
  local maximum_pdf_total="$5"
  local maximum_quick_look="$6"
  local maximum_word_total="$7"
  local maximum_stall="$8"
  local maximum_rss="$9"
  local report="$RESULTS_DIRECTORY/$label.json"
  local resources="$RESULTS_DIRECTORY/$label.resources"

  /usr/bin/time -lp "$BINARY" --benchmark "$bytes" >"$report" 2>"$resources"
  local rss
  rss="$(awk '/maximum resident set size/ { print $1 }' "$resources")"
  if [[ -z "$rss" ]]; then
    echo "The $label benchmark did not report maximum resident memory." >&2
    exit 1
  fi

  jq -e \
    --argjson requested_bytes "$bytes" \
    --argjson maximum_parse "$maximum_parse" \
    --argjson maximum_attributed "$maximum_attributed" \
    --argjson maximum_pdf_total "$maximum_pdf_total" \
    --argjson maximum_quick_look "$maximum_quick_look" \
    --argjson maximum_word_total "$maximum_word_total" \
    --argjson maximum_stall "$maximum_stall" \
    --argjson maximum_rss "$maximum_rss" \
    --argjson rss "$rss" \
    '
      .sourceBytes >= $requested_bytes
      and .parseSeconds <= $maximum_parse
      and .attributedSeconds <= $maximum_attributed
      and .pdfTotalSeconds <= $maximum_pdf_total
      and .quickLookSeconds <= $maximum_quick_look
      and .wordTotalSeconds <= $maximum_word_total
      and .mainActorMaxStallSeconds <= $maximum_stall
      and $rss <= $maximum_rss
    ' "$report" >/dev/null || {
      echo "The $label benchmark exceeded a performance budget." >&2
      jq --argjson rss "$rss" '. + {maximumResidentBytes: $rss}' "$report" >&2
      exit 1
    }

  jq --arg label "$label" --argjson rss "$rss" \
    '{size: $label, parseSeconds, attributedSeconds, pdfTotalSeconds, quickLookSeconds, wordTotalSeconds, mainActorMaxStallSeconds, maximumResidentBytes: $rss}' \
    "$report"
}

run_benchmark "100 KB" 100000 0.10 0.20 1.0 0.50 1.5 0.10 125829120
run_benchmark "1 MB" 1000000 0.60 1.00 6.0 3.00 8.0 0.15 471859200

SMALL_REPORT="$RESULTS_DIRECTORY/100 KB.json"
LARGE_REPORT="$RESULTS_DIRECTORY/1 MB.json"
jq -e -n \
  --slurpfile small "$SMALL_REPORT" \
  --slurpfile large "$LARGE_REPORT" \
  '
    $large[0].parseSeconds <= ($small[0].parseSeconds * 15)
    and $large[0].attributedSeconds <= ($small[0].attributedSeconds * 15)
    and $large[0].quickLookSeconds <= ($small[0].quickLookSeconds * 15)
    and $large[0].wordTotalSeconds <= ($small[0].wordTotalSeconds * 15)
  ' >/dev/null || {
    echo "The 10x input benchmark grew by more than 15x in a parser or renderer path." >&2
    exit 1
  }

echo "Performance checks passed."
