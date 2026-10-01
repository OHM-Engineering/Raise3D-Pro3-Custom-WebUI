# Installation guide

This mirrors exactly what was deployed on a **Raise3D Pro3 HyperSpeed**
(i.MX6 Quad, armv7 hard-float, glibc 2.23, Yocto, 1 GB RAM, no systemd).

> Conventions used below
> - All commands run on the printer as `root` over SSH unless noted.
> - Paths follow the layout used in this repo (`/opt/moonraker/...`).
> - `curl` on this old distro fails TLS verification (stale CA store) — every download
>   below uses `curl -k`. Integrity is checked where practical.
>
> **Nothing here rotates the X session or replaces the stock UI.** Klipper is only
> patched to also open its API socket, and the stock `MXCUI` keeps running.

> **Disclaimer — use at your own risk.** This installs software that can move the printer's
> axes and control its heaters. A misconfiguration or fault can **damage the printer**, the
> build surface, or the hotend, and 3D printing carries fire risk. Provided **without
> warranty** (see [LICENSE](../LICENSE)); you are responsible for your machine.

---

## 0. Before you start

### Enable SSH on the printer

SSH is **disabled by default** and is turned on from the printer's touchscreen. Menu labels
vary slightly by firmware version; the path on current RaiseTouch is:

1. On the touchscreen open **Settings** (gear) → **Machine** → **More Settings** →
   **Privacy and Security**.
   - Some firmware exposes it directly under **Settings → Network** (look for **SSH**,
     **SSH Settings**).
2. If prompted, enter the **Security Password** (Secure Password). The first time you enable
   SSH you'll be asked to set one (a random value is suggested — set your own and remember
   it). If SSH was enabled before, the security password defaults to the SSH password.
3. Under **SSH Settings**, enable the **SSH server** and set an **SSH password**. That
   password is what you log in with; the SSH user is **`root`**.
4. Note the printer's **IP address** (shown on the **Network** page).

Security: change the SSH password from whatever default you set, since it also guards SSH
access. The printer stores it (encrypted) in `/opt/Raise3D/config/printer.cfg`. Enabling the
SSH server is also what permits the optional Raise3D Remote Access API.

Official reference: <https://support.raise3d.com/RaiseTouch/6-1-4-2-ssh-settings-17-863.html>

### Confirm access

```sh
ssh root@<printer-ip>
uname -a                 # Linux ... armv7l
ldd --version | head -1  # glibc 2.23
```

Make backups of everything you touch:

```sh
KP=/opt/Raise3D/klipper-master
cp -a $KP/klippy/klippy.py $KP/klippy/klippy.py.orig-moonraker
cp -a $KP/config/printer_raise3d_pro3.cfg $KP/config/printer_raise3d_pro3.cfg.orig-moonraker
```

Free some space if needed (the rootfs is ~15 GB):

```sh
df -h /
```

---

## 1. Install a modern Python (3.11)

The stock device only has Python 2.7 and a very old 3.5. Moonraker needs ≥ 3.7
(currently effectively ≥ 3.10). We use a prebuilt standalone CPython for
**armv7 hard-float** from `python-build-standalone`, which bundles its own
OpenSSL and needs only **glibc ≥ 2.17** (the device has 2.23).

Find the latest release asset named like
`cpython-3.11.*-armv7-unknown-linux-gnueabihf-install_only_stripped.tar.gz` at
<https://github.com/astral-sh/python-build-standalone/releases>. The version used here:

```sh
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260929/cpython-3.11.16+20260929-armv7-unknown-linux-gnueabihf-install_only_stripped.tar.gz"
mkdir -p /opt/moonraker
curl -k -L -f --retry 3 -o /tmp/py311.tar.gz "$PY_URL"

# optional: verify against the release's SHA256SUMS
sha256sum /tmp/py311.tar.gz

# replace any previous runtime and extract (archive contains a top-level "python/" dir)
rm -rf /opt/moonraker/python
tar -xzf /tmp/py311.tar.gz -C /opt/moonraker

/opt/moonraker/python/bin/python3.11 -V
/opt/moonraker/python/bin/python3.11 -c "import ssl,sqlite3,ctypes; print(ssl.OPENSSL_VERSION)"
```

