#!/bin/sh
# Deploy the files from this repo to a printer that already has the runtime set up
# (Python 3.11, Moonraker venv, libsodium, FreeType — see docs/INSTALL.md).
#
# Usage:
#   PRINTER=root@192.168.1.50 ./scripts/deploy.sh
#   PRINTER=root@192.168.1.50 ./scripts/deploy.sh --with-webui   # also (re)start web UI
#
# Pick the web UI frontend with WEBUI (fluidd or mainsail, default fluidd):
#   PRINTER=root@192.168.1.50 WEBUI=mainsail ./scripts/deploy.sh --with-webui
#
# Uses your normal ssh/scp (ssh config, keys, or an SSH tunnel). It does NOT touch
# the Python/dependency installation or the Klipper patch.
set -e

PRINTER="${PRINTER:?Set the printer address, e.g. PRINTER=root@192.168.1.50}"
WEBUI="${WEBUI:-fluidd}"
case "$WEBUI" in
  fluidd|mainsail) ;;
  *) echo "WEBUI must be fluidd or mainsail (got: $WEBUI)" >&2; exit 1 ;;
esac
HERE=$(cd "$(dirname "$0")/.." && pwd)
SSH="ssh $PRINTER"
SCP="scp"

echo "Deploying to $PRINTER"

$SSH 'mkdir -p /opt/moonraker/printer_data/{config,logs,comms,database} /opt/moonraker/www'

echo " - panel UI + helpers"
$SCP "$HERE/panel/moonui.py"          "$PRINTER:/opt/moonraker/moonui.py"
$SCP "$HERE/panel/start-ui.sh"        "$PRINTER:/opt/moonraker/start-ui.sh"
$SCP "$HERE/panel/stop-ui.sh"         "$PRINTER:/opt/moonraker/stop-ui.sh"
$SCP "$HERE/panel/render-ui.sh"       "$PRINTER:/opt/moonraker/render-ui.sh"

echo " - web UI server"
$SCP "$HERE/webui/webui.py"           "$PRINTER:/opt/moonraker/webui.py"

echo " - init scripts"
$SCP "$HERE/init/moonraker"           "$PRINTER:/etc/init.d/moonraker"
sed "s#@WEBUI@#$WEBUI#g" "$HERE/init/webui" | \
  $SSH "cat > /etc/init.d/$WEBUI && chmod +x /etc/init.d/$WEBUI"

echo " - sample config (only if absent)"
$SSH '[ -f /opt/moonraker/printer_data/config/moonraker.conf ] || \
      cat > /opt/moonraker/printer_data/config/moonraker.conf' < "$HERE/config/moonraker.conf.sample"

echo " - permissions, symlinks, runlevels"
$SSH "chmod +x /opt/moonraker/start-ui.sh /opt/moonraker/stop-ui.sh \
        /opt/moonraker/render-ui.sh /etc/init.d/moonraker /etc/init.d/$WEBUI
      ln -sf python /opt/moonraker/venv/bin/moonui   # safe process name for the panel UI
      for rl in 2 3 4 5; do
        ln -sf ../init.d/moonraker /etc/rc\$rl.d/S99moonraker
        ln -sf ../init.d/$WEBUI    /etc/rc\$rl.d/S99$WEBUI
      done
      for rl in 0 1 6; do
        ln -sf ../init.d/moonraker /etc/rc\$rl.d/K01moonraker
        ln -sf ../init.d/$WEBUI    /etc/rc\$rl.d/K01$WEBUI
      done"

if [ "$1" = "--with-webui" ]; then
  echo " - restarting services"
  $SSH "/etc/init.d/moonraker restart; /etc/init.d/$WEBUI restart; sleep 3;
        /etc/init.d/moonraker status; /etc/init.d/$WEBUI status"
fi

echo "Done."
echo "Web UI:   http://${PRINTER#*@}/"
echo "Panel UI: ${PRINTER}: /opt/moonraker/start-ui.sh"
