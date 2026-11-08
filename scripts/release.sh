#!/bin/zsh
# Prepare signed/notarized universal artifacts and a signed Sparkle feed. Never publishes.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool Keychain profile}"
[[ "$SIGNING_IDENTITY" == 'Developer ID Application: '* ]] || {
  echo 'Distribution requires a Developer ID Application certificate.' >&2; exit 1
}
ACCOUNT="${SPARKLE_KEY_ACCOUNT:-DockShift}"
DERIVED="${DERIVED_DATA_PATH:-/tmp/DockShift-release-derived}"
VERSION=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?/\1/p' project.yml | head -1)
OUT="${RELEASE_OUTPUT:-$PWD/build/release-$VERSION-$(date +%Y%m%d-%H%M%S)}"
[[ ! -e "$OUT" ]] || { echo "Refusing to replace existing output: $OUT" >&2; exit 1; }
STAGE=$(mktemp -d /tmp/DockShift-release.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

scripts/build-rune.sh universal
xcodegen generate --quiet
xcodebuild -project DockShift.xcodeproj -scheme DockShift -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  -archivePath "$STAGE/DockShift.xcarchive" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" CODE_SIGN_STYLE=Manual archive -quiet
# Xcode's Developer ID export signs nested Sparkle helpers for distribution as well.
python3 - "$STAGE/ExportOptions.plist" "$SIGNING_IDENTITY" "${DEVELOPMENT_TEAM:-8C5LBVCRXP}" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(method='developer-id', signingStyle='manual',
                       signingCertificate=sys.argv[2], teamID=sys.argv[3]), f)
PY
xcodebuild -exportArchive -archivePath "$STAGE/DockShift.xcarchive" \
  -exportOptionsPlist "$STAGE/ExportOptions.plist" -exportPath "$STAGE/export" -quiet
APP="$STAGE/export/DockShift.app"
TOOLS="${SPARKLE_BIN:-$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin}"
# Public key only. generate_keys -p never creates, exports, or prints a private key.
PUBLIC_KEY=$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)
python3 scripts/validate-update-build.py "$APP" "$PUBLIC_KEY"
codesign --verify --deep --strict "$APP"
test -d "$APP/Contents/Resources/Metadata.appintents"
[[ "$(lipo -archs "$APP/Contents/MacOS/DockShift")" == *arm64* ]]
[[ "$(lipo -archs "$APP/Contents/MacOS/DockShift")" == *x86_64* ]]
[[ "$(lipo -archs "$APP/Contents/Frameworks/libdockshift_ui.dylib")" == *arm64* ]]
[[ "$(lipo -archs "$APP/Contents/Frameworks/libdockshift_ui.dylib")" == *x86_64* ]]

# Notarize and staple before making the update archive: its signature covers the final bytes.
ditto -c -k --keepParent "$APP" "$STAGE/notarize.zip"
xcrun notarytool submit "$STAGE/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/DockShift-$VERSION.zip"
mkdir "$STAGE/dmg"
ditto "$APP" "$STAGE/dmg/DockShift.app"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -volname "DockShift $VERSION" -srcfolder "$STAGE/dmg" -format UDZO \
  "$OUT/DockShift-$VERSION.dmg" -quiet
xcrun notarytool submit "$OUT/DockShift-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT/DockShift-$VERSION.dmg"
# Feed contains the ZIP only, with a stable immutable versioned download URL.
mkdir "$STAGE/feed"
cp "$OUT/DockShift-$VERSION.zip" "$STAGE/feed/"
"$TOOLS/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/quentinsteinke/DockShift/releases/download/v$VERSION/" \
  "$STAGE/feed"
cp "$STAGE/feed/appcast.xml" "$OUT/appcast.xml"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$OUT/appcast.xml"
(cd "$OUT" && shasum -a 256 "DockShift-$VERSION.dmg" "DockShift-$VERSION.zip" appcast.xml > SHA256SUMS.txt)
echo "Prepared (not published): $OUT"
echo "Attach all four files to GitHub release v$VERSION. appcast.xml must retain its exact signed bytes."
