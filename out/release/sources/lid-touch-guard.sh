#!/bin/bash
# lid-touch-guard — remove the internal touchscreen while the lid is CLOSED, so a
# folded-over keyboard / shut lid can't fire phantom touches on an external
# display (docked mode), and restore it when the lid opens.
#
# Also stays unbound while /run/starlite-external-only is set (user disabled the
# internal panel for external-only — see external-only-guard.sh). Cases without
# a keyboard can't close the lid; that flag covers them.
#
# We UNBIND the Goodix touchscreen's i2c driver rather than using the kernel
# `inhibited` knob: on this generic/reven build, ChromeOS re-enables an inhibited
# touchscreen the moment it reconfigures into docked mode, so `inhibited` never
# sticks. Unbinding makes the digitizer physically disappear from the input
# stack — there is nothing left for ChromeOS to re-enable. Rebinding on lid-open
# brings it back. (Verified on-device: inhibited failed while docked, unbind
# fixed it.)

DEV=i2c-GXTP7386:00
FLAG=/run/starlite-external-only

# The i2c-HID-over-ACPI driver (i2c_hid_acpi on 6.x). Detect it rather than
# hard-coding, falling back to the usual name.
DRV=$(ls /sys/bus/i2c/drivers/ 2>/dev/null | grep -i hid | head -1)
[ -z "$DRV" ] && DRV=i2c_hid_acpi

is_bound() { [ -e "/sys/bus/i2c/drivers/$DRV/$DEV" ]; }

# Wait for the ACPI lid-state file (proven reliable on this hardware; `evtest`
# is not installed, so we poll this rather than parse input events).
LIDFILE=""
for _ in $(seq 30); do
  LIDFILE=$(ls /proc/acpi/button/lid/*/state 2>/dev/null | head -1)
  [ -n "$LIDFILE" ] && break
  sleep 1
done
[ -z "$LIDFILE" ] && { logger -t lid-touch-guard "no ACPI lid file"; exit 0; }

last=""
while true; do
  case "$(cat "$LIDFILE" 2>/dev/null)" in
    *closed*) lid=1 ;;
    *)        lid=0 ;;
  esac
  # Unbind when lid closed OR external-only mode is active.
  if [ "$lid" = 1 ] || [ -f "$FLAG" ]; then
    s=1
  else
    s=0
  fi
  if [ "$s" != "$last" ]; then
    if [ "$s" = 1 ]; then
      is_bound && echo "$DEV" > "/sys/bus/i2c/drivers/$DRV/unbind" 2>/dev/null
      logger -t lid-touch-guard "touchscreen unbound (lid=$lid external-only=$([ -f "$FLAG" ] && echo 1 || echo 0))"
    else
      is_bound || echo "$DEV" > "/sys/bus/i2c/drivers/$DRV/bind" 2>/dev/null
      logger -t lid-touch-guard "lid open: touchscreen rebound"
    fi
    last=$s
  fi
  sleep 0.5
done
