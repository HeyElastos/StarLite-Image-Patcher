#!/usr/bin/env bash
# Thin host entrypoint for the Flatpak GUI (flatpak-spawn --host).
# Execs build-fydeos-starlite.sh with the same args.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/build-fydeos-starlite.sh"
if [[ ! -x "$SCRIPT" && ! -f "$SCRIPT" ]]; then
  echo "error: missing $SCRIPT" >&2
  exit 127
fi
exec bash "$SCRIPT" "$@"
