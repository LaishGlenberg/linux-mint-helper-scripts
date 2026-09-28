#!/usr/bin/env bash
# recent.sh - pick a recently opened VS Code folder or xed file and open it.
# Intended to be bound to a Linux Mint keyboard shortcut.
#
# Hotkey command (Linux Mint / Cinnamon, System Settings > Keyboard > Shortcuts >
# Custom Shortcuts) - either of these works, the script opens its own terminal:
#     /home/lg/scripts/recent.sh
#     gnome-terminal -- /home/lg/scripts/recent.sh
#
# Starts in VS Code mode (recent folders). At the prompt you can type one or
# more numbers (e.g. "3,4,5") and press Enter, or hold Shift and press a number
# (Shift+2 -> @) to open that item instantly.
#
# Typing letters (no digits) and pressing Enter searches instead: the query is
# split into terms on whitespace and/or commas, and each term is matched against
# the paths from right to left (the match closest to the folder/file name wins).
# Every term opens its own best match, so "scripts api" opens two items.
#
# Typing "xed", "note" or "notepad" switches to xed mode, which lists files xed
# recently opened (from the GTK recent list) and opens them with xed. Typing
# "code" or "vscode" switches back to VS Code mode. Each mode has its own list
# but shares all of the selection/search controls.
#
# If a search matches nothing (or a selection is invalid) you are simply asked
# again - the window stays open for a retry.
#
# Optionally set RECENT_LIMIT to change how many entries are listed (default
# 20). When more than 10 entries are listed, a blank line separates the first
# 10 from the rest.

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/collect.sh
. "$SCRIPT_DIR/lib/collect.sh"
# shellcheck source=lib/picker.sh
. "$SCRIPT_DIR/lib/picker.sh"

# Load each list once; switching modes just reuses the arrays.
mapfile -t vscode_folders < <(collect_vscode_folders)
mapfile -t xed_files < <(collect_xed_files)

PICKER_LIMIT="${RECENT_LIMIT:-20}"

mode=vscode
while true; do
    case "$mode" in
        vscode)
            declare -A PICKER_KEYWORDS=([xed]=xed [note]=xed [notepad]=xed)
            picker_run vscode_folders "Recent VS Code projects:" "project" code -n
            rc=$?
            ;;
        xed)
            declare -A PICKER_KEYWORDS=([code]=vscode [vscode]=vscode [folders]=vscode)
            picker_run xed_files "Recent xed files:" "file" xed
            rc=$?
            ;;
    esac

    # Exit status 3 means a keyword asked us to switch lists; loop with the new
    # mode. Anything else (opened, EOF) is final.
    if [ "$rc" -eq 3 ]; then
        mode="$PICKER_MODE"
        continue
    fi
    exit "$rc"
done