> The resulting interpreter is relocatable and includes `pip`. Do **not** set `PYTHONHOME`.

---

## 2. libsodium (needed by Moonraker's `libnacl`)

Moonraker's `authorization` component imports `libnacl`, which needs the `libsodium`
shared library:

```sh
cd /tmp
curl -k -L -f --retry 3 -o libsodium.tar.gz \
  https://github.com/jedisct1/libsodium/releases/download/1.0.18-RELEASE/libsodium-1.0.18.tar.gz
tar -xzf libsodium.tar.gz && cd libsodium-1.0.18
./configure --prefix=/usr/local && make -j4 && make install

# make it findable at runtime
mkdir -p /etc/ld.so.conf.d
echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local.conf
[ -f /etc/ld.so.conf ] || echo "include /etc/ld.so.conf.d/*.conf" > /etc/ld.so.conf
ldconfig
ldconfig -p | grep -i sodium
```

---

## 3. Moonraker venv + dependencies

```sh
/opt/moonraker/python/bin/python3.11 -m venv /opt/moonraker/venv
/opt/moonraker/venv/bin/python -m pip install --upgrade pip setuptools wheel

# Pure-Python deps install as wheels; a few need building (see note below).
/opt/moonraker/venv/bin/python -m pip install \
  pyserial==3.4 distro==1.9.0 jinja2==3.1.6 paho-mqtt==2.1.0 "apprise<=1.13.0" \
  ldap3==2.9.1 python-periphery==2.4.1 "importlib_metadata<=9.0.0" \
  preprocess-cancellation==0.2.1 inotify-simple==2.0.1 libnacl==2.1.0 \
  "tornado>=6.2.0,<=6.5.8" "pillow>=9.5.0,<=12.3.0" \
  "streaming-form-data>=1.11.0,<=2.1.0" "dbus-fast>=2.21.3,<=5.0.22" \
  "zeroconf>=0.131.0,<=0.150.0"
```

Notes:
- Some packages build from source on the device (tornado, pillow, streaming-form-data,
  dbus-fast, markupsafe, pyyaml). The vendor's `gcc 5.3` works.
