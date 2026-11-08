#!/bin/zsh
# Build and launch a separately identified, paused app with disposable sample profiles.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/build/rune-target}"
PREVIEW_ROOT="${RUNE_PREVIEW_ROOT:-$(mktemp -d /tmp/DockShift-Rune.XXXXXX)}"
DERIVED="${RUNE_PREVIEW_DERIVED:-/tmp/DockShift-RunePreview-build}"
mkdir -p "$PREVIEW_ROOT/assets"
scripts/build-rune.sh
BIN="$CARGO_TARGET_DIR/release/dockshift-preview"
"$BIN" --scene art-coast --size 1600x1000 --snap "$PREVIEW_ROOT/assets/11-wallpaper-coast.png"
"$BIN" --scene art-dusk --size 1600x1000 --snap "$PREVIEW_ROOT/assets/12-wallpaper-dusk.png"
"$BIN" --scene art-clay --size 1600x1000 --snap "$PREVIEW_ROOT/assets/13-wallpaper-clay.png"
python3 scripts/prepare-rune-preview.py "$PREVIEW_ROOT/data" "$PREVIEW_ROOT/assets"
xcodegen generate --quiet
xcodebuild -project DockShift.xcodeproj -scheme DockShift -configuration Debug \
  -derivedDataPath "$DERIVED" ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  PRODUCT_BUNDLE_IDENTIFIER=com.quentinsteinke.DockShift.RunePreview build -quiet
APP="$DERIVED/Build/Products/Debug/DockShift.app"
# Keep disposable Focus/Shortcuts actions out of LaunchServices beside the installed app.
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -u "$APP" 2>/dev/null || true
echo "Paused preview data: $PREVIEW_ROOT/data"
echo "Preview log: $PREVIEW_ROOT/app.log (this terminal stays attached until the app quits)"
export DOCKSHIFT_TEST_DATA_DIRECTORY="$PREVIEW_ROOT/data"
exec "$APP/Contents/MacOS/DockShift" --show-window > "$PREVIEW_ROOT/app.log" 2>&1
