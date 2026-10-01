# Troubleshooting / gotchas

These are the non-obvious issues encountered on this hardware; they're likely to bite on
similar vendor images too.

## MXC kills `python` processes at boot

`MXCUI` runs `pidof python` to find Klipper and will kill/replace any process named
`python`. If Moonraker/your UI runs as `python`, it gets killed seconds after boot (its log
shows `Exiting with signal SIGTERM`).

**Fix:** run long-lived Python services under a different process name:

- Moonraker: `.../venv/bin/moonraker` (symlink to the venv `python`).
- Panel UI: `.../venv/bin/moonui`.
- `python3.11` is *not* matched by `pidof python`, which is why the web UI survived.

Log evidence (`/opt/Raise3D/logs/system/mxcui.log`):

```
[MainWindow] check python server pid  906     <- this was Moonraker
[MainWindow] run klipper server. 0
```

## A Klipper soft `RESTART` doesn't apply source patches

`RESTART` recreates the `Printer` object but the `klippy.py` module is already imported, so a
patch to `klippy.py` only takes effect after a **full process restart** of Klipper. (Config
changes *are* picked up by `RESTART`, since the config file is re-read.)

## `curl` TLS fails on the device

The distro's CA bundle is stale; `curl` reports
`server certificate verification failed`. Use `curl -k` (and verify hashes where you can).
Moonraker's outbound HTTPS can also fail (`SSL: CERTIFICATE_VERIFY_FAILED`); set
`SSL_CERT_FILE` to a current bundle (e.g. the `certifi` one in the venv) — the init script
does this.

## Moonraker logs `ip -json` errors

The `machine` component shells out to `ip -json -det address`, but the distro's `ip` predates
`-json`. It only clutters the log (no functional impact). Set the service provider to disable
service actions entirely:

```ini
[machine]
provider: none
```

## Moonraker `[printer]` / `klippy_uds_address`

In current Moonraker, `klippy_uds_address` lives in **`[server]`**, not `[printer]`. A stray
`[printer]` section makes Moonraker try to load a non-existent `printer` component
(`ModuleNotFoundError: No module named 'moonraker.components.printer'`) and Klipper never
connects.

## Can't edit the Klipper config in the web UI (reserved path)

Moonraker reserves the **Klipper source tree** (`klipper_path` from Klipper, here
`/opt/Raise3D/klipper-master`) for writes, and `check_reserved_path()` **resolves symlinks**
before comparing. The vendor keeps the Klipper config *inside* that tree
(`.../klipper-master/config/printer_raise3d_pro3.cfg`), so:

- Making Moonraker's config root a **symlink** to it fails: the path resolves back into the
  reserved tree and the write returns `403 ... forbidden by reserved path 'klipper'`.
- Moving the file out and symlinking the vendor path is unsafe: Klipper's `SAVE_CONFIG` uses
  `os.rename()`, which replaces the symlink with a regular file.

**Fix (what this project does):** a **bind mount** so the same directory appears at
Moonraker's config root, outside the reserved tree:

```sh
mkdir -p /opt/moonraker/printer_data/config
mount --bind /opt/Raise3D/klipper-master/config /opt/moonraker/printer_data/config
```

`init/moonraker` (re)creates the mount at boot; `check_klipper_config_path` is `False`
because the reported Klipper path differs from the mount path. Result: the web UI's editor
can edit `printer_raise3d_pro3.cfg`, and writes land in the real file.

## Build fails: `arm-linux-gnueabihf-gcc` not found

The standalone CPython's `sysconfig` records a cross-compiler name. When pip builds an sdist
that uses it, force the system compiler:

```sh
export CC=gcc CXX=g++ LDSHARED="gcc -shared"
```

## Pillow text fails: `undefined symbol: FT_Done_MM_Var`

Pillow 12 needs FreeType ≥ 2.9; the device has 2.6.3. Build FreeType 2.13 into `/usr/local`
and run with `LD_LIBRARY_PATH=/usr/local/lib` (see INSTALL §4). Don't run `ldconfig` against
it if you want to leave the system/Xorg FreeType untouched.

## mss (screenshots) crashes on this X

`mss` 9+/10 uses XCB and hits `undefined symbol: xcb_randr_monitor_info_next` on the old
libxcb. Use `mss==8.0.3` (plain Xlib/XShm).

## Camera 401 / auth token changes each boot

`MXCCameraServer` uses HTTP Basic with a per-boot password. Don't hardcode it — read it from
the process command line (as `webui/webui.py` does).

## `start-stop-daemon` / backgrounding under `sh`

When writing init/helper scripts, note that `VAR=val cmd &` in `sh` can run `cmd` in a
subshell (so `$!` isn't the daemon) and that matching process text with an unanchored glob
can match your own script. Anchor match patterns to the executable path (e.g.
`/opt/moonraker/venv/bin/*...`).

## glibc floor

Prebuilt armv7 binaries must target glibc ≤ 2.23 (this system). The
`python-build-standalone` armv7 builds target 2.17, which is why they work.
