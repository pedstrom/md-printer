#!/usr/bin/env bash
set -euo pipefail

INCLUDE_IOS=false
if [[ "${1:-}" == "--include-ios" ]]; then
  INCLUDE_IOS=true
  shift
fi

if [[ "$#" -eq 0 ]]; then
  echo "Usage: scripts/commit_staged.sh [--include-ios] \"Commit message\"" >&2
  exit 2
fi

if git diff --cached --quiet; then
  echo "No staged changes to commit." >&2
  exit 1
fi

if [[ "$INCLUDE_IOS" == true ]]; then
  scripts/verify.sh --staged --include-ios
else
  scripts/verify.sh --staged
fi
git commit -m "$*"
