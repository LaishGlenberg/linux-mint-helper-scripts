#!/usr/bin/env bash
# Integration tests for recent.sh (search mode + numeric selection).
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

pass=0
fail=0

# run <input> -> populates $OUT with the recorded `code` invocations
run() {
    : >"$T/code.log"
    printf '%s' "$1" | HOME="$T" PATH="$T/bin:$PATH" CODE_LOG="$T/code.log" \
        script -q -e -c "bash '$RECENT'" /dev/null >/dev/null 2>&1 || true
    OUT="$(tr '\n' '|' <"$T/code.log")"
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
# Search: no match opens nothing.
check "search with no match is a no-op" \
    "" \
    $'zzz\n'
# Numeric selection still works, one or many.
check "single numeric selection" \
    "-n /home/lg/scripts-backup|" \
    $'3\n'
check "multiple numeric selection" \
    "-n /home/lg/scripts|-n /home/lg/proj/api/src|" \
    $'5,1\n'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
