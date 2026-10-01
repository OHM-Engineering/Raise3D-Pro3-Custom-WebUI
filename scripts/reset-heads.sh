#!/bin/sh
# Reset the mainboard/head controller (HCB): clears a stuck thermostatic head
# fan that ignores host fan commands. M5100 RESET leaves Klipper in shutdown,
# so this also runs FIRMWARE_RESTART afterwards and waits for Klipper to be
# ready. Everything runs detached so the caller returns immediately.

setsid sh -c '
curl -s -m 10 "http://127.0.0.1:7125/printer/gcode/script?script=M5100%20RESET" >/dev/null 2>&1
sleep 6
curl -s -m 10 -X POST "http://127.0.0.1:7125/printer/firmware_restart" >/dev/null 2>&1
i=0
while [ $i -lt 40 ]; do
    if curl -s -m 5 "http://127.0.0.1:7125/printer/info" 2>/dev/null \
        | grep -q "\"state\":\"ready\""; then
        break
    fi
    sleep 3
    i=$(( i + 1 ))
done
exit 0
' >/dev/null 2>&1 &

exit 0
