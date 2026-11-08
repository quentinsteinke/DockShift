#!/bin/zsh
# Deterministic renders and UI tests use synthetic profiles. No desktop settings are changed.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-rune.sh
export RUSTUP_TOOLCHAIN=1.99.1
if command -v rustup >/dev/null; then export PATH="$(dirname "$(rustup which cargo)"):$PATH"; fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/build/rune-target}"
cargo test --manifest-path RuneUI/Cargo.toml --release --locked --lib
OUT="$PWD/build/rune-review/final"
mkdir -p "$OUT"
BIN="$CARGO_TARGET_DIR/release/dockshift-preview"
for scene in profiles studio studio-dark desktops settings focus new dark; do
  "$BIN" --scene "$scene" --snap "$OUT/$scene.png" --tree "$OUT/$scene.json"
done
"$BIN" --snap "$OUT/overview.png" --tree "$OUT/overview.json"
"$BIN" --scene studio-dark --size 1000x640 --snap "$OUT/compact.png" --tree "$OUT/compact.json"
"$BIN" --scene menu --size 355x620 --snap "$OUT/menu.png" --tree "$OUT/menu.json"
"$BIN" --script RuneUI/tests/showcase.json --at 2.3 --snap "$OUT/interaction.png" --trace "$OUT/motion.jsonl"
if command -v ffmpeg >/dev/null; then
  "$BIN" --script RuneUI/tests/showcase.json --duration 4 --video "$OUT/showcase.mp4" --fps 60
fi
echo "Rune review artifacts: $OUT"
