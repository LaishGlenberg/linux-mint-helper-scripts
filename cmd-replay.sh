#!/usr/bin/env bash
# cmd-replay.sh - replay a list of shell commands with timed pauses and screen
# clears. Made for recording README demos: start your recorder, run this, stop
# the recorder, and the same demo comes out every time.
#
#   ./cmd-replay.sh demo.script
#   ./cmd-replay.sh --pace 3 -w 45 demo.script
#   printf 'ls\n@sleep 1\npwd\n' | ./cmd-replay.sh -
#
# This only drives the terminal, it does not encode anything: pair it with a
# screen recorder (ScreenToGif on Windows, or VHS if you want the gif
# re-renderable from source).
#
# Requires bash 4+ (mapfile) and bash 5+ for --pace ($EPOCHREALTIME). Works in
# Git Bash on Windows too.

set -uo pipefail

pause=2          # seconds after each command
pace=''          # if set, per-step time budget instead of a fixed pause
type_ms=0        # 0 = print commands instantly, >0 = type them out
clear=1          # clear between steps
stop_on_error=0
prompt='$ '

die() { printf 'cmd-replay.sh: %s\n' "$*" >&2; exit 2; }

is_num() { awk -v x="$1" 'BEGIN { exit !(x ~ /^[0-9]+([.][0-9]+)?$/) }'; }

usage() {
    cat <<'EOF'
cmd-replay.sh - replay commands with timed pauses and screen clears

usage: cmd-replay.sh [options] [SCRIPT]

  SCRIPT               file of commands, one per line ('-' or omitted = stdin)

options:
  -p, --pause SEC      seconds to wait after each command (default 2)
      --pace SEC       instead of a fixed pause, give each step a SEC budget:
                       wait only for the time the command itself didn't use
  -w, --type MS        type each command out at MS milliseconds per char
  -C, --no-clear       don't clear the screen between commands
  -e, --stop-on-error  stop if a command exits non-zero
  -h, --help           this help

script syntax:
  some command         run it (eval'd, so pipes, &&, cd and export persist --
                       note `exit` therefore ends the replay)
  @sleep SEC           wait SEC extra seconds, leaving the screen as it is
  @pause SEC           override the pause after the command above it
  # comment            ignored (blank lines too)

notes:
  no pause is added after the last command. Put a trailing `@sleep SEC` in the
  script if you want the final screen to linger. The exit status is that of the
  last command that failed (0 if none did).

examples:
  ./cmd-replay.sh demo.script
  ./cmd-replay.sh --pace 3 -w 45 demo.script
  printf 'ls\n@sleep 1\npwd\n' | ./cmd-replay.sh -
  ./cmd-replay.sh -C <<'EOS'
  git status --short
  git log --oneline -5
  EOS
EOF
}

# ---- args ----------------------------------------------------------------
while (($#)); do
    case $1 in
        -p|--pause)
            [ $# -ge 2 ] || die "$1 needs a value"
            is_num "$2" || die "$1 needs a number of seconds, got '$2'"
            pause=$2; shift 2
            ;;
        --pace)
            [ $# -ge 2 ] || die "--pace needs a value"
            is_num "$2" || die "--pace needs a number of seconds, got '$2'"
            pace=$2; shift 2
            ;;
        -w|--type)
            [ $# -ge 2 ] || die "$1 needs a value"
            is_num "$2" || die "$1 needs milliseconds per char, got '$2'"
            type_ms=$2; shift 2
            ;;
        -C|--no-clear)      clear=0; shift ;;
        -e|--stop-on-error) stop_on_error=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        -|-)                break ;;
        --)                 shift; break ;;
        -*)                 die "unknown option '$1' (try --help)" ;;
        *)                  break ;;
    esac
done

