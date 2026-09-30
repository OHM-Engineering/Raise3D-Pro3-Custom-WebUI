# Camera

The stock `MXCCameraServer` owns the USB camera (`/dev/video1`) continuously and exposes an
MJPEG stream used by the Raise3D touchscreen (and cloud/remote API). To avoid disturbing it
(and because a UVC device is typically single-owner), the web UI **reuses that stream**
through a small local proxy instead of opening the camera a second time.

## Stock server

`MXCCameraServer` listens on **`0.0.0.0:30216`** and requires HTTP Basic auth:

| Endpoint | Returns |
|---|---|
| `GET /api/v1/camera/stream` | MJPEG (`multipart/x-mixed-replace`) |
| `GET /api/v1/camera/takeshot` | single JPEG |
| `GET /api/v1/camera/state` | JSON status |

All endpoints return `401` without credentials. The username is `raise3d_camera`; the
**password is regenerated every boot** and passed by `MXCUI` on the server's command line
(`-auth raise3d_camera:<token>`). There is no localhost bypass.

Because the token changes, a static config can't embed it. `webui/webui.py` therefore reads
the live token from `/proc/<pid>/cmdline` (refreshed every few seconds) and attaches the
Basic auth header when proxying.

## Proxy (`webui/webui.py`)

The proxy is part of the port‑80 server (same origin as Fluidd, so no CORS/token issues):

- `GET /camera/stream`   → MJPEG from `/api/v1/camera/stream`
- `GET /camera/snapshot` → JPEG from `/api/v1/camera/takeshot`

Fluidd is pointed at it via Moonraker (relative URLs):

```ini
[webcam printer]
service: mjpegstreamer
stream_url: /camera/stream
snapshot_url: /camera/snapshot
target_fps: 5
target_fps_idle: 5
```

The stock camera keeps working: multi-client access was verified (the touchscreen and the
proxy can stream simultaneously).

## Bandwidth note

The stock stream is 1280×720 MJPEG and fairly heavy on WiFi. Resolution/FPS can be adjusted
in the printer's Camera settings (`/opt/Raise3D/config/printer-camera.cfg`), which `MXCUI`
applies to `MXCCameraServer`; the proxy follows automatically.
