# Raise3D Pro3 — Klipper/Moonraker web UI + on‑panel touch UI

Add a modern web interface (**Fluidd**) and a **custom touch UI** to a **Raise3D Pro3 /
Pro3 HyperSpeed** — *without* giving up the stock Raise3D software.

Everything here is **additive**:

- The stock `MXCUI` touchscreen keeps working (Klipper is untouched apart from enabling its
  API socket, and the X session / display rotation is **not** changed).
- The camera keeps streaming to the stock UI/cloud, and is **also** shown in Fluidd via a
  small local proxy.
- Moonraker and the web UI run alongside `MXC*` and auto‑start on boot.

> Target device: Raise3D Pro3 / Pro3 HyperSpeed — **Freescale i.MX6 Quad, armv7 hard-float,
> glibc 2.23**, Yocto "i.MX Release Distro", 1 GB RAM, **no systemd, no package manager**.

---

## What you get

| Component | Description |
|---|---|
| **Moonraker** | Klipper API server on `:7125`, installed from source into a modern Python 3.11 venv. |
| **Fluidd** | Web UI on `:80`, served together with a camera proxy by `webui/webui.py`. |
| **Config editing** | Edit the Klipper config (`printer_raise3d_pro3.cfg`) and `moonraker.conf` in Fluidd's built‑in code editor (safe bind‑mount setup; see docs). |
| **Camera proxy** | Re‑streams the stock `MXCCameraServer` MJPEG without disturbing it. |
| **Panel UI** | `panel/moonui.py` — a native touch UI that renders on the printer's portrait screen (Move / Heat / Print). |
| **Init scripts** | SysV init services for Moonraker and the web UI, wired into `rc5.d`. |

The **on‑panel UI** (controls: jog, homing, nozzle/bed heat, print job) renders in a
600×1024 portrait space and is rotated into the 1024×600 framebuffer to match the stock UI.

> No binaries are included in this repository. The Python runtime, FreeType, libsodium, etc.
> are downloaded/built on the device — see **[docs/INSTALL.md](docs/INSTALL.md)**.

To generate UI previews (as PNGs, upright) without touching the printer screen:

```sh
/opt/moonraker/render-ui.sh            # -> /opt/moonraker/ui-preview/ui_{move,heat,print}.png
```

---

## Requirements

- Raise3D Pro3 / Pro3 HyperSpeed with **root SSH access** enabled — see
  [Enable SSH on the printer](docs/INSTALL.md#enable-ssh-on-the-printer)
  (touchscreen: Settings → Machine → More Settings → Privacy and Security → SSH Settings).
- Basic Linux/SSH familiarity. Internet access on the printer (for downloads).
- `git` is **not** required on the printer (Moonraker is fetched as a tarball).

---

## Quick start

### 1. Enable SSH on the printer

SSH is **disabled by default** — turn it on from the printer's touchscreen (menu labels vary
a little by firmware):

1. Open **Settings** (gear) → **Machine** → **More Settings** → **Privacy and Security**
   (on some firmware it's under **Settings → Network** — look for **SSH** / **SSH Settings**).
2. If prompted, enter the **Security Password**. The first time you enable SSH you'll be
   asked to set one (a random value is suggested — set your own and remember it). If SSH was
   already enabled before, the security password defaults to the SSH password.
3. Under **SSH Settings**, enable the **SSH server** and set an **SSH password**. That's what
   you log in with; the user is **`root`**.
4. Note the printer's **IP address** (shown on the **Network** page).

Then connect from your computer:

```sh
ssh root@<printer-ip>
```

(Details: [Enable SSH on the printer](docs/INSTALL.md#enable-ssh-on-the-printer).)

### 2. Install

On the printer, as root, a single command:

```sh
curl -fsSL https://raw.githubusercontent.com/OHM-Engineering/Raise3D-Pro3-Custom-WebUI/main/install.sh | sh
```

(or `git clone` / `scp` the repo and run `./install.sh`). It's **self-contained** — it
downloads and builds everything on the device and starts the services. Pass flags with
`sh -s --`, e.g. `... | sh -s -- --no-panel`. Options:

```
--no-panel          skip the on-panel touch UI
--no-webui          skip Moonraker + Fluidd
--subnet X.X.X.0/24 trusted LAN subnet for Moonraker auth (auto-detected, /24)
--restart-klipper   restart Klipper now to activate the API socket
-y, --yes           no prompts
```

Then open:
- Web UI: `http://<printer-ip>/`
- Moonraker API: `http://<printer-ip>:7125/`

The on-panel touch UI (optional) is shown with `/opt/moonraker/start-ui.sh`
(its **Exit** button returns to the stock Raise3D UI).

A reboot (or `--restart-klipper`) is needed once so Klipper re-opens its API socket;
until then Moonraker reports "disconnected". [docs/INSTALL.md](docs/INSTALL.md) has the
same steps explained manually.

---

## Repository layout

```
install.sh        Self-contained one-shot installer (generated — see tools/)
tools/            install.sh.in template + build-installer.py (embeds the files)
panel/            On-screen touch UI (Python + Pillow) and helper scripts
webui/            Port‑80 server: Fluidd static files + camera MJPEG/JPEG proxy
init/             SysV init scripts (moonraker, fluidd)
config/           Sample Moonraker configuration
klipper/          Klipper changes: enable API socket, add display_status / CANCEL_PRINT
docs/             Install guide, panel UI notes, camera notes, troubleshooting
scripts/          deploy.sh helper (copies files to a printer over SSH)
```

`install.sh` is generated from `tools/install.sh.in` plus the files above. After editing
any of them, regenerate with `python3 tools/build-installer.py`.

---

## How it fits together

```
                    +------------------ printer (i.MX6, 1024x600 portrait) ------------------+
  Fluidd (browser)  |  webui.py :80  ---- static Fluidd + /camera/* proxy --> MXCCameraServer  |
  -------:7125----->|  Moonraker :7125 --UDS--> Klipper (webhooks API socket)                 |
  touchscreen       |  MXCUI (stock)  <--pty console--  Klipper                                 |
  custom panel UI   |  moonui.py (X client on :0, rotated 90 deg)                              |
                    +--------------------------------------------------------------------------+
```

- Klipper's **webhooks API socket** is enabled by a tiny patch so Moonraker and the stock UI
  can coexist (the stock UI talks over a pty console; the API socket is separate/additive).
- Moonraker and the panel UI run with **process names that MXC does not kill** at boot
  (`moonraker`, `moonui`) — this is important, see troubleshooting.

See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for details.

---

## Notes & limitations

- Tested on a Pro3 HyperSpeed running the vendor firmware; your mileage may vary with other
  firmware revisions. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the known
  gotchas (process‑name kills, CA bundle, `ip -json`, camera token rotation, FreeType).
- The camera stream is the stock 1280×720 MJPEG and is fairly bandwidth‑heavy; tune it in the
  printer's Camera settings if needed.
- Config is edited over SSH (Moonraker's in‑UI config editor does not manage the vendor's
  Klipper config path).

---

## Disclaimer

**Use at your own risk.** This project installs software on your printer that can command
the motion system and the heaters. A misconfiguration or a software fault can **damage the
printer**, the build surface, or the hotend, and 3D printing carries a fire risk. This
software is provided **without warranty** of any kind (see [LICENSE](LICENSE)); you are
solely responsible for your machine and its safe operation. Editing the configuration can
make the printer behave unexpectedly — always review changes before running a job.

## License

MIT for the original code in this repository. The Klipper and Moonraker projects are
GPL‑3.0; see [NOTICE](NOTICE). Nothing GPL is vendored here — installers fetch those
projects directly.