[ $# -gt 1 ] && die "expected one script, got $#"
src=${1:-}

if [ -z "$src" ] || [ "$src" = "-" ]; then
    [ -t 0 ] && die "no script given and stdin is a terminal (try --help)"
    mapfile -t lines
else
    [ -f "$src" ] || die "no such file: $src"
    mapfile -t lines < "$src"
fi

cls() { ((clear)) && printf '\033[2J\033[3J\033[H'; }

# Typing one char per sleep means one process spawn per char. That is harmless
# on Linux, but Git Bash (MSYS) falls over when it forks hundreds of times in a
# few seconds ("dofork: child died unexpectedly"), so type in chunks and cap
# spawns per line. The per-chunk delay keeps the apparent speed identical.
max_frames=40

emit() { # print "$ prompt + command", optionally typed out
    local s=$1 n i step ms d
    n=${#s}
    if ((type_ms <= 0 || n == 0)); then
        printf '%s%s\n' "$prompt" "$s"
        return
    fi
    step=$(((n + max_frames - 1) / max_frames))
    ms=$((step * type_ms))
    d=$(printf '%d.%03d' $((ms / 1000)) $((ms % 1000)))
    printf '%s' "$prompt"
    for ((i = 0; i < n; i += step)); do
        printf '%s' "${s:i:step}"
        sleep "$d"
    done
    printf '\n'
}

# ---- parse the script into parallel arrays --------------------------------
cmds=()        # command to run
pre_sleep=()   # extra wait before this command (@sleep)
post_pause=()  # pause after this command overriding the default (@pause)

pending_sleep=0
for raw in ${lines[@]+"${lines[@]}"}; do
    line=${raw%$'\r'}                       # tolerate CRLF
    line=${line#"${line%%[![:space:]]*}"}   # ltrim
    line=${line%"${line##*[![:space:]]}"}   # rtrim
    [ -z "$line" ] && continue
    case $line in \#*) continue ;; esac

    case $line in
        '@sleep '*|'@wait '*)
            secs=${line#* }
            is_num "$secs" || die "@sleep needs a number of seconds, got '$secs'"
            pending_sleep=$secs
            continue
            ;;
        '@pause '*)
            secs=${line#* }
            is_num "$secs" || die "@pause needs a number of seconds, got '$secs'"
            # applies to the gap after the command above it, hence the last one
            [ ${#cmds[@]} -gt 0 ] && post_pause[$((${#cmds[@]} - 1))]=$secs
            continue
            ;;
    esac

    cmds+=("$line")
    pre_sleep+=("$pending_sleep")
    post_pause+=('')
    pending_sleep=0
done

# ---- replay ---------------------------------------------------------------
last=$((${#cmds[@]} - 1))
final_rc=0
for ((i = 0; i <= last; i++)); do
    # wait before clearing, so the previous output stays on screen meanwhile
    [ "${pre_sleep[i]}" != 0 ] && sleep "${pre_sleep[i]}"

    ((i == 0)) || cls

    emit "${cmds[i]}"

    start=$EPOCHREALTIME
    eval "${cmds[i]}"
    rc=$?
    end=$EPOCHREALTIME

    if ((rc != 0)); then
        printf '\033[31m[exit %s]\033[0m\n' "$rc"
        final_rc=$rc
        ((stop_on_error)) && exit "$rc"
    fi

    ((i == last)) && break   # nothing to wait for after the final command

    if [ -n "${post_pause[i]}" ]; then
        wait_for=${post_pause[i]}
    elif [ -n "$pace" ]; then
        elapsed=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.3f", b - a }')
        wait_for=$(awk -v p="$pace" -v d="$elapsed" \
            'BEGIN { x = p - d; if (x < 0) x = 0; printf "%.3f", x }')
    else
        wait_for=$pause
    fi

    sleep "$wait_for"
done

# a trailing @sleep is a deliberate hold on the final screen
if [ "$pending_sleep" != 0 ]; then
    sleep "$pending_sleep"
fi

# report the last failure even when -e is off, so callers notice
exit "$final_rc"
