#!/bin/sh
# Show the custom panel UI on the printer screen (DISPLAY :0).
export LD_LIBRARY_PATH=/usr/local/freetype/lib:/usr/local/lib:$LD_LIBRARY_PATH
exec /opt/moonraker/venv/bin/moonui /opt/moonraker/moonui.py "$@"
