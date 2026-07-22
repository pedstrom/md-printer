#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: scripts/build-and-run/render_markdown.sh <input.md> <output.pdf>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p .build/module-cache .build/swiftpm-cache
CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" \
  SWIFTPM_CUSTOM_CACHE_PATH="$ROOT/.build/swiftpm-cache" \
  swift run MarkdownPrinterCLI "$1" "$2"
