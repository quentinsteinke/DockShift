#!/bin/zsh
# Generate the Xcode project and build DockShift.
# Usage: scripts/build.sh [Debug|Release]   (default: Release)
#   DEVELOPMENT_TEAM=XXXXXXXXXX scripts/build.sh   sign with your own team
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
CONFIG="${1:-Release}"
# Build products need a local folder, outside iCloud Drive's metadata updates.
DERIVED="${DERIVED_DATA_PATH:-/tmp/DockShift-build}"

SIGNING=()
if [[ "${ADHOC:-0}" == 1 ]]; then
  echo 'Sparkle with hardened runtime requires an Apple Development identity for local builds.' >&2
  echo 'Use DEVELOPMENT_TEAM=<your team ID> scripts/build.sh instead.' >&2
  exit 1
elif [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  SIGNING=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

xcodegen generate --quiet
xcodebuild -project DockShift.xcodeproj -scheme DockShift -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" "${SIGNING[@]}" build -quiet
BUILT="$DERIVED/Build/Products/$CONFIG/DockShift.app"

# Xcode registers every build with LaunchServices. Next to an installed copy, a registered build
# copy competes for Focus-filter pushes, the Shortcuts action and the login item.
if [[ -d /Applications/DockShift.app ]]; then
  "$LSREGISTER" -u "$BUILT" 2>/dev/null || true
  echo "Unregistered the build copy from LaunchServices (/Applications/DockShift.app is installed)."
fi
echo "Built: $BUILT"