- If a build fails with `No such file or directory: arm-linux-gnueabihf-gcc`, force the
  system compiler (the standalone CPython's `sysconfig` points at a cross name):
  ```sh
  export CC=gcc CXX=g++ LDSHARED="gcc -shared"
  ```
- `libnacl` must import cleanly:
  ```sh
  /opt/moonraker/venv/bin/python -c "from libnacl.sign import Signer; Signer(); print('libnacl OK')"
  ```

---

## 4. FreeType 2.13 + mss (for the on-panel UI)

The panel UI draws text with Pillow. Pillow's FreeType extension needs symbols that the
distro's ancient FreeType 2.6.3 lacks. Build a newer FreeType into a **separate prefix**
(`/usr/local/freetype`) and run the UI with `LD_LIBRARY_PATH`, so the **system's** FreeType
(used by Xorg) is left alone. See [docs/PANEL-UI.md](PANEL-UI.md). Skip this section if you
don't want the panel UI.

```sh
cd /tmp
curl -k -L -f --retry 3 -o ft.tar.gz \
  https://github.com/freetype/freetype/releases/download/VER-2-13-2/freetype-2.13.2.tar.gz
tar -xzf ft.tar.gz && cd freetype-2.13.2
./configure --prefix=/usr/local/freetype --without-harfbuzz --without-brotli \
            --without-png --without-bzip2
make -j4 && make install

LD_LIBRARY_PATH=/usr/local/freetype/lib:/usr/local/lib /opt/moonraker/venv/bin/python -c \
  "from PIL import ImageFont; ImageFont.truetype('/usr/share/fonts/ttf/LiberationSans-Bold.ttf',30); print('font OK')"
```

For headless screenshots (`render-ui.sh`) install `mss` 8.x (10.x uses XCB APIs this old
libxcb lacks):

```sh
/opt/moonraker/venv/bin/python -m pip install "mss==8.0.3"
/opt/moonraker/python/bin/python3.11 -m pip install "mss==8.0.3"
```

---

## 5. Enable Klipper's API socket (additive patch)

The stock `MXCUI` launches Klipper **without** `-a`, so its webhooks API socket is never
created — and Moonraker needs it. Rather than touch the (binary) `MXCUI`, give Klipper's
`--api-server` option a default value in `klippy.py`.

See **[klipper/enable-webhooks-socket.md](../klipper/enable-webhooks-socket.md)** for the
exact diff. Apply it, then verify Python 2 syntax:

```sh
python2 -c "compile(open('/opt/Raise3D/klipper-master/klippy/klippy.py').read(),'klippy.py','exec'); print('ok')"
```

Add the required Klipper config bits (see
**[klipper/config-additions.md](../klipper/config-additions.md)**): `[display_status]` and a
`CANCEL_PRINT` macro that renames the built-in.

A full Klipper restart is needed for the patch to take effect — restart it the same way
`MXCUI` does, or simply reboot:

```sh
# clean restart that matches MXCUI's invocation:
pkill -f 'klippy/klippy.py'
sleep 2
cd /opt/Raise3D/klipper-master
setsid python klippy/klippy.py \
  /opt/Raise3D/klipper-master/config/printer_raise3d_pro3.cfg \
  -l /opt/Raise3D/logs/system/klippy.log </dev/null >>/opt/Raise3D/logs/system/klippy.log 2>&1 &
# wait, then confirm the socket appears:
ls -l /opt/moonraker/printer_data/comms/klippy.sock
```

> `MXCUI` does **not** restart Klipper for you; starting it yourself (as above) is fine and
> `MXCUI` keeps working over `/tmp/printer`.

---

## 6. Moonraker (source + config)

`git` is not installed, so fetch a tarball:

```sh
cd /opt/moonraker
curl -k -L -f --retry 3 -o moonraker.tar.gz \
  https://github.com/Arksine/moonraker/archive/refs/heads/master.tar.gz
tar -xzf moonraker.tar.gz
rm -rf moonraker && mv moonraker-master moonraker

mkdir -p /opt/moonraker/printer_data/{config,logs,comms,database}
ln -sfn /home/root /opt/moonraker/printer_data/gcodes   # same dir Klipper's virtual_sdcard uses

# Expose the vendor Klipper config dir as Moonraker's config root (see below):
mkdir -p /opt/moonraker/printer_data/config
mount --bind /opt/Raise3D/klipper-master/config /opt/moonraker/printer_data/config

# Moonraker's own config lives one level up, outside the mounted config root:
cp ../config/moonraker.conf.sample /opt/moonraker/printer_data/moonraker.conf
```

Edit `moonraker.conf` and set `trusted_clients`/`cors_domains` for your LAN (see the sample).
Moonraker is now started with `-c /opt/moonraker/printer_data/moonraker.conf` (the provided
init script does this). A first manual start:

```sh
/opt/moonraker/venv/bin/moonraker \
  /opt/moonraker/moonraker/moonraker/moonraker.py \
  -d /opt/moonraker/printer_data -c /opt/moonraker/printer_data/moonraker.conf &
```

Confirm via the API:

```sh
curl -s http://127.0.0.1:7125/server/info
curl -s http://127.0.0.1:7125/printer/info
```

### Editing the printer config (web UI)

The vendor keeps the Klipper config **inside the Klipper source tree**
(`/opt/Raise3D/klipper-master/config/`), which Moonraker treats as a **reserved path** and
refuses to write to (and it resolves symlinks, so a symlink there doesn't help). The bind
mount above makes the same directory appear at `/opt/moonraker/printer_data/config` —
outside the reserved tree — so the web UI's built-in editor can edit
`printer_raise3d_pro3.cfg` (and the other files in that folder), while Klipper and the stock
UI keep using the original path. The provided `init/moonraker` recreates the mount at boot;
`check_klipper_config_path` is set to `False` because the reported path differs from the
mount path.

To apply changes: edit in the web UI → **Save** → **Restart Klipper** (or issue `RESTART`).

---

## 7. Web UI (Fluidd or Mainsail) + camera proxy on port 80

`webui/webui.py` serves the static build of **either frontend** and proxies the stock
camera. Pick one — **Fluidd** (default) or **Mainsail**:

```sh
mkdir -p /opt/moonraker/www
cd /tmp

# --- Fluidd ---
curl -k -L -f --retry 3 -o fluidd.zip \
  https://github.com/fluidd-core/fluidd/releases/latest/download/fluidd.zip
rm -rf /opt/moonraker/www/fluidd && mkdir -p /opt/moonraker/www/fluidd
/opt/moonraker/python/bin/python3.11 -c \
  "import zipfile; zipfile.ZipFile('/tmp/fluidd.zip').extractall('/opt/moonraker/www/fluidd')"

# --- or Mainsail ---
# curl -k -L -f --retry 3 -o mainsail.zip \
#   https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip
# rm -rf /opt/moonraker/www/mainsail && mkdir -p /opt/moonraker/www/mainsail
# /opt/moonraker/python/bin/python3.11 -c \
#   "import zipfile; zipfile.ZipFile('/tmp/mainsail.zip').extractall('/opt/moonraker/www/mainsail')"

# copy the server from this repo
cp webui/webui.py /opt/moonraker/webui.py

# point it at the frontend you installed (defaults to Fluidd)
R3D_WEBROOT=/opt/moonraker/www/fluidd \
  /opt/moonraker/python/bin/python3.11 /opt/moonraker/webui.py 80 &
# ...or /opt/moonraker/www/mainsail for Mainsail.

curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/          # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/camera/snapshot
```

See [docs/CAMERA.md](CAMERA.md) for how the proxy works.

---

## 8. Autostart (SysV init, no systemd)

Copy the init scripts and wire the runlevels. `init/webui` is a template: substitute
`@WEBUI@` with the frontend you installed (`fluidd` or `mainsail`). Fluidd below — for
Mainsail just replace `fluidd` with `mainsail` throughout:

```sh
cp init/moonraker /etc/init.d/moonraker
sed 's#@WEBUI@#fluidd#g' init/webui > /etc/init.d/fluidd
chmod +x /etc/init.d/moonraker /etc/init.d/fluidd
for rl in 2 3 4 5; do
  ln -sf ../init.d/moonraker /etc/rc$rl.d/S99moonraker
  ln -sf ../init.d/fluidd    /etc/rc$rl.d/S99fluidd
done
for rl in 0 1 6; do
  ln -sf ../init.d/moonraker /etc/rc$rl.d/K01moonraker
  ln -sf ../init.d/fluidd    /etc/rc$rl.d/K01fluidd
done
```

Manage with `service moonraker start|stop|restart|status` (or `/etc/init.d/...`).

> **Important:** run Moonraker under the process name `moonraker`, not `python`. At boot
> `MXCUI` runs `pidof python` to locate Klipper and will kill/replace any `python` process —
> taking Moonraker down with it. The init script uses the venv launcher
> `.../venv/bin/moonraker` (a symlink to `python`) to avoid this. See
> [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 9. On-panel touch UI (optional)

```sh
cp panel/moonui.py /opt/moonraker/moonui.py
ln -sf python /opt/moonraker/venv/bin/moonui       # safe process name
cp panel/start-ui.sh panel/stop-ui.sh panel/render-ui.sh /opt/moonraker/
chmod +x /opt/moonraker/start-ui.sh /opt/moonraker/stop-ui.sh /opt/moonraker/render-ui.sh

/opt/moonraker/render-ui.sh          # generate previews (no screen interaction)
/opt/moonraker/start-ui.sh           # show it on the panel (Exit returns to MXCUI)
```

See [docs/PANEL-UI.md](PANEL-UI.md) for the rotation model and controls.

---

## 10. Reboot & verify

```sh
reboot
# after it comes back:
curl -s http://127.0.0.1:7125/server/info     # klippy_connected: true
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/   # 200
```

Then open the web UI from your PC: `http://<printer-ip>/`.

---

## Rollback

- Klipper: restore `klippy.py.orig-moonraker` and
  `printer_raise3d_pro3.cfg.orig-moonraker`, then restart Klipper.
- Disable autostart: remove the `/etc/rc*.d/S99moonraker` and `/etc/rc*.d/S99fluidd`
  (or `S99mainsail`) symlinks (and the `K01*` ones).
- Full removal: delete `/opt/moonraker`, `/usr/local/lib/libsodium*`,
  `/usr/local/lib/libfreetype*`, and the init scripts.
