# scripts

Small personal helper scripts for this machine (`/home/lg`).

| Script | What it does |
| --- | --- |
| `pi-md.sh` | Interactive picker: choose a pi session project + session, export it to Markdown via `pi-session-to-md`. |
| `recent.sh` | Interactive picker: choose one or more recent VS Code folders (e.g. `3,4,5`) and open them in new windows. |
| `autohide.sh` | Autohide helper (see file header). |

## pi-md.sh

Turns a pi session log into readable Markdown without hunting for the file path.

It lists the session project directories under `~/.pi/agent/sessions` (newest
activity first, numbered, showing the real `cwd` and session count), asks which
one you want, then lists that project's `.jsonl` sessions (date, size, and a
preview of the first user message), and feeds your choice to
`pi-session-to-md`.

Both lists are always sorted newest-first and trimmed to a limit, so the most
relevant entries are the ones you see. The default is **5 project directories**
and **5 sessions**; raise the limits (or set them to `0` for no limit) to reach
older entries. When a list is trimmed you get a `... N more` hint telling you how
many were hidden.

### Usage

```bash
pi-md.sh                      # interactive (5 newest dirs, 5 newest sessions)
pi-md.sh --no-thinking        # extra flags are forwarded to pi-session-to-md
pi-md.sh --timestamps --include-bash
pi-md.sh -o /tmp/transcript.md
PI_MD_OPEN=0 pi-md.sh          # don't open VS Code afterwards
PI_DIR_LIMIT=10 PI_SESSION_LIMIT=20 pi-md.sh   # wider lists
PI_DIR_LIMIT=0 pi-md.sh       # 0 = list everything
./pi-md.sh --help
```

By default the Markdown is written next to you (current directory) as
`<project>_<session-date>_<session-id>.md` **and opened in VS Code**, so you can
read or preview it right away. Pass `-o/--output` to choose a path yourself (it
gets opened too), or set `PI_MD_STDOUT=1` / `-o -` to stream to stdout (nothing
is opened).

Turn the editor off with `PI_MD_OPEN=0`, or point it elsewhere with
`PI_MD_OPENER` (anything on `PATH`, e.g. `PI_MD_OPENER=codium`,
`PI_MD_OPENER=code-insiders`, `PI_MD_OPENER=xdg-open`). A missing opener only
warns; the Markdown is still written.

Type `q` at either prompt to cancel.

### Options

All arguments are forwarded to `pi_session_to_md.py` (`--no-thinking`,
`--mode branch`, `--leaf`, `--include-bash`, `--timestamps`,
`--no-group-turns`, `-o/--output`). Its full help:

```bash
python3 ~/pi-session-to-md/pi_session_to_md.py --help
```

### Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `PI_SESSIONS_DIR` | `~/.pi/agent/sessions` | Session root to browse. |
| `PI_DIR_LIMIT` | `5` | How many project directories to list; `0` = all. |
| `PI_SESSION_LIMIT` | `5` | How many sessions to list per project; `0` = all. |
| `PI_SESSION_TO_MD` | auto-detected | Converter script (`.py`) or binary to run. |
| `PI_MD_OUTDIR` | current directory | Where the default `.md` file is written. |
| `PI_MD_STDOUT` | `0` | `1` = print Markdown to stdout instead of writing a file. |
| `PI_MD_SNIPPET` | `60` | Preview length (chars) for session entries; `0` disables. |
| `PI_MD_OPEN` | `1` | Open the written `.md` when done; `0` = don't. |
| `PI_MD_OPENER` | `code` | Editor command used to open it. |

Limits must be non-negative integers; anything else is rejected with a clear
error before any listing happens.

The converter is looked up in this order: `$PI_SESSION_TO_MD`, then
`~/pi-session-to-md/pi_session_to_md.py`, then the repo's
`.venv/bin/pi-session-to-md`, then `pi-session-to-md` on `PATH`, then
`python3 -m pi_session_to_md`.

### Notes

- Prompting works in any terminal; if started without a TTY (e.g. a keyboard
  shortcut) the script relaunches itself in the first available terminal
  emulator.
- Auto-open runs the opener in the foreground. `code` only hands the request to
  the already-running VS Code instance and returns (verified ~1s), so it does not
  hold the script up. This is deliberate: backgrounding the opener loses a race,
  because the picker exits immediately and the closing terminal kills the child
  before it can open anything.
- Session directories are ordered by their most recently modified `.jsonl`, so
  active projects appear first; sessions are ordered the same way. When a list is
  longer than its limit, the first 10 shown are separated from a longer run by a
  blank line.
