#!/usr/bin/env bash
# lib/picker.sh - reusable interactive picker for "recent item" scripts.
#
# Sourced by recent.sh (see that file for the user-facing behaviour). It keeps
# the terminal interaction in one place so the VS Code folder list and the xed
# file list share the exact same controls:
#
#   * numbers select items ("3,4,5") and open each one
#   * Shift+number (! @ # ...) opens that item instantly, no Enter needed
#   * letters search the list; each comma/whitespace term opens its best match,
#     matched from right to left so the file/folder name wins
#   * mode keywords (e.g. "xed") switch the caller to another list
#
# Public entry point:
#
#   picker_run ARRAY_NAME HEADER NOUN OPENER...
#
#   ARRAY_NAME  name of the array in the caller holding candidate paths
#   HEADER      title printed above the numbered list
#   NOUN        singular word used in messages ("project", "file")
#   OPENER...   command prefix used to open a path (e.g. `code -n`, `xed`)
#
#   Environment:
#     PICKER_LIMIT     max entries to show (default 20, 0 = no limit)
#     PICKER_KEYWORDS  associative array mapping a typed word -> mode id
#
#   Returns:
#     0  after opening the chosen item(s)
#     1  on EOF / user cancel
#     3  when a keyword was entered (PICKER_MODE holds the target mode id)

# Safe default so picker_run can be used without an explicit keyword map.
declare -A PICKER_KEYWORDS=()

# picker_match QUERY
# Reads candidate paths from stdin (one per line) and prints the best match for
# each whitespace/comma separated term, de-duplicated. Diagnostics go to stderr.
picker_match() {
    python3 -c '
import re, sys

terms = [t for t in re.split(r"[,\s]+", sys.argv[1].lower()) if t]
paths = [line.rstrip("\n") for line in sys.stdin if line.strip()]

seen = set()
for term in terms:
    best = None
    best_score = None
    for path in paths:
        hay = path.lower()
        idx = hay.rfind(term)          # rightmost occurrence
        if idx == -1:
            continue
        # Fewer characters after the match wins; shorter path breaks ties.
        score = (len(hay) - (idx + len(term)), len(hay))
        if best_score is None or score < best_score:
            best_score = score
            best = path
    if best is None:
        print("No match for: %s" % term, file=sys.stderr)
    elif best not in seen:
        seen.add(best)
        print(best)
' "$1"
}

# picker_render HEADER ENTRIES...
# Numbered list; a blank line separates the first 10 entries from the rest.
picker_render() {
    local header="$1"; shift
    local i=1 entry
    echo "$header"
    for entry in "$@"; do
        if [ "$i" -eq 11 ]; then
            echo
        fi
        printf "  %2d) %s\n" "$i" "$entry"
        i=$((i + 1))
    done
    echo
}

picker_run() {
    local array_name="$1" header="$2" noun="$3"; shift 3
    local -n picker_entries="$array_name"
    local -a opener=("$@")

    # Clip to the display limit without disturbing the caller's full list.
    local limit="${PICKER_LIMIT:-20}"
    local -a entries
    if [ "$limit" -gt 0 ] && [ "${#picker_entries[@]}" -gt "$limit" ]; then
        entries=("${picker_entries[@]:0:$limit}")
    else
        entries=("${picker_entries[@]}")
    fi

    if [ "${#entries[@]}" -eq 0 ]; then
        echo "$header"
        echo "  (none found)"
        echo
    else
        picker_render "$header" "${entries[@]}"
    fi

    # Advertise any words that switch to a different list.
    if [ "${#PICKER_KEYWORDS[@]}" -gt 0 ]; then
        local words
        words="$(printf '%s\n' "${!PICKER_KEYWORDS[@]}" | sort | paste -sd',' - | sed 's/,/, /g')"
        echo "Type $words to switch lists."
    fi

    while true; do
        printf "Open which %s(s)? (e.g. 3,4,5, or Shift+number for instant open) " "$noun"
        local first rest choice instant
        if ! IFS= read -rn1 first; then
            printf '\n'
            return 1
        fi
        # Ctrl-D / end of input: leave quietly instead of looping forever.
        if [ "$first" = $'\004' ]; then
            printf '\n'
            return 1
        fi

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
            # Otherwise read the rest of the line (digits, commas, spaces, text).
            IFS= read -r rest || rest=""
            printf '\n'
            choice="${first}${rest}"
        fi

        # Empty input: just ask again.
        if [ -z "$choice" ]; then
            continue
        fi

        # Mode keyword (exact, case-insensitive) - hand control back to caller.
        local word
        word="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        if [ -n "$word" ] && [ -n "${PICKER_KEYWORDS[$word]+x}" ]; then
            PICKER_MODE="${PICKER_KEYWORDS[$word]}"
            PICKER_WORD="$word"
            return 3
        fi

        # Letters without digits enter search mode instead: split the query on
        # whitespace and/or commas, then open the best match for each term.
        if [[ "$choice" =~ [[:alpha:]] && ! "$choice" =~ [0-9] ]]; then
            local -a selected=()
            local match
            while IFS= read -r match; do
                [ -n "$match" ] && selected+=("$match")
            done < <(printf '%s\n' "${entries[@]}" | picker_match "$choice")
            if [ "${#selected[@]}" -eq 0 ]; then
                echo "No $noun matches: $choice - try again."
                continue
            fi
            for match in "${selected[@]}"; do
                echo "Opening: $match"
                "${opener[@]}" "$match"
            done
            return 0
        fi

        # Accept one or more numbers separated by commas and/or spaces.
        local -a picked=()
        local n invalid=""
        for n in ${choice//,/ }; do
            if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#entries[@]}" ]; then
                echo "Invalid selection: $n - try again."
                invalid=1
                break
            fi
            picked+=("${entries[n-1]}")
        done
        if [ -n "$invalid" ]; then
            continue
        fi
        if [ "${#picked[@]}" -eq 0 ]; then
            echo "No selection - try again."
            continue
        fi

        for match in "${picked[@]}"; do
            "${opener[@]}" "$match"
        done
        return 0
    done
}
