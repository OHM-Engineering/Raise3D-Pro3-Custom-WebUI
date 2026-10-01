#!/bin/sh
#
# Raise3D Pro3 / Pro3 HyperSpeed — one-shot installer
# ------------------------------------------------------------------
# Installs, alongside the stock Raise3D software (nothing here rotates the
# X session or replaces MXCUI):
#   * a modern Python 3.11 (portable armv7 build)
#   * Moonraker (from source) + Fluidd on :80, with a camera proxy
#   * an optional on-panel touch UI (rotated to match the portrait panel)
#   * SysV init services that auto-start on boot
#
# Self-contained: run it from anywhere, or pipe it, as root on the printer.
#     ./install.sh                     # everything
#     ./install.sh --no-panel          # web UI only
#     ./install.sh --no-webui          # panel UI only
#     ./install.sh --subnet 192.168.1.0/24
#
# One-liner (from the published repo):
#     curl -fsSL https://raw.githubusercontent.com/OHM-Engineering/Raise3D-Pro3-Custom-WebUI/main/install.sh | sh
#     curl -fsSL https://raw.githubusercontent.com/OHM-Engineering/Raise3D-Pro3-Custom-WebUI/main/install.sh | sh -s -- --no-panel
#
# It downloads/builds dependencies on the device. No binaries are shipped.
set -eu

# ------------------------------------------------------------------ config
PBS_TAG="${PBS_TAG:-20260929}"
PY_VERSION="${PY_VERSION:-3.11.16}"
PY_URL="${PY_URL:-https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PY_VERSION}+${PBS_TAG}-armv7-unknown-linux-gnueabihf-install_only_stripped.tar.gz}"
LIBSODIUM_URL="${LIBSODIUM_URL:-https://github.com/jedisct1/libsodium/releases/download/1.0.18-RELEASE/libsodium-1.0.18.tar.gz}"
FREETYPE_URL="${FREETYPE_URL:-https://github.com/freetype/freetype/releases/download/VER-2-13-2/freetype-2.13.2.tar.gz}"
MOONRAKER_URL="${MOONRAKER_URL:-https://github.com/Arksine/moonraker/archive/refs/heads/master.tar.gz}"
FLUIDD_URL="${FLUIDD_URL:-https://github.com/fluidd-core/fluidd/releases/latest/download/fluidd.zip}"

MR=/opt/moonraker
VENV="$MR/venv"
PY="$MR/python/bin/python3.11"
VENVPY="$VENV/bin/python"
KL_Dir=/opt/Raise3D/klipper-master
KLIPPY="$KL_Dir/klippy/klippy.py"
KCFG="$KL_Dir/config/printer_raise3d_pro3.cfg"
SOCK="$MR/printer_data/comms/klippy.sock"

DO_WEBUI=1
DO_PANEL=1
DO_RESTART_KLIPPER=0
SUBNET=""
ASSUME_YES=0

# --- embedded auxiliary files (written to a temp staging dir) ---
STAGE=$(mktemp -d /tmp/r3d-install.XXXXXX 2>/dev/null || echo /tmp/r3d-install.$$)
mkdir -p "$STAGE/panel" "$STAGE/webui" "$STAGE/init" "$STAGE/config"
trap 'rm -rf "$STAGE"' EXIT INT TERM
cat > "$STAGE/panel/moonui.py" <<'__EMBED_PANEL_MOONUI_PY__'
#!/usr/bin/env python3
"""Raise3D Pro3 panel UI (portrait, immediate-mode / Pillow).

Logical space is 600x1024 (portrait, as the physical panel). It is rotated
90 deg CCW into the 1024x600 X framebuffer (matching MXCUI). Touch coords are
mapped back. Can also render headlessly to a PNG for iteration off-printer.

Run on panel:   LD_LIBRARY_PATH=/usr/local/lib DISPLAY=:0 python moonui.py
Render to file: LD_LIBRARY_PATH=/usr/local/lib python moonui.py --render out.png [--mock]
"""
import argparse
import json
import threading
import time
import urllib.request

from PIL import Image, ImageDraw, ImageFont

MOONRAKER = "http://127.0.0.1:7125"
LW, LH = 600, 1024
ROT = 90  # logical -> framebuffer

BG = (16, 16, 20)
PANEL = (26, 26, 33)
PANEL2 = (37, 37, 49)
FG = (233, 233, 237)
MUTED = (150, 158, 170)
ACC = (33, 150, 243)
BTN = (45, 45, 58)
GOOD = (58, 208, 106)
WARN = (240, 160, 32)
BAD = (229, 72, 77)
HOMEBG = (46, 111, 78)

FBD = "/usr/share/fonts/ttf/LiberationSans-Bold.ttf"
FRG = "/usr/share/fonts/ttf/LiberationSans-Regular.ttf"
_FONTS = {}


def font(path, size):
    key = (path, size)
    if key not in _FONTS:
        _FONTS[key] = ImageFont.truetype(path, size)
    return _FONTS[key]


def http_get(path):
    req = urllib.request.Request(MOONRAKER + path,
                                 headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=4) as r:
        return json.loads(r.read().decode())


def send_gcode(script):
    data = json.dumps({"script": script}).encode()
    req = urllib.request.Request(MOONRAKER + "/printer/gcode/script",
                                 data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())


def fmt(v):
    try:
        return "%.0f" % float(v)
    except Exception:
        return "--"


