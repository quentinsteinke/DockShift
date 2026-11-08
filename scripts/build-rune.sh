#!/bin/zsh
# Build the pinned renderer. Local builds use this Mac's architecture; releases request both.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TOOLCHAIN=1.99.1
export RUSTUP_TOOLCHAIN="$TOOLCHAIN"
if command -v rustup >/dev/null; then
  RUSTUP_BIN="$(command -v rustup || true)"
  "$RUSTUP_BIN" toolchain install "$TOOLCHAIN" --profile minimal
  export PATH="$(dirname "$("$RUSTUP_BIN" which --toolchain "$TOOLCHAIN" cargo)"):$PATH"
fi
command -v cargo >/dev/null || { echo 'Install Rust with rustup before building Rune.' >&2; exit 1; }
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/build/rune-target}"
mkdir -p build/rune
cargo build --manifest-path RuneUI/Cargo.toml --release --locked
LIB="$CARGO_TARGET_DIR/release/libdockshift_ui.dylib"
if [[ "${1:-native}" == universal ]]; then
  HOST_ARCH="$(uname -m)"
  OTHER=x86_64-apple-darwin
  [[ "$HOST_ARCH" == arm64 ]] || OTHER=aarch64-apple-darwin
  rustup target add "$OTHER" --toolchain "$TOOLCHAIN"
  cargo build --manifest-path RuneUI/Cargo.toml --release --locked --target "$OTHER" --lib
  lipo -create "$LIB" "$CARGO_TARGET_DIR/$OTHER/release/libdockshift_ui.dylib" -output build/rune/libdockshift_ui.dylib
else
  cp "$LIB" build/rune/libdockshift_ui.dylib
fi
install_name_tool -id @rpath/libdockshift_ui.dylib build/rune/libdockshift_ui.dylib
echo "Rune renderer: $(lipo -archs build/rune/libdockshift_ui.dylib)"
