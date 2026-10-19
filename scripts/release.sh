#!/bin/zsh
# Build a distributable DockShift: universal Release build, ad-hoc signed (no Apple account needed),
# packaged as build/release/DockShift-<version>.dmg and .zip.
# Not notarized: on first launch macOS asks the user to approve it in Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

VERSION=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?/\1/p' project.yml | head -1)
OUT=build/release
DERIVED=build/release-derived
APP="$DERIVED/Build/Products/Release/DockShift.app"

xcodegen generate --quiet
rm -rf "$DERIVED" "$OUT"
xcodebuild -project DockShift.xcodeproj -scheme DockShift -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build -quiet
# Xcode registers every build with LaunchServices; this copy must not compete with an installed one.
"$LSREGISTER" -u "$APP" 2>/dev/null || true

codesign --verify --deep --strict "$APP"
test -d "$APP/Contents/Resources/Metadata.appintents"   # the Focus filter lives here
lipo -archs "$APP/Contents/MacOS/DockShift"

mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/DockShift-$VERSION.zip"

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/DockShift.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DockShift $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  "$OUT/DockShift-$VERSION.dmg" -quiet
rm -rf "$STAGE"

(cd "$OUT" && shasum -a 256 DockShift-"$VERSION".dmg DockShift-"$VERSION".zip > SHA256SUMS.txt)
echo "Release $VERSION:"
ls -lh "$OUT"
