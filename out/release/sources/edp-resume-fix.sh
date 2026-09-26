#!/bin/bash
# Restore panel after suspend. Remember the last brightness the user set instead
# of forcing ~80% of max (which felt like "always wakes at full").
DEST=org.chromium.DisplayService; OBJ=/org/chromium/DisplayService
IF=org.chromium.DisplayServiceInterface
STATE=/var/lib/starlite-last-brightness
BL=$(for b in /sys/class/backlight/*; do [ -w "$b/brightness" ] && { echo "$b"; break; }; done)
BMAX=$(cat "$BL/max_brightness" 2>/dev/null); BMAX=${BMAX:-100}
# Fallback if we never saw a user level yet (same as old powerd no-ALS default).
DEFAULT=$((BMAX * 4 / 5))

sp(){ dbus-send --system --type=method_call --dest=$DEST $OBJ $IF.SetPower int32:$1 2>/dev/null; }

read_bl(){ cat "$BL/brightness" 2>/dev/null; }
save_bl(){
  [ -n "$BL" ] || return
  cur=$(read_bl); [ -n "$cur" ] || return
  # Ignore zeros (panel already off / mid-blank) so we don't "remember" darkness.
  [ "$cur" -gt 0 ] 2>/dev/null || return
  echo "$cur" > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE" 2>/dev/null
}
want_bl(){
  if [ -s "$STATE" ]; then
    w=$(cat "$STATE" 2>/dev/null)
    [ -n "$w" ] && [ "$w" -gt 0 ] 2>/dev/null && { echo "$w"; return; }
  fi
  echo "$DEFAULT"
}
bset(){
  [ -n "$BL" ] || return
  # Don't fight external-only-guard (user disabled internal for HDMI/USB-C only).
  [ -f /run/starlite-external-only ] && return
  w=$(want_bl)
  [ "$w" -gt "$BMAX" ] 2>/dev/null && w=$BMAX
  echo "$w" > "$BL/brightness" 2>/dev/null
}
relight(){
  [ -f /run/starlite-external-only ] && return
  sp 1; sleep 0.4; sp 0
  ( for i in $(seq 12); do bset; sleep 0.4; done ) &
}

mkdir -p "$(dirname "$STATE")" 2>/dev/null
# Seed once so first resume has something sensible.
[ -s "$STATE" ] || echo "$DEFAULT" > "$STATE" 2>/dev/null

( for i in $(seq 8); do bset; sleep 0.5; done ) &
( while true; do save_bl; sleep 30; done ) &
# A stall is not a resume. Treating a clock step as wake called SetPower 1
# and turned the panel off during setup. Relight only after a real suspend.
exec dbus-monitor --system "type='signal',interface='org.chromium.PowerManager',member='SuspendDone'" | while read -r line; do
  case "$line" in
    *member=SuspendDone*) relight ;;
  esac
done
