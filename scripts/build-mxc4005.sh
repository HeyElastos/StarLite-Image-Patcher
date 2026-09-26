#!/usr/bin/env bash
# build-mxc4005.sh — build mxc4005.ko matching a FydeOS/openFyde image KVER.
#
# Preferred order (see docs / StarLite plan):
#   A) Out-of-tree against openFyde/chromeos kernel checkout under src/ matching KVER
#   B) Module.symvers + .config extracted from kernel partition / build artifacts;
#      compile mxc4005.c from Linux mainline (same major) with matching vermagic
#   C) Cache result at out/release/sources/mxc4005/$KVER/mxc4005.ko
#
# Usage:
#   ./scripts/build-mxc4005.sh --kver 6.12.54-01180-gb4e10020ba49-dirty
#   ./scripts/build-mxc4005.sh --from-image downloads/FydeOS_for_PC_iris_v23.0-SP1-io.bin
#
# Exit 0 on success (module cached). Exit 2 if blocked (no headers/symvers) with
# a clear next-step message. Never silently ships a wrong-vermagic module.
set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRCDIR="$BASE/out/release/sources"
CACHEDIR_ROOT="$SRCDIR/mxc4005"
WORKDIR="${TMPDIR:-/tmp}/build-mxc4005-$$"

KVER=""
FROM_IMAGE=""
MAINLINE_MAJOR=""

say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
die(){ printf '  \033[31m✗ %s\033[0m\n' "$*"; exit 1; }
block(){ printf '  \033[33mBLOCKED: %s\033[0m\n' "$*"; exit 2; }

usage() {
  sed -n '2,20p' "$0"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --kver) KVER="${2:?}"; shift 2 ;;
    --from-image) FROM_IMAGE="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1" ;;
  esac
done

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT
mkdir -p "$WORKDIR" "$CACHEDIR_ROOT"

if [ -n "$FROM_IMAGE" ]; then
  [ -f "$FROM_IMAGE" ] || die "image not found: $FROM_IMAGE"
  say "detect KVER from $FROM_IMAGE"
  KVER=$(guestfish --ro -a "$FROM_IMAGE" -m /dev/sda3:/ <<'GF' 2>/dev/null | tr -d '\r' | awk '/^[0-9]+\.[0-9]+/{print; exit}'
sh 'ls -1 /lib/modules 2>/dev/null | head -5'
GF
)
  [ -n "$KVER" ] || die "could not detect KVER from image"
  ok "KVER=$KVER"
fi

[ -n "$KVER" ] || die "pass --kver <ver> or --from-image <bin>"

CACHE="$CACHEDIR_ROOT/$KVER"
mkdir -p "$CACHE"
OUT_KO="$CACHE/mxc4005.ko"

if [ -s "$OUT_KO" ]; then
  VM=$(modinfo -F vermagic "$OUT_KO" 2>/dev/null | awk '{print $1}')
  if [ "$VM" = "$KVER" ] && python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); raise SystemExit(0 if b"-1, 0, 0; 0, 1, 0; 0, 0, 1" in d else 1)' "$OUT_KO"; then
    ok "cache hit $OUT_KO (vermagic $VM, proven mount matrix)"
    # also refresh flat copy for older callers
    cp -f "$OUT_KO" "$SRCDIR/mxc4005.ko"
    exit 0
  fi
  echo "  WARN: stale cache vermagic=$VM — rebuilding"
fi

MAINLINE_MAJOR=$(printf '%s' "$KVER" | cut -d. -f1-2) # e.g. 6.12

