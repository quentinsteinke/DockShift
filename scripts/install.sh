#!/bin/zsh
# Build a Release copy, install it to /Applications and launch it.
# The Focus filter, the Shortcuts action and the login item bind to the copy LaunchServices
# knows about. Xcode registers both the Debug and the Release build, so both build-folder copies
# are unregistered and only /Applications stays registered.
set -euo pipefail
cd "$(dirname "$0")/.."
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

zsh scripts/build.sh Release
BUILT="$PWD/build/Build/Products/Release/DockShift.app"

osascript -e 'quit app "DockShift"' 2>/dev/null || true
sleep 1
rm -rf /Applications/DockShift.app
ditto "$BUILT" /Applications/DockShift.app
for config in Debug Release; do
  "$LSREGISTER" -u "$PWD/build/Build/Products/$config/DockShift.app" 2>/dev/null || true
done
"$LSREGISTER" -f /Applications/DockShift.app

# Any other registered copy (another checkout, a mounted disk image) can still bind the Focus filter.
others=$("$LSREGISTER" -dump 2>/dev/null \
  | sed -nE 's|^path: +(.*/DockShift\.app) \(0x[0-9a-f]+\)$|\1|p' \
  | grep -vx /Applications/DockShift.app | sort -u || true)
if [[ -n "$others" ]]; then
  echo "Warning: other DockShift copies are registered with LaunchServices:" >&2
  print -r -- "$others" | sed 's/^/  /' >&2
  echo "Unregister each with: $LSREGISTER -u <path>" >&2
fi

open /Applications/DockShift.app
echo "Installed /Applications/DockShift.app"
