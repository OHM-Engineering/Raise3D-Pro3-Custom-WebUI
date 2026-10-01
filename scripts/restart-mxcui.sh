#!/bin/sh
# Restart the stock Raise3D touch UI (MXCUI).
#
# MXCUI reads its settings (e2config.cfg, hotend.cfg, ...) once at start, so a
# restart is needed to pick up edits made through the web UI. It is launched by
# the X/matchbox session with a specific environment, which we reproduce here.
#
# MXCUI also stops and relaunches Klipper when it starts. Moonraker does not
# reliably reconnect to the replacement, so once the new Klipper reports ready
# we bounce Moonraker to restore the web UI/API link.
#
# The caller (Klipper's RUN_SHELL_COMMAND) must not block, so this script
# re-execs itself detached and returns immediately.

if [ "$1" != "--worker" ]; then
    setsid "$0" --worker >/dev/null 2>&1 &
    exit 0
fi

# --- detached worker from here on -------------------------------------------

klipper_ready() {
    /usr/bin/python2 - <<'PY' 2>/dev/null
import socket, json, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect("/opt/moonraker/printer_data/comms/klippy.sock")
    s.sendall(json.dumps({"id": 1, "method": "info"}) + "\x03")
    data = ""
    while "\x03" not in data:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()
    sys.exit(0 if '"state":"ready"' in data else 1)
except Exception:
    sys.exit(1)
PY
}

# Capture the D-Bus session address from the running instance, if any.
ADDR=$(tr '\0' '\n' < /proc/"$(pidof MXCUI)"/environ 2>/dev/null \
       | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
[ -n "$ADDR" ] && export DBUS_SESSION_BUS_ADDRESS="$ADDR"

export DISPLAY=:0.0
export TSLIB_TSDEVICE=/dev/input/touchscreen0
export XSERVER_DEFAULT_ORIENTATION=normal
export GTK_CSD=0
export WINDOWPATH=1
export LC_ALL=zh_CN.UTF-8
export HOME=/home/root
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

OLD_K=$(pidof python)
sleep 1
kill -9 $(pidof MXCUI) 2>/dev/null
sleep 2
cd /opt/Raise3D
/opt/Raise3D/MXCUI >/dev/null 2>&1 &

# Wait (up to ~120s) for the *replacement* Klipper to be ready. Comparing the
# PID avoids a race where the old Klipper (still up while MXCUI starts) reports
# ready before MXCUI has replaced it.
i=0
while [ $i -lt 60 ]; do
    NEW_K=$(pidof python)
    if [ -n "$NEW_K" ] && [ "$NEW_K" != "$OLD_K" ] && klipper_ready; then
        break
    fi
    sleep 2
    i=$((i + 1))
done

# Reconnect Moonraker to the new Klipper.
/etc/init.d/moonraker restart >/dev/null 2>&1
exit 0
