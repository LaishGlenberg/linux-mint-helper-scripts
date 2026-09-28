#!/usr/bin/env bash
# lib/collect.sh - recent-item collectors for recent.sh.
#
# Each function prints candidate paths, newest first, one per line, so the
# caller can load them with mapfile. The interactive picking lives in
# lib/picker.sh; this file only knows how to read each application's history.
#
#   collect_vscode_folders   VS Code folders from its workspaceStorage dir
#   collect_xed_files        files opened by xed, from the GTK recent XBEL
#
# Environment overrides (mainly for tests):
#   RECENT_VSCODE_WS   workspaceStorage dir (default ~/.config/Code/User/workspaceStorage)
#   RECENT_XBEL        GTK recently-used file (default ~/.local/share/recently-used.xbel)

collect_vscode_folders() {
    local ws="${RECENT_VSCODE_WS:-$HOME/.config/Code/User/workspaceStorage}"
    [ -d "$ws" ] || return 0
    python3 - "$ws" <<'PY'
import json, os, sys, glob, urllib.parse

ws = os.path.expanduser(sys.argv[1])
entries = []
for d in glob.glob(os.path.join(ws, "*")):
    wj = os.path.join(d, "workspace.json")
    if not os.path.isfile(wj):
        continue
    try:
        with open(wj) as f:
            data = json.load(f)
    except Exception:
        continue
    uri = data.get("folder") or data.get("workspace")
    if not uri or not uri.startswith("file://"):
        continue
    path = urllib.parse.unquote(uri[len("file://"):])
    entries.append((os.path.getmtime(d), path))

entries.sort(reverse=True)
seen = set()
for _, path in entries:
    if path not in seen:
        seen.add(path)
        print(path)
PY
}

collect_xed_files() {
    local xbel="${RECENT_XBEL:-$HOME/.local/share/recently-used.xbel}"
    [ -f "$xbel" ] || return 0
    python3 - "$xbel" <<'PY'
import os, sys, urllib.parse
import xml.etree.ElementTree as ET

NS = "{http://www.freedesktop.org/standards/desktop-bookmarks}"
xbel = os.path.expanduser(sys.argv[1])
try:
    root = ET.parse(xbel).getroot()
except Exception:
    sys.exit(0)


def local(tag):
    return tag.rsplit("}", 1)[-1]


entries = []
for bm in root.iter():
    if local(bm.tag) != "bookmark":
        continue
    uri = bm.get("href")
    if not uri or not uri.startswith("file://"):
        continue

    apps = {}
    groups = set()
    for node in bm.iter():
        if local(node.tag) == "application":
            apps[node.get("name")] = node
        elif local(node.tag) == "group":
            groups.add((node.text or "").lower())

    if "xed" not in apps and "xed" not in groups:
        continue

    app = apps.get("xed")
    # Prefer when xed itself last touched the file, then the generic stamps.
    stamp = ((app.get("modified") if app is not None else None)
             or bm.get("modified") or bm.get("visited") or "")
    path = urllib.parse.unquote(uri[len("file://"):])
    entries.append((stamp, path))

entries.sort(reverse=True)
seen = set()
for _, path in entries:
    if path not in seen:
        seen.add(path)
        print(path)
PY
}
