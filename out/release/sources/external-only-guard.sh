#!/bin/bash
# external-only-guard — when an external display is connected AND the user has
# disabled the internal panel in ChromeOS display settings (DRM eDP "enabled"
# becomes "disabled"), force the eDP backlight fully off and unbind the Goodix
# touchscreen. Cases without a keyboard can't close the lid, so lid-touch-guard
# alone isn't enough.
#
# On external disconnect (or when the user re-enables the internal display),
# clear the force-off flag, restore the remembered brightness, and let
# lid-touch-guard rebind touch if the lid is open.
#
# Flag file /run/starlite-external-only is the coordination point for
# edp-resume-fix and lid-touch-guard.

FLAG=/run/starlite-external-only
STATE=/var/lib/starlite-last-brightness
DEV=i2c-GXTP7386:00
DRV=$(ls /sys/bus/i2c/drivers/ 2>/dev/null | grep -i hid | head -1)
[ -z "$DRV" ] && DRV=i2c_hid_acpi

is_bound() { [ -e "/sys/bus/i2c/drivers/$DRV/$DEV" ]; }
unbind_ts() { is_bound && echo "$DEV" > "/sys/bus/i2c/drivers/$DRV/unbind" 2>/dev/null; }
bind_ts()   { is_bound || echo "$DEV" > "/sys/bus/i2c/drivers/$DRV/bind" 2>/dev/null; }

bl_node() {
  for b in /sys/class/backlight/*; do
    [ -w "$b/brightness" ] && { echo "$b"; return; }
  done
}

force_bl0() {
  BL=$(bl_node)
  [ -n "$BL" ] || return
  echo 0 > "$BL/brightness" 2>/dev/null
}

restore_bl() {
  BL=$(bl_node)
  [ -n "$BL" ] || return
  BMAX=$(cat "$BL/max_brightness" 2>/dev/null); BMAX=${BMAX:-100}
  w=$BMAX
  if [ -s "$STATE" ]; then
    t=$(cat "$STATE" 2>/dev/null)
    [ -n "$t" ] && [ "$t" -gt 0 ] 2>/dev/null && w=$t
  else
    w=$((BMAX * 4 / 5))
  fi
  [ "$w" -gt "$BMAX" ] 2>/dev/null && w=$BMAX
  echo "$w" > "$BL/brightness" 2>/dev/null
}

# True if any non-internal connector reports connected.
has_external() {
  local c name st
  for c in /sys/class/drm/card*-*; do
    [ -f "$c/status" ] || continue
    name=$(basename "$c")
    case "$name" in
      *eDP*|*LVDS*|*DSI*) continue ;;
    esac
    st=$(cat "$c/status" 2>/dev/null)
    [ "$st" = connected ] && return 0
  done
  return 1
}

# ChromeOS sets DRM "enabled" to disabled when the user turns the internal
# display off in Settings → Displays (external-only).
edp_user_disabled() {
  local c en
  for c in /sys/class/drm/card*-eDP* /sys/class/drm/card*-LVDS* /sys/class/drm/card*-DSI*; do
    [ -f "$c/enabled" ] || continue
    en=$(cat "$c/enabled" 2>/dev/null)
    [ "$en" = disabled ] && return 0
  done
  return 1
}

want_force() {
  has_external || return 1
  edp_user_disabled || return 1
  return 0
}

active=0
while true; do
  if want_force; then
    if [ "$active" != 1 ]; then
      touch "$FLAG" 2>/dev/null
      unbind_ts
      force_bl0
      logger -t external-only-guard "external-only: eDP forced off, touch unbound"
      active=1
    else
      # Keep winning races against ChromeOS / edp-resume re-lighting the panel.
      force_bl0
      unbind_ts
    fi
  else
    if [ "$active" = 1 ]; then
      rm -f "$FLAG" 2>/dev/null
      restore_bl
      # Only rebind touch if lid is open (or no lid file); closed lid stays unbound.
      lid=$(cat /proc/acpi/button/lid/*/state 2>/dev/null | head -1)
      case "$lid" in
        *closed*) ;;
        *) bind_ts ;;
      esac
      logger -t external-only-guard "restored: eDP on, touch per lid state"
      active=0
    fi
  fi
  sleep 0.5
done
