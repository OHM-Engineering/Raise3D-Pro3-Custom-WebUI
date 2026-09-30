#!/bin/sh
# Render UI previews (upright 600x1024) without touching the printer screen.
export LD_LIBRARY_PATH=/usr/local/freetype/lib:/usr/local/lib
OUT=${1:-/opt/moonraker/ui-preview}
mkdir -p "$OUT"
PY=/opt/moonraker/venv/bin/python
for t in move heat print; do
  $PY /opt/moonraker/moonui.py --render "$OUT/ui_$t.png" --tab $t --mock
done
echo "previews in $OUT"
