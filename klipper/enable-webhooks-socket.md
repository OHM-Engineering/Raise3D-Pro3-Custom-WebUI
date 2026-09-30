# Enable Klipper's API socket

Moonraker talks to Klipper over its **webhooks Unix-domain socket** (JSON-RPC). The vendor
`MXCUI` starts Klipper *without* `-a`, so the socket is never created. We can't change the
command line built into the `MXCUI` binary, so instead we give `--api-server` a **default**
value inside `klippy.py`.

This is additive: `MXCUI` continues to drive Klipper over the `/tmp/printer` pty console.

## The change

File: `/opt/Raise3D/klipper-master/klippy/klippy.py`, inside `main()`.

```diff
     options, args = opts.parse_args()
     if len(args) != 1:
         opts.error("Incorrect number of arguments")
-    start_args = {'config_file': args[0], 'apiserver': options.apiserver,
-                  'start_reason': 'startup'}
+    _apiserver = options.apiserver
+    if not _apiserver:
+        _apiserver = '/opt/moonraker/printer_data/comms/klippy.sock'
+    start_args = {'config_file': args[0], 'apiserver': _apiserver,
+                  'start_reason': 'startup'}
```

If you prefer `-a <path>` to still win when provided, this preserves that (it only supplies a
default when none is given).

## Apply

```sh
KP=/opt/Raise3D/klipper-master
cp -a $KP/klippy/klippy.py $KP/klippy/klippy.py.orig-moonraker   # backup

# make sure the socket's directory exists before Klipper starts
mkdir -p /opt/moonraker/printer_data/comms

# edit the file (vi/nano) to apply the diff above, then verify Python 2 syntax:
python2 -c "compile(open('$KP/klippy/klippy.py').read(),'klippy.py','exec'); print('syntax ok')"
```

## Restart Klipper

The change only takes effect after a **full Klipper process restart** (a soft `RESTART` does
not re-read `klippy.py`). `MXCUI` does not restart Klipper for you:

```sh
pkill -f 'klippy/klippy.py'
sleep 2
cd /opt/Raise3D/klipper-master
setsid python klippy/klippy.py \
  /opt/Raise3D/klipper-master/config/printer_raise3d_pro3.cfg \
  -l /opt/Raise3D/logs/system/klippy.log \
  </dev/null >>/opt/Raise3D/logs/system/klippy.log 2>&1 &
```

Confirm the socket now exists and Klipper is ready:

```sh
ls -l /opt/moonraker/printer_data/comms/klippy.sock
sleep 12
grep -i ready /opt/Raise3D/logs/system/klippy.log | tail -1
```

Moonraker's `/printer/info` should then return `"state":"ready"`.
