# Klipper config additions

Applied to `/opt/Raise3D/klipper-master/config/printer_raise3d_pro3.cfg`
(back it up first).

## `[display_status]`

Moonraker (and the web UI/panel UI) uses `display_status` for print progress. Add the bare
section if it isn't already present:

```ini
[display_status]
```

(`[virtual_sdcard]` and `[pause_resume]` are already present on this printer.)

## `CANCEL_PRINT` macro

The web UI (Fluidd/Mainsail) warns that it can't find a `CANCEL_PRINT` macro. This vendor Klipper already provides
`CANCEL_PRINT` as a **built-in command** (from `[pause_resume]`), but frontends expect a
`[gcode_macro CANCEL_PRINT]`. Define one that simply renames and calls the built-in, so
behaviour is unchanged:

```ini
[gcode_macro CANCEL_PRINT]
description = Cancel the current print
rename_existing = _CANCEL_PRINT
gcode =
	_CANCEL_PRINT
```

> Use a tab or spaces to indent the `gcode` block body as required by this Klipper version.
> `rename_existing` moves the built-in to `_CANCEL_PRINT`; the macro then calls it. Order
> matters, so append this section at the **end** of the file (after `[pause_resume]`).

## Apply

Append the sections if missing, e.g.:

```sh
CFG=/opt/Raise3D/klipper-master/config/printer_raise3d_pro3.cfg
cp -a "$CFG" "$CFG.orig-moonraker"

grep -q '^\[display_status\]' "$CFG" || printf '\n[display_status]\n' >> "$CFG"

cat >> "$CFG" <<'EOF'

[gcode_macro CANCEL_PRINT]
description = Cancel the current print
rename_existing = _CANCEL_PRINT
gcode =
	_CANCEL_PRINT
EOF
```

Config changes are picked up by a plain `RESTART` (Klipper re-reads the config file), so a
soft restart via Moonraker is enough:

```sh
curl -s -X POST "http://127.0.0.1:7125/printer/gcode/script?script=RESTART" >/dev/null
```

Then check the web UI's warnings are gone and `CANCEL_PRINT` resolves:

```sh
curl -s "http://127.0.0.1:7125/printer/gcode/help" | tr ',' '\n' | grep -i cancel
```
