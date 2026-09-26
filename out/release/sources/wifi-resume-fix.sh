#!/bin/bash
# Intentionally idle.
# Unloading iwlwifi or bouncing shill on a clock step aborts WPA and
# looks like a wrong password. Do not bring that healer back.
while true; do
  sleep 3600
done
