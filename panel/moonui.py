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
