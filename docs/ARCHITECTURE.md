# Architecture

```
                          Raise3D Pro3 (i.MX6, 1024x600 panel, portrait)
 ┌────────────────────────────────────────────────────────────────────────────┐
 │  X server :0 (Xorg + matchbox)                                              │
 │    ├── MXCUI            stock Raise3D touch UI (Qt), fullscreen             │
 │    └── moonui.py        optional custom panel UI (separate X client)        │
 │                                                                             │
 │  Klipper (python2, vendor fork)                                             │
 │    ├── pty console /tmp/printer ... <── MXCUI drives it (text G-code)        │
 │    └── webhooks UDS comms/klippy.sock <── Moonraker (JSON-RPC API)          │
 │                                                                             │
 │  Moonraker :7125  (python3.11 venv) ──JSON-RPC──> klippy.sock               │
 │  webui.py  :80    Fluidd/Mainsail + /camera/* proxy ─> MXCCameraServer :30216│
 │  MXCCameraServer :30216  (owns /dev/video1)                                 │
 └────────────────────────────────────────────────────────────────────────────┘
```

## Why Klipper needs a small patch

On the vendor image, `MXCUI` starts Klipper like this (no `-a`):

```
python .../klippy/klippy.py .../printer_raise3d_pro3.cfg -l .../klippy.log &
```

so Klipper's **webhooks API socket is never created**. `MXCUI` talks to Klipper over a
**pty console** (`/tmp/printer -> /dev/pts/N`, created by `klippy.py` via
`util.create_pty()`). The API socket is a **separate, additive** interface, so enabling it
does not disturb the stock UI.

Two consequences worth knowing:

1. The patch must give `--api-server` a **default** value, because we cannot change the
   command line the vendor binary uses.
2. A Klipper **soft `RESTART`** (the `RESTART` G-code) re-creates the `Printer` object but
   does **not** re-read `klippy.py`, so a source patch only takes effect after a **full
   process restart**. See `klipper/enable-webhooks-socket.md`.

## Process naming (important)

At boot `MXCUI` calls `pidof python` to find Klipper and will kill/replace **any** process
named `python`. Therefore:

- Moonraker runs via `.../venv/bin/moonraker` (a symlink to the venv `python`), so its
  process name is `moonraker`.
- The panel UI runs via `.../venv/bin/moonui`.
- The web UI runs as `python3.11` (which is *not* matched by `pidof python`).

## Editing the Klipper config

Moonraker refuses writes under the Klipper source tree (`/opt/Raise3D/klipper-master`), where
the vendor keeps `printer_raise3d_pro3.cfg`. So `init/moonraker` **bind-mounts** the vendor
config dir onto Moonraker's config root (`/opt/moonraker/printer_data/config`): the same
files appear at two paths, the web UI can edit them, and Klipper keeps using the original
path (so `SAVE_CONFIG`/the stock UI are unaffected). See
[docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Components

| Path | Role |
|---|---|
| `webui/webui.py` | Port‑80 HTTP server: serves the Fluidd or Mainsail build (`R3D_WEBROOT`) and proxies the camera. |
| `panel/moonui.py` | Immediate-mode (Pillow) touch UI; draws 600×1024 portrait, rotated into the 1024×600 framebuffer; talks to Moonraker over HTTP. |
| `init/moonraker`, `init/webui` | SysV init services (auto-start on boot). `init/webui` is a template instantiated for `fluidd` or `mainsail`. |
| `config/moonraker.conf.sample` | Moonraker config tuned for this device. |

## Startup order

`rc5.d`: `S01xserver-nodm` (X + `MXCUI`, which starts Klipper) → `S99fluidd` (or
`S99mainsail`, port 80) → `S99moonraker`. Moonraker simply retries the Klipper socket until it appears, so exact
ordering is not critical.
