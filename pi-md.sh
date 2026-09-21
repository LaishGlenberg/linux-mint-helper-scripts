#!/usr/bin/env bash
# pi-md.sh - interactive picker that converts a pi session JSONL into Markdown.
#
# Flow:
#   1. list session project directories (newest activity first), numbered
#   2. you pick one
#   3. list that project's session .jsonl files, numbered (with date/size/preview)
#   4. you pick one, it is fed to pi_session_to_md.py
#
# Usage:
#   pi-md.sh [options forwarded to pi_session_to_md.py]
#
# Examples:
#   pi-md.sh
#   pi-md.sh --no-thinking
#   pi-md.sh --timestamps --include-bash
#   pi-md.sh -o /tmp/transcript.md      # explicit output path
#   PI_MD_STDOUT=1 pi-md.sh             # stream markdown to stdout instead of a file
#
# Env:
#   PI_SESSIONS_DIR    session root           (default: ~/.pi/agent/sessions)
#   PI_DIR_LIMIT       project dirs listed    (default: 5, 0 = all)
#   PI_SESSION_LIMIT   sessions listed        (default: 5, 0 = all)
#   PI_SESSION_TO_MD   converter script/binary (auto-detected if unset)
#   PI_MD_OUTDIR       where default .md lands (default: current directory)
#   PI_MD_SNIPPET      preview length in chars (default: 60, 0 disables)
#   PI_MD_OPEN         open the .md in an editor when done (default: 1, 0 = no)
#   PI_MD_OPENER       editor command used to open it (default: code)
#
# Lists are always ordered newest-first; the limits only trim the tail, so set
# the limit to 0 (or a bigger number) to reach older projects/sessions.

set -uo pipefail

SESSIONS_DIR="${PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
OUTDIR="${PI_MD_OUTDIR:-$PWD}"
SNIPPET="${PI_MD_SNIPPET:-60}"
DIR_LIMIT="${PI_DIR_LIMIT:-5}"
SESSION_LIMIT="${PI_SESSION_LIMIT:-5}"

die() { echo "pi-md: $*" >&2; exit 1; }

# Limits must be non-negative integers; 0 means "no limit".
for spec in "PI_DIR_LIMIT=$DIR_LIMIT" "PI_SESSION_LIMIT=$SESSION_LIMIT"; do
    [[ "${spec#*=}" =~ ^[0-9]+$ ]] || die "${spec%%=*} must be a non-negative integer (got '${spec#*=}')"
done

# Print the header comment block as help.
usage() {
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

# When launched from a hotkey there is no TTY, so the picker would be invisible.
# Relaunch inside a terminal window (same trick as recent.sh).
if [ ! -t 0 ] || [ ! -t 1 ]; then
    for term in gnome-terminal x-terminal-emulator xfce4-terminal mate-terminal konsole kitty alacritty xterm; do
        if command -v "$term" >/dev/null 2>&1; then
            case "$term" in
                gnome-terminal) exec "$term" -- "$0" "$@" ;;
                *)              exec "$term" -e "$0" "$@" ;;
            esac
        fi
    done
    die "no terminal emulator found"
fi

[ -d "$SESSIONS_DIR" ] || die "session directory not found: $SESSIONS_DIR"

# ---------------------------------------------------------------------------
# Locate the converter: env override, repo script, venv entry point, PATH.
# ---------------------------------------------------------------------------
CONVERTER=()
if [ -n "${PI_SESSION_TO_MD:-}" ]; then
    case "$PI_SESSION_TO_MD" in
        *.py) CONVERTER=(python3 "$PI_SESSION_TO_MD") ;;
        *)    CONVERTER=("$PI_SESSION_TO_MD") ;;
    esac
elif [ -f "$HOME/pi-session-to-md/pi_session_to_md.py" ]; then
    CONVERTER=(python3 "$HOME/pi-session-to-md/pi_session_to_md.py")
elif [ -x "$HOME/pi-session-to-md/.venv/bin/pi-session-to-md" ]; then
    CONVERTER=("$HOME/pi-session-to-md/.venv/bin/pi-session-to-md")
elif command -v pi-session-to-md >/dev/null 2>&1; then
    CONVERTER=(pi-session-to-md)
elif python3 -c 'import pi_session_to_md' >/dev/null 2>&1; then
    CONVERTER=(python3 -m pi_session_to_md)
else
    die "cannot find pi_session_to_md.py (set PI_SESSION_TO_MD)"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print the session project directories, newest activity first, as:
#   <dir>\t<last-activity>\t<session-count>\t<cwd>
list_dirs() {
    python3 - "$SESSIONS_DIR" <<'PY'
import datetime, glob, json, os, sys

root = os.path.expanduser(sys.argv[1])
rows = []
for d in glob.glob(os.path.join(root, "*")):
    if not os.path.isdir(d):
        continue
    files = [f for f in glob.glob(os.path.join(d, "*.jsonl")) if os.path.isfile(f)]
    if not files:
        continue
    files.sort(key=os.path.getmtime, reverse=True)

    # Prefer the real cwd recorded in the session header over the mangled dir name.
    cwd = ""
    try:
        with open(files[0], encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") == "session" and obj.get("cwd"):
                    cwd = obj["cwd"]
                    break
    except Exception:
        pass
    if not cwd:
        cwd = "/" + os.path.basename(d).strip("-").replace("-", "/")

    rows.append((os.path.getmtime(files[0]), d, len(files), cwd))

rows.sort(key=lambda r: r[0], reverse=True)
for mtime, d, n, cwd in rows:
    ts = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M")
    print("\t".join((d, ts, str(n), cwd)))
PY
}

# Print the session files of one directory, newest first, as:
#   <file>\t<modified>\t<size>\t<first-user-message-preview>
list_files() {
    python3 - "$1" "$SNIPPET" <<'PY'
import datetime, glob, json, os, re, sys

d, snippet_len = sys.argv[1], int(sys.argv[2])
files = [f for f in glob.glob(os.path.join(d, "*.jsonl")) if os.path.isfile(f)]
files.sort(key=os.path.getmtime, reverse=True)

def preview(path):
    if snippet_len <= 0:
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                msg = obj.get("message") or {}
                if obj.get("type") != "message" or msg.get("role") != "user":
                    continue
                content = msg.get("content")
                text = ""
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    text = " ".join(
                        p.get("text", "") for p in content
                        if isinstance(p, dict) and p.get("type") == "text"
                    )
                text = re.sub(r"\s+", " ", text).strip()
                if text:
                    return text[:snippet_len]
                return ""
    except Exception:
        pass
    return ""

def pretty_size(n):
    for unit in ("B", "K", "M", "G"):
        if n < 1024 or unit == "G":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024.0

for f in files:
    ts = datetime.datetime.fromtimestamp(os.path.getmtime(f)).strftime("%Y-%m-%d %H:%M")
    print("\t".join((f, ts, pretty_size(os.path.getsize(f)), preview(f))))
PY
}

# Ask until a valid 1..N selection (or 'q' to quit). Echoes the index on success.
# Returns non-zero on cancel/EOF so callers can bail out (exit would only leave the
# command substitution subshell).
prompt_index() {
    local prompt="$1" count="$2" answer
    while true; do
        read -rp "$prompt" answer || return 130
        case "$answer" in
            q|Q|quit|exit) echo "Cancelled." >&2; return 1 ;;
        esac
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "$count" ]; then
            echo "$answer"
            return 0
        fi
        # Must go to stderr: stdout of this function is captured as the index.
        echo "Please enter a number between 1 and $count (or q to quit)." >&2
    done
}

# Open the freshly written Markdown in an editor (VS Code by default).
# Best-effort: a missing opener is a warning, not a failure.
open_output() {
    local path="$1"
    [ "${PI_MD_OPEN:-1}" = "1" ] || return 0

    local opener="${PI_MD_OPENER:-code}"
    if ! command -v "$opener" >/dev/null 2>&1; then
        echo "pi-md: '$opener' not found, skipping auto-open (set PI_MD_OPENER or PI_MD_OPEN=0)" >&2
        return 0
    fi

    # Foreground on purpose. `code` just hands the request to the already-running
    # VS Code instance and returns, so this is quick. Backgrounding it (even with
    # setsid/nohup) loses the race: this script exits immediately afterwards, the
    # terminal closes, and the child is killed before it can open anything.
    # stdin is /dev/null so the opener can't swallow the rest of your input.
    "$opener" "$path" </dev/null ||
        echo "pi-md: warning: '$opener' exited with status $?" >&2
    return 0
}

# ---------------------------------------------------------------------------
# 1) pick a session project directory
# ---------------------------------------------------------------------------
echo "Pi session projects ($SESSIONS_DIR):"
mapfile -t dir_rows < <(list_dirs)

if [ "${#dir_rows[@]}" -eq 0 ]; then
    die "no session directories with .jsonl files found"
