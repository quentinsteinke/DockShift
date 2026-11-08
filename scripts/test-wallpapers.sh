#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/wallpaper-tests
swiftc -parse-as-library -module-cache-path build/wallpaper-tests/modules \
  DockShift/Sources/Model/Models.swift DockShift/Sources/Services/SpaceMonitor.swift \
  DockShift/Sources/Services/Log.swift DockShift/Sources/Engine/WallpaperSync.swift \
  tests/WallpaperSyncTests.swift -o build/wallpaper-tests/check
build/wallpaper-tests/check
