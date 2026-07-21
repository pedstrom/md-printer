#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "Usage: scripts/commit_staged.sh \"Commit message\"" >&2
  exit 2
fi

if git diff --cached --quiet; then
  echo "No staged changes to commit." >&2
  exit 1
fi

scripts/verify.sh --staged
git commit -m "$*"
