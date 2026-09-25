#!/usr/bin/env bash
# recent.sh - pick a recently opened VS Code folder and open it in a new window.
# Intended to be bound to a Linux Mint keyboard shortcut.
#
# Hotkey command (Linux Mint / Cinnamon, System Settings > Keyboard > Shortcuts >
# Custom Shortcuts) - either of these works, the script opens its own terminal:
#     /home/lg/scripts/recent.sh
#     gnome-terminal -- /home/lg/scripts/recent.sh
#
# Optionally set RECENT_LIMIT to change how many entries are listed (default 10).
# When more than 10 entries are listed, a blank line separates the first 10
# from the rest.
#
# At the prompt you can type one or more numbers (e.g. "3,4,5") and press Enter,
# or hold Shift and press a number (Shift+2 -> @) to open that project instantly.

WS="$HOME/.config/Code/User/workspaceStorage"
LIMIT="${RECENT_LIMIT:-20}"

# When launched from a Cinnamon keyboard shortcut there is no TTY, so the prompt
# would be invisible. Relaunch ourselves inside a terminal window (guarded so
# the inner run proceeds normally).
if [ ! -t 0 ] || [ ! -t 1 ]; then
    for term in gnome-terminal x-terminal-emulator xfce4-terminal mate-terminal konsole kitty alacritty xterm; do
        if command -v "$term" >/dev/null 2>&1; then
            case "$term" in
                gnome-terminal) exec "$term" -- "$0" "$@" ;;
                *)              exec "$term" -e "$0" "$@" ;;
            esac
        fi
    done
    echo "recent.sh: no terminal emulator found" >&2
    exit 1
fi

# Build a most-recent-first list of unique folder paths.
mapfile -t folders < <(
python3 - "$WS" <<'PY'
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
)

if [ "${#folders[@]}" -eq 0 ]; then
    echo "No recent VS Code projects found."
    read -rp "Press Enter to close..."
    exit 1
fi

if [ "${#folders[@]}" -gt "$LIMIT" ]; then
    folders=("${folders[@]:0:$LIMIT}")
fi

echo "Recent VS Code projects:"
i=1
for f in "${folders[@]}"; do
    # Visually separate the first 10 entries from everything after them.
    if [ "$i" -eq 11 ]; then
        echo
    fi
    printf "  %2d) %s\n" "$i" "$f"
    i=$((i + 1))
done
echo

printf "Open which project(s)? (e.g. 3,4,5, or Shift+number for instant open) "
IFS= read -rn1 first

# Shift+<digit> on a US keyboard emits the symbol above the number key.
# Map those to the digit so a single keypress opens immediately.
instant=""
case "$first" in
    '!') instant=1  ;;
    '@') instant=2  ;;
    '#') instant=3  ;;
    '$') instant=4  ;;
    '%') instant=5  ;;
    '^') instant=6  ;;
    '&') instant=7  ;;
    '*') instant=8  ;;
    '(') instant=9  ;;
    ')') instant=10 ;;
esac

if [ -n "$instant" ]; then
    # Instant single open - no Enter needed.
    printf '\n'
    choice="$instant"
else
    # Otherwise read the rest of the line (plain digits, commas, spaces).
    IFS= read -r rest
    printf '\n'
    choice="${first}${rest}"
fi

# Accept one or more numbers separated by commas and/or spaces.
selected=()
for n in ${choice//,/ }; do
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#folders[@]}" ]; then
        echo "Invalid selection: $n"
        read -rp "Press Enter to close..."
        exit 1
    fi
    selected+=("${folders[n-1]}")
done

if [ "${#selected[@]}" -eq 0 ]; then
    echo "No selection."
    read -rp "Press Enter to close..."
    exit 1
fi

for path in "${selected[@]}"; do
    code -n "$path"
done
