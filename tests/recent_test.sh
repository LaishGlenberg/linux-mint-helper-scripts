#!/usr/bin/env bash
# Integration tests for recent.sh (search mode + numeric selection + xed
# create-on-miss).
#
# Runs the real script under a pseudo-terminal (util-linux `script`) with a
# temporary fake workspaceStorage and a stubbed `code` binary, then asserts
# which folder(s) would have been opened.
#
# Usage: tests/recent_test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECENT="$ROOT/recent.sh"

if ! command -v script >/dev/null 2>&1; then
    echo "SKIP: util-linux 'script' is required for these tests"
    exit 0
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/.config/Code/User/workspaceStorage" "$T/bin"
cat >"$T/bin/code" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CODE_LOG"
EOF
chmod +x "$T/bin/code"
cat >"$T/bin/xed" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$XED_LOG"
EOF
chmod +x "$T/bin/xed"

# add_folder <hash> <path> <day>  (later day = more recent)
add_folder() {
    local dir="$T/.config/Code/User/workspaceStorage/$1"
    mkdir -p "$dir"
    printf '{"folder":"file://%s"}\n' "$2" >"$dir/workspace.json"
    touch -d "2024-01-0$3" "$dir"
}

add_folder aaaa /home/lg/scripts 1
add_folder bbbb /home/lg/old/scripts 2
add_folder cccc /home/lg/scripts-backup 3
add_folder dddd /home/lg/proj/src/api 4
add_folder eeee /home/lg/proj/api/src 5

# Fake GTK recent list. Newest-first order is by the xed `modified` stamp; the
# gedit-only bookmark is deliberately the newest so a bad filter would show up
# as the wrong first entry. group-only.txt has no <application> element and is
# included through its <group> instead.
mkdir -p "$T/.local/share"
cat >"$T/.local/share/recently-used.xbel" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<xbel version="1.0"
      xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks"
      xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info">
  <bookmark href="file:///home/lg/mixed/xed-not-really.txt" added="2024-01-10T00:00:00Z" modified="2024-01-10T00:00:00Z" visited="2024-01-10T00:00:00Z">
    <info>
      <metadata owner="http://freedesktop.org">
        <mime:mime-type type="text/plain"/>
        <bookmark:groups>
          <bookmark:group>gedit</bookmark:group>
        </bookmark:groups>
        <bookmark:applications>
          <bookmark:application name="gedit" exec="gedit %u" modified="2024-01-10T00:00:00Z" count="1"/>
        </bookmark:applications>
      </metadata>
    </info>
  </bookmark>
  <bookmark href="file:///home/lg/work/group-only.txt" added="2024-01-06T00:00:00Z" modified="2024-01-06T00:00:00Z" visited="2024-01-06T00:00:00Z">
    <info>
      <metadata owner="http://freedesktop.org">
        <mime:mime-type type="text/plain"/>
        <bookmark:groups>
          <bookmark:group>xed</bookmark:group>
        </bookmark:groups>
      </metadata>
    </info>
  </bookmark>
  <bookmark href="file:///home/lg/work/notes.txt" added="2024-01-05T00:00:00Z" modified="2024-01-05T00:00:00Z" visited="2024-01-05T00:00:00Z">
    <info>
      <metadata owner="http://freedesktop.org">
        <mime:mime-type type="text/plain"/>
        <bookmark:applications>
          <bookmark:application name="xed" exec="xed %u" modified="2024-01-05T00:00:00Z" count="3"/>
        </bookmark:applications>
      </metadata>
    </info>
  </bookmark>
  <bookmark href="file:///home/lg/work/notes-old.txt" added="2024-01-04T00:00:00Z" modified="2024-01-04T00:00:00Z" visited="2024-01-04T00:00:00Z">
    <info>
      <metadata owner="http://freedesktop.org">
        <mime:mime-type type="text/plain"/>
        <bookmark:applications>
          <bookmark:application name="xed" exec="xed %u" modified="2024-01-04T00:00:00Z" count="1"/>
        </bookmark:applications>
      </metadata>
    </info>
  </bookmark>
  <bookmark href="file:///home/lg/misc/readme.md" added="2024-01-03T00:00:00Z" modified="2024-01-03T00:00:00Z" visited="2024-01-03T00:00:00Z">
    <info>
      <metadata owner="http://freedesktop.org">
        <mime:mime-type type="text/plain"/>
        <bookmark:applications>
          <bookmark:application name="xed" exec="xed %u" modified="2024-01-03T00:00:00Z" count="1"/>
        </bookmark:applications>
      </metadata>
    </info>
  </bookmark>
</xbel>
EOF

pass=0
fail=0

# run <input> -> populates $OUT with the recorded `code` invocations
#
# Input lines are fed one at a time with a short pause. `script` injects an EOF
# character as soon as its own stdin closes, which can otherwise land in front
# of buffered retry input and defeat the retry tests.
run() {
    : >"$T/code.log"
    : >"$T/xed.log"
    {
        while IFS= read -r line; do
            printf '%s\n' "$line"
            sleep 0.3
        done < <(printf '%s' "$1")
    } | HOME="$T" PATH="$T/bin:$PATH" CODE_LOG="$T/code.log" XED_LOG="$T/xed.log" \
        RECENT_DOCUMENTS="$T/Documents" \
        script -q -e -c "bash '$RECENT'" /dev/null >/dev/null 2>&1 || true
    OUT="$(tr '\n' '|' <"$T/code.log")"
    XOUT="$(tr '\n' '|' <"$T/xed.log")"
}

