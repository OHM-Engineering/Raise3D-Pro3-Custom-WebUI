#!/bin/sh
# Stop the custom panel UI (returns to the Raise3D stock UI).
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  c=$(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null || true)
  case "$c" in
    /opt/moonraker/venv/bin/*moonui.py*) echo "stop ui $p"; kill $p;;
  esac
done
