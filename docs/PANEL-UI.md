# Panel UI (`panel/moonui.py`)

A small native touch UI for the printer's screen, shown as a normal X client **on top of**
the stock `MXCUI`. Pressing **Exit** closes it and returns to the Raise3D UI. It talks to
Moonraker on `http://127.0.0.1:7125`.

## Controls

- **Move** — position readout + `homed`; step size (0.1 / 1 / 10 / 50 mm); jog
  X−/X+/Y−/Y+/Z−/Z+; Home X / Y / Z / All; Motors Off.
- **Heat** — tool T0/T1 selector; nozzle target with −5/+5/−1/+1 and presets
  (Off / PLA 200 / PETG 230 / ABS 240); heat bed target with −5/+5/−1/+1 and presets
  (Off / PLA 60 / PETG 80 / ABS 100).
- **Print** — job state, filename, progress, elapsed/left, Pause/Resume/Cancel, and a
  scrollable G-code list with **Start selected** / **Reload files**.

All actions issue G-code through Moonraker (`SET_HEATER_TEMPERATURE`, `G28`, relative
`G1` jogs, `PAUSE`/`RESUME`/`CANCEL_PRINT`, `SDCARD_PRINT_FILE`).

## Portrait + rotation model (why it looks right)

The physical panel is mounted **portrait**, but X is configured **landscape**
(`1024×600`). The stock `MXCUI` therefore draws its content *rotated 90°* inside the
framebuffer. This UI does the same:

- It draws in a logical **600×1024 portrait** space.
- It is rotated **90° CCW** into the framebuffer: `fb = logical.rotate(90, expand=True)`.
- Touch coordinates are inverse-mapped:
  `logical = (599 - fb_y, fb_x)`.

Do **not** rotate the X session (`xrandr`/matchbox); that would break the stock UI.

## Running

```sh
/opt/moonraker/start-ui.sh     # show on the panel
/opt/moonraker/stop-ui.sh      # hide (back to MXCUI)
```

`start-ui.sh` sets `LD_LIBRARY_PATH=/usr/local/freetype/lib:/usr/local/lib` (for the FreeType
built in [docs/INSTALL.md §4](INSTALL.md)) and runs `.../venv/bin/moonui`, giving it a process
name MXC won't kill.

## Previews without touching the printer

```sh
/opt/moonraker/render-ui.sh [outdir]
```

renders each tab headlessly to an **upright** 600×1024 PNG (using `--mock` demo data) that
shows exactly what appears on the panel:

```sh
# equivalently, directly:
LD_LIBRARY_PATH=/usr/local/freetype/lib:/usr/local/lib \
  /opt/moonraker/venv/bin/python /opt/moonraker/moonui.py \
  --render out.png --tab heat --mock
```

`--mock` uses demo values; drop it to render live data (needs Moonraker running).

## Dependencies

- Qt is **not** required; this is pure Python + Tk (display) + Pillow (drawing).
- Pillow's text rendering needs **FreeType ≥ 2.9** (the distro ships 2.6.3), hence the
  locally built FreeType in `/usr/local/freetype` and the `LD_LIBRARY_PATH` in the launcher.
- Fonts: Liberation Sans (present at `/usr/share/fonts/ttf/`).

## Known caveats

- Single-touch only (TSC2007).
- It is a separate window; while visible it covers `MXCUI` (nothing is modified, closing it
  restores the stock UI).
- Rapid jog taps can queue G-code; Klipper executes them in order.