fi

total_dirs="${#dir_rows[@]}"
if [ "$DIR_LIMIT" -gt 0 ] && [ "$total_dirs" -gt "$DIR_LIMIT" ]; then
    dir_rows=("${dir_rows[@]:0:$DIR_LIMIT}")
fi

dir_paths=()
i=1
for row in "${dir_rows[@]}"; do
    IFS=$'\t' read -r dpath dts dcount dcwd <<<"$row"
    dir_paths+=("$dpath")
    if [ "$i" -eq 11 ]; then
        echo
    fi
    printf "  %3d) %s  [%s sessions, last %s]\n" "$i" "$dcwd" "$dcount" "$dts"
    i=$((i + 1))
done
if [ "${#dir_rows[@]}" -lt "$total_dirs" ]; then
    printf "  ... %d more (PI_DIR_LIMIT=%s, use 0 for all)\n" \
        "$((total_dirs - ${#dir_rows[@]}))" "$DIR_LIMIT"
fi
echo

dir_idx="$(prompt_index "Export from which project? " "${#dir_paths[@]}")" || exit 1
SEL_DIR="${dir_paths[dir_idx-1]}"
IFS=$'\t' read -r _ _ _ SEL_CWD <<<"${dir_rows[dir_idx-1]}"

# ---------------------------------------------------------------------------
# 2) pick a session file
# ---------------------------------------------------------------------------
echo
echo "Sessions in $SEL_CWD:"
mapfile -t file_rows < <(list_files "$SEL_DIR")

total_files="${#file_rows[@]}"
if [ "$SESSION_LIMIT" -gt 0 ] && [ "$total_files" -gt "$SESSION_LIMIT" ]; then
    file_rows=("${file_rows[@]:0:$SESSION_LIMIT}")
fi

file_paths=()
i=1
for row in "${file_rows[@]}"; do
    IFS=$'\t' read -r fpath fts fsize fprev <<<"$row"
    file_paths+=("$fpath")
    printf "  %3d) %s  %8s  %s\n" "$i" "$fts" "$fsize" "$fprev"
    i=$((i + 1))
done
if [ "${#file_rows[@]}" -lt "$total_files" ]; then
    printf "  ... %d more (PI_SESSION_LIMIT=%s, use 0 for all)\n" \
        "$((total_files - ${#file_rows[@]}))" "$SESSION_LIMIT"
fi
echo

file_idx="$(prompt_index "Convert which session? " "${#file_paths[@]}")" || exit 1
SEL_FILE="${file_paths[file_idx-1]}"

# ---------------------------------------------------------------------------
# 3) convert
# ---------------------------------------------------------------------------
# Work out the output path. -o/--output from the caller (in any of the forms
# "-o p", "--output p", "--output=p", "-op") means "don't pick one for me";
# "-o -" and PI_MD_STDOUT=1 mean stream to stdout, so there is no file to open.
out_path=""
next_is_out=false
for arg in "$@"; do
    if [ "$next_is_out" = true ]; then
        out_path="$arg"
        next_is_out=false
        continue
    fi
    case "$arg" in
        -o|--output) next_is_out=true ;;
        -o*)         out_path="${arg#-o}" ;;
        --output=*)  out_path="${arg#--output=}" ;;
    esac
done

writes_file=true
if [ "${PI_MD_STDOUT:-0}" = "1" ] || [ "$out_path" = "-" ]; then
    writes_file=false
fi

base="$(basename "${SEL_FILE%.jsonl}")"
stamp="${base%%_*}"                 # 2026-09-21T10-35-23-242Z
stamp="${stamp//T/_}"
stamp="${stamp%%.*}"                # 2026-09-21_10-35-23-242Z
short="${base##*_}"                 # session uuid
short="${short:0:8}"
proj="$(basename "$SEL_CWD")"
proj="${proj//[^A-Za-z0-9._-]/_}"

args=("$SEL_FILE" "${@}")
if [ "$writes_file" = true ] && [ -z "$out_path" ]; then
    mkdir -p "$OUTDIR"
    out_path="$OUTDIR/${proj}_${stamp}_${short}.md"
    args+=(--output "$out_path")
fi

"${CONVERTER[@]}" "${args[@]}"
status=$?

if [ "$status" -ne 0 ]; then
    die "conversion failed (exit $status)"
fi

if [ "$writes_file" = true ]; then
    echo
    echo "Wrote: $out_path"
    open_output "$out_path"
fi
