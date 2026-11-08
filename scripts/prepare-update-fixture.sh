#!/bin/zsh
# Prepare isolated real-app update fixtures. Does not launch apps or a server.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="${UPDATE_TEST_ROOT:-/tmp/DockShift-updater-e2e}"
[[ ! -e "$ROOT/installed" ]] || { echo 'Existing fixture retained; choose a new UPDATE_TEST_ROOT.' >&2; exit 1; }
mkdir -p "$ROOT"
swiftc -parse-as-library -module-cache-path "$ROOT/modules" tests/MakeUpdateTestKey.swift -o "$ROOT/make-key"
"$ROOT/make-key" "$ROOT/private-key" "$ROOT/public-key"
PUBLIC_KEY=$(cat "$ROOT/public-key")
scripts/build-rune.sh
xcodegen generate --quiet
xcodebuild -project DockShift.xcodeproj -scheme DockShift -configuration Debug \
  -derivedDataPath "$ROOT/derived" -destination 'generic/platform=macOS' \
  PRODUCT_BUNDLE_IDENTIFIER=com.quentinsteinke.DockShift.UpdaterTest \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES DOCKSHIFT_UPDATE_PUBLIC_KEY="$PUBLIC_KEY" \
  DOCKSHIFT_UPDATE_FEED_URL=http://127.0.0.1:8765/appcast.xml build -quiet
mkdir -p "$ROOT/installed" "$ROOT/new" "$ROOT/feed"
ditto "$ROOT/derived/Build/Products/Debug/DockShift.app" "$ROOT/new/DockShift.app"
python3 - "$ROOT/new/DockShift.app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
with open(sys.argv[1], 'wb') as f: plistlib.dump(info, f)
PY
IDENTITY="${TEST_SIGNING_IDENTITY:-Apple Development}"
codesign --force --sign "$IDENTITY" --options runtime "$ROOT/new/DockShift.app"
ditto "$ROOT/new/DockShift.app" "$ROOT/installed/DockShift.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' "$ROOT/installed/DockShift.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.0' "$ROOT/installed/DockShift.app/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --options runtime "$ROOT/installed/DockShift.app"
codesign --verify --deep --strict "$ROOT/installed/DockShift.app"
codesign --verify --deep --strict "$ROOT/new/DockShift.app"
NEW_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/new/DockShift.app/Contents/Info.plist")
ditto -c -k --keepParent "$ROOT/new/DockShift.app" "$ROOT/feed/DockShift-$NEW_VERSION.zip"
TOOLS="$ROOT/derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$TOOLS/generate_appcast" --ed-key-file "$ROOT/private-key" --maximum-deltas 0 \
  --download-url-prefix http://127.0.0.1:8765/ "$ROOT/feed"
"$TOOLS/sign_update" --ed-key-file "$ROOT/private-key" --verify "$ROOT/feed/appcast.xml"
echo "Fixture ready: $ROOT (test key is only for these disposable apps)"
echo "Run a loopback-only server: python3 -m http.server 8765 --bind 127.0.0.1 --directory $ROOT/feed"
