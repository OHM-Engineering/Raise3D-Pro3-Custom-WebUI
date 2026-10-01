#!/opt/moonraker/python/bin/python3.11
"""Combined web UI on port 80:
 - serves the static Fluidd or Mainsail build (R3D_WEBROOT, default Fluidd)
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

WEBROOT = os.environ.get("R3D_WEBROOT", "/opt/moonraker/www/fluidd")
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
