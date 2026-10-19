#!/bin/zsh
# Generate the Xcode project and build DockShift.
# Usage: scripts/build.sh [Debug|Release]   (default: Release)
#   ADHOC=1 scripts/build.sh                 sign ad hoc (no Apple account needed)
#   DEVELOPMENT_TEAM=XXXXXXXXXX scripts/build.sh   sign with your own team
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
CONFIG="${1:-Release}"

SIGNING=()
if [[ "${ADHOC:-0}" == 1 ]]; then
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
elif [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  SIGNING=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

xcodegen generate --quiet
xcodebuild -project DockShift.xcodeproj -scheme DockShift -configuration "$CONFIG" \
  -derivedDataPath ./build "${SIGNING[@]}" build -quiet
BUILT="$PWD/build/Build/Products/$CONFIG/DockShift.app"

# Xcode registers every build with LaunchServices. Next to an installed copy, a registered build
# copy competes for Focus-filter pushes, the Shortcuts action and the login item.
if [[ -d /Applications/DockShift.app ]]; then
  "$LSREGISTER" -u "$BUILT" 2>/dev/null || true
  echo "Unregistered the build copy from LaunchServices (/Applications/DockShift.app is installed)."
fi
echo "Built: $BUILT"
