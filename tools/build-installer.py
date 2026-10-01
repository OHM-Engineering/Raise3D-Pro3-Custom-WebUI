#!/usr/bin/env python3
"""Assemble the self-contained ./install.sh.

The installer logic lives in tools/install.sh.in with a single placeholder
(``@@EMBED@@``) at the point where it needs the auxiliary files. This script
replaces that placeholder with a block that writes every auxiliary file
(panel UI, web UI, init scripts, sample config, helper scripts) to a temp
staging dir, so the resulting install.sh needs nothing else — it can be run
from a checkout *or* piped straight from the repository:

    curl -fsSL https://raw.githubusercontent.com/OHM-Engineering/Raise3D-Pro3-Custom-WebUI/main/install.sh | sh

Regenerate after editing any of the embedded files or the template:

    python3 tools/build-installer.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "tools" / "install.sh.in"
OUT = ROOT / "install.sh"

# (repo-relative path, unique heredoc delimiter)
EMBEDS = [
    ("panel/moonui.py", "__EMBED_PANEL_MOONUI_PY__"),
    ("webui/webui.py", "__EMBED_WEBUI_PY__"),
    ("panel/start-ui.sh", "__EMBED_START_UI_SH__"),
    ("panel/stop-ui.sh", "__EMBED_STOP_UI_SH__"),
    ("panel/render-ui.sh", "__EMBED_RENDER_UI_SH__"),
    ("init/moonraker", "__EMBED_INIT_MOONRAKER__"),
    ("init/webui", "__EMBED_INIT_WEBUI__"),
    ("config/moonraker.conf.sample", "__EMBED_MOONRAKER_CONF__"),
    ("klipper/gcode_shell_command.py", "__EMBED_GCODE_SHELL_COMMAND_PY__"),
    ("scripts/restart-mxcui.sh", "__EMBED_RESTART_MXCUI_SH__"),
    ("scripts/reset-heads.sh", "__EMBED_RESET_HEADS_SH__"),
]


def build() -> None:
    template = TEMPLATE.read_text(encoding="utf-8")
    if template.count("@@EMBED@@") != 1:
        sys.exit("template must contain exactly one @@EMBED@@ placeholder")

    lines = [
        "# --- embedded auxiliary files (written to a temp staging dir) ---",
        "STAGE=$(mktemp -d /tmp/r3d-install.XXXXXX 2>/dev/null || echo /tmp/r3d-install.$$)",
        'mkdir -p "$STAGE/panel" "$STAGE/webui" "$STAGE/init" "$STAGE/config" \\',
        '         "$STAGE/klipper" "$STAGE/scripts"',
        "trap 'rm -rf \"$STAGE\"' EXIT INT TERM",
    ]
    for rel, delim in EMBEDS:
        content = (ROOT / rel).read_text(encoding="utf-8").rstrip("\n")
        if any(line == delim for line in content.splitlines()):
            sys.exit("delimiter collision in %s: %s" % (rel, delim))
        lines.append('cat > "$STAGE/%s" <<\'%s\'' % (rel, delim))
        lines.append(content)
        lines.append(delim)
    lines.append('HERE="$STAGE"')
    embed_block = "\n".join(lines)

    out = template.replace("@@EMBED@@", embed_block)
    OUT.write_text(out, encoding="utf-8", newline="\n")
    print("wrote %s (%d lines total)" % (OUT, out.count("\n") + 1))


if __name__ == "__main__":
    build()
