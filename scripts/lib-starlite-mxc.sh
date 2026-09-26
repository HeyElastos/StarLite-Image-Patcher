# shellcheck shell=bash
# lib-starlite-mxc.sh — detect image KVER, select matching mxc4005.ko, refuse wrong vermagic.
# Source from build-fydeos-starlite.sh (needs: BASE, SRCDIR, OUT, W, die, ok, say).

# Detect the (first) kernel version under /lib/modules on ROOT-A of $OUT (or $1).
starlite_detect_kver() {
  local img="${1:-$OUT}"
  local raw
  raw=$(guestfish --ro -a "$img" -m /dev/sda3:/ <<'GF' 2>/dev/null
sh 'ls -1 /lib/modules 2>/dev/null | head -5'
GF
)
  # guestfish may prefix lines; take first token that looks like a kver
  local k
  k=$(printf '%s\n' "$raw" | tr -d '\r' | awk '/^[0-9]+\.[0-9]+/{print; exit}')
  [ -n "$k" ] || die "starlite_detect_kver: no /lib/modules/* on $img"
  printf '%s' "$k"
}

# Read /etc/lsb-release and /lib/modules from a FydeOS or OpenFyde image.
# Prints one machine line:
#   IDENT|family|version|board|build|kver|module|known
# family is FydeOS, OpenFyde, or ChromeOS. module is ready or missing.
# Sets IMAGE_KVER, IMAGE_FAMILY, IMAGE_MODULE.
starlite_print_identity() {
  local img="$1"
  local tmp raw kver board version build family module known vm
  tmp=$(mktemp -d)
  raw=$(guestfish --ro -a "$img" -m /dev/sda3:/ <<GF 2>/dev/null
download /etc/lsb-release ${tmp}/lsb-release
sh 'ls -1 /lib/modules 2>/dev/null'
GF
)
  kver=$(printf '%s\n' "$raw" | tr -d '\r' | awk '/^[0-9]+\.[0-9]+/{print; exit}')
  [ -n "$kver" ] || die "no /lib/modules/* on $img"
  [ -s "${tmp}/lsb-release" ] || die "no /etc/lsb-release on $img"
  board=$(sed -n 's/^CHROMEOS_RELEASE_BOARD=//p' "${tmp}/lsb-release" | tr -d '\r' | head -1)
  version=$(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' "${tmp}/lsb-release" | tr -d '\r' | head -1)
  build=$(sed -n 's/^CHROMEOS_RELEASE_BUILD_TYPE=//p' "${tmp}/lsb-release" | tr -d '\r' | head -1)
  case "$board" in
    *openfyde*) family=OpenFyde ;;
    *fydeos*) family=FydeOS ;;
    *) family=ChromeOS ;;
  esac
  module=missing
  if [ -s "$SRCDIR/mxc4005/$kver/mxc4005.ko" ]; then
    module=ready
  elif [ -s "$SRCDIR/mxc4005.ko" ]; then
    vm=$(starlite_ko_vermagic "$SRCDIR/mxc4005.ko")
    [ "$vm" = "$kver" ] && module=ready
  fi
  known=$(find "$SRCDIR/mxc4005" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  rm -rf "$tmp"
  printf 'IDENT|%s|%s|%s|%s|%s|%s|%s\n' \
    "$family" "$version" "$board" "$build" "$kver" "$module" "$known"
  if [ "$module" = ready ]; then
    ok "$family $version ($board, $build) kernel $kver — accelerometer module ready"
  else
    ok "$family $version ($board, $build) kernel $kver — no accelerometer module for this kernel (have: ${known:-none})"
  fi
  IMAGE_KVER=$kver
  IMAGE_FAMILY=$family
  IMAGE_MODULE=$module
}

# Read vermagic string from a .ko (host strings/modinfo).
starlite_ko_vermagic() {
  local ko="$1"
  if command -v modinfo >/dev/null 2>&1; then
    modinfo -F vermagic "$ko" 2>/dev/null | head -1 | awk '{print $1}'
    return 0
  fi
  # Fallback: strings — vermagic is "X.Y.Z-... SMP ..."
  strings "$ko" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+[^ ]* SMP' | head -1 | awk '{print $1}'
}

