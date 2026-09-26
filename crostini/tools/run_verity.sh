#!/bin/bash
# Run the board-build verity with its own loader + libraries.
# Self-contained: uses toolchain/ (extracted from the old 171GB src/ checkout),
# so the chromiumos source tree is no longer required to rebuild an image.
BT="$(cd "$(dirname "$0")/../../toolchain" && pwd)"
exec "$BT/lib64/ld-linux-x86-64.so.2" \
  --library-path "$BT/usr/lib64:$BT/lib64:$BT/usr/local/factory/bundle/setup/libx64" \
  "$BT/usr/bin/verity" "$@"