check() { # <name> <expected> <input>
    run "$3"
    if [ "$OUT" = "$2" ]; then
        echo "ok   - $1"
        pass=$((pass + 1))
    else
        echo "FAIL - $1"
        echo "       expected: $2"
        echo "       actual:   $OUT"
        fail=$((fail + 1))
    fi
}

check_xed() { # <name> <expected> <input>  (asserts the xed log instead)
    run "$3"
    if [ "$XOUT" = "$2" ]; then
        echo "ok   - $1"
        pass=$((pass + 1))
    else
        echo "FAIL - $1"
        echo "       expected: $2"
        echo "       actual:   $XOUT"
        fail=$((fail + 1))
    fi
}

check_exists() { # <name> <path>  (asserts the path was created)
    if [ -f "$2" ]; then
        echo "ok   - $1"
        pass=$((pass + 1))
    else
        echo "FAIL - $1"
        echo "       expected file: $2"
        fail=$((fail + 1))
    fi
}

check_absent() { # <name> <path>  (asserts the path was NOT created)
    if [ ! -e "$2" ]; then
        echo "ok   - $1"
        pass=$((pass + 1))
    else
        echo "FAIL - $1"
        echo "       unexpected file: $2"
        fail=$((fail + 1))
    fi
}

# Search: rightmost (folder-name) match wins, even against an older path.
check "search picks match closest to end" \
    "-n /home/lg/scripts|" \
    $'scripts\n'
# Search: each term opens its own best match (space- or comma-separated).
check "multi-term search opens each best match (spaces)" \
    "-n /home/lg/scripts|-n /home/lg/proj/src/api|" \
    $'scripts api\n'
check "multi-term search opens each best match (commas)" \
    "-n /home/lg/scripts|-n /home/lg/proj/src/api|" \
    $'scripts,api\n'
# Search: the same project matched by two terms only opens once.
check "multi-term search de-duplicates projects" \
    "-n /home/lg/scripts|" \
    $'scripts,scripts\n'
# Search: an unmatched term is skipped, the rest still open.
check "unmatched term is skipped" \
    "-n /home/lg/scripts|" \
    $'scripts zzz\n'
# Search: a failed search asks again instead of exiting - the retry opens.
check "failed search retries" \
    "-n /home/lg/scripts|" \
    $'zzz\nscripts\n'
# An invalid number also asks again rather than forcing a close.
check "invalid selection retries" \
    "-n /home/lg/proj/api/src|" \
    $'99\n1\n'
# End of input after a failed search exits instead of hanging.
check "end of input exits quietly" \
    "" \
    $'zzz\n'
# Numeric selection still works, one or many.
check "single numeric selection" \
    "-n /home/lg/scripts-backup|" \
    $'3\n'
check "multiple numeric selection" \
    "-n /home/lg/scripts|-n /home/lg/proj/api/src|" \
    $'5,1\n'

# --- xed mode -------------------------------------------------------------
# Typing a keyword switches lists; the same numbering/search controls apply.
check_xed "xed keyword switches mode and selects by number" \
    "/home/lg/work/notes.txt|" \
    $'xed\n2\n'
check_xed "notepad keyword alias" \
    "/home/lg/work/group-only.txt|" \
    $'notepad\n1\n'
check_xed "note keyword alias" \
    "/home/lg/work/group-only.txt|" \
    $'note\n1\n'
# Only four xed entries exist; index 4 proves the gedit bookmark is ignored.
check_xed "xed list excludes other apps" \
    "/home/lg/misc/readme.md|" \
    $'xed\n4\n'
check_xed "xed search picks match closest to end" \
    "/home/lg/work/notes.txt|" \
    $'xed\nnotes\n'
check_xed "xed multi-term search opens each best match" \
    "/home/lg/work/notes.txt|/home/lg/misc/readme.md|" \
    $'xed\nnotes,readme\n'
check_xed "xed instant shift+number" \
    "/home/lg/work/notes.txt|" \
    $'xed\n@\n'
check_xed "xed invalid selection retries" \
    "/home/lg/work/notes.txt|" \
    $'xed\n99\n2\n'
# Switch back to VS Code mode with a keyword of its own.
check "code keyword switches back to VS Code" \
    "-n /home/lg/proj/api/src|" \
    $'xed\ncode\n1\n'

# --- xed mode: create a brand new file on a miss --------------------------
# An unmatched name in xed mode is offered for creation in Documents; a .txt
# extension is appended and xed opens the new path.
check_xed "xed miss offers to create a .txt file" \
    "$T/Documents/newfile.txt|" \
    $'xed\nnewfile\ny\n'
check_exists "created .txt file is on disk" "$T/Documents/newfile.txt"

# Enter (the empty answer) also means yes.
check_xed "xed creation accepts Enter as yes" \
    "$T/Documents/enter-name.txt|" \
    $'xed\nenter-name\n\n'
check_exists "Enter-created file is on disk" "$T/Documents/enter-name.txt"

# The long form "yes" works and an explicit extension is preserved.
check_xed "xed creation accepts yes and keeps extension" \
    "$T/Documents/journal.md|" \
    $'xed\njournal.md\nyes\n'
check_exists "yes-created file is on disk" "$T/Documents/journal.md"

# Declining returns to the prompt without creating anything.
check_xed "xed creation declined returns to prompt" \
    "/home/lg/work/group-only.txt|" \
    $'xed\ndeclined-file\nno\n1\n'
check_absent "declined file is not created" "$T/Documents/declined-file.txt"

# A search that matches must not offer to create anything.
check_absent "matched search creates no new file" "$T/Documents/notes.txt"

# VS Code mode keeps retrying and never creates folders/files.
check "vscode miss does not create" "" $'zzz\n'
check_absent "vscode cannot create files" "$T/Documents/zzz.txt"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