def hhmm(secs):
    secs = int(max(0, secs))
    return "%d:%02d" % (secs // 3600, (secs % 3600) // 60)


class Ui:
    def __init__(self, tab="move", mock=False):
        self.tab = tab
        self.mock = mock
        self.online = False
        self.data = {}
        self.lock = threading.Lock()
        self.step = 10.0
        self.tool = "extruder"
        self.files = []
        self.file_sel = None
        self.file_scroll = 0
        self.msg = ""
        self.msg_t = 0
        self.confirm = None  # (question, script)
        self.hits = []
        self._photo = None
        self._last_draw = 0

    # ---------------- data ----------------
    def start_poller(self):
        threading.Thread(target=self._poll, daemon=True).start()

    def _poll(self):
        q = ("/printer/objects/query?extruder&extruder1&heater_bed&toolhead"
             "&print_stats&virtual_sdcard&gcode_move")
        while True:
            if self.mock:
                with self.lock:
                    self.data = self._mock()
                self.online = True
            else:
                try:
                    self.data = http_get(q)["result"]["status"]
                    self.online = True
                    if self.msg.startswith(("Connecting", "Moonraker offline")):
                        self.msg = "Connected"
                except Exception:
                    self.online = False
                    if not self.msg.startswith("ERROR"):
                        self.msg = "Moonraker offline"
            time.sleep(0.8)

    def _mock(self):
        return {
            "extruder": {"temperature": 219.4, "target": 220},
            "extruder1": {"temperature": 26.8, "target": 0},
            "heater_bed": {"temperature": 59.7, "target": 60},
            "toolhead": {"homed_axes": "xyz",
                         "position": [120.5, 98.2, 12.4, 0.0]},
            "print_stats": {"state": "printing", "filename": "benchy.gcode",
                            "print_duration": 742.0, "total_duration": 755.0},
            "virtual_sdcard": {"progress": 0.342, "is_active": True},
            "gcode_move": {"speed_factor": 1.0},
        }

    def load_files(self):
        if self.mock:
            self.files = ["benchy.gcode", "calibration_cube.gcode",
                          "bracket_v3.gcode", "phone_stand.gcode"]
            return
        try:
            data = http_get("/server/files/list?root=gcodes")
            self.files = sorted(f["path"] for f in data.get("result", [])
                                if f.get("path", "").lower().endswith(
                                    (".gcode", ".g", ".gco")))
        except Exception as exc:
            self.msg = "files: %s" % exc

    # ---------------- drawing helpers ----------------
    def panel(self, d, rect, radius=10, fill=PANEL):
        x, y, w, h = rect
        d.rounded_rectangle([x, y, x + w, y + h], radius=radius, fill=fill)

    def btn(self, d, rect, label, action, fill=BTN, fg=FG, size=20):
        x, y, w, h = rect
        d.rounded_rectangle([x, y, x + w, y + h], radius=10, fill=fill)
        d.text((x + w / 2, y + h / 2), label, font=font(FBD, size),
               fill=fg, anchor="mm")
        self.hits.append((x, y, w, h, action))

    # ---------------- draw ----------------
    def draw(self):
        img = Image.new("RGB", (LW, LH), BG)
        d = ImageDraw.Draw(img)
        self.hits = []
        self._header(d)
        if self.tab == "move":
            self._move(d)
        elif self.tab == "heat":
            self._heat(d)
        else:
            self._print(d)
        self._nav(d)
        self._status(d)
        if self.confirm:
            self._overlay(d)
        return img

    def _header(self, d):
        d.rectangle([0, 0, LW, 140], fill=PANEL)
        d.text((16, 14), "RAISE3D", font=font(FBD, 26), fill=ACC)
        st = "ready" if self.online else "offline"
        tw = d.textlength(st, font=font(FBD, 15))
        d.rounded_rectangle([152, 20, 152 + tw + 26, 52], radius=15, fill=PANEL2)
        d.text((152 + 13, 36), st, font=font(FBD, 15),
               fill=(GOOD if self.online else BAD), anchor="lm")
        self.btn(d, (LW - 118, 12, 102, 52), "Exit", ("exit",), size=20)
        chips = [("L noz", "extruder"), ("R noz", "extruder1"),
                 ("Bed", "heater_bed")]
        for i, (label, key) in enumerate(chips):
            cx = 8 + i * 196
            self.panel(d, (cx, 72, 188, 60), fill=PANEL2)
            d.text((cx + 12, 80), label, font=font(FRG, 15), fill=MUTED)
            o = self.data.get(key, {})
            d.text((cx + 12, 100), "%s/%s" % (fmt(o.get("temperature")),
                                              fmt(o.get("target"))),
                   font=font(FBD, 22), fill=FG)

    def _nav(self, d):
        y = 950
        d.rectangle([0, y, LW, LH], fill=PANEL)
        for i, (key, label) in enumerate([("move", "Move"), ("heat", "Heat"),
                                          ("print", "Print")]):
            x = 8 + i * 196
            active = self.tab == key
            self.btn(d, (x, y + 8, 188, 58), label, ("tab", key),
                     fill=(ACC if active else BTN),
                     fg=(255, 255, 255) if active else FG, size=22)

    def _status(self, d):
        if not self.msg or (time.time() - self.msg_t) > 4:
            return
        tw = min(LW - 40, d.textlength(self.msg, font=font(FRG, 16)) + 32)
        x = (LW - tw) / 2
        d.rounded_rectangle([x, 900, x + tw, 938], radius=12, fill=PANEL2)
        d.text((LW / 2, 919), self.msg[:52], font=font(FRG, 16), fill=FG,
               anchor="mm")

    def _overlay(self, d):
        d.rectangle([0, 0, LW, LH], fill=(0, 0, 0))
        q, _ = self.confirm
        d.rounded_rectangle([40, 430, LW - 40, 594], radius=14, fill=PANEL2)
        d.text((LW / 2, 470), q[:40], font=font(FBD, 20), fill=FG, anchor="mm")
        self.btn(d, (60, 510, 220, 64), "No", ("confirm_no",), size=22)
        self.btn(d, (320, 510, 220, 64), "Yes", ("confirm_yes",),
                 fill=BAD, size=22)

    # ---------------- tabs ----------------
    def _move(self, d):
        th = self.data.get("toolhead", {})
        p = th.get("position") or [0, 0, 0, 0]
        self.panel(d, (8, 150, 584, 168))
        d.text((20, 158), "Position (mm)", font=font(FRG, 15), fill=MUTED)
        for i, (ax, val) in enumerate([("X", p[0]), ("Y", p[1]), ("Z", p[2])]):
            yy = 186 + i * 36
            d.text((26, yy + 12), ax, font=font(FBD, 24), fill=ACC, anchor="lm")
            d.text((74, yy + 12), fmt(val), font=font(FBD, 24), fill=FG,
                   anchor="lm")
        homed = th.get("homed_axes") or "-"
        d.text((430, 298), "homed: %s" % homed, font=font(FRG, 15),
               fill=(GOOD if homed == "xyz" else MUTED))

        self.panel(d, (8, 326, 584, 88))
        d.text((20, 332), "Step (mm)", font=font(FRG, 15), fill=MUTED)
        for i, s in enumerate([0.1, 1, 10, 50]):
            x = 16 + i * 142
            self.btn(d, (x, 360, 134, 46), "%g" % s, ("step", s),
                     fill=(ACC if self.step == s else BTN), size=20)

        self.panel(d, (8, 422, 584, 264))
        d.text((20, 428), "Jog", font=font(FRG, 15), fill=MUTED)
        specs = [("X -", ("jog", "X", -1)), ("X +", ("jog", "X", 1)),
                 ("Y -", ("jog", "Y", -1)), ("Y +", ("jog", "Y", 1)),
                 ("Z -", ("jog", "Z", -1)), ("Z +", ("jog", "Z", 1))]
        for i, (label, act) in enumerate(specs):
            cx = 16 + (i % 2) * 288
            cy = 456 + (i // 2) * 76
            self.btn(d, (cx, cy, 272, 68), label, act, size=24)

        self.panel(d, (8, 694, 584, 246))
        d.text((20, 700), "Home", font=font(FRG, 15), fill=MUTED)
        self.btn(d, (16, 726, 272, 68), "Home X", ("gcode", "G28 X"),
                 fill=HOMEBG, size=22)
        self.btn(d, (304, 726, 272, 68), "Home Y", ("gcode", "G28 Y"),
                 fill=HOMEBG, size=22)
        self.btn(d, (16, 802, 272, 68), "Home Z", ("gcode", "G28 Z"),
                 fill=HOMEBG, size=22)
        self.btn(d, (304, 802, 272, 68), "Home All",
                 ("confirm", "Home all axes?", "G28"), fill=ACC, size=22)
        self.btn(d, (16, 878, 560, 54), "Motors Off (M84)",
                 ("confirm", "Disable motors?", "M84"), size=18)

    def _heat(self, d):
        self.panel(d, (8, 158, 584, 72))
        d.text((20, 166), "Tool", font=font(FRG, 15), fill=MUTED)
        self.btn(d, (80, 176, 246, 46), "T0  Left", ("tool", "extruder"),
                 fill=(ACC if self.tool == "extruder" else BTN), size=18)
        self.btn(d, (334, 176, 246, 46), "T1  Right", ("tool", "extruder1"),
                 fill=(ACC if self.tool == "extruder1" else BTN), size=18)

        self.panel(d, (8, 238, 584, 330))
        nm = "T0  Left" if self.tool == "extruder" else "T1  Right"
        d.text((20, 246), "Nozzle (%s)" % nm, font=font(FBD, 20), fill=FG)
        ex = self.data.get(self.tool, {})
        d.text((20, 282), fmt(ex.get("temperature")), font=font(FBD, 44),
               fill=GOOD)
        d.text((20, 338), "target %s" % fmt(ex.get("target")),
               font=font(FBD, 20), fill=MUTED)
        self.btn(d, (20, 378, 132, 62), "- 5", ("tooltemp", -5), size=22)
        self.btn(d, (160, 378, 132, 62), "+ 5", ("tooltemp", 5), size=22)
        self.btn(d, (300, 378, 132, 62), "- 1", ("tooltemp", -1), size=22)
        self.btn(d, (440, 378, 132, 62), "+ 1", ("tooltemp", 1), size=22)
        for i, (lbl, t) in enumerate([("Off", 0), ("PLA 200", 200),
                                      ("PETG 230", 230), ("ABS 240", 240)]):
            x = 20 + (i % 2) * 290
            yy = 452 + (i // 2) * 66
            self.btn(d, (x, yy, 280, 56), lbl, ("toolset", t), size=18)

        self.panel(d, (8, 576, 584, 342))
        d.text((20, 584), "Heat Bed", font=font(FBD, 20), fill=FG)
        bed = self.data.get("heater_bed", {})
        d.text((20, 620), fmt(bed.get("temperature")), font=font(FBD, 44),
               fill=GOOD)
        d.text((20, 676), "target %s" % fmt(bed.get("target")),
               font=font(FBD, 20), fill=MUTED)
        self.btn(d, (20, 716, 132, 62), "- 5", ("bedtemp", -5), size=22)
        self.btn(d, (160, 716, 132, 62), "+ 5", ("bedtemp", 5), size=22)
        self.btn(d, (300, 716, 132, 62), "- 1", ("bedtemp", -1), size=22)
        self.btn(d, (440, 716, 132, 62), "+ 1", ("bedtemp", 1), size=22)
        for i, (lbl, t) in enumerate([("Off", 0), ("PLA 60", 60),
                                      ("PETG 80", 80), ("ABS 100", 100)]):
            x = 20 + (i % 2) * 290
            yy = 790 + (i // 2) * 66
            self.btn(d, (x, yy, 280, 56), lbl, ("bedset", t), size=18)

    def _print(self, d):
        self.panel(d, (8, 158, 584, 326))
        d.text((20, 166), "Current Job", font=font(FRG, 15), fill=MUTED)
        ps = self.data.get("print_stats", {})
        vs = self.data.get("virtual_sdcard", {})
        state = ps.get("state", "standby")
        col = {"printing": ACC, "paused": WARN, "complete": GOOD,
               "error": BAD}.get(state, PANEL2)
        tw = d.textlength(state, font=font(FBD, 18)) + 28
        d.rounded_rectangle([20, 190, 20 + tw, 224], radius=16, fill=col)
        d.text((34, 207), state, font=font(FBD, 18), fill=(255, 255, 255),
               anchor="lm")
        d.text((20, 238), (ps.get("filename") or "-")[:40],
               font=font(FBD, 18), fill=FG)

        prog = float(vs.get("progress") or 0)
        if state == "complete":
            prog = 1.0
        d.rounded_rectangle([20, 274, 580, 312], radius=6, fill=PANEL2)
        d.rounded_rectangle([20, 274, 20 + int(560 * max(0.0, min(1.0, prog))),
                             312], radius=6, fill=ACC)
        d.text((20, 322), "%.1f%%" % (prog * 100), font=font(FBD, 22), fill=FG)
        dur = float(ps.get("print_duration") or 0)
        left = dur * (1 - prog) / prog if prog > 0.001 else 0
        d.text((20, 356), "elapsed %s    left %s" % (hhmm(dur), hhmm(left)),
               font=font(FRG, 18), fill=MUTED)

        self.btn(d, (20, 392, 168, 72), "Pause", ("gcode", "PAUSE"),
                 fill=(122, 92, 16), size=20)
        self.btn(d, (208, 392, 168, 72), "Resume", ("gcode", "RESUME"),
                 fill=HOMEBG, size=20)
        self.btn(d, (396, 392, 184, 72), "Cancel",
                 ("confirm", "Cancel current print?", "CANCEL_PRINT"),
                 fill=(122, 31, 34), size=20)

        self.panel(d, (8, 494, 584, 432))
        d.text((20, 502), "G-code files", font=font(FRG, 15), fill=MUTED)
        rows = 6
        rr = 54
        for i in range(rows):
            idx = self.file_scroll + i
            if idx >= len(self.files):
                break
            y = 528 + i * rr
            sel = (idx == self.file_sel)
            self.btn(d, (20, y, 468, rr - 8),
                     self.files[idx][-46:], ("filesel", idx),
                     fill=(ACC if sel else BTN), size=16)
        self.btn(d, (504, 528, 76, 76), "\u25b2", ("fileup",), size=22)
        self.btn(d, (504, 616, 76, 76), "\u25bc", ("filedown",), size=22)
        self.btn(d, (20, 872, 270, 48), "Reload files", ("fileload",), size=16)
        self.btn(d, (304, 872, 276, 48), "Start selected", ("filestart",),
                 fill=ACC, size=16)

    # ---------------- actions ----------------
    def say(self, m):
        self.msg = m
        self.msg_t = time.time()

    def dispatch(self, act):
        k = act[0]
        if k == "exit":
            raise SystemExit
        elif k == "tab":
            self.tab = act[1]
        elif k == "step":
            self.step = act[1]
        elif k == "jog":
            ax, dirn = act[1], act[2]
            feed = 600 if ax == "Z" else 6000
            self.send("G91\nG1 %s%.3f F%d\nG90" % (ax, dirn * self.step, feed))
        elif k == "gcode":
            self.send(act[1])
        elif k == "tool":
            self.tool = act[1]
        elif k == "tooltemp":
            cur = self.data.get(self.tool, {}).get("target", 0) or 0
            tgt = max(0, min(300, int(cur + act[1])))
            self.send("SET_HEATER_TEMPERATURE HEATER=%s TARGET=%d"
                      % (self.tool, tgt))
        elif k == "toolset":
            self.send("SET_HEATER_TEMPERATURE HEATER=%s TARGET=%d"
                      % (self.tool, act[1]))
        elif k == "bedtemp":
            cur = self.data.get("heater_bed", {}).get("target", 0) or 0
            tgt = max(0, min(120, int(cur + act[1])))
            self.send("SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=%d" % tgt)
        elif k == "bedset":
            self.send("SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=%d"
                      % act[1])
        elif k == "confirm":
            self.confirm = (act[1], act[2])
        elif k == "confirm_yes":
            script = self.confirm[1] if self.confirm else None
            self.confirm = None
            if script:
                self.send(script)
        elif k == "confirm_no":
            self.confirm = None
        elif k == "fileload":
            self.load_files()
        elif k == "filesel":
            self.file_sel = act[1]
            if act[1] < self.file_scroll:
                self.file_scroll = act[1]
            elif act[1] > self.file_scroll + 5:
                self.file_scroll = act[1] - 5
        elif k == "fileup":
            self.file_scroll = max(0, self.file_scroll - 1)
        elif k == "filedown":
            self.file_scroll = min(max(0, len(self.files) - 6),
                                   self.file_scroll + 1)
        elif k == "filestart":
            if self.file_sel is None or self.file_sel >= len(self.files):
                self.say("select a file first")
            else:
                self.confirm = ("Start %s?" % self.files[self.file_sel][-28:],
                                'SDCARD_PRINT_FILE FILENAME="%s"'
                                % self.files[self.file_sel])

    def send(self, script):
        self.say(">> " + script.replace("\n", " ")[:48])
        def run():
            try:
                send_gcode(script)
            except Exception as exc:
                self.msg = "ERROR: %s" % exc
                self.msg_t = time.time()
        if self.mock:
            return
        threading.Thread(target=run, daemon=True).start()

    def hit(self, lx, ly):
        for (x, y, w, h, act) in reversed(self.hits):
            if x <= lx <= x + w and y <= ly <= y + h:
                self.dispatch(act)
                return True
        return False


# ---------------- display ----------------
def run_display(ui, tab):
    import tkinter as tk
    root = tk.Tk()
    root.overrideredirect(True)
    root.geometry("1024x600+0+0")
    root.configure(bg="#000000")
    try:
        root.attributes("-topmost", True)
    except Exception:
        pass
    label = tk.Label(root, bd=0, bg="#000000")
    label.pack()

    if tab == "print":
        ui.load_files()

    def on_click(ev):
        fx, fy = ev.x, ev.y
        lx, ly = (LW - 1 - fy), fx
        try:
            ui.hit(lx, ly)
        except SystemExit:
            root.destroy()
            return
        render()

    label.bind("<Button-1>", on_click)

    from PIL import ImageTk

    def render():
        img = ui.draw().rotate(ROT, expand=True)
        ui._photo = ImageTk.PhotoImage(img)
        label.config(image=ui._photo)

    def tick():
        now = time.time()
        if now - ui._last_draw > 0.6:
            ui._last_draw = now
            render()
        root.after(150, tick)

    ui.start_poller()
    render()
    root.after(200, tick)
    root.mainloop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tab", default="move", choices=["move", "heat", "print"])
    ap.add_argument("--mock", action="store_true")
    ap.add_argument("--render", metavar="PNG")
    args = ap.parse_args()

    ui = Ui(tab=args.tab, mock=args.mock)
    if args.render:
        if args.mock:
            ui.data = ui._mock()
            ui.online = True
            ui.load_files()
        else:
            ui.data = http_get(
                "/printer/objects/query?extruder&extruder1&heater_bed&toolhead"
                "&print_stats&virtual_sdcard&gcode_move")["result"]["status"]
            ui.online = True
            ui.load_files()
        ui.draw().save(args.render)
        print("wrote", args.render)
        return
    run_display(ui, args.tab)


if __name__ == "__main__":
    main()
__EMBED_PANEL_MOONUI_PY__
cat > "$STAGE/webui/webui.py" <<'__EMBED_WEBUI_PY__'
#!/opt/moonraker/python/bin/python3.11
"""Combined web UI on port 80:
 - serves Fluidd static files
 - /camera/stream   -> MJPEG proxy of the stock MXCCameraServer
 - /camera/snapshot -> JPEG snapshot proxy
Reads the live basic-auth token from the MXCCameraServer command line,
so it keeps working across reboots/restarts (the token is per-boot random).
"""
import base64
import http.client
import os
import re
import socket
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

WEBROOT = "/opt/moonraker/www/fluidd"
CAM_HOST = "127.0.0.1"
CAM_PORT = 30216
BOUNDARY = "raise3dcameraboundary"

_token_lock = threading.Lock()
_token = {"value": None, "ts": 0.0}


def get_token():
    now = time.time()
    with _token_lock:
        if _token["value"] and (now - _token["ts"]) < 5.0:
            return _token["value"]
    found = None
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as fh:
                cmd = fh.read().replace(b"\x00", b" ").decode("latin1", "ignore")
        except OSError:
            continue
        if "MXCCameraServer" in cmd:
            m = re.search(r"-auth\s+[^:\s]+:([A-Za-z0-9]+)", cmd)
            if m:
                found = m.group(1)
                break
    with _token_lock:
        _token["value"] = found
        _token["ts"] = now
    return found


def auth_header():
    tok = get_token()
    if not tok:
        return None
    raw = ("raise3d_camera:" + tok).encode()
    return "Basic " + base64.b64encode(raw).decode()


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEBROOT, **kwargs)

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/camera/stream":
            self.proxy_stream()
        elif path in ("/camera/snapshot", "/camera/snapshot.jpg"):
            self.proxy_snapshot()
        else:
            super().do_GET()

    def proxy_snapshot(self):
        hdr = auth_header()
        if not hdr:
            self.send_error(503, "Camera server not available")
            return
        try:
            conn = http.client.HTTPConnection(CAM_HOST, CAM_PORT, timeout=10)
            conn.request("GET", "/api/v1/camera/takeshot",
                         headers={"Authorization": hdr})
            resp = conn.getresponse()
            data = resp.read()
            ctype = resp.getheader("Content-Type") or "image/jpeg"
            conn.close()
        except Exception as exc:  # noqa: BLE001
            self.send_error(502, "Camera upstream error: %s" % exc)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def proxy_stream(self):
        hdr = auth_header()
        if not hdr:
            self.send_error(503, "Camera server not available")
            return
        try:
            conn = http.client.HTTPConnection(CAM_HOST, CAM_PORT, timeout=10)
            conn.request("GET", "/api/v1/camera/stream",
                         headers={"Authorization": hdr})
            resp = conn.getresponse()
        except Exception as exc:  # noqa: BLE001
            self.send_error(502, "Camera upstream error: %s" % exc)
            return
        self.send_response(200)
        self.send_header("Age", "0")
        self.send_header("Cache-Control", "no-cache, private")
        self.send_header("Pragma", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header(
            "Content-Type",
            "multipart/x-mixed-replace; boundary=%s" % BOUNDARY,
        )
        self.end_headers()
        try:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, socket.timeout, OSError):
            pass
        finally:
            try:
                conn.close()
            except Exception:  # noqa: BLE001
                pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 80
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
__EMBED_WEBUI_PY__
cat > "$STAGE/panel/start-ui.sh" <<'__EMBED_START_UI_SH__'
#!/bin/sh
# Show the custom panel UI on the printer screen (DISPLAY :0).
export LD_LIBRARY_PATH=/usr/local/freetype/lib:/usr/local/lib:$LD_LIBRARY_PATH
exec /opt/moonraker/venv/bin/moonui /opt/moonraker/moonui.py "$@"
__EMBED_START_UI_SH__
cat > "$STAGE/panel/stop-ui.sh" <<'__EMBED_STOP_UI_SH__'
#!/bin/sh
# Stop the custom panel UI (returns to the Raise3D stock UI).
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  c=$(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null || true)
  case "$c" in
    /opt/moonraker/venv/bin/*moonui.py*) echo "stop ui $p"; kill $p;;
  esac
done
__EMBED_STOP_UI_SH__
cat > "$STAGE/panel/render-ui.sh" <<'__EMBED_RENDER_UI_SH__'
#!/bin/sh
# Render UI previews (upright 600x1024) without touching the printer screen.
export LD_LIBRARY_PATH=/usr/local/freetype/lib:/usr/local/lib
OUT=${1:-/opt/moonraker/ui-preview}
mkdir -p "$OUT"
PY=/opt/moonraker/venv/bin/python
for t in move heat print; do
  $PY /opt/moonraker/moonui.py --render "$OUT/ui_$t.png" --tab $t --mock
done
echo "previews in $OUT"
__EMBED_RENDER_UI_SH__
cat > "$STAGE/init/moonraker" <<'__EMBED_INIT_MOONRAKER__'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          moonraker
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Moonraker API server for Klipper
### END INIT INFO
NAME=moonraker
MR=/opt/moonraker
DAEMON=$MR/venv/bin/moonraker
DAEMON_ARGS="$MR/moonraker/moonraker/moonraker.py -d $MR/printer_data -c $MR/printer_data/moonraker.conf"
PIDFILE=/var/run/moonraker.pid
LOGFILE=$MR/printer_data/logs/moonraker-console.log
CERTIFI=$MR/venv/lib/python3.11/site-packages/certifi/cacert.pem
SSD=/sbin/start-stop-daemon
# Expose the vendor Klipper config dir inside Moonraker's config root as a bind
# mount: the files stay at their original path (so Klipper's SAVE_CONFIG and the
# stock UI keep working) but are also editable in the web UI. A bind mount is
# used instead of a symlink because Moonraker blocks writes under the reserved
# Klipper source tree, and resolves symlinks (a symlink would resolve into it).
MNT=$MR/printer_data/config
VENDOR=/opt/Raise3D/klipper-master/config
[ -f "$CERTIFI" ] && export SSL_CERT_FILE="$CERTIFI"
mount_config() {
    mkdir -p "$MNT"
    grep -q " $MNT " /proc/mounts || mount --bind "$VENDOR" "$MNT" 2>/dev/null || true
}
umount_config() {
    grep -q " $MNT " /proc/mounts && umount "$MNT" 2>/dev/null || true
}
case "$1" in
  start)
    echo "Starting $NAME"
    mount_config
    $SSD --start --background --quiet --make-pidfile --pidfile "$PIDFILE" \
         --exec "$DAEMON" -- $DAEMON_ARGS >> "$LOGFILE" 2>&1
    ;;
  stop)
    echo "Stopping $NAME"
    $SSD --stop --quiet --pidfile "$PIDFILE" --retry 10
    rm -f "$PIDFILE"
    umount_config
    ;;
  restart|force-reload) $0 stop; sleep 2; $0 start ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "$NAME running (pid $(cat "$PIDFILE"))"
    else echo "$NAME not running"; fi ;;
  *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
exit 0
__EMBED_INIT_MOONRAKER__
cat > "$STAGE/init/fluidd" <<'__EMBED_INIT_FLUIDD__'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          fluidd
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Fluidd web UI + camera proxy (port 80)
### END INIT INFO
NAME=fluidd
DAEMON=/opt/moonraker/python/bin/python3.11
DAEMON_ARGS="/opt/moonraker/webui.py 80"
PIDFILE=/var/run/fluidd.pid
LOGFILE=/opt/moonraker/printer_data/logs/webui.log
SSD=/sbin/start-stop-daemon
case "$1" in
  start)
    echo "Starting $NAME"
    $SSD --start --background --quiet --make-pidfile --pidfile "$PIDFILE" \
         --exec "$DAEMON" -- $DAEMON_ARGS >> "$LOGFILE" 2>&1
    ;;
  stop)
    echo "Stopping $NAME"
    $SSD --stop --quiet --pidfile "$PIDFILE" --retry 10
    rm -f "$PIDFILE"
    ;;
  restart|force-reload) $0 stop; sleep 2; $0 start ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "$NAME running (pid $(cat "$PIDFILE"))"
    else echo "$NAME not running"; fi ;;
  *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
exit 0
__EMBED_INIT_FLUIDD__
cat > "$STAGE/config/moonraker.conf.sample" <<'__EMBED_MOONRAKER_CONF__'
[server]
host: 0.0.0.0
port: 7125
klippy_uds_address: /opt/moonraker/printer_data/comms/klippy.sock

[file_manager]
# The vendor Klipper config dir is exposed here via a bind mount (see init/moonraker),
# so Klipper's reported config path does not match this folder's path. Editing still
# works; the location check is just disabled.
check_klipper_config_path: False

[machine]
# No systemd on this device; "none" disables service actions instead of failing to load.
provider: none

[octoprint_compat]
# OctoPrint-compatible API (/api/version, /api/printer, /api/files/local, ...).
# OrcaSlicer 2.3.x ("Octo/Klipper" host) and similar slicers need these to
# connect to Moonraker. Point stream_url at the web UI camera for the camera.
webcam_enabled: true
stream_url: /camera/stream

[authorization]
# Trusted LAN clients need no login. Adjust to your subnet.
trusted_clients:
    127.0.0.1
    192.168.1.0/24
# Allow the Fluidd frontend (served on the same host, port 80) to call the API.
cors_domains:
    *

[webcam printer]
service: mjpegstreamer
stream_url: /camera/stream
snapshot_url: /camera/snapshot
target_fps: 5
target_fps_idle: 5
__EMBED_MOONRAKER_CONF__
HERE="$STAGE"

# ------------------------------------------------------------------ helpers
log()  { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*" >&2; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'USAGE'
Raise3D Pro3 / Pro3 HyperSpeed — one-shot installer

  ./install.sh [--no-panel] [--no-webui] [--subnet X.X.X.0/24]
               [--restart-klipper] [-y|--yes]

  --no-panel         skip the on-panel touch UI
  --no-webui         skip Moonraker + Fluidd
  --subnet CIDR      trusted LAN subnet for Moonraker auth (auto-detected, /24)
  --restart-klipper  restart Klipper now to activate the API socket
  -y, --yes          no prompts
USAGE
    exit 0
}

# ------------------------------------------------------------------ args
while [ $# -gt 0 ]; do
    case "$1" in
        --no-webui) DO_WEBUI=0 ;;
        --no-panel) DO_PANEL=0 ;;
        --restart-klipper) DO_RESTART_KLIPPER=1 ;;
        --subnet) shift; SUBNET="${1:-}" ;;
        --subnet=*) SUBNET="${1#*=}" ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[ "$DO_WEBUI" = 1 ] || [ "$DO_PANEL" = 1 ] || die "nothing to do (both --no-webui and --no-panel)"

# ------------------------------------------------------------------ disclaimer
cat <<'DISCLAIMER'
============================================================
 DISCLAIMER — USE AT YOUR OWN RISK
 This installs software on your printer that can move axes
 and control heaters. A misconfiguration or a software fault
 can DAMAGE THE PRINTER, the print surface, or the hotend,
 and 3D printing carries fire risk. Provided WITHOUT WARRANTY
 (see LICENSE). You are solely responsible for your printer.
============================================================
DISCLAIMER
if [ "$ASSUME_YES" != 1 ]; then
    if [ -r /dev/tty ]; then
        printf '[install] Type "yes" to accept the risk and continue: '
        read -r ans < /dev/tty || ans=""
        [ "$ans" = "yes" ] || die "aborted (risk not accepted)"
    else
        warn "non-interactive run: continuing; you accept the risk by running this"
    fi
fi

# ------------------------------------------------------------------ preflight
[ "$(id -u)" = 0 ] || die "please run as root"
for t in curl tar make gcc; do
    have "$t" || die "missing required tool: $t"
done
[ -d /opt/Raise3D ] || die "this does not look like a Raise3D device (/opt/Raise3D missing)"
[ -f "$KLIPPY" ] || die "Klipper not found at $KLIPPY"

# (all auxiliary files are embedded by tools/build-installer.py)

# auto-detect the LAN subnet for Moonraker auth (assumes /24) unless given
if [ -z "$SUBNET" ]; then
    IPADDR=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
    [ -n "$IPADDR" ] || IPADDR=$(ifconfig eth0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
    if [ -n "$IPADDR" ]; then
        SUBNET=$(echo "$IPADDR" | awk -F. '{print $1"."$2"."$3".0/24"}')
    fi
fi
log "trusted subnet: ${SUBNET:-<sample default>}"

log "creating $MR/data dirs"
mkdir -p "$MR" "$MR/printer_data/comms" "$MR/printer_data/config" \
         "$MR/printer_data/logs" "$MR/printer_data/database"

# ================================================================== 1. Python
log "== [1/10] Python $PY_VERSION =="
if [ ! -x "$PY" ]; then
    curl -k -L -f --retry 3 -o /tmp/py311.tar.gz "$PY_URL"
    rm -rf "$MR/python"
    tar -xzf /tmp/py311.tar.gz -C "$MR"
fi
"$PY" -V || die "python failed to run"
"$PY" -c "import ssl, sqlite3, ctypes; print('[install] openssl', ssl.OPENSSL_VERSION)"

# ================================================================== 2. libsodium
log "== [2/10] libsodium =="
if [ ! -e /usr/local/lib/libsodium.so.23 ] && [ ! -e /usr/local/lib/libsodium.so ]; then
    curl -k -L -f --retry 3 -o /tmp/libsodium.tar.gz "$LIBSODIUM_URL"
    ( cd /tmp && rm -rf libsodium-1.0.18 && tar -xzf libsodium.tar.gz \
      && cd libsodium-1.0.18 && ./configure --prefix=/usr/local \
      && make -j4 && make install )
fi
mkdir -p /etc/ld.so.conf.d
echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local.conf
[ -f /etc/ld.so.conf ] || echo "include /etc/ld.so.conf.d/*.conf" > /etc/ld.so.conf
ldconfig || true

# ================================================================== 3. venv + deps
log "== [3/10] Moonraker venv + dependencies =="
if [ ! -x "$VENVPY" ]; then
    "$PY" -m venv "$VENV"
fi
"$VENVPY" -m pip install --upgrade pip setuptools wheel
# the standalone interpreter's sysconfig points at a cross compiler; force gcc
export CC=gcc CXX=g++ LDSHARED="gcc -shared"
"$VENVPY" -m pip install \
    pyserial==3.4 distro==1.9.0 jinja2==3.1.6 paho-mqtt==2.1.0 "apprise<=1.13.0" \
    ldap3==2.9.1 python-periphery==2.4.1 "importlib_metadata<=9.0.0" \
    preprocess-cancellation==0.2.1 inotify-simple==2.0.1 libnacl==2.1.0 \
    "tornado>=6.2.0,<=6.5.8" "pillow>=9.5.0,<=12.3.0" \
    "streaming-form-data>=1.11.0,<=2.1.0" "dbus-fast>=2.21.3,<=5.0.22" \
    "zeroconf>=0.131.0,<=0.150.0"
"$VENVPY" -c "from libnacl.sign import Signer; Signer(); print('[install] libnacl OK')"

# ================================================================== 4. FreeType + mss
if [ "$DO_PANEL" = 1 ]; then
    log "== [4/10] FreeType (for the panel UI) =="
    if [ ! -e /usr/local/freetype/lib/libfreetype.so.6 ]; then
        curl -k -L -f --retry 3 -o /tmp/ft.tar.gz "$FREETYPE_URL"
        ( cd /tmp && rm -rf freetype-2.13.2 && tar -xzf ft.tar.gz \
          && cd freetype-2.13.2 \
          && ./configure --prefix=/usr/local/freetype --without-harfbuzz --without-brotli \
                         --without-png --without-bzip2 \
          && make -j4 && make install )
    fi
    # NOTE: installed under /usr/local/freetype and versioned via LD_LIBRARY_PATH,
    # so the system's (old) FreeType used by Xorg is never touched/re-cached.
    "$VENVPY" -m pip install "mss==8.0.3"     # 8.x uses Xlib (9+/10 needs newer libxcb)
    "$PY" -m pip install "mss==8.0.3" || true
else
    log "== [4/10] FreeType skipped (--no-panel) =="
fi

# ================================================================== 5. Klipper patch
log "== [5/10] Enable Klipper API socket =="
[ -f "$KLIPPY.orig-moonraker" ] || cp -a "$KLIPPY" "$KLIPPY.orig-moonraker"
"$PY" - "$KLIPPY" "$SOCK" <<'PY'
import sys
path, sock = sys.argv[1], sys.argv[2]
s = open(path).read()
if sock in s:
    print("[install] klippy.py already patched")
    raise SystemExit(0)
old = ("    start_args = {'config_file': args[0], 'apiserver': options.apiserver,\n"
       "                  'start_reason': 'startup'}")
new = ("    _apiserver = options.apiserver\n"
       "    if not _apiserver:\n"
       "        _apiserver = '%s'\n"
       "    start_args = {'config_file': args[0], 'apiserver': _apiserver,\n"
       "                  'start_reason': 'startup'}" % sock)
if s.count(old) != 1:
    print("[install] ERROR: expected klippy.py pattern not found (unsupported fork?)")
    raise SystemExit(1)
open(path, "w").write(s.replace(old, new))
print("[install] patched klippy.py")
PY
python2 -c "compile(open('$KLIPPY').read(),'klippy.py','exec')" \
    && log "klippy.py syntax OK" || die "klippy.py syntax check failed"

# ================================================================== 6. Klipper config
log "== [6/10] Klipper config additions =="
[ -f "$KCFG.orig-moonraker" ] || cp -a "$KCFG" "$KCFG.orig-moonraker"
grep -q '^\[display_status\]' "$KCFG" || printf '\n[display_status]\n' >> "$KCFG"
if ! grep -q '^\[gcode_macro CANCEL_PRINT\]' "$KCFG"; then
    cat >> "$KCFG" <<'EOF'

[gcode_macro CANCEL_PRINT]
description = Cancel the current print
rename_existing = _CANCEL_PRINT
gcode =
	_CANCEL_PRINT
EOF
fi

# Shell-command helper: lets macros run host commands. Used below to expose a
# RESTART_MXCUI macro so offset edits made in the web UI can be applied without
# the on-screen wizard (MXCUI only reads its cfg files at start).
cp "$HERE/klipper/gcode_shell_command.py" "$KL_Dir/klippy/extras/gcode_shell_command.py"
cp "$HERE/scripts/restart-mxcui.sh" /opt/Raise3D/restart-mxcui.sh
chmod +x /opt/Raise3D/restart-mxcui.sh
if ! grep -q '^\[gcode_shell_command restart_mxcui\]' "$KCFG"; then
    cat >> "$KCFG" <<'EOF'

[gcode_shell_command restart_mxcui]
command: /opt/Raise3D/restart-mxcui.sh
timeout: 30.
verbose: True

[gcode_macro RESTART_MXCUI]
description = Restart the stock Raise3D touch UI (reloads settings files)
gcode =
	RUN_SHELL_COMMAND CMD=restart_mxcui
EOF
fi

# Fan macros: this Klipper fork has four PWM fans ([fan] pin/pin1/pin2/pin3 =
# left head, right head, P2, P3), and its mingled M107/P255 "all" path only
# stops the first two, so switch each one explicitly. Shows up as a button in
# Fluidd/MoonUI when the macro is pinned.
if ! grep -q '^\[gcode_macro FANS_OFF\]' "$KCFG"; then
    cat >> "$KCFG" <<'EOF'

[gcode_macro FANS_OFF]
description = Turn off all fans (left/right head + P2 + P3)
gcode =
	M106 P0 S0
	M106 P1 S0
	M106 P2 S0
	M106 P3 S0

[gcode_macro FANS_ON]
description = Turn all fans to 100%
gcode =
	M106 P0 S255
	M106 P1 S255
	M106 P2 S255
	M106 P3 S255
EOF
fi

# Head-fan reset: the HCB head fans are thermostatic and ignore host fan
# commands (M106 P*/M5100 G* F*), so a stuck-on fan is cleared by rebooting the
# head controller (M5100 RESET). That puts Klipper in shutdown, so the helper
# script follows up with a FIRMWARE_RESTART and waits for ready.
cp "$HERE/scripts/reset-heads.sh" /opt/Raise3D/reset-heads.sh
chmod +x /opt/Raise3D/reset-heads.sh
if ! grep -q '^\[gcode_macro RESET_HEAD_FANS\]' "$KCFG"; then
    cat >> "$KCFG" <<'EOF'

[gcode_shell_command reset_head_fans]
command = /opt/Raise3D/reset-heads.sh
timeout = 60.
verbose = False

[gcode_macro RESET_HEAD_FANS]
description = Reboot mainboard/HCB to clear stuck head fans (then auto-recovers)
gcode =
	RUN_SHELL_COMMAND CMD=reset_head_fans
EOF
fi

# LED macros: the vendor light module drives both head LEDs through the HCB
# via M355 (MXCUI's own convention: S1 = on, S0 = off).
if ! grep -q '^\[gcode_macro LEDS_ON\]' "$KCFG"; then
    cat >> "$KCFG" <<'EOF'

[gcode_macro LEDS_ON]
description = Turn on the chamber LEDs (both heads)
gcode =
	M355 S1

[gcode_macro LEDS_OFF]
description = Turn off the chamber LEDs (both heads)
gcode =
	M355 S0
EOF
fi

# ================================================================== 7. Moonraker
if [ "$DO_WEBUI" = 1 ]; then
    log "== [7/10] Moonraker =="
    if [ ! -d "$MR/moonraker/moonraker" ]; then
        curl -k -L -f --retry 3 -o /tmp/moonraker.tar.gz "$MOONRAKER_URL"
        ( cd "$MR" && rm -rf moonraker-master && tar -xzf /tmp/moonraker.tar.gz \
          && rm -rf moonraker && mv moonraker-master moonraker )
    fi
    [ -e "$MR/printer_data/gcodes" ] || ln -sfn /home/root "$MR/printer_data/gcodes"
    # Expose the vendor Klipper config dir as Moonraker's config root so it is
    # editable in the web UI. A bind mount (not a symlink) keeps the files at
    # their original path and outside the reserved Klipper source tree.
    mkdir -p "$MR/printer_data/config"
    grep -q " $MR/printer_data/config " /proc/mounts \
        || mount --bind "$KL_Dir/config" "$MR/printer_data/config" 2>/dev/null || true
    # Also expose the stock Raise3D settings dir (e2config.cfg, hotend.cfg, ...)
    # as a "raise3d" subfolder of the config root so it is viewable/editable.
    mkdir -p "$MR/printer_data/config/raise3d"
    grep -q " $MR/printer_data/config/raise3d " /proc/mounts \
        || mount --bind /opt/Raise3D/config "$MR/printer_data/config/raise3d" 2>/dev/null || true
    if [ ! -f "$MR/printer_data/moonraker.conf" ]; then
        sed "s#192.168.1.0/24#${SUBNET:-192.168.1.0/24}#" \
            "$HERE/config/moonraker.conf.sample" \
            > "$MR/printer_data/moonraker.conf"
        log "wrote moonraker.conf (trusted: ${SUBNET:-192.168.1.0/24})"
    fi
else
    log "== [7/10] Moonraker skipped (--no-webui) =="
fi

# ================================================================== 8. Web UI
if [ "$DO_WEBUI" = 1 ]; then
    log "== [8/10] Fluidd + camera proxy =="
    mkdir -p "$MR/www"
    if [ ! -f "$MR/www/fluidd/index.html" ]; then
        curl -k -L -f --retry 3 -o /tmp/fluidd.zip "$FLUIDD_URL"
        rm -rf "$MR/www/fluidd" && mkdir -p "$MR/www/fluidd"
        "$PY" -c "import zipfile; zipfile.ZipFile('/tmp/fluidd.zip').extractall('$MR/www/fluidd')"
    fi
    cp "$HERE/webui/webui.py" "$MR/webui.py"
else
    log "== [8/10] Web UI skipped (--no-webui) =="
fi

# ================================================================== 9. Autostart
if [ "$DO_WEBUI" = 1 ]; then
    log "== [9/10] Init services =="
    cp "$HERE/init/moonraker" /etc/init.d/moonraker
    cp "$HERE/init/fluidd"    /etc/init.d/fluidd
    chmod +x /etc/init.d/moonraker /etc/init.d/fluidd
    for rl in 2 3 4 5; do
        ln -sf ../init.d/moonraker "/etc/rc$rl.d/S99moonraker"
        ln -sf ../init.d/fluidd    "/etc/rc$rl.d/S99fluidd"
    done
    for rl in 0 1 6; do
        ln -sf ../init.d/moonraker "/etc/rc$rl.d/K01moonraker"
        ln -sf ../init.d/fluidd    "/etc/rc$rl.d/K01fluidd"
    done
else
    log "== [9/10] Init services skipped (--no-webui) =="
fi

# ================================================================== 10. Panel UI
if [ "$DO_PANEL" = 1 ]; then
    log "== [10/10] On-panel touch UI =="
    cp "$HERE/panel/moonui.py"     "$MR/moonui.py"
    cp "$HERE/panel/start-ui.sh"   "$MR/start-ui.sh"
    cp "$HERE/panel/stop-ui.sh"    "$MR/stop-ui.sh"
    cp "$HERE/panel/render-ui.sh"  "$MR/render-ui.sh"
    chmod +x "$MR/start-ui.sh" "$MR/stop-ui.sh" "$MR/render-ui.sh"
    ln -sf python "$VENV/bin/moonui"     # safe process name (MXC kills "python")
    LD_LIBRARY_PATH=/usr/local/freetype/lib:/usr/local/lib \
        "$PY" "$MR/moonui.py" --render /tmp/ui-preview-move.png --tab move --mock >/dev/null
    log "panel UI OK (preview rendered)"
else
    log "== [10/10] Panel UI skipped (--no-panel) =="
fi

# ================================================================== start
if [ "$DO_WEBUI" = 1 ]; then
    log "starting services"
    /etc/init.d/fluidd start  || warn "fluidd start failed"
    /etc/init.d/moonraker start || warn "moonraker start failed"
fi

if [ "$DO_RESTART_KLIPPER" = 1 ]; then
    log "restarting Klipper to activate the API socket"
    pkill -f 'klippy/klippy.py' || true
    sleep 2
    ( cd "$KL_Dir" && setsid python klippy/klippy.py "$KCFG" \
        -l /opt/Raise3D/logs/system/klippy.log \
        </dev/null >>/opt/Raise3D/logs/system/klippy.log 2>&1 & )
    sleep 12
    [ -S "$SOCK" ] && log "API socket present: $SOCK" || warn "socket not seen yet"
fi

# ================================================================== summary
IPADDR=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
[ -n "$IPADDR" ] || IPADDR="<printer-ip>"
cat <<EOF

[install] Done.
  Web UI:     http://$IPADDR/          (Fluidd)
  Moonraker:  http://$IPADDR:7125/
  Panel UI:   $MR/start-ui.sh   (Exit button returns to the stock UI)

EOF
if [ "$DO_RESTART_KLIPPER" = 0 ]; then
    echo "[install] NOTE: reboot (or run this script with --restart-klipper) so the"
    echo "[install] Klipper API socket is created; until then Moonraker shows disconnected."
fi
if [ "$DO_WEBUI" = 1 ] && [ -z "$SUBNET" ]; then
    echo "[install] NOTE: could not auto-detect your subnet; re-run with"
    echo "[install] --subnet <x.x.x.0/24> or edit moonraker.conf if the UI asks for login."
fi
