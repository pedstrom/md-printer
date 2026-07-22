#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/scripts/build-and-run/build_app.sh" >/dev/null
open "$ROOT/build/Markdown Printer.app"
