#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?Usage: validate_ios_bundle.sh path/to/app}"
PLIST="$APP_PATH/Info.plist"
[[ "$(plutil -extract UIDeviceFamily json -o - "$PLIST" | jq -c 'sort')" == '[1,2]' ]]
[[ "$(plutil -extract UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes raw "$PLIST")" == true ]]
[[ "$(plutil -extract 'UISupportedInterfaceOrientations~ipad' json -o - "$PLIST" | jq 'unique | length')" == 4 ]]
for orientation in Portrait PortraitUpsideDown LandscapeLeft LandscapeRight; do
  plutil -extract 'UISupportedInterfaceOrientations~ipad' json -o - "$PLIST" \
    | jq -e --arg value "UIInterfaceOrientation$orientation" 'index($value) != null' >/dev/null
done
[[ "$(plutil -extract UIRequiresFullScreen raw "$PLIST" 2>/dev/null || true)" != true ]]
plutil -extract UILaunchScreen json -o - "$PLIST" >/dev/null
[[ "$(plutil -extract CFBundleDocumentTypes.0.CFBundleTypeRole raw "$PLIST")" == Viewer ]]
[[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$PLIST")" == false ]]
test -s "$APP_PATH/PrivacyInfo.xcprivacy"
echo "Validated native iPhone/iPad bundle, windowing, orientations, and privacy metadata."
