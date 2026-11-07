#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEMP=$(mktemp -d /tmp/DockShift-update-tests.XXXXXX)
trap 'rm -rf "$TEMP"' EXIT
swiftc -module-cache-path "$TEMP/modules" DockShift/Sources/Services/UpdateConfiguration.swift tests/UpdateConfigurationTests.swift \
  -o "$TEMP/configuration-tests"
"$TEMP/configuration-tests"
swiftc -D DEBUG -module-cache-path "$TEMP/modules" DockShift/Sources/Services/UpdateConfiguration.swift tests/UpdateConfigurationTests.swift \
  -o "$TEMP/debug-configuration-tests"
"$TEMP/debug-configuration-tests"
python3 -m py_compile scripts/validate-update-build.py
for script in scripts/*.sh; do zsh -n "$script"; done