# Resolve which mxc4005.ko to inject for $KVER.
# Prefer: out/release/sources/mxc4005/$KVER/mxc4005.ko
# Fallback: SRCDIR/mxc4005.ko only if vermagic matches KVER.
# Sets: MXC_KO (path)  MXC_VERMAGIC
starlite_select_mxc_ko() {
  local kver="$1"
  local cache="$SRCDIR/mxc4005/$kver/mxc4005.ko"
  local flat="$SRCDIR/mxc4005.ko"
  MXC_KO=""
  MXC_VERMAGIC=""
  MXC_SKIP=0

  if [ "${STARLITE_SKIP_MXC:-0}" = "1" ]; then
    MXC_SKIP=1
    echo "  WARN: STARLITE_SKIP_MXC=1 — skipping accelerometer module inject (auto-rotate will not work)"
    return 0
  fi

  if [ -s "$cache" ]; then
    MXC_KO="$cache"
  elif [ -s "$flat" ]; then
    MXC_KO="$flat"
  else
    die "no mxc4005.ko for KVER=$kver (tried $cache and $flat). Run: scripts/build-mxc4005.sh --kver $kver   (or STARLITE_SKIP_MXC=1 / --skip-mxc for lean-only)"
  fi

  MXC_VERMAGIC=$(starlite_ko_vermagic "$MXC_KO")
  [ -n "$MXC_VERMAGIC" ] || die "could not read vermagic from $MXC_KO"

  if [ "$MXC_VERMAGIC" != "$kver" ]; then
    die "mxc4005 vermagic $MXC_VERMAGIC != image kernel $kver. Refusing to replace the image kernel or ship a module that will not load. Build out/release/sources/mxc4005/$kver/mxc4005.ko for this exact vermagic."
  fi
  if ! python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); raise SystemExit(0 if b"-1, 0, 0; 0, 1, 0; 0, 0, 1" in d else 1)' "$MXC_KO"; then
    die "mxc4005.ko $MXC_KO is not the proven mount matrix (-1, 0, 0; 0, 1, 0; 0, 0, 1)"
  fi
  ok "mxc4005.ko selected: $MXC_KO (vermagic $MXC_VERMAGIC)"
}

# FydeOS iioservice only attaches an hrtimer named iioservice-%i.
# OpenFyde iioservice accepts the driver's own trigger name.
starlite_check_trigger_name() {
  local family="$1"
  local ko="$2"
  local need=""
  case "$family" in
    FydeOS) need="iioservice-0" ;;
    OpenFyde) need="mxc4005-hr" ;;
    *) return 0 ;;
  esac
  python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); raise SystemExit(0 if sys.argv[2].encode() in d else 1)' "$ko" "$need" \
    || die "$family mxc4005.ko must contain trigger name $need"
  ok "$family accelerometer trigger name $need"
}

# Optional: try to rebuild via build-mxc4005.sh before select. Non-fatal if blocked.
starlite_ensure_mxc_for_kver() {
  local kver="$1"
  local cache="$SRCDIR/mxc4005/$kver/mxc4005.ko"
  if [ -s "$cache" ]; then
    ok "cached mxc4005 for $kver already present"
    return 0
  fi
  if [ -x "$BASE/scripts/build-mxc4005.sh" ] || [ -f "$BASE/scripts/build-mxc4005.sh" ]; then
    say "mxc) attempting build-mxc4005.sh for $kver"
    if bash "$BASE/scripts/build-mxc4005.sh" --kver "$kver"; then
      ok "build-mxc4005 produced module for $kver"
      return 0
    fi
    echo "  WARN: build-mxc4005.sh failed for $kver — will try existing SRCDIR/mxc4005.ko if vermagic matches"
    return 0
  fi
  echo "  WARN: no scripts/build-mxc4005.sh — using staged ko only"
}

# Append a modules.dep entry for mxc4005 if depmod unavailable in guestfish.
# Arg1=path to modules.dep (host-side temp); Arg2=kver
starlite_modules_dep_line() {
  local kver="$1"
  # relative path as modules.dep expects
  printf 'kernel/drivers/iio/accel/mxc4005.ko:\n'
}
