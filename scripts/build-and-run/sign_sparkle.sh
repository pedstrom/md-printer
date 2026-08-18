#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <app-path> <signing-identity> [--timestamp]" >&2
  exit 2
fi

APP_PATH="$1"
SIGNING_IDENTITY="$2"
TIMESTAMP_OPTION="${3:-}"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/B"

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Embedded Sparkle framework not found: $SPARKLE_FRAMEWORK" >&2
  exit 1
fi
if [[ -n "$TIMESTAMP_OPTION" && "$TIMESTAMP_OPTION" != "--timestamp" ]]; then
  echo "Unknown option: $TIMESTAMP_OPTION" >&2
  exit 2
fi

SIGNING_OPTIONS=(
  --force
  --options runtime
  --preserve-metadata=identifier,entitlements
  --sign "$SIGNING_IDENTITY"
)
if [[ "$TIMESTAMP_OPTION" == "--timestamp" ]]; then
  SIGNING_OPTIONS+=(--timestamp)
fi

# Sparkle's helpers cross privilege boundaries. Sign each nested component with
# the app's identity before sealing the containing framework and application.
codesign "${SIGNING_OPTIONS[@]}" "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
codesign "${SIGNING_OPTIONS[@]}" "$SPARKLE_VERSION/XPCServices/Installer.xpc"
codesign "${SIGNING_OPTIONS[@]}" "$SPARKLE_VERSION/Updater.app"
codesign "${SIGNING_OPTIONS[@]}" "$SPARKLE_VERSION/Autoupdate"
codesign "${SIGNING_OPTIONS[@]}" "$SPARKLE_FRAMEWORK"