# ---------------------------------------------------------------------------
# A) openFyde / chromeos kernel tree matching this release
# ---------------------------------------------------------------------------
find_kernel_tree() {
  local cand
  for cand in \
    "$BASE/src/src/third_party/kernel/v${MAINLINE_MAJOR}" \
    "$BASE/src/src/third_party/kernel/v6.12" \
    "$BASE/src/src/third_party/kernel/v6.6" \
    "$BASE/src/third_party/kernel/v${MAINLINE_MAJOR}" \
    "$BASE/src/kernel" \
    "$BASE/src/out/build/"*/build/modules/"$KVER"/build \
    /lib/modules/"$KVER"/build
  do
    if [ -d "$cand" ] && { [ -f "$cand/Makefile" ] || [ -f "$cand/source/Makefile" ]; }; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# Locate mxc4005.c (mainline or chromeos tree)
find_mxc_src() {
  local cand
  for cand in \
    "$BASE/src/src/third_party/kernel/v${MAINLINE_MAJOR}/drivers/iio/accel/mxc4005.c" \
    "$BASE/out/release/sources/mxc4005.c" \
    "$WORKDIR/mxc4005.c"
  do
    [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

fetch_mainline_mxc_c() {
  # Same major as image kernel. Prefer local linux src if present.
  local localc
  for localc in \
    /usr/src/linux/drivers/iio/accel/mxc4005.c \
    /usr/src/kernels/*/drivers/iio/accel/mxc4005.c
  do
    if [ -f "$localc" ]; then
      cp -f "$localc" "$WORKDIR/mxc4005.c"
      ok "mxc4005.c from $localc"
      return 0
    fi
  done
  # Network fetch from kernel.org stable (best-effort)
  local url="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/iio/accel/mxc4005.c?h=linux-${MAINLINE_MAJOR}.y"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "$url" -o "$WORKDIR/mxc4005.c" && [ -s "$WORKDIR/mxc4005.c" ]; then
      ok "fetched mxc4005.c from kernel.org linux-${MAINLINE_MAJOR}.y"
      return 0
    fi
  fi
  return 1
}

say "A) look for matching kernel build tree for $KVER"
KTREE=$(find_kernel_tree || true)
if [ -n "${KTREE:-}" ]; then
  ok "kernel tree: $KTREE"
  SRC_C=$(find_mxc_src || true)
  if [ -z "${SRC_C:-}" ]; then
    fetch_mainline_mxc_c || true
    SRC_C=$(find_mxc_src || true)
  fi
  if [ -n "${SRC_C:-}" ]; then
    mkdir -p "$WORKDIR/otree"
    cat > "$WORKDIR/otree/Makefile" <<MK
obj-m := mxc4005.o
MK
    cp -f "$SRC_C" "$WORKDIR/otree/mxc4005.c"
    if make -C "$KTREE" M="$WORKDIR/otree" modules -j"$(nproc 2>/dev/null || echo 2)"; then
      if [ -s "$WORKDIR/otree/mxc4005.ko" ]; then
        VM=$(modinfo -F vermagic "$WORKDIR/otree/mxc4005.ko" 2>/dev/null | awk '{print $1}')
        if [ "$VM" = "$KVER" ]; then
          cp -f "$WORKDIR/otree/mxc4005.ko" "$OUT_KO"
          cp -f "$OUT_KO" "$SRCDIR/mxc4005.ko"
          ok "A) built $OUT_KO vermagic=$VM"
          exit 0
        fi
        echo "  WARN: A) built vermagic=$VM != $KVER — not caching"
      fi
    else
      echo "  WARN: A) make failed against $KTREE"
    fi
  else
    echo "  WARN: A) no mxc4005.c found"
  fi
else
  echo "  (no matching kernel tree under src/ or /lib/modules/$KVER/build)"
fi

# ---------------------------------------------------------------------------
# B) Extract Module.symvers + .config from image / artifacts; compile OOT
# ---------------------------------------------------------------------------
say "B) try Module.symvers + .config from image/artifacts"

SYMVERS=""
KCONFIG=""
for cand in \
  "$BASE/out/kernel-artifacts/$KVER/Module.symvers" \
  "$BASE/src/out/build/"*/Module.symvers \
  "$BASE/vk1-verify/rebuild/Module.symvers"
do
  [ -f "$cand" ] && SYMVERS="$cand" && break
done
for cand in \
  "$BASE/out/kernel-artifacts/$KVER/.config" \
  "$BASE/src/out/build/"*/.config
do
  [ -f "$cand" ] && KCONFIG="$cand" && break
done

# Try pull System.map / modules.builtin from ROOT-A (headers almost never present)
if [ -z "$SYMVERS" ] && [ -n "${FROM_IMAGE:-}" ]; then
  guestfish --ro -a "$FROM_IMAGE" -m /dev/sda3:/ <<GF 2>/dev/null || true
download /lib/modules/$KVER/modules.dep $WORKDIR/modules.dep
download /lib/modules/$KVER/modules.builtin $WORKDIR/modules.builtin
GF
fi

if [ -z "$SYMVERS" ] || [ -z "$KCONFIG" ]; then
  block "no ChromeOS-matching headers for $KVER.
  Next steps to get a 6.12.54 module:
    1) Check out openFyde iris kernel (third_party/kernel/v6.12) matching
       commit/tag that builds $KVER, OR
    2) Drop Module.symvers + .config from that build into
       $BASE/out/kernel-artifacts/$KVER/{Module.symvers,.config}
       then re-run: $0 --kver $KVER
    3) Host Fedora mainline mxc4005 has WRONG vermagic — do not use it.
  Lean strip + dynamic KVER inject path can still ship; auto-rotate needs this .ko."
fi

# If we somehow have symvers+config but no full tree, still blocked without a makeable KDIR
block "Module.symvers/.config found but no compilable KDIR for $KVER — place a prepared tree at src/ or /lib/modules/$KVER/build"
