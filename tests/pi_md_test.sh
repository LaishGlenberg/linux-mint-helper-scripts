#!/usr/bin/env bash
# Integration tests for pi-md.sh, focused on the -c/--cron auto-delete flag.
#
# Runs the real script under a pseudo-terminal (util-linux `script`) with a fake
# session tree, a stubbed converter, crontab, and date, then asserts what got
# written to the (fake) crontab and what was forwarded to the converter.
#
# Usage: tests/pi_md_test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_MD="$ROOT/pi-md.sh"

if ! command -v script >/dev/null 2>&1; then
    echo "SKIP: util-linux 'script' is required for these tests"
    exit 0
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/home/.pi/agent/sessions/-home-lg-proj" "$T/bin" "$T/out"
SESS="$T/home/.pi/agent/sessions/-home-lg-proj/2024-01-01T00-00-00-000Z_abcdefgh-1234.jsonl"
cat >"$SESS" <<'EOF'
{"type":"session","cwd":"/home/lg/proj"}
{"type":"message","message":{"role":"user","content":"hello world"}}
EOF

# Fake converter: records one arg per line and writes the requested --output.
cat >"$T/bin/convert" <<'EOF'
#!/usr/bin/env bash
{ for a in "$@"; do printf '%s\n' "$a"; done; } >>"$CONVERT_LOG"
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in --output) out="$2"; shift ;; esac
    shift
done
[ -n "$out" ] && { mkdir -p "$(dirname "$out")"; echo "# md" >"$out"; }
exit 0
EOF

# Fake crontab: `-l` prints the store, anything else replaces it from stdin.
# Buffer stdin before replacing so the store is never truncated while `-l` in
# the same pipeline is still reading it (real crontab is atomic; this mimics it).
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -l) [ -f "$CRON_FILE" ] && cat "$CRON_FILE" || exit 1 ;;
    *)  tmp="$(mktemp)"; cat >"$tmp"; mv "$tmp" "$CRON_FILE" ;;
esac
EOF

# Fake date: deterministic clock so assertions can pin the scheduled minute.
cat >"$T/bin/date" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"+10 minutes"*) echo "05 12 01 01" ;;
    *"+15 minutes"*) echo "10 13 02 02" ;;
    *"+3 minutes"*)  echo "59 23 31 12" ;;
    *"+%s"*)         echo "1700000000" ;;
    *)               echo "" ;;
esac
EOF
chmod +x "$T/bin/convert" "$T/bin/crontab" "$T/bin/date"

# run <input> [pi-md args...] -> fills CRON, CONVERT_ARGS, OUT_FILE, RUN_STATUS
# CONVERT_ARGS is the converter argv joined with '|' and wrapped in '|' so exact
# token checks are possible (e.g. "|-c|").
run() {
    local input="$1"; shift
    : >"$T/crontab"
    : >"$T/convert.log"
    rm -rf "$T/out"; mkdir -p "$T/out"
    printf '%s' "$input" | \
        HOME="$T/home" PATH="$T/bin:$PATH" \
        PI_SESSION_TO_MD="$T/bin/convert" \
        PI_MD_OUTDIR="$T/out" PI_MD_OPEN=0 \
        CRON_FILE="$T/crontab" CONVERT_LOG="$T/convert.log" \
        script -q -e -c "bash '$PI_MD' $*" /dev/null >/dev/null 2>&1
    RUN_STATUS=$?
    CRON="$(cat "$T/crontab")"
    CONVERT_ARGS="|$(tr '\n' '|' <"$T/convert.log")"
    OUT_FILE="$(ls "$T/out"/*.md 2>/dev/null | head -1 || true)"
}

pass=0
fail=0
ok()  { echo "ok   - $1"; pass=$((pass + 1)); }
bad() { echo "FAIL - $1"; echo "       $2"; fail=$((fail + 1)); }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "'$3' not found in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "'$3' unexpectedly present in: $2" ;; *) ok "$1" ;; esac; }

SELECT=$'1\n1\n'

# 1) `-c` with no value uses the 10 minute default and installs one entry.
run "$SELECT" -c
has "default -c schedules the 10 minute slot" "$CRON" "05 12 01 01 * "
has "cron command removes the file" "$CRON" "rm -f -- '$OUT_FILE'"
has "cron command cleans up after itself" "$CRON" "grep -vF 'pi-md-expire-"
has "cron cleanup survives a failed crontab -l" "$CRON" "crontab -l >"
has "converter ran on the selected session" "$CONVERT_ARGS" "|$SESS|"
hasnt "-c is not forwarded to the converter" "$CONVERT_ARGS" "|-c|"

# 2) `--cron 15` schedules the explicit minute and is consumed.
run "$SELECT" --cron 15
has "explicit --cron 15 schedules the 15 minute slot" "$CRON" "10 13 02 02 * "
hasnt "--cron is not forwarded to the converter" "$CONVERT_ARGS" "|--cron|"
hasnt "the 15 value is not forwarded to the converter" "$CONVERT_ARGS" "|15|"

# 3) Attached forms parse too.
run "$SELECT" -c15
has "-c15 schedules the 15 minute slot" "$CRON" "10 13 02 02 * "
run "$SELECT" --cron=3
has "--cron=3 schedules the 3 minute slot" "$CRON" "59 23 31 12 * "

# 4) Without the flag nothing is scheduled, and other args pass through.
run "$SELECT" --no-thinking
has "no -c leaves the crontab empty" "$CRON" ""
has "other flags reach the converter" "$CONVERT_ARGS" "|--no-thinking|"

# 5) -c combined with other flags still strips only the cron flags.
run "$SELECT" --timestamps -c 15
has "flags plus cron: slot scheduled" "$CRON" "10 13 02 02 * "
has "flags plus cron: flag forwarded" "$CONVERT_ARGS" "|--timestamps|"
hasnt "flags plus cron: cron not forwarded" "$CONVERT_ARGS" "|-c|"
hasnt "flags plus cron: value not forwarded" "$CONVERT_ARGS" "|15|"

# 6) Streaming to stdout leaves no file, so --cron is a no-op (with a warning).
run "$SELECT" -c -o -
if [ -z "$CRON" ] && [ "$RUN_STATUS" -eq 0 ]; then
    ok "stdout mode writes no file and schedules nothing"
else
    bad "stdout mode writes no file and schedules nothing" "cron='$CRON' status=$RUN_STATUS"
fi

# 7) A non-numeric value is rejected before the picker runs.
run "$SELECT" -c abc
if [ "$RUN_STATUS" -ne 0 ] && [ -z "$CRON" ] && [ "$CONVERT_ARGS" = "|" ]; then
    ok "invalid -c value is rejected before conversion"
else
    bad "invalid -c value is rejected before conversion" "status=$RUN_STATUS cron='$CRON' args='$CONVERT_ARGS'"
fi

# 8) Run the scheduled command the way cron would: the file goes away and the
#    entry removes itself without touching unrelated crontab lines.
run "$SELECT" -c
printf '# keep me\n%s\n' "$CRON" >"$T/crontab"
cmd="${CRON#* * * * * }"
PATH="$T/bin:$PATH" CRON_FILE="$T/crontab" sh -c "$cmd"
CRON_AFTER="$(cat "$T/crontab")"
if [ ! -e "$OUT_FILE" ]; then ok "cron run deletes the exported file";
else bad "cron run deletes the exported file" "$OUT_FILE still exists"; fi
if [ "$CRON_AFTER" = "# keep me" ]; then ok "cron run removes only its own entry";
else bad "cron run removes only its own entry" "crontab is now: $CRON_AFTER"; fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
