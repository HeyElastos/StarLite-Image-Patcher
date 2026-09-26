#!/bin/bash
# Compat wrapper — the real daemon is the EVIOCGRAB binary.
exec /usr/sbin/power-sleep
