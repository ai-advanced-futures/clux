#!/usr/bin/env bash
# terminal.sh — the companion terminal. One private directory per Claude
# session, driving a known interactive Bash through tmux. A pane owner (in
# tmux) has a directory keyed by tmux server and owner pane. A session owner
# (a Claude Code session with no tmux pane) has a directory keyed by the
# first 8 characters of its session id.
#
# TWO poll loops here run every 0.2 s for the whole of a command's timeout
# (wait_for_prompt, wait_for_run_files). Everything they touch is therefore
# written fork-free, except the Laya pane probe on each fifth step, and the
# two caches below exist for them. wait --pattern polls each 1 s, because
# each change of the screen goes through the Laya output guard:
#
#   1. The pattern files are parsed ONCE per process into two joined EREs
#      (_load_patterns). A boolean "does any pattern match" answer is the same
#      whether the patterns run one at a time or joined with `|`, so joining
#      turns one grep per pattern plus one sed per pattern-file line into ONE
#      grep per kind. @clux-terminal-patterns is read once (_load_user_patterns)
#      because it cannot change inside one invocation.
#   2. The state file is read ONCE into S_MODE/S_PANE/S_SOCKET/S_SEQ
#      (state_load). Every tmux call needs mode and socket, so reading them per
#      call cost a sed pipeline each time. state_load is the ONLY reader and
#      write_state the ONLY writer, so the file format lives in two places.
#      One exception: seq_now reads the seq again (through state_load), as
#      another verb can start a run while a wait loop runs.
#
# Prefer parameter expansion over sed/cut/basename throughout — path.sh made the
# same move for the same reason and documents it at length.

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
SHIPPED_PATTERNS="$SCRIPT_DIR/../config/credential-patterns.txt"
source "$SCRIPT_DIR/path.sh"

# Laya (spec 2026-09-28-clux-companion-laya-guard-design.md). laya_client.py
# is the only code that speaks to Laya. The venv is not in the plugin cache,
# because a plugin update deletes the cache.
LAYA_CLIENT="$SCRIPT_DIR/laya_client.py"
LAYA_VERSION=0.3.21
LAYA_VENV="${XDG_DATA_HOME:-$HOME/.local/share}/clux/laya"
LAYA_MARKER="$LAYA_VENV/.clux-installed"
LAYA_PY="${CLUX_LAYA_PYTHON:-$LAYA_VENV/bin/python3}"

# The time budget of run. The sum of the gate with its retry (11 s), the
# prompt wait (2 s), the clear (5 s), this run limit, the last pane probe
# (11 s), the report grace (1 s), one late SECONDS tick (1 s) and the guard
# limit stays 10 s under the 120 s limit of the Bash tool. test/terminal.bats
# checks the sum. test/laya-live.bats measures the guard time.
RUN_TIMEOUT_DEFAULT=64
LAYA_GUARD_LIMIT=15
# The guard gets at most this many bytes (the end of the text), so that a
# large output does not use the full guard limit. About 55 blocks.
LAYA_GUARD_BYTES=32768

# laya install: venv, pip and the checkpoint download share one budget. The
# skill runs the verb with a Bash tool timeout of 600 s.
LAYA_INSTALL_BUDGET=540

# [inferred] A session owner (spec 2026-09-30, section 9): the time that
# open can take. It is more than laya_wait_ready (60 s) and
# wait_for_prompt 5. The sessions reaper keeps a directory with no state,
# or with no pane mark, while it is younger than this: an open can be at
# work in it.
OPEN_BUDGET_DEFAULT=120
# The pause of the watchdog of a session owner (spec 2026-09-30, section 9).
WATCH_INTERVAL=10
# The directory lock (dir_lock). open and close wait at most DIR_LOCK_WAIT
# seconds for a live holder: more than one open (laya_wait_ready 60 s and
# wait_for_prompt 5 s). The SessionEnd hook has 5 s, so it waits
# DIR_LOCK_HOOK_WAIT. CLUX_TERMINAL_LOCK_WAIT changes DIR_LOCK_WAIT (tests).
DIR_LOCK_WAIT=75
case "${CLUX_TERMINAL_LOCK_WAIT:-}" in ''|*[!0-9]*) ;; *) DIR_LOCK_WAIT="$CLUX_TERMINAL_LOCK_WAIT" ;; esac
DIR_LOCK_HOOK_WAIT=2

usage() {
    printf '%s\n' 'usage: terminal.sh open|run|send|read|wait|close|list|check-line|laya install|laya status' >&2
    exit 2
}

fail() {
    printf '%s\n' "$1" >&2
    exit "${2:-2}"
}

# The owner of the companion (spec 2026-09-30-clux-companion-background-
# sessions-design.md, section 5). A pane owner has TMUX and TMUX_PANE: the
# 4.0.0 path. Each other Claude Code session is a session owner:
# CLUX_SESSION_ID (the SessionStart hook writes it) first, then
# CLAUDE_CODE_SESSION_ID, and the process CLAUDE_PID. Sets OWNER_KIND, and
# for a session owner SESSION_ID, OWNER_PID and OWNER_START. An empty
# OWNER_KIND (a test that sources this file) keeps the pane path.
OWNER_KIND=
SESSION_ID=
OWNER_PID=
OWNER_START=
require_owner() {
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
        OWNER_KIND=pane
        return 0
    fi
    SESSION_ID="${CLUX_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
    [ -n "$SESSION_ID" ] || fail 'clux terminal must run inside tmux or in a Claude Code session' 2
    valid_session_id "$SESSION_ID" || fail 'invalid Claude session id' 2
    OWNER_PID="${CLAUDE_PID:-}"
    positive_integer "$OWNER_PID" && process_start "$OWNER_PID" \
        || fail 'cannot identify the Claude session process' 2
    OWNER_START="$PROC_START"
    OWNER_KIND=session
}

# A session id is a UUID in lower case. The script puts it in a path only
# after this check. The characters are explicit, not a range: in some
# locales a range also matches other characters.
SESSION_ID_RE='^[0123456789abcdef]{8}-[0123456789abcdef]{4}-[0123456789abcdef]{4}-[0123456789abcdef]{4}-[0123456789abcdef]{12}$'
valid_session_id() {
    [[ $1 =~ $SESSION_ID_RE ]]
}

# [inferred] The name of a session directory: the first 8 characters of a
# session id.
SHORT_ID_RE='^[0123456789abcdef]{8}$'
valid_short_id() {
    [[ $1 =~ $SHORT_ID_RE ]]
}

# process_start PID — the start time of PID in PROC_START, with the spaces
# at the end removed: macOS ps adds them. A pid alone can repeat, the pid
# and its start time cannot. Fails when ps does not know PID.
PROC_START=
process_start() {
    local out
    PROC_START=
    out=$(ps -o lstart= -p "$1" 2>/dev/null) || return 1
    rtrim "$out"
    PROC_START="$RTRIM"
    [ -n "$PROC_START" ]
}

# owner_alive PID START — PID runs and started at START.
owner_alive() {
    positive_integer "${1:-}" && [ -n "${2:-}" ] && process_start "$1" && [ "$PROC_START" = "$2" ]
}

# random_hex BYTES — BYTES random bytes from /dev/urandom in hex, on one
# line. The callers check the length: an empty or short result is a failure.
random_hex() {
    LC_ALL=C od -An -N"$1" -tx1 /dev/urandom | LC_ALL=C tr -d ' \n'
}

positive_integer() {
    case "$1" in ''|*[!0-9]*|0) return 1 ;; esac
    return 0
}

# Strip trailing whitespace into $RTRIM. Sets a global rather than printing,
# because a command substitution would fork a subshell and the callers sit on
# the 0.2 s poll path.
RTRIM=
rtrim() { RTRIM="${1%"${1##*[![:space:]]}"}"; }

_CLUX_PAT_KEY=
_CLUX_PAT_INC=
_CLUX_PAT_EXC=

# Parse the given pattern files into one include ERE and one exclude ERE,
# cached under the file list. A leading ! marks an exclusion and is not part of
# the regex. A pattern that is empty after the ! is dropped rather than joined:
# an empty alternative matches every line, so one stray `!` would otherwise
# silence the whole detector.
_load_patterns() {
    local key="$*" file raw clean pattern
    [ "$key" != "$_CLUX_PAT_KEY" ] || return 0
    _CLUX_PAT_KEY="$key"
    _CLUX_PAT_INC=
    _CLUX_PAT_EXC=
    for file in "$@"; do
        [ -r "$file" ] || continue
        while IFS= read -r raw || [ -n "$raw" ]; do
            clean="${raw#"${raw%%[![:space:]]*}"}"
            case "$clean" in
                ''|'#'*) continue ;;
                '!'*)
                    pattern="${clean#\!}"
                    [ -n "$pattern" ] || continue
                    _CLUX_PAT_EXC="${_CLUX_PAT_EXC:+$_CLUX_PAT_EXC|}$pattern" ;;
                *) _CLUX_PAT_INC="${_CLUX_PAT_INC:+$_CLUX_PAT_INC|}$clean" ;;
            esac
        done < "$file"
    done
}

# The empty-ERE guard is load-bearing: an empty alternative matches every line,
# and a user pattern file with no ! lines leaves the exclude ERE empty.
_pattern_matches() {
    [ -n "$1" ] || return 1
    grep -E -i -q -- "$1" <<<"$2"
}

_CLUX_USER_PATTERNS=
_CLUX_USER_PATTERNS_SET=

_load_user_patterns() {
    [ -z "$_CLUX_USER_PATTERNS_SET" ] || return 0
    _CLUX_USER_PATTERNS_SET=1
    # [inferred] Window mode reads the option from the server of the user
    # (spec 2026-09-30, section 8). The other modes read the default server:
    # for a pane owner it is the server of the owner pane; for a session
    # owner with no default server, no user patterns apply.
    if [ "$S_MODE" = window ]; then
        _CLUX_USER_PATTERNS=$(tmux -S "$S_SOCKET" show-option -gqv '@clux-terminal-patterns' 2>/dev/null || true)
    else
        _CLUX_USER_PATTERNS=$(tmux show-option -gqv '@clux-terminal-patterns' 2>/dev/null || true)
    fi
}

# A credential prompt must first end in : ? or ] — the shipped patterns are
# unanchored, so that suffix gate is load-bearing. It is stated in the header of
# config/credential-patterns.txt because it is part of that file's contract.
# Any exclusion wins over any inclusion, whichever file it came from.
#
# The include ERE is tested FIRST even though exclusions win: on the poll path
# almost every line is ordinary output, and an include that fails settles the
# answer with ONE grep. Testing excludes first made every ordinary line pay two.
# _load_patterns skips an unreadable file, so the unset user file needs no
# branch of its own.
line_is_credential() {
    local line="$1" override="${2:-}" trimmed
    rtrim "$line"
    trimmed="$RTRIM"
    case "$trimmed" in
        *:|*\?|*\]) ;;
        *) return 1 ;;
    esac
    if [ -n "$override" ]; then
        set -- "$override"
    else
        _load_user_patterns
        set -- "$SHIPPED_PATTERNS" "$_CLUX_USER_PATTERNS"
    fi
    _load_patterns "$@"
    _pattern_matches "$_CLUX_PAT_INC" "$trimmed" || return 1
    ! _pattern_matches "$_CLUX_PAT_EXC" "$trimmed"
}

check_line_command() {
    local patterns="$SHIPPED_PATTERNS" line=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --patterns) [ "$#" -ge 2 ] || usage; patterns="$2"; shift 2 ;;
            --) shift; line="$*"; break ;;
            *) usage ;;
        esac
    done
    line_is_credential "$line" "$patterns"
}

# The one place that reports a credential prompt, so the wording and the exit
# code cannot drift between the three verbs that refuse one.
refuse_credential() {
    printf '%s\n' 'credential prompt in the companion pane: the user must answer it there' >&2
    return 3
}

refuse_laya() {
    printf '%s\n' 'laya not available: close and open the companion' >&2
    return 6
}

# The pane probes of a run failed. The command continues and the run keeps
# the lock, so close would stop it.
refuse_laya_run() {
    printf 'laya not available: run %s continues in the pane; use wait --run %s again\n' "$1" "$1" >&2
    return 6
}

# Run the client with the server of this companion. The URL and the key come
# from state, not from the environment, so all verbs of one companion use one
# server. The client stderr has only fixed messages; each verb prints its own.
# laya_pid_check — the server that open started is alive, and the first
# check of a verb also finds that its pid is laya-serve (one ps): a new
# process can get the pid. The callers that run the client in a subshell
# (a command substitution or a pipe) call it first, in the verb, so the
# mark stays and the wait loops fork no ps each second.
LAYA_PID_CHECKED=
laya_pid_check() {
    [ -n "$S_LAYA_PID" ] || return 0
    kill -0 "$S_LAYA_PID" 2>/dev/null || return 1
    [ "$LAYA_PID_CHECKED" != "$S_LAYA_PID" ] || return 0
    laya_pid_is_server "$S_LAYA_PID" || return 1
    LAYA_PID_CHECKED="$S_LAYA_PID"
}

laya_call() {
    # [inferred] When the server that open started ended, another process
    # can take its port: that process must not get the key or the text.
    laya_pid_check || return 1
    CLUX_LAYA_URL="$S_LAYA_URL" CLUX_LAYA_KEY="$S_LAYA_KEY" "$LAYA_PY" "$LAYA_CLIENT" "$@" 2>/dev/null
}

# The client makes the check (http, a loopback host, no user part), so the
# rule is in one place.
laya_url_is_loopback() {
    "$LAYA_PY" "$LAYA_CLIENT" check-url "$1" >/dev/null 2>&1
}

# "Installed" is the marker of `laya install` and the English checkpoint in
# the Hugging Face cache. open, laya install and laya status use this one
# check (spec section 6).
laya_checkpoint_present() {
    [ -x "$LAYA_VENV/bin/python3" ] || return 1
    "$LAYA_VENV/bin/python3" "$LAYA_CLIENT" checkpoint >/dev/null 2>&1
}

# One client process checks the checkpoint and the laya import of the venv.
# A CLUX_LAYA_PYTHON that is not the venv python needs its own import check.
laya_installed() {
    [ -f "$LAYA_MARKER" ] && [ -x "$LAYA_VENV/bin/python3" ] || return 1
    "$LAYA_VENV/bin/python3" "$LAYA_CLIENT" ready >/dev/null 2>&1 || return 1
    [ "$LAYA_PY" = "$LAYA_VENV/bin/python3" ] || laya_python_ready "$LAYA_PY"
}

# laya_python_ready PY — PY runs and can import the laya package that the
# client uses. For the venv python: a Python upgrade (Homebrew) can break a
# venv and keep its marker.
laya_python_ready() {
    [ -x "$1" ] || return 1
    "$1" -c 'import laya.structured' >/dev/null 2>&1
}

# The Laya checks of open, before it makes $D. Each refusal exits 6.
laya_open_check() {
    if [ -n "${CLUX_LAYA_URL:-}" ]; then
        # The client needs a Python that can import laya, also for a server
        # that the user starts.
        laya_python_ready "$LAYA_PY" || fail 'laya not installed: run terminal.sh laya install' 6
        laya_url_is_loopback "$CLUX_LAYA_URL" \
            || fail 'CLUX_LAYA_URL must name a loopback host: 127.0.0.1, localhost or ::1' 6
        # A server that the user starts has no pid in state: a pid from the
        # state of a dead companion must not stop laya_call.
        S_LAYA_PID=
        S_LAYA_URL="$CLUX_LAYA_URL"
        S_LAYA_KEY="${CLUX_LAYA_KEY:-}"
        laya_call health >/dev/null || fail 'laya not available at CLUX_LAYA_URL' 6
        laya_key_check
        return 0
    fi
    laya_installed || fail 'laya not installed: run terminal.sh laya install' 6
}

# laya_key_check — /health of laya-serve does not check the API key, so one
# POST (a pane request) tells whether the server takes CLUX_LAYA_KEY. The
# client exits 4 when the server refuses the key (401 or 403).
laya_key_check() {
    printf '%s\n' 'clux$' | laya_call pane >/dev/null
    case $? in
        0) return 0 ;;
        4) fail 'laya not available: the server at CLUX_LAYA_URL refused CLUX_LAYA_KEY: set the key of that server' 6 ;;
        *) fail 'laya not available at CLUX_LAYA_URL' 6 ;;
    esac
}

# clux stops only a process whose pid is in state and whose command line
# contains laya-serve, so a new process with a reused pid stays.
laya_pid_is_server() {
    local command
    command=$(ps -o command= -p "$1" 2>/dev/null) || return 1
    case "$command" in *laya-serve*) return 0 ;; esac
    return 1
}

# laya_stop_server PID... — kill each server, then kill -9 each one that
# still runs after 3 s. One wait for all, so the reaper of open does not
# wait 3 s for each dead companion.
laya_stop_server() {
    local pid live=() left i=0
    for pid in "$@"; do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        laya_pid_is_server "$pid" || continue
        kill "$pid" 2>/dev/null && live+=("$pid")
    done
    while [ "${#live[@]}" -gt 0 ] && [ "$i" -lt 15 ]; do
        left=()
        for pid in "${live[@]}"; do
            ! laya_pid_is_server "$pid" || left+=("$pid")
        done
        live=(${left[@]+"${left[@]}"})
        [ "${#live[@]}" -gt 0 ] || return 0
        sleep .2
        i=$((i + 1))
    done
    for pid in ${live[@]+"${live[@]}"}; do
        ! laya_pid_is_server "$pid" || kill -9 "$pid" 2>/dev/null || true
    done
}

# laya_stop_server_later PID — the same stop in a process that the hook does
# not wait for. It ignores HUP and TERM, so the end of the session does not
# stop it before its kill -9.
laya_stop_server_later() {
    ( trap '' HUP INT TERM; laya_stop_server "$1" ) < /dev/null > /dev/null 2>&1 3>&- &
}

# laya_start_server LOG OFFLINE — start laya-serve on a free loopback port
# with a new key of 32 random bytes in hex (spec section 6, steps 3 and 4).
# The server output goes to LOG. OFFLINE=1 sets HF_HUB_OFFLINE, so the
# server does not download; laya install passes 0. Sets LAYA_PID, LAYA_URL
# and LAYA_KEY.
laya_start_server() {
    local port key offline=
    port=$("$LAYA_PY" "$LAYA_CLIENT" port 2>/dev/null) || return 1
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    key=$(random_hex 32)
    [ "${#key}" -eq 64 ] || return 1
    [ "$2" -eq 0 ] || offline=HF_HUB_OFFLINE=1
    # The key goes in the environment of env, not in its arguments: ps
    # shows the arguments of a process to each local user.
    LAYA_API_KEY="$key" env LAYA_HOST=127.0.0.1 LAYA_PORT="$port" LAYA_LOG_LEVEL=warning \
        LAYA_MODELS=english USE_TF=0 ${offline:+"$offline"} \
        nohup "$LAYA_VENV/bin/laya-serve" >> "$1" 2>&1 < /dev/null 3>&- &
    LAYA_PID=$!
    LAYA_URL="http://127.0.0.1:$port"
    LAYA_KEY="$key"
}

# laya_wait_health DEADLINE — health each 0.5 s until SECONDS reaches
# DEADLINE, for the server of LAYA_PID and LAYA_URL. Returns 2 when the
# server process ends, 1 when the time ends. health sends no key: the key
# goes only to a server that laya_owns_port found.
laya_wait_health() {
    until S_LAYA_PID="$LAYA_PID" S_LAYA_URL="$LAYA_URL" S_LAYA_KEY= laya_call health >/dev/null; do
        kill -0 "$LAYA_PID" 2>/dev/null || return 2
        [ "$SECONDS" -lt "$1" ] || return 1
        sleep .5
    done
    # [inferred] The port was free when the client found it, but another
    # process can take it before laya-serve does. That process would get
    # the key and the terminal text, so the answer must come from our
    # server: our process must listen on the port.
    kill -0 "$LAYA_PID" 2>/dev/null || return 2
    laya_owns_port "$LAYA_PID" "${LAYA_URL##*:}" || return 2
}

# laya_owns_port PID PORT — PID listens on the loopback TCP PORT. It uses
# lsof, else ss, else /proc. With none of them it cannot check, so it
# returns 1: the key and the pane text do not go to a port that another
# process can own.
laya_owns_port() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -a -p "$1" -iTCP:"$2" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        ss -ltnpH "sport = :$2" 2>/dev/null | grep -q "pid=$1,"
    elif [ -r "$PROC_ROOT/net/tcp" ]; then
        laya_proc_owns_port "$1" "$2"
    else
        return 1
    fi
}

# laya_proc_owns_port PID PORT — the Linux /proc form of laya_owns_port: a
# socket that listens (state 0A) on PORT is a file of PID.
PROC_ROOT=/proc
laya_proc_owns_port() {
    local hex inode fd
    hex=$(printf '%04X' "$2")
    for inode in $(awk -v p=":$hex" 'FNR > 1 && $4 == "0A" && substr($2, length($2) - 4) == p { print $10 }' \
        "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/tcp6" 2>/dev/null); do
        for fd in "$PROC_ROOT/$1/fd/"*; do
            [ "$(readlink "$fd" 2>/dev/null)" != "socket:[$inode]" ] || return 0
        done
    done
    return 1
}

# Spec section 6, step 7: health for at most 60 s, then a warm-up request,
# because the first call after a start takes about 1.4 s. The warm-up tries
# again until the same 60 s end: on a cold machine the first request can
# take more than the 5 s request limit.
laya_wait_ready() {
    local deadline=$((SECONDS + 60))
    laya_wait_health "$deadline" || return 1
    until printf '%s\n' 'clux$' | laya_call pane >/dev/null; do
        kill -0 "$LAYA_PID" 2>/dev/null || return 1
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep .5
    done
}

# laya_restart_if_down — open on a live companion: when the Laya server that
# open started does not answer (it ended, or the user stopped it), start a
# new one, so open again is enough after "close and open the companion". A
# server that the user started (CLUX_LAYA_URL, no laya_pid) is not changed:
# when it does not answer, open exits 6.
laya_restart_if_down() {
    # A companion that clux 3.x opened has no Laya server and an old rc.bash.
    [ -n "$S_LAYA_URL" ] || fail 'laya not available: this companion has no Laya server: use close, then open' 6
    if laya_call health >/dev/null; then
        [ -n "$S_LAYA_PID" ] || laya_key_check
        return 0
    fi
    [ -n "$S_LAYA_PID" ] || fail 'laya not available: the server at CLUX_LAYA_URL does not answer' 6
    # The typing lock, so no run writes state (its seq) at the same time,
    # then the state again: another open can have started a server.
    lock_and_load || return 5
    if laya_call health >/dev/null; then
        release_typing_lock
        return 0
    fi
    laya_installed || fail 'laya not installed: run terminal.sh laya install' 6
    laya_stop_server "$S_LAYA_PID"
    LAYA_PID=
    laya_start_server "$D/laya.log" 1 || fail 'laya not available: the server did not start' 6
    # laya_call reads the URL and the key from state, so write them first.
    write_state "$S_MODE" "$S_PANE" "$S_SOCKET" "$S_SEQ" "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
    if ! laya_wait_ready; then
        laya_stop_server "$LAYA_PID"
        fail 'laya not available: the server did not answer' 6
    fi
    release_typing_lock
}

# open_abort PANE_MADE MESSAGE [CODE] — undo a failed open and exit CODE
# (default 6, spec section 6, step 8). PANE_MADE is 1 when the pane exists.
# open holds the lock of $D (dir_lock), so $D is only what this open made.
open_abort() {
    laya_stop_server "$LAYA_PID"
    [ "$1" -eq 0 ] || kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" 1
    rm -rf "$D"
    fail "$2" "${3:-6}"
}

resolve_root() {
    ROOT="${CLUX_TERMINAL_DIR:-}"
    [ -n "$ROOT" ] || ROOT="${TMPDIR:-/tmp}/clux-terminal-$EUID"
}

terminal_init() {
    # Every file and directory this process makes ($D, state, busy, <n>.cmd)
    # is private. The pane shell keeps the user's own umask.
    umask 077
    # The locks of the verbs are flock locks that perl holds (LOCK_HELPER).
    command -v perl > /dev/null 2>&1 || fail 'clux terminal needs perl' 2
    resolve_root
    if [ "$OWNER_KIND" = session ]; then
        # A session owner needs no tmux server key (spec 2026-09-30,
        # section 6). The full id would make the socket path too long.
        SERVER_KEY=
        D="$ROOT/sessions/${SESSION_ID:0:8}"
        return 0
    fi
    SERVER_KEY=$(resolve_agent_server_key)
    _clux_valid_server_key "$SERVER_KEY" || fail 'cannot identify the tmux server' 2
    OWNER_PANE="${TMUX_PANE#%}"
    case "$OWNER_PANE" in ''|*[!0-9]*) fail 'invalid owner pane' 2 ;; esac
    D="$ROOT/$SERVER_KEY-$OWNER_PANE"
}

S_MODE=
S_PANE=
S_SOCKET=
S_SEQ=
S_LAYA_PID=
S_LAYA_URL=
S_LAYA_KEY=
S_TOKEN=
# The fields of a session owner (spec 2026-09-30, section 6).
S_SESSION=
S_OWNER_PID=
S_OWNER_START=
S_SERVER=
S_WATCH_PID=
PROMPT_MARK='clux$'
CONT_MARK=

# The ONE state-file reader. $1 defaults to the current companion's directory;
# reap_companions and list_command pass a foreign one. Fails when there is no
# state file, which is the same question "is a companion open" asks.
#
# Clearing the globals first is load-bearing, not defensive: the two loops call
# this once per directory, so a field missing from the second file would
# otherwise keep the first file's value. Both loops run before any S_* is used
# for tmux, so the clobber is safe. laya_pid is present only when open started
# the server; laya_url and laya_key name the server of this companion.
state_load() {
    local dir="${1:-$D}" key value
    S_MODE=''; S_PANE=''; S_SOCKET=''; S_SEQ=''
    S_LAYA_PID=''; S_LAYA_URL=''; S_LAYA_KEY=''; S_TOKEN=''
    S_SESSION=''; S_OWNER_PID=''; S_OWNER_START=''; S_SERVER=''; S_WATCH_PID=''
    [ -f "$dir/state" ] || return 1
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in
            mode) S_MODE="$value" ;;
            pane) S_PANE="$value" ;;
            socket) S_SOCKET="$value" ;;
            seq) S_SEQ="$value" ;;
            laya_pid) S_LAYA_PID="$value" ;;
            laya_url) S_LAYA_URL="$value" ;;
            laya_key) S_LAYA_KEY="$value" ;;
            token) S_TOKEN="$value" ;;
            session) S_SESSION="$value" ;;
            owner_pid) S_OWNER_PID="$value" ;;
            owner_start) S_OWNER_START="$value" ;;
            server) S_SERVER="$value" ;;
            watch_pid) S_WATCH_PID="$value" ;;
        esac
    done 2>/dev/null < "$dir/state"
    # A companion that an older clux opened has no token.
    PROMPT_MARK='clux$'
    CONT_MARK=
    [ -z "$S_TOKEN" ] || { PROMPT_MARK="clux-$S_TOKEN\$"; CONT_MARK="clux-$S_TOKEN> "; }
    return 0
}

# Whole-row test against a listing already in memory: the newline delimiters are
# what keep %1 from matching %10, exactly as grep -qxF did.
listing_has_pane() {
    case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
    return 1
}

# The one place that decides how a companion is torn down. A private server
# goes as a whole; a split pane goes only when the caller owns it; a window
# pane on the server of the user goes only when it holds the mark. The
# window arm never uses kill-server: that server is the server of the user.
#
# A case, not if/elif: a socket-mode state with an empty socket field must do
# nothing. Its pane id names a pane on the PRIVATE server, and an elif that
# fell through would kill the pane with that id on the user's own server.
kill_companion() {
    local mode="$1" pane="$2" socket="$3" kill_split="${4:-0}"
    case "$mode" in
        socket)
            [ -z "$socket" ] || tmux -S "$socket" kill-server >/dev/null 2>&1 || true ;;
        split)
            [ "$kill_split" -ne 1 ] || [ -z "$pane" ] || tmux kill-pane -t "$pane" >/dev/null 2>&1 || true ;;
        window)
            # The user's own server: kill the companion pane (its window closes with
            # it), never the server. The identity check stops a stale pane id from
            # naming a pane of the user after a server restart.
            [ -z "$socket" ] || [ -z "$pane" ] || ! companion_pane_is_ours "$socket" "$pane" \
                || tmux -S "$socket" kill-pane -t "$pane" >/dev/null 2>&1 || true ;;
    esac
}

# remove_companion_dir DIR KILL_SPLIT — the reaper adds the server pid to
# REAP_PIDS; reap_companions stops all of them with one wait.
REAP_PIDS=()
remove_companion_dir() {
    local dir="$1" kill_split="${2:-0}"
    state_load "$dir" || { rm -rf "$dir"; return; }
    [ -z "$S_LAYA_PID" ] || REAP_PIDS+=("$S_LAYA_PID")
    kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" "$kill_split"
    rm -rf "$dir"
}

# ONE listing answers the liveness question for every directory. The flat
# <server-key>-<pane> name has to be split before the store's own validator
# will accept the server part. The server key is NOT asked for here the way
# path.sh's reaper does: these rows are matched against a pane id alone, and
# terminal_init already holds the key.
companion_listing() {
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null
}

reap_companions() {
    local listing
    # [inferred] A session owner does not read the tmux listing and does not
    # reach the directories of pane owners.
    if [ "$OWNER_KIND" != session ]; then
        listing=$(companion_listing)
        [ -z "$listing" ] || reap_pane_dirs "$listing"
    fi
    reap_session_dirs
    reap_stale_locks
    stop_reaped_servers
}

# locked DIR COMMAND... — the reaper: run COMMAND under the lock of DIR, and
# try the lock one time. A DIR whose lock another live verb holds stays:
# that verb opens or closes it now. A lock that this process held before
# stays held.
locked() {
    local dir="$1" held=0 rc=0
    shift
    ! dir_held "$dir" || held=1
    dir_lock "$dir" 0 || return 0
    "$@" || rc=$?
    [ "$held" -eq 1 ] || dir_unlock "$dir"
    return "$rc"
}

# tmux_server_alive PID — PID runs and is a tmux process: the liveness test
# of a foreign server. kill -0 alone keeps the directory of a dead server
# for ever when another process gets its pid.
tmux_server_alive() {
    local command
    command=$(ps -o command= -p "$1" 2>/dev/null) || return 1
    case "$command" in *tmux*) return 0 ;; esac
    return 1
}

# reap_pane_dirs LISTING — the 4.0.0 loop over $ROOT/<server-key>-<pane>.
# _clux_valid_server_key refuses the name "sessions", so this loop skips
# the directories of session owners.
reap_pane_dirs() {
    local listing="$1" dir base server owner pid
    for dir in "$ROOT"/*; do
        [ -d "$dir" ] || continue
        base="${dir##*/}"
        server="${base%-*}"
        owner="${base##*-}"
        _clux_valid_server_key "$server" || continue
        case "$owner" in ''|*[!0-9]*) continue ;; esac
        if [ "$server" = "$SERVER_KEY" ]; then
            listing_has_pane "$listing" "%$owner" || locked "$dir" remove_companion_dir "$dir" 1
        else
            pid="${server%%-*}"
            tmux_server_alive "$pid" || locked "$dir" remove_companion_dir "$dir" 0
        fi
    done
}

# reap_session_dirs — the loop over $ROOT/sessions/* (spec 2026-09-30,
# section 9). It needs no tmux listing, so it also runs when the default
# server does not answer. A directory goes when:
#   - its owner process is gone, or has another start time;
#   - the caller is a session owner, the owner process is the process of
#     the caller, but the session id is different: one Claude process runs
#     one session at a time, so this is a companion left from a /clear
#     whose SessionEnd hook did not run;
#   - its pane does not hold the mark (section 8).
# A directory with no state, or with no mark on its pane, stays while it is
# younger than OPEN_BUDGET_DEFAULT. The Laya pid goes to REAP_PIDS, as in
# reap_pane_dirs. The state is read and the decision made under the lock of
# DIR (locked), so the state of an open or close at work does not count.
reap_session_dirs() {
    local dir now
    [ -d "$ROOT/sessions" ] || return 0
    now=$(date +%s)
    for dir in "$ROOT"/sessions/*; do
        [ -d "$dir" ] || continue
        valid_short_id "${dir##*/}" || continue
        locked "$dir" reap_session_dir "$dir" "$now"
    done
}

# reap_session_dir DIR NOW — one directory of reap_session_dirs.
reap_session_dir() {
    local dir="$1" age
    [ -d "$dir" ] || return 0
    age=$(($2 - $(dir_mtime "$dir")))
    if ! state_load "$dir"; then
        [ "$age" -lt "$OPEN_BUDGET_DEFAULT" ] || rm -rf "$dir"
        return 0
    fi
    if ! owner_alive "$S_OWNER_PID" "$S_OWNER_START" \
        || { [ "$OWNER_KIND" = session ] && [ "$S_OWNER_PID" = "$OWNER_PID" ] \
            && [ "$S_OWNER_START" = "$OWNER_START" ] && [ "$S_SESSION" != "$SESSION_ID" ]; } \
        || { [ "$age" -ge "$OPEN_BUDGET_DEFAULT" ] && ! companion_pane_is_ours "$S_SOCKET" "$S_PANE"; }; then
        remove_companion_dir "$dir" 0
        watch_stop "$S_WATCH_PID" "${dir##*/}"
    fi
}

# dir_mtime DIR — the last change of DIR in seconds since the epoch: GNU
# stat, then BSD stat (the method of dismiss-notification.sh). 0 when both
# fail, so the directory counts as old.
dir_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# stop_reaped_servers — stop the servers that remove_companion_dir found.
stop_reaped_servers() {
    [ "${#REAP_PIDS[@]}" -eq 0 ] || laya_stop_server "${REAP_PIDS[@]}"
    REAP_PIDS=()
}

list_command() {
    local listing="" dir base server state
    terminal_init
    # [inferred] A session owner does not read the tmux listing: the
    # directories of pane owners are foreign to it.
    [ "$OWNER_KIND" = session ] || listing=$(companion_listing)
    for dir in "$ROOT"/*; do
        state_load "$dir" || continue
        base="${dir##*/}"
        server="${base%-*}"
        if [ "$server" != "$SERVER_KEY" ]; then
            state=foreign
        elif listing_has_pane "$listing" "$S_PANE"; then
            state=alive
        else
            state=gone
        fi
        printf 'owner=%s mode=%s pane=%s state=%s\n' "$base" "$S_MODE" "$S_PANE" "$state"
    done
    # The directories of session owners (spec 2026-09-30, section 11): alive
    # when the pane holds the mark.
    for dir in "$ROOT"/sessions/*; do
        state_load "$dir" || continue
        state=gone
        ! companion_pane_is_ours "$S_SOCKET" "$S_PANE" || state=alive
        printf 'owner=sessions/%s mode=%s pane=%s state=%s\n' "${dir##*/}" "$S_MODE" "$S_PANE" "$state"
    done
}

# command_sum TEXT — the first 32 hex characters of the SHA-256 of TEXT.
# run puts it on the typed line, and the pane shell compares it with the
# sum of <n>.cmd (spec section 7).
command_sum() {
    local out
    if command -p -v shasum >/dev/null 2>&1; then
        out=$(printf '%s' "$1" | command -p shasum -a 256)
    else
        out=$(printf '%s' "$1" | command -p sha256sum)
    fi || return 1
    out="${out%% *}"
    [ "${#out}" -eq 64 ] || return 1
    printf '%s' "${out:0:32}"
}

# The private directory and the prompt token go into rc.bash as read-only
# values, not as exported variables: a program in the pane does not get
# them in its environment, and a command cannot change them.
write_rc_file() {
    {
        printf 'readonly __clux_dir=%q\n' "$D"
        printf "PS1='clux-%s\$ '\n" "$S_TOKEN"
        # A continuation line has its own mark, so send finds it (spec
        # section 7) and does not add text to a command that the gate did
        # not examine in full.
        printf "PS2='clux-%s> '\n" "$S_TOKEN"
        cat <<'EOF'
unset HISTFILE
set +o history
# Keys that came while a command ran (typeahead) would go to readline at
# this prompt with no gate: Escape and C-e is shell-expand-line, and Enter
# runs the line in this shell. The shell drops them before each prompt.
__clux_flush() {
  local s
  s=$(command -p stty -g 2>/dev/null) || return 0
  command -p stty -icanon min 0 time 0 2>/dev/null
  command -p dd bs=4096 count=64 of=/dev/null 2>/dev/null
  command -p stty "$s" 2>/dev/null
  return 0
}
PROMPT_COMMAND=__clux_flush
PS0=
PS3=
PS4='+ '
# Read-only: the shell expands these before each prompt or line with no
# gate. Each line of Claude runs in a subshell, but a key such as M-C-e can
# expand text in this shell.
readonly PROMPT_COMMAND PS0 PS1 PS2 PS3 PS4
# Each external program runs with command -p (the default PATH of the
# system): a run can give back PATH, and this shell runs these helpers with
# no gate (PROMPT_COMMAND at each prompt).
# No aliases. Each run command runs in a subshell (__clux_run), so it
# cannot change the functions, the aliases, the traps or the options of
# this shell; only the directory and the exported variables come back.
shopt -u expand_aliases
# terminal.sh clears the line with C-e, then C-u, before it types a
# __clux_ line. A vi mode or other keys from ~/.inputrc must not change that.
bind 'set editing-mode emacs' 2>/dev/null
bind '"\C-e": end-of-line' 2>/dev/null
bind '"\C-u": unix-line-discard' 2>/dev/null
# C-d at an empty prompt must not end the pane shell (spec section 7).
set -o ignoreeof
# Read-only: a line that sets IGNOREEOF=0 or TMOUT=1 would let C-d (an
# interrupt key, with no gate) or the idle time end the pane shell. bash
# still lets set +o ignoreeof remove it; each line of Claude runs in a subshell.
readonly IGNOREEOF=1000000 TMOUT=0
# MAILPATH holds a message that the shell expands ($(...) too) before a
# prompt, with no gate, and FUNCNEST=1 would stop __clux_line. The four
# names stay unset and read-only.
unset MAIL MAILPATH MAILCHECK FUNCNEST
readonly MAIL MAILPATH MAILCHECK FUNCNEST
__clux_refuse() { printf '%s\n' 'refused: this word closes the companion'; return 1; }
exit() { __clux_refuse; }
exec() { __clux_refuse; }
logout() { __clux_refuse; }
__clux_clear() { printf '\033[2J\033[H'; }
# __clux_carry NAME — an exported variable that a run can give back to this
# shell. Names that change how the shell reads or runs later commands stay.
__clux_carry() {
  case "$1" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
    __clux*|BASH*|ENV|PROMPT_COMMAND|PS[0-4]|IFS|SHELLOPTS|POSIXLY_CORRECT|CDPATH|GLOBIGNORE|HISTFILE|HISTCMD|TMOUT|IGNOREEOF|MAIL|MAILPATH|MAILCHECK|FUNCNEST|SHLVL|PWD|OLDPWD|LD_*|DYLD_*|_) return 1 ;;
  esac
  return 0
}
# __clux_keep FILE — in the subshell of a run: write the directory, then
# each exported variable, then an end record, NUL-separated.
__clux_keep() {
  local __clux_v
  # The options that the command set (set -e, set -u, noclobber) must not
  # stop the write; they change only this subshell.
  (set +e +u +C; umask 077
   { printf '%s\0' "$PWD"
     # One name on each line, read with no word split: the command can
     # leave any IFS.
     while IFS= read -r __clux_v; do printf '%s=%s\0' "$__clux_v" "${!__clux_v}"; done < <(compgen -e)
     printf '=\0'
   } > "$1")
}
# __clux_load FILE — in this shell: take the directory and the exported
# variables that __clux_keep wrote. The subshell runs the command, so the
# file is data: only names that __clux_carry permits are set, with export,
# and nothing is evaluated. A file with no end record changes nothing.
__clux_load() {
  local __clux_kv __clux_k __clux_w __clux_i __clux_end=0 __clux_new=' '
  local -a __clux_names __clux_values
  [ -f "$1" ] || return 0
  {
    IFS= read -r -d '' __clux_w
    while IFS= read -r -d '' __clux_kv; do
      [ "$__clux_kv" = '=' ] && { __clux_end=1; break; }
      __clux_k="${__clux_kv%%=*}"
      __clux_carry "$__clux_k" || continue
      __clux_names[${#__clux_names[@]}]="$__clux_k"
      __clux_values[${#__clux_values[@]}]="${__clux_kv#*=}"
      __clux_new="$__clux_new$__clux_k "
    done
  } 2>/dev/null < "$1"
  command -p rm -f "$1"
  [ "$__clux_end" -eq 1 ] || return 0
  for __clux_k in $(compgen -e); do
    __clux_carry "$__clux_k" || continue
    case "$__clux_new" in *" $__clux_k "*) ;; *) unset "$__clux_k" 2>/dev/null ;; esac
  done
  __clux_i=0
  while [ "$__clux_i" -lt "${#__clux_names[@]}" ]; do
    export "${__clux_names[$__clux_i]}=${__clux_values[$__clux_i]}" 2>/dev/null
    __clux_i=$((__clux_i + 1))
  done
  builtin cd -- "$__clux_w" 2>/dev/null
  # In POSIX mode exit and exec run before the functions above.
  set +o posix
  return 0
}
# __clux_sub CMD KEEP — run CMD in a subshell, then take back the directory
# and the exported variables. In the subshell, exit, exec and logout are the
# builtins again: exit ends the command (cd dir || exit 1), not only this
# shell. The keep file is written after the command, and by the EXIT trap
# after exit. The path goes into the trap now: the locals are gone when the
# trap runs. A command that sets its own EXIT trap and ends with exit writes
# no keep file: then a note says that nothing came back.
__clux_sub() {
  command -p rm -f "$2"
  ( unset -f exit exec logout
    readonly __clux_k="$2"
    trap "__clux_keep $(printf '%q' "$2")" EXIT
    readonly __clux_t="$(trap -p EXIT)"
    __clux_c="$1"; set --
    eval "$__clux_c"
    set -- "$?"
    # A DEBUG, ERR or RETURN trap of the command must not run in the keep step.
    trap - DEBUG ERR RETURN
    __clux_keep "$__clux_k" || :
    # Only the trap of clux goes: an EXIT trap that the command set runs
    # at exit, as in a plain subshell (trap "rm -rf $tmp" EXIT).
    [ "$(trap -p EXIT)" != "$__clux_t" ] || trap - EXIT
    exit "$1" )
  set -- "$?" "$2"
  [ -f "$2" ] || printf '%s\n' 'clux: the directory and the exported variables did not come back: the command set an EXIT trap and ended with exit'
  return "$1"
}
__clux_sum() {
  local __clux_o
  if command -p -v shasum >/dev/null 2>&1; then
    __clux_o=$(printf '%s' "$1" | command -p shasum -a 256)
  else
    __clux_o=$(printf '%s' "$1" | command -p sha256sum)
  fi
  __clux_o="${__clux_o%% *}"
  printf '%s' "${__clux_o:0:32}"
}
# __clux_at_prompt — the caller of the function that calls this was typed
# at the prompt of the pane shell: it is not in a subshell and no other
# function called it. A line from send or run runs in the subshell of
# __clux_sub, so a line cannot call __clux_run or __clux_line, also when
# quotes split the name ("__clux"_run) and the text check of terminal.sh
# does not see it.
__clux_at_prompt() {
  [ "$BASH_SUBSHELL" -eq 0 ] && [ -z "${FUNCNAME[2]:-}" ]
}
# __clux_run N SUM MODE — run <n>.cmd. terminal.sh types this line after
# the Laya gate. The line, not a file in the private directory, tells what
# the gate decided: SUM is the sum of the command that Laya examined, MODE
# is plain or confirm (dangerous: ask the user). A command that is not the
# same is refused.
#
# A dangerous run asks the user first. Only "y" runs it. The INT trap keeps
# Ctrl-C from ending the question: without it, Ctrl-C ends this function and
# leaves <n>.confirm, and each verb refuses until close. Each <n>.cmd runs
# one time: a run with no .cmd, or with an .rc, is refused, and .cmd is
# deleted when it is read. Thus a declined run cannot run again.
__clux_run() {
  local __clux_n="$1" __clux_s="${2:-}" __clux_m="${3:-}"
  local __clux_d="$__clux_dir" __clux_cmd __clux_rc __clux_i __clux_reason __clux_answer
  __clux_at_prompt || { printf '%s\n' 'refused: only the companion types __clux_run at the prompt'; return 1; }
  case "$__clux_n" in ''|*[!0-9]*) printf '%s\n' 'refused: this run is not waiting to start'; return 1 ;; esac
  if [ -z "$__clux_s" ] || [ ! -f "$__clux_d/$__clux_n.cmd" ] || [ -e "$__clux_d/$__clux_n.rc" ]; then
    # A run that ended cannot ask a question: its .confirm goes.
    [ ! -e "$__clux_d/$__clux_n.rc" ] || command -p rm -f "$__clux_d/$__clux_n.confirm"
    printf '%s\n' 'refused: this run is not waiting to start'
    return 1
  fi
  { __clux_cmd=$(<"$__clux_d/$__clux_n.cmd"); } 2>/dev/null
  command -p rm -f "$__clux_d/$__clux_n.cmd"
  if [ "$(__clux_sum "$__clux_cmd")" != "$__clux_s" ]; then
    __clux_cmd='printf "%s\n" "refused: the command changed after Laya examined it"; (builtin exit 126)'
    __clux_m=plain
  elif [ "$__clux_m" != plain ] && [ "$__clux_m" != confirm ]; then
    __clux_cmd='printf "%s\n" "refused: the mode is not plain or confirm"; (builtin exit 126)'
    __clux_m=plain
  fi
  # Only the question removes .confirm after the answer; a refused or a
  # plain run removes it now, so no verb waits for a question.
  [ "$__clux_m" = confirm ] || command -p rm -f "$__clux_d/$__clux_n.confirm"
  if [ "$__clux_m" = confirm ]; then
    { __clux_reason=$(<"$__clux_d/$__clux_n.reason"); } 2>/dev/null
    # Control characters show as ?, so the question shows the full command.
    printf 'laya: dangerous (%s)\n$ %s\n' "${__clux_reason//[[:cntrl:]]/?}" "${__clux_cmd//[[:cntrl:]]/?}"
    # The read is in a subshell: bash goes on with a read after a trapped
    # C-c, but C-c ends the subshell, so C-c (and C-d) declines. The pane
    # shell ignores the C-c, and C-z cannot stop the question.
    trap : INT
    __clux_answer=$(trap - INT; trap '' TSTP; builtin read -r -p 'run? [y/N] ' __clux_a && printf '%s' "$__clux_a")
    trap - INT
    command -p rm -f "$__clux_d/$__clux_n.confirm"
    if [ "$__clux_answer" != y ]; then
      (umask 077; printf 'declined\n' > "$__clux_d/$__clux_n.declined"; : > "$__clux_d/$__clux_n.done"
        printf '126\n' > "$__clux_d/$__clux_n.rc.tmp") \
        && command -p mv -f "$__clux_d/$__clux_n.rc.tmp" "$__clux_d/$__clux_n.rc"
      return 126
    fi
  else
    printf '$ %s\n' "${__clux_cmd//[[:cntrl:]]/?}"
  fi
  # The command runs in a subshell: it cannot change this shell for later
  # commands (a function, an alias, a trap, an option, enable). The
  # directory and the exported variables come back through __clux_load.
  __clux_sub "$__clux_cmd" "$__clux_d/$__clux_n.keep" > >(umask 077; command -p tee "$__clux_d/$__clux_n.out"; : > "$__clux_d/$__clux_n.done") 2>&1
  __clux_rc=$?
  __clux_load "$__clux_d/$__clux_n.keep"
  __clux_i=0
  while [ ! -e "$__clux_d/$__clux_n.done" ] && [ "$__clux_i" -lt 20 ]; do command -p sleep .05; __clux_i=$((__clux_i + 1)); done
  (umask 077; printf '%s\n' "$__clux_rc" > "$__clux_d/$__clux_n.rc.tmp") \
    && command -p mv -f "$__clux_d/$__clux_n.rc.tmp" "$__clux_d/$__clux_n.rc"
}
# __clux_line SUM — the line that send ends at the clux prompt. terminal.sh
# writes it to line.cmd after the Laya gate and types this call, so no line
# from Claude runs in this shell: it runs in a subshell, on the terminal, as
# a run command does. SUM is the sum of the line that Laya examined; a
# line.cmd with a different sum, or none, runs nothing. line.cmd is deleted
# when it is read.
__clux_line() {
  local __clux_s="${1:-}" __clux_d="$__clux_dir" __clux_cmd __clux_rc
  __clux_at_prompt || { printf '%s\n' 'refused: only the companion types __clux_line at the prompt'; return 1; }
  if [ -z "$__clux_s" ] || [ ! -f "$__clux_d/line.cmd" ]; then
    printf '%s\n' 'refused: no line is waiting'
    return 1
  fi
  { __clux_cmd=$(<"$__clux_d/line.cmd"); } 2>/dev/null
  command -p rm -f "$__clux_d/line.cmd"
  if [ "$(__clux_sum "$__clux_cmd")" != "$__clux_s" ]; then
    printf '%s\n' 'refused: the line changed after Laya examined it'
    return 1
  fi
  printf '$ %s\n' "${__clux_cmd//[[:cntrl:]]/?}"
  __clux_sub "$__clux_cmd" "$__clux_d/line.keep"
  __clux_rc=$?
  __clux_load "$__clux_d/line.keep"
  return "$__clux_rc"
}
# A line cannot make a new __clux_run that skips the question. exit, exec
# and logout stay plain functions: the subshell of a command unsets them.
readonly -f __clux_flush __clux_refuse __clux_clear __clux_carry __clux_keep __clux_load __clux_sub __clux_sum __clux_at_prompt __clux_run __clux_line
EOF
    } > "$D/rc.bash"
}

# The ONE state-file writer. After open, seq changes on each run, the laya
# fields change when laya_restart_if_down starts a new server, and a session
# owner gets watch_pid when open starts the watchdog. Each call writes all
# the fields again from the S_* globals, also the session-owner fields.
# write_state MODE PANE SOCKET SEQ [LAYA_PID LAYA_URL LAYA_KEY]: with four
# arguments the laya fields keep the values that state_load read. mode,
# pane, socket and seq are always written; each other field only when it is
# not empty, so a pane owner has the same state as in 4.0.0.
# [inferred] The write goes to a temporary file in $D, and mv renames it to
# state, so a reader (the watchdog, the reaper) never sees a half-written
# file.
write_state() {
    local tmp="$D/state.$$"
    S_MODE="$1"
    S_PANE="$2"
    S_SOCKET="$3"
    S_SEQ="${4:-0}"
    if [ "$#" -ge 5 ]; then
        S_LAYA_PID="$5"
        S_LAYA_URL="${6:-}"
        S_LAYA_KEY="${7:-}"
    fi
    {
        printf 'mode=%s\npane=%s\nsocket=%s\nseq=%s\n' "$S_MODE" "$S_PANE" "$S_SOCKET" "$S_SEQ"
        [ -z "$S_TOKEN" ] || printf 'token=%s\n' "$S_TOKEN"
        [ -z "$S_LAYA_PID" ] || printf 'laya_pid=%s\n' "$S_LAYA_PID"
        [ -z "$S_LAYA_URL" ] || printf 'laya_url=%s\n' "$S_LAYA_URL"
        [ -z "$S_LAYA_KEY" ] || printf 'laya_key=%s\n' "$S_LAYA_KEY"
        [ -z "$S_SESSION" ] || printf 'session=%s\n' "$S_SESSION"
        [ -z "$S_OWNER_PID" ] || printf 'owner_pid=%s\n' "$S_OWNER_PID"
        [ -z "$S_OWNER_START" ] || printf 'owner_start=%s\n' "$S_OWNER_START"
        [ -z "$S_SERVER" ] || printf 'server=%s\n' "$S_SERVER"
        [ -z "$S_WATCH_PID" ] || printf 'watch_pid=%s\n' "$S_WATCH_PID"
    } > "$tmp" && mv -f "$tmp" "$D/state"
}

# A session owner has no TMUX, so plain tmux can reach another server:
# socket and window mode always name the server with -S. No fork: the poll
# loops call this.
tmux_state() {
    case "$S_MODE" in
        socket|window) tmux -S "$S_SOCKET" "$@" ;;
        *) tmux "$@" ;;
    esac
}

# Sets CURSOR_LINE rather than printing it: the callers run on every poll, and a
# command substitution would fork a subshell each time. -S 0 keeps -J joining
# wrapped rows, so a long prompt arrives as one logical line.
capture_cursor_line() {
    capture_to_cursor || return 1
    CURSOR_LINE="${CAPTURE##*$'\n'}"
}

CAPTURE=

# capture_to_cursor — the screen from row 0 to the cursor row, in CAPTURE.
# The x keeps a blank cursor line: without it, the command substitution
# removes it, and the last line of CAPTURE is the line above the cursor.
# The cursor line goes to its end: after Home on a long line, the rows below
# the cursor row are part of the line, and a line that ends goes whole. A
# second capture to the last row gives them; the lines above the cursor line
# are the same in the two captures. The second capture is only made when the
# line can go on below: the cursor row is not the last row, and the line has
# the characters to fill a row (a character uses at most 2 cells). This
# keeps the 0.2 s poll paths at one capture for a short line. With no width
# or height, the second capture is made.
capture_to_cursor() {
    local pos cy w h all head line
    pos=$(tmux_state display-message -p -t "$S_PANE" '#{cursor_y} #{pane_width} #{pane_height}') || return 1
    cy="${pos%% *}"
    w=; h=
    case "$pos" in *' '*' '*) w="${pos#* }"; h="${w#* }"; w="${w%% *}" ;; esac
    CAPTURE=$(tmux_state capture-pane -p -J -t "$S_PANE" -S 0 -E "$cy" && printf x) || return 1
    CAPTURE="${CAPTURE%x}"
    CAPTURE="${CAPTURE%$'\n'}"
    if positive_integer "$w" && positive_integer "$h"; then
        [ "$cy" -lt "$((h - 1))" ] || return 0
        line="${CAPTURE##*$'\n'}"
        [ "$(( ${#line} * 2 ))" -ge "$((w - 1))" ] || return 0
    fi
    all=$(tmux_state capture-pane -p -J -t "$S_PANE" -S 0 -E - && printf x) || return 1
    all="${all%x}"
    head=
    case "$CAPTURE" in *$'\n'*) head="${CAPTURE%$'\n'*}"$'\n' ;; esac
    case "$all" in "$head"*) ;; *) return 0 ;; esac
    line="${all:${#head}}"
    line="${line%%$'\n'*}"
    # Only a longer line of the same start: else the screen changed.
    case "$line" in "${CAPTURE:${#head}}"*) CAPTURE="$head$line" ;; esac
}

# A suffix test on the line capture_cursor_line already holds, so one poll
# step can ask both "at the prompt" and "credential prompt" for one capture.
line_at_prompt() {
    rtrim "$CURSOR_LINE"
    case "$RTRIM" in *"$PROMPT_MARK") return 0 ;; esac
    return 1
}

# prompt_input — the cursor line holds the clux-<token>$ prompt, also after
# output with no last newline (fooclux-<token>$ ). Sets PROMPT_INPUT to the
# text after the FIRST prompt mark: when the output before the prompt holds
# the mark too, the gate gets more text, not less.
PROMPT_INPUT=
prompt_input() {
    case "$CURSOR_LINE" in
        *"$PROMPT_MARK "*) PROMPT_INPUT="${CURSOR_LINE#*"$PROMPT_MARK "}" ;;
        *"$PROMPT_MARK") PROMPT_INPUT= ;;
        *) return 1 ;;
    esac
}

PANE_STATE=
PANE_TEXT=
PANE_TEXT_STATE=
PANE_TEXT_KEY=
PANE_LAST=
SCREEN_ABOVE=
PANE_RE='"state": "(credential|yes_no|menu|pager|shell_prompt|other)"'

# pane_state — the prompt type on the cursor line (spec section 9). Sets
# CURSOR_LINE, SCREEN_ABOVE (the 4 lines above it) and PANE_STATE. Returns 1
# when the capture fails, 7 when the cursor line is too long for Laya
# (client exit 3) and 6 when the client fails. The 3.9.0 regular
# expressions (line_is_credential) can only add "credential". This call
# forks the client, so the poll loops call it only on each fifth step, and
# it sends no request when the window that goes to Laya (the last 5 lines)
# is the same as at the last answer: a program that changes only its top
# rows (watch, top) sends no request on each probe. The cache keeps that
# answer (PANE_TEXT_STATE): a probe that gave "other" for changed output
# does not change it, so a window that comes back (A, B, A) gets its answer.
pane_state() {
    local window out key
    capture_to_cursor || return 1
    CURSOR_LINE="${CAPTURE##*$'\n'}"
    # The last 5 lines, with no fork: the poll loops call this each second.
    local rest="$CAPTURE" i=0
    while [ "$i" -lt 4 ] && [[ "$rest" == *$'\n'* ]]; do
        rest="${rest%$'\n'*}"
        i=$((i + 1))
    done
    window="${rest##*$'\n'}${CAPTURE:${#rest}}"
    case "$window" in
        *$'\n'*) SCREEN_ABOVE="${window%$'\n'*}" ;;
        *) SCREEN_ABOVE= ;;
    esac
    # A wait probe settles on the cursor line and the line above it (the
    # prompt and its label), not on the full window: a live timer or a
    # status line above a password prompt must not stop the request.
    key="${SCREEN_ABOVE##*$'\n'}"$'\n'"$CURSOR_LINE"
    if [ -n "$PANE_TEXT_STATE" ] && { [ "$window" = "$PANE_TEXT" ] \
        || { [ "${PANE_SETTLE:-0}" -eq 1 ] && [ "$key" = "$PANE_TEXT_KEY" ]; }; }; then
        PANE_STATE="$PANE_TEXT_STATE"
        PANE_LAST="$key"
        return 0
    fi
    # At the clux prompt the state is known: it is not a credential prompt,
    # a pager or a menu. No request; the local patterns still apply.
    if prompt_input; then
        PANE_STATE=shell_prompt
        ! line_is_credential "$CURSOR_LINE" || PANE_STATE=credential
        PANE_TEXT="$window"
        PANE_TEXT_KEY="$key"
        PANE_TEXT_STATE="$PANE_STATE"
        return 0
    fi
    # A wait probe (PANE_SETTLE=1): a cursor line, or the line above it,
    # that changed since the probe before is not a prompt that waits for
    # input, so it sends no request (npm install would send one each second
    # to the one-worker server). When the two lines stay, one request goes,
    # and its answer stays while only the rows above change. The first probe
    # of a verb sends. The local patterns apply.
    if [ "${PANE_SETTLE:-0}" -eq 1 ] && [ -n "$PANE_LAST" ] && [ "$key" != "$PANE_LAST" ]; then
        PANE_LAST="$key"
        PANE_STATE=other
        ! line_is_credential "$CURSOR_LINE" || PANE_STATE=credential
        return 0
    fi
    PANE_LAST="$key"
    PANE_STATE=
    laya_pid_check || return 6
    # PANE_LIMIT: the seconds that are left before the deadline of a wait.
    out=$(printf '%s\n' "$window" | laya_call pane ${PANE_LIMIT:+--limit "$PANE_LIMIT"})
    case $? in 0) ;; 3) return 7 ;; *) return 6 ;; esac
    [[ "$out" =~ $PANE_RE ]] || return 6
    PANE_STATE="${BASH_REMATCH[1]}"
    [ "$PANE_STATE" = credential ] || ! line_is_credential "$CURSOR_LINE" || PANE_STATE=credential
    PANE_TEXT="$window"
    PANE_TEXT_KEY="$key"
    PANE_TEXT_STATE="$PANE_STATE"
    return 0
}

PROBE_FAILS=0

# probe_pane — one pane probe of a wait loop. Returns 3 on a credential
# prompt and 6 after 3 failed probes in a row, else 0. One failed probe
# (a slow machine, or a 503 while a guard uses the server) does not end the
# wait, and it still applies the local credential patterns.
probe_pane() {
    PANE_SETTLE=1 pane_state
    case $? in
        0)
            PROBE_FAILS=0
            [ "$PANE_STATE" != credential ] || return 3
            ;;
        6|7)
            PROBE_FAILS=$((PROBE_FAILS + 1))
            ! line_is_credential "$CURSOR_LINE" || return 3
            [ "$PROBE_FAILS" -lt 3 ] || return 6
            ;;
    esac
    return 0
}

# check_pane — pane_state for a verb that must not act on a credential
# prompt. Returns 3 (with the message) on a credential prompt, 6 (with the
# message) when Laya fails, else 0. A failed capture gets one more try, then
# it is a refusal: with no cursor line, the gate cannot examine the line
# (exit 4 when the pane is gone, else exit 5).
check_pane() {
    local rc
    pane_state
    rc=$?
    if [ "$rc" -eq 1 ]; then
        sleep .2
        pane_state
        rc=$?
    fi
    case $rc in
        0) [ "$PANE_STATE" != credential ] || { refuse_credential; return; } ;;
        1)
            current_companion_alive || fail 'no companion is open for this owner' 4
            printf '%s\n' 'cannot read the companion pane: try again' >&2
            return 5
            ;;
        7)
            printf '%s\n' 'laya: the cursor line is too long to examine: send --key C-c' >&2
            return 2
            ;;
        *) refuse_laya; return ;;
    esac
    return 0
}

GATE_LEVEL=
GATE_REASON=
LEVEL_RE='"level": "(safe|caution|dangerous)", "reason": "([^"]*)"'

# laya_gate [--screen] < TEXT — the command gate of the
# client (spec section 7). Sets GATE_LEVEL and GATE_REASON. Returns 2 when
# the client refuses the input (exit 2), 3 when the text is too long for
# Laya (exit 3: Laya would examine only its start) and 6 when it fails. [inferred] terminal.sh reads the fixed JSON shape with a
# bash regular expression, because jq is only recommended for clux.
laya_gate() {
    local out rc=0
    laya_pid_check || return 6
    out=$(laya_call command "$@") || rc=$?
    [ "$rc" -ne 2 ] || return 2
    [ "$rc" -ne 3 ] || return 3
    [ "$rc" -eq 0 ] || return 6
    [[ "$out" =~ $LEVEL_RE ]] || return 6
    GATE_LEVEL="${BASH_REMATCH[1]}"
    GATE_REASON="${BASH_REMATCH[2]}"
}

GUARD_HELD=0
GUARD_LATE=0
GUARD_TEXT=
GUARD_CUT=0
# A marker line that the guard puts in place of held text.
HELD_MARK_RE='^\[held by laya: [a-z_]+(, [0-9]+ lines)?\]$'

# laya_guard FILE [PIECES] [RUNS] — the output guard (spec section 8).
# PIECES=1: no cut to LAYA_GUARD_BYTES; the client guards all of
# the text in pieces of whole lines of at most LAYA_GUARD_BYTES, with one
# time limit (wait --pattern). RUNS (with PIECES): the first line of each
# run of lines that are next to each other (0,4,9). Sets GUARD_TEXT (the
# guarded text), GUARD_HELD (the count of held lines), GUARD_LATE (the
# count of held lines that the time limit left not examined: a later guard
# can show them) and GUARD_CUT (1 when only the last LAYA_GUARD_BYTES went
# to the guard, 2 when these bytes were one cut line, so nothing went; see
# guard_cut_note). Returns 6 when the
# client fails or its time limit ends. [inferred] The command substitution
# removes blank lines at the end of the text. The byte cut starts inside a
# line, maybe inside a token: the end of a secret with no prefix (ghp_,
# AKIA, a key name) that the guard cannot know. So the text up to the
# first newline goes, and no part of that line reaches the guard or Claude
# ("output cut" tells Claude). When the byte before the cut is a newline,
# the first line is whole and stays. A cut text with no newline is all one
# cut line, so none of it goes (GUARD_CUT=2).
laya_guard() {
    local data size tmp args=(output --render)
    if [ "${2:-0}" -eq 1 ]; then
        GUARD_CUT=0
        data=$(LC_ALL=C tr -d '\000' 2>/dev/null < "$1" && printf x) || return 6
        data="${data%x}"
        args+=(--pieces "$LAYA_GUARD_BYTES" --runs "${3:-0}")
        laya_guard_call "$data" "${args[@]}"
        return
    fi
    # A file, because $1 can be a pipe and is read two times: the size, then
    # the text. The file holds one byte more than the guard gets: the byte
    # before the cut. Bash drops NUL bytes from a command substitution with
    # a warning, so tr removes them first, and the size comes from wc.
    # LC_ALL=C on each command: tail and tr count bytes, not characters, and
    # tr does not stop on bytes that are not UTF-8.
    tmp=$(mktemp "$D/guard.XXXXXX") || return 6
    LC_ALL=C tail -c "$((LAYA_GUARD_BYTES + 1))" "$1" > "$tmp" || { rm -f "$tmp"; return 6; }
    size=$(LC_ALL=C wc -c < "$tmp")
    # The x keeps the newlines at the end.
    data=$(LC_ALL=C tr -d '\000' < "$tmp" && printf x)
    rm -f "$tmp"
    data="${data%x}"
    GUARD_CUT=0
    if [ "$((size + 0))" -gt "$LAYA_GUARD_BYTES" ]; then
        GUARD_CUT=1
        # When the byte before the cut is a newline, only that byte goes.
        # Else all up to the first newline goes: that byte and the cut line.
        # A NUL byte before the cut is gone after tr, but the rule gives the
        # same text: the cut line goes, or it is empty.
        case "$data" in
            $'\n'*) data="${data#?}" ;;
            *$'\n'*) data="${data#*$'\n'}" ;;
            *) data= GUARD_CUT=2 ;;
        esac
    fi
    laya_guard_call "$data" "${args[@]}"
}

# The note for a byte cut of laya_guard (GUARD_CUT), for each verb that
# prints guarded text.
guard_cut_note() {
    case "$GUARD_CUT" in
        1) printf 'output cut: the last %s bytes, from the first full line\n' "$LAYA_GUARD_BYTES" ;;
        2) printf 'output cut: the last %s bytes are one line with no start: nothing is shown\n' "$LAYA_GUARD_BYTES" ;;
    esac
}

# laya_guard_call DATA ARGS... — send DATA to the client of laya_guard and
# read its answer.
laya_guard_call() {
    local out data="$1"
    shift
    laya_pid_check || return 6
    out=$(printf '%s' "$data" | laya_call "$@" --limit "$LAYA_GUARD_LIMIT") || return 6
    case "$out" in held=*) ;; *) return 6 ;; esac
    GUARD_HELD="${out%%$'\n'*}"
    GUARD_LATE=0
    case "$GUARD_HELD" in
        *' not_examined='*) GUARD_LATE="${GUARD_HELD##* not_examined=}"; GUARD_HELD="${GUARD_HELD%% *}" ;;
    esac
    GUARD_HELD="${GUARD_HELD#held=}"
    case "$GUARD_HELD" in ''|*[!0-9]*) return 6 ;; esac
    case "$GUARD_LATE" in ''|*[!0-9]*) return 6 ;; esac
    case "$out" in
        *$'\n'*) GUARD_TEXT="${out#*$'\n'}" ;;
        *) GUARD_TEXT= ;;
    esac
    return 0
}

# reserved_word TEXT — the functions of rc.bash start with __clux_. Only
# run itself types them, so send and run refuse them with no Laya request.
# Quotes and backslashes can split the name ("__clux"_run), so the test
# reads the text with none. It is not complete (${a}ux_run): __clux_run and
# __clux_line also refuse a call that the prompt did not type.
reserved_word() {
    local t=${1//[\"\'\\]/}
    case "$t" in
        *__clux_*) fail 'refused: __clux_ names are for the companion only' 2 ;;
    esac
}

# key_name KEY — a tmux key name: a named key (Enter, Up, F5 and more), or
# a modifier (C-, M-, S-) with one character or a named key, or ^X. tmux
# types any other argument as text, with no echo check, so send refuses it
# (exit 2). One character alone is text too: send it with send -- TEXT.
key_name() {
    local k="$1" mods=0
    while key_is "$k" '[CMS]-?*'; do
        k="${k#??}"
        mods=1
    done
    key_is "$k" Enter Escape Tab BTab Space BSpace Up Down Left Right Home End \
        PageUp PgUp PageDown PgDn NPage PPage Insert IC Delete DC 'F[1-9]' 'F1[0-2]' && return 0
    case "$k" in
        '^'?) [ "$mods" -eq 0 ] ;;
        ?) [ "$mods" -eq 1 ] ;;
        *) return 1 ;;
    esac
}

# interrupt_key KEY — C-c, C-d, C-z, C-\ or Escape (spec section 7).
interrupt_key() { key_is "$1" C-c C-d C-z 'C-\\' '^c' '^d' '^z' '^\\' Escape; }

# nav_key KEY — a key that only moves in a pager or a menu: Up, Down, Left,
# Right, Home, End and the page keys, with no modifier. In a pager or a menu
# these keys go to the pane with no command request (spec section 7). Space
# is not one: it selects in a menu.
nav_key() { key_is "$1" Up Down Left Right Home End PageUp PgUp PageDown PgDn NPage PPage; }

# send_gate TEXT — the command gate for a send that ends a line (spec
# section 7). check_pane must run first: it sets CURSOR_LINE and
# SCREEN_ABOVE. The line is the cursor line plus TEXT. At the clux prompt
# the prompt goes off, and the line goes alone, as run sends it. In any
# other program (ssh, python3, psql) the full cursor line goes, with the 4
# lines above it as the screen. The cursor line is the
# text that tmux shows, so cells that readline erased show as spaces.
send_gate() {
    local line prompt=0 shell=0 flags
    if prompt_input; then
        line="$PROMPT_INPUT$1"
        prompt=1
        line="${line#"${line%%[![:space:]]*}"}"
    else
        # Text that clux typed and the pane does not show is in the line too.
        typed_split "$1"
        line="$LINE_HEAD$LINE_TYPED"
    fi
    reserved_word "$line"
    # [inferred] A blank line at the clux$ prompt runs nothing, so it needs
    # no request. In a program a blank line can accept a default ([Y/n], a
    # menu), so Laya gets the screen above it; only a blank screen too has
    # nothing to examine.
    case "$line" in
        *[![:space:]]*) ;;
        *)
            [ "$prompt" -eq 0 ] || return 0
            case "$SCREEN_ABOVE" in *[![:space:]]*) ;; *) return 0 ;; esac
            ;;
    esac
    # At the clux prompt a line runs in a subshell (__clux_line), so it
    # cannot change the pane shell. In another shell process (a nested bash
    # or zsh, with any prompt that Laya can call other) the line runs in
    # that shell: a line that can change it for later lines is dangerous.
    # This is also true in ssh, docker or kubectl: the shell is on the other
    # side. The process decides, not the Laya class of the prompt: only a
    # known program that is not a shell (python3, psql, vim) has no rules.
    if [ "$prompt" -eq 0 ] && ! pane_runs_program; then
        shell=1
    fi
    if [ "$prompt" -eq 1 ]; then
        # At the clux prompt the line runs as run runs it (__clux_line), so
        # Laya gets the line alone, as run gives it: output above the prompt
        # (cat notes.txt) must not lower the score of the line.
        laya_gate < <(printf '%s' "$line")
    elif [ "$shell" -eq 1 ]; then
        # The shell rule reads only the text that clux typed in this line,
        # not the prompt: the client gets the start of the line and the
        # typed text as two lines, and Laya gets them as one line.
        laya_gate --screen --shell < <(printf '%s\n%s\n%s\n' "$SCREEN_ABOVE" "$LINE_HEAD" "$LINE_TYPED")
    else
        laya_gate --screen < <(printf '%s\n%s\n' "$SCREEN_ABOVE" "$line")
    fi
    case $? in
        0) ;;
        2) fail 'laya: bad input' 2 ;;
        3) fail 'laya: the line is too long to examine: make it shorter' 2 ;;
        *) refuse_laya; return ;;
    esac
    case "$GATE_LEVEL" in
        caution) printf 'laya: caution (%s)\n' "$GATE_REASON" >&2 ;;
        dangerous)
            # run works only at the clux prompt. In a program (psql, a
            # nested shell, a [Y/n] question) only the user can type it.
            if [ "$prompt" -eq 1 ]; then
                printf 'laya: dangerous (%s): use run, it asks the user\n' "$GATE_REASON" >&2
            else
                printf 'laya: dangerous (%s): ask the user to type this line in the pane\n' "$GATE_REASON" >&2
            fi
            return 6
            ;;
    esac
    return 0
}

LINE_HEAD=
LINE_TYPED=

# $D/typed holds four lines: the cursor line before the last text that
# send typed, 1 when send sent a key that can edit the line after it typed
# (else 0), the text that send typed in this line, and the row of the
# cursor (from the top of the history) when the record started. send
# writes it; Enter and C-c from send remove it. When the user ends the line
# (Enter in a nested shell), the cursor goes to a new line: the record is
# old, and the next send removes it.
#
# typed_load — read the four lines of $D/typed into TYPED_BEFORE,
# TYPED_STRICT, TYPED_TEXT and TYPED_START. Returns 1 when there is no
# record.
typed_load() {
    TYPED_BEFORE= TYPED_STRICT=0 TYPED_TEXT= TYPED_START=
    [ -f "$D/typed" ] || return 1
    { IFS= read -r TYPED_BEFORE; IFS= read -r TYPED_STRICT; IFS= read -r TYPED_TEXT; IFS= read -r TYPED_START; } 2>/dev/null < "$D/typed"
    return 0
}

# typed_split TEXT — split the cursor line plus TEXT for the gate. LINE_TYPED
# is the text that clux typed in this line plus TEXT; LINE_HEAD is the start
# of the line before it (the prompt, and text that the user typed). When the
# cursor line is still the line before the last text, the pane did not show
# that text (echo off), so it goes to the gate too. When the line changed in
# another way (a key, the user, or the end of the line), all of the line is
# typed text: the rule then reads more, not less. No fork.
typed_split() {
    local before strict t row tt line
    rtrim "$CURSOR_LINE"
    line="$RTRIM"
    LINE_HEAD="$CURSOR_LINE"
    LINE_TYPED="$1"
    typed_load || return 0
    before="$TYPED_BEFORE" strict="$TYPED_STRICT" t="$TYPED_TEXT" row="$TYPED_START"
    rtrim "$t"
    tt="$RTRIM"
    if [ "$strict" != 1 ] && [ -n "$tt" ] && [[ "$line" == *"$tt" ]]; then
        LINE_HEAD="${line:0:$((${#line} - ${#tt}))}"
    elif typed_new_line "$row"; then
        rm -f "$D/typed"
        return 0
    elif [ -z "$t" ]; then
        [ "$strict" != 1 ] || { LINE_HEAD=; LINE_TYPED="$CURSOR_LINE$1"; }
        return 0
    elif [ "$CURSOR_LINE" = "$before" ]; then
        LINE_TYPED="$t$1"
        [ "$strict" != 1 ] || LINE_HEAD=
    else
        LINE_HEAD=
    fi
    LINE_TYPED="${CURSOR_LINE:${#LINE_HEAD}}$LINE_TYPED"
}

# typed_add BEFORE TEXT — send typed TEXT when the cursor line was BEFORE.
typed_add() {
    typed_load || { typed_row; TYPED_START="$TYPED_ROW"; }
    printf '%s\n%s\n%s\n%s\n' "$1" "${TYPED_STRICT:-0}" "$TYPED_TEXT$2" "$TYPED_START" > "$D/typed"
}

# typed_edit — send sent a key that can edit the line: the typed text can
# be anywhere in the line now. With no typed text (the key edits text that
# the user typed), all of the line is typed text.
typed_edit() {
    typed_load || { typed_row; TYPED_START="$TYPED_ROW"; }
    printf '%s\n1\n%s\n%s\n' "$TYPED_BEFORE" "$TYPED_TEXT" "$TYPED_START" > "$D/typed"
}

# typed_row — TYPED_ROW is the row of the cursor from the top of the
# history, TYPED_HIST the history size and TYPED_Y the cursor row. All are
# empty when tmux cannot tell.
TYPED_ROW=
TYPED_HIST=
TYPED_Y=
typed_row() {
    local pos h y
    TYPED_ROW=
    pos=$(tmux_state display-message -p -t "$S_PANE" '#{history_size} #{cursor_y}' 2>/dev/null) || return 1
    read -r h y <<< "$pos"
    case "$h" in ''|*[!0-9]*) return 1 ;; esac
    case "$y" in ''|*[!0-9]*) return 1 ;; esac
    TYPED_HIST="$h"
    TYPED_Y="$y"
    TYPED_ROW=$((h + y))
}

# typed_new_line ROW — the cursor is not on the line of ROW now: a line
# ended after send typed (the user pressed Enter), or the screen was
# cleared. The rows from ROW to the cursor row are one line when the typed
# text wraps; after an Enter they are two lines or more. Returns 1 when
# tmux cannot tell: the record then stays, and the gate reads more.
typed_new_line() {
    local joined
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    typed_row || return 1
    [ "$TYPED_ROW" -ne "$1" ] || return 1
    [ "$TYPED_ROW" -gt "$1" ] || return 0
    joined=$(tmux_state capture-pane -p -J -t "$S_PANE" -S "$(($1 - TYPED_HIST))" -E "$TYPED_Y") || return 1
    case "$joined" in *$'\n'*) return 0 ;; esac
    return 1
}

# key_is KEY PATTERN... — KEY matches one of the glob PATTERNs, with no case
# (tmux reads a key name with no case: enter is Enter). No subshell.
key_is() {
    local k="$1" p rc=1 was=0
    shift
    ! shopt -q nocasematch || was=1
    shopt -s nocasematch
    for p in "$@"; do
        # shellcheck disable=SC2254
        case "$k" in $p) rc=0; break ;; esac
    done
    [ "$was" -eq 1 ] || shopt -u nocasematch
    return "$rc"
}

# pane_shell_front — the pane shell (the clux shell) is in the front group
# of the pane (PANE_SHELL of pane_front): no run and no program is in front.
# Also true when tmux or ps cannot tell: the rule then only refuses more.
pane_shell_front() {
    [ "$PANE_FRONT_SET" = 1 ] || pane_front
    [ "$PANE_SHELL" = 1 ]
}

# refuse_meta_front — Escape is a Meta prefix in readline. When the clux
# shell is in front (at its prompt, or just before the prompt comes back,
# when __clux_flush already ran), it can stay in readline, and the next C-e
# is then M-C-e (shell-expand-line). A run or a program in front gets the
# key, so it goes. Other Meta keys (M-f, C-[) are not interrupt keys: the
# clux prompt takes only edit keys, and with no prompt on the screen send
# refuses each key but an interrupt key while the clux shell is in front.
refuse_meta_front() {
    ! pane_shell_front || fail 'the clux shell is in front: Escape is not permitted: use send --key C-c' 2
}

# accept_key KEY — a key that ends the line in readline: Enter, C-m, C-j.
accept_key() { key_is "$1" Enter C-m C-j '^m' '^j'; }

# edit_key KEY — the only keys that send gives with no Enter at the clux
# prompt and in a nested shell: they move in the line or delete text. It is
# a small list on purpose: Tab runs completion (the completion of make runs
# make -npq), Up and Down show history, M- and C-x keys run readline or zle
# commands, and each of them can run code with no Enter. A user binding of
# these keys (inputrc, bindkey) is out of scope (spec section 7).
edit_key() {
    key_is "$1" Left Right Home End BSpace DC Delete C-u C-k '^u' '^k'
}

# send_line LINE — end a line at the clux prompt: LINE runs in a subshell
# through __clux_line (spec section 7), not in the pane shell. A blank line
# runs nothing, so it gets a plain Enter.
send_line() {
    local sum
    case "$1" in
        *[![:space:]]*) ;;
        *) send_key Enter; return 0 ;;
    esac
    sum=$(command_sum "$1") || fail 'cannot make the sum of the line' 1
    printf '%s' "$1" > "$D/line.cmd"
    clear_line; send_literal "__clux_line $sum"; send_key Enter
}

# The front of the pane, from pane_front: PANE_NESTED=1 when a nested shell
# is in front (only the user ends a line there), PANE_PROGRAM=1 when a known
# program that is not a shell is in front (no shell rules), PANE_SHELL=1
# when the pane shell itself is in the front group (no run and no program:
# keys go to its readline). A verb reads the tree one time: pane_front sets
# PANE_FRONT_SET=1, and each check uses that read, so the checks of send
# see the same state. No wait loop uses these checks. When tmux or ps
# cannot tell, NESTED and SHELL are 1: the rules then only refuse more.
PANE_NESTED=1
PANE_PROGRAM=0
PANE_SHELL=0
PANE_FRONT_SET=0
pane_front() {
    local pid out
    PANE_FRONT_SET=1
    PANE_NESTED=1
    PANE_PROGRAM=0
    PANE_SHELL=1
    pid=$(tmux_state display-message -p -t "$S_PANE" '#{pane_pid}') || return 0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    out=$(front_kinds "$pid")
    case "$out" in
        [01]' '[01]' '[01])
            PANE_NESTED="${out%% *}"; out="${out#* }"
            PANE_PROGRAM="${out% *}"; PANE_SHELL="${out#* }"
            ;;
    esac
    return 0
}

# pane_runs_program — a known program that is not a shell (python3, psql,
# node, vim, less and others) is in the front of the pane. The shell rules
# do not apply there. Any other process (a shell, ssh, docker, kubectl, or a
# name that tmux or ps cannot give) gets the shell rules: they only refuse
# more.
pane_runs_program() {
    [ "$PANE_FRONT_SET" = 1 ] || pane_front
    [ "$PANE_PROGRAM" = 1 ]
}

# pane_nested_shell — a nested shell is in the front of the pane: only the
# user ends a line there (spec section 7). Also true when tmux or ps cannot
# tell: the rule then only refuses more.
pane_nested_shell() {
    [ "$PANE_FRONT_SET" = 1 ] || pane_front
    [ "$PANE_NESTED" = 1 ]
}

# front_kinds PID — one ps (pid, parent, group, state, arguments) of the processes
# below PID (the pane shell) gives "NESTED PROGRAM". #{pane_current_command}
# is not enough: a line of __clux_line runs in a subshell of the pane shell,
# so tmux gives bash, not python3. The name is the first argument with no
# path, no - and no case (Python on macOS).
# NESTED is 1 when a process in a front group (+ in the state) is a nested
# shell, or runs under a nested shell and is not a known program: text that
# sleep does not read goes to that shell at its next prompt. A nested shell
# is a shell that is not a fork of the pane shell (the __clux_sub subshell
# has the same arguments) and reads commands from the terminal: no script
# file (bash ./x.sh) and no -c (sh -c of npm or make), or -i or -s. Or a tool
# that gives a shell (ssh, docker exec, kubectl exec, su, tmux). A shell on a
# pty of its own (pty.spawn, :terminal) is in the front group of that pty.
# A shell with a name that is not in the list (a copy of bash, exec -a x
# bash, ksh93) has job control: it leads its own process group in front.
# A program of a line of __clux_line stays in the group of the subshell.
# So a front process that leads its group and is not a known program is a
# nested shell too, when it is not the subshell (a fork of the pane shell,
# with the same arguments). This includes a program that the user starts
# at the pane prompt (it leads its group too): only the user answers it.
# PROGRAM is 1 when a known program is in a front group, and no shell or ssh
# runs under a process that is not a shell.
front_kinds() {
    ps -A -o pid= -o ppid= -o pgid= -o stat= -o args= 2>/dev/null | awk -v root="$1" '
        function base(w) { sub(/.*\//, "", w); sub(/^-/, "", w); return tolower(w) }
        function shell(n) {
            return n ~ /^(r?bash|zsh|sh|dash|ksh.*|mksh|oksh|yash|fish|tcsh|csh|ash|busybox|nu|nushell|xonsh|elvish|pwsh|osh|ysh|oil|rc|es|ion|murex)$/
        }
        function remote(n) {
            return n ~ /^(ssh|mosh.*|telnet|rsh|rlogin|docker|podman|nerdctl|kubectl|oc|lxc|incus|su|nsenter|chroot|script|screen|tmux|session-manager-plugin|vagrant|multipass|distrobox|toolbox|machinectl)$/
        }
        function program(n) {
            return n ~ /^(i?python.*|bpython.*|psql|mysql|mariadb|sqlite3|redis-cli|mongo|mongosh|node|deno|bun|irb|pry|ghci|lua.*|r|julia|erl|iex|scala|sbcl|gdb|lldb|php|vi|vim|nvim|view|nano|pico|emacs|less|more|most|man|top|htop|btop|tig|fzf)$/
        }
        # A shell reads commands from the terminal when it has no script
        # file and no -c, or when it has -i or -s. sh -c "read -p x" of npm,
        # make or a git hook, and bash ./x.sh, are not nested shells. The
        # parse knows the options of the POSIX shells (bash, sh, dash, zsh,
        # ksh, mksh, yash, ash): a group of short letters (-euo), o and O
        # take the next word as a value (also in a group: -euo pipefail),
        # - and -- end the options, and a few long options (--rcfile,
        # --init-file and --emulate take a value). Any other form (an unknown
        # letter or long option, -c with no text, a value that is not there)
        # reads the terminal: fail closed. Another shell (fish, tcsh) runs no
        # script only when its first word is a script file.
        function posix(n) { return n ~ /^(r?bash|zsh|sh|dash|ksh.*|mksh|oksh|yash|ash)$/ }
        function reads(p,   w, n, i, j, ch, skip) {
            n = split(args[p], w, " ")
            if (!posix(name[p])) return !(name[p] != "busybox" && n >= 2 && w[2] !~ /^[-+]/)
            for (i = 2; i <= n; i++) {
                if (w[i] == "--" || w[i] == "-") return (i == n)
                if (w[i] ~ /^--/) {
                    if (w[i] == "--rcfile" || w[i] == "--init-file" || w[i] == "--emulate") { i++; continue }
                    if (w[i] ~ /^--(login|noprofile|norc|no-rcs|noediting|posix|restricted|verbose|debugger|dump-strings|dump-po-strings|pretty-print)$/) continue
                    return 1
                }
                if (w[i] !~ /^[-+]/) return 0
                if (w[i] !~ /^[-+][A-Za-z]+$/) return 1
                skip = 0
                for (j = 2; j <= length(w[i]); j++) {
                    ch = substr(w[i], j, 1)
                    if (ch == "o" || ch == "O") skip++
                    else if (ch == "c" && w[i] ~ /^-/) continue
                    else if (index("abefhklmnprtuvxBCDEHIPT", ch) == 0) return 1
                }
                i += skip
            }
            return 1
        }
        function nest(p) {
            if (remote(name[p])) return 1
            if (grp[p] == p && !program(name[p]) && (up[p] != root || args[p] != args[root])) return 1
            return shell(name[p]) && args[p] != args[root] && reads(p)
        }
        { a = $5; for (i = 6; i <= NF; i++) a = a " " $i
          up[$1] = $2; grp[$1] = $3; args[$1] = a; front[$1] = ($4 ~ /\+/)
          name[$1] = base($5) }
        END {
            if (!(root in up)) { print "1 0 1"; exit }
            nested = 0; found = 0; inner = 0
            for (p in up) {
                if (p == root) continue
                q = up[p]; other = 0; under = 0; n = 0
                while (q in up && q != root && n < 64) {
                    if (!shell(name[q]) && name[q] != "ssh") other = 1
                    if (nest(q)) under = 1
                    q = up[q]; n++
                }
                if (q != root) continue
                if ((shell(name[p]) || name[p] == "ssh") && other) inner = 1
                if (!front[p]) continue
                if (program(name[p])) found = 1
                if (nest(p) || (under && !program(name[p]))) nested = 1
            }
            print nested " " ((found && !inner) ? 1 : 0) " " front[root]
        }'
}

# wait_for_echo TEXT BEFORE — after a send with no Enter, wait at most 2 s
# until the cursor line ends with the text or is not BEFORE any more. The
# next gate reads the cursor line, so the text must be on the screen. A
# program that takes the key and does not show it (q in a pager) changes the
# line, so that is not hidden text. Returns 1 when the line did not change.
wait_for_echo() {
    local i=0
    while [ "$i" -lt 10 ]; do
        if capture_cursor_line; then
            case "$CURSOR_LINE" in *"$1") return 0 ;; esac
            [ "$CURSOR_LINE" = "$2" ] || return 0
        fi
        sleep .2
        i=$((i + 1))
    done
    return 1
}

# shell_line — the cursor line is a shell prompt: the clux$ prompt, or a
# prompt that Laya calls shell_prompt (ssh, python3, psql).
shell_line() {
    prompt_input && return 0
    [ "$PANE_STATE" = shell_prompt ]
}

# cursor_mid_line — 0: there is text after the cursor on the cursor row;
# 1: the cursor is at the end; 2: the verb cannot tell (the capture or the
# client failed). cursor_x counts screen cells, and a wide character takes
# 2, so the client counts the cells of the row.
cursor_mid_line() {
    local pos x y alt row rc
    pos=$(tmux_state display-message -p -t "$S_PANE" '#{cursor_x} #{cursor_y} #{alternate_on}') || return 2
    read -r x y alt <<< "$pos"
    case "$x$y" in ''|*[!0-9]*) return 2 ;; esac
    # A full-screen program (vim, nano, less) uses the alternate screen. Its
    # cursor is on a character, and its text is not a line of a shell.
    [ "$alt" != 1 ] || return 1
    row=$(tmux_state capture-pane -p -t "$S_PANE" -S "$y" -E "$y") || return 2
    # A row of printable ASCII has one cell for each character: no client.
    if row_is_ascii "$row"; then
        rtrim "$row"
        [ "${#RTRIM}" -gt "$x" ]
        return
    fi
    rc=$(printf '%s\n' "$row" | "$LAYA_PY" "$LAYA_CLIENT" after-cursor "$x" 2>/dev/null) || return 2
    case "$rc" in
        mid) return 0 ;;
        end) return 1 ;;
    esac
    return 2
}

# hides_text TEXT — TEXT has a character that can hide or reorder a part
# of what the user reads in the question of a dangerous run, or that acts
# on the pane: a C0 or C1 control character, DEL, a Unicode format
# character (Cf: the bidi controls, the zero width characters, the tag
# characters) or the line and paragraph separators. The list is in UTF-8
# bytes (Unicode 15.0), so it does not depend on the locale; a test
# compares it with unicodedata. run and send use this one list.
HIDE_PATTERNS=(
    $'*[\x01-\x1f\x7f]*'
    $'*\xc2[\x80-\x9f\xad]*'
    $'*\xd8[\x80-\x85\x9c]*' $'*\xdb\x9d*' $'*\xdc\x8f*'
    $'*\xe0\xa2[\x90\x91]*' $'*\xe0\xa3\xa2*' $'*\xe1\xa0\x8e*'
    $'*\xe2\x80[\x8b-\x8f\xa8-\xae]*' $'*\xe2\x81[\xa0-\xa4\xa6-\xaf]*'
    $'*\xef\xbb\xbf*' $'*\xef\xbf[\xb9-\xbb]*'
    $'*\xf0\x91\x82\xbd*' $'*\xf0\x91\x83\x8d*' $'*\xf0\x93\x90[\xb0-\xbf]*'
    $'*\xf0\x9b\xb2[\xa0-\xa3]*' $'*\xf0\x9d\x85[\xb3-\xba]*'
    $'*\xf3\xa0\x80[\x81\xa0-\xbf]*' $'*\xf3\xa0\x81[\x80-\xbf]*'
)
hides_text() {
    local LC_ALL=C p
    for p in "${HIDE_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        [[ $1 != $p ]] || return 0
    done
    return 1
}

# row_is_ascii ROW — each byte of ROW is printable ASCII. LC_ALL=C makes
# [:print:] match bytes, not characters.
row_is_ascii() {
    local LC_ALL=C
    case "$1" in *[![:print:]]*) return 1 ;; esac
    return 0
}

hidden_text() { [ -e "$D/hidden" ]; }

refuse_hidden() {
    printf '%s\n' 'text that the pane does not show is on the line: send --key C-c first' >&2
    return 3
}

# $2=1 adds the pane probe on each fifth step (each 1 s): a credential prompt
# ends the wait with 3, a Laya confirmation with 8, a client failure with 6.
# PANE_STATE keeps the last answer for the pane= line of wait --idle.
wait_for_prompt() {
    local deadline probe="${2:-0}" tick=0
    deadline=$((SECONDS + $1))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if capture_cursor_line; then
            line_at_prompt && return 0
            tick=$(( (tick + 1) % 5 ))
            if [ "$probe" -eq 1 ] && [ "$tick" -eq 1 ]; then
                ! laya_confirm_pending || return 8
                probe_pane || return
            fi
        fi
        sleep .2
    done
    return 1
}

# After __clux_clear the whole visible screen is the prompt line and nothing
# else. A prompt test on the cursor line is not enough: it can pass before
# the pane shell reads the clear line, and clear-history then runs before the
# screen is clear. A cursor_y test is not enough either: a secret command can
# move the cursor to row 0 itself.
wait_for_clear() {
    local deadline text
    deadline=$((SECONDS + $1))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if text=$(tmux_state capture-pane -p -t "$S_PANE"); then
            rtrim "$text"
            [ "$RTRIM" = "$PROMPT_MARK" ] && return 0
        fi
        sleep .2
    done
    return 1
}

# Asking about ONE pane needs no listing and no grep: list-panes exits non-zero
# when the target does not resolve. (display-message -p is not a substitute — it
# exits 0 with empty output for a missing pane.)
current_companion_alive() {
    state_load || return 1
    [ -n "$S_PANE" ] || return 1
    state_is_ours || return 1
    if [ "$OWNER_KIND" = session ]; then
        companion_pane_is_ours "$S_SOCKET" "$S_PANE"
        return
    fi
    tmux_state list-panes -t "$S_PANE" >/dev/null 2>&1
}

# state_is_ours — the state that state_load read belongs to this owner. For
# a session owner the session field must be the session id of the caller:
# two sessions can have the same first 8 characters, and after /clear the
# old companion has the old id (spec 2026-09-30, section 6).
state_is_ours() {
    [ "$OWNER_KIND" != session ] || [ "$S_SESSION" = "$SESSION_ID" ]
}

# companion_pane_is_ours SOCKET PANE — PANE on the server at SOCKET holds
# the token of this state in its @clux-companion option (spec 2026-09-30,
# section 8). A pane id is unique only in one server, and a restarted server
# starts again at %0: without the mark, a stale pane id can name a pane of
# the user. For a pane that is gone, the value is empty or tmux fails, so
# the compare fails.
companion_pane_is_ours() {
    local mark
    [ -n "$1" ] && [ -n "$2" ] && [ -n "$S_TOKEN" ] || return 1
    mark=$(tmux -S "$1" display-message -p -t "$2" '#{@clux-companion}' 2>/dev/null) || return 1
    [ "$mark" = "$S_TOKEN" ]
}

check_tmux_version() {
    local version major minor
    version=$(tmux -V 2>/dev/null) || fail 'tmux is required' 2
    version="${version#tmux }"
    version="${version%%[!0-9.]*}"
    major="${version%%.*}"
    minor="${version#*.}"
    minor="${minor%%.*}"
    case "$major:$minor" in *[!0-9:]*|*:|:*) fail 'cannot read the tmux version' 2 ;; esac
    [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 2 ]; } || fail 'clux terminal needs tmux 3.2 or newer' 2
}

# find_dashboard — the pane of the `claude agents` dashboard that owns this
# session, on the default tmux server (spec 2026-09-30, section 7). Sets
# DASH_SERVER, DASH_SOCKET, DASH_PANE and DASH_SESSION. Fails when the
# default server does not answer or no dashboard pane is found: open then
# uses socket mode. A session owner needs no server key, so a server that
# does not answer is not an error here.
DASH_SERVER=
DASH_SOCKET=
DASH_PANE=
DASH_SESSION=
find_dashboard() {
    local info file found sessions
    DASH_SERVER= DASH_SOCKET= DASH_PANE= DASH_SESSION=
    info=$(tmux display-message -p '#{pid}-#{start_time} #{socket_path}' 2>/dev/null) || return 1
    DASH_SERVER="${info%% *}"
    DASH_SOCKET="${info#* }"
    _clux_valid_server_key "$DASH_SERVER" && [ -n "$DASH_SOCKET" ] || return 1
    # hooks/agent-state.sh writes agents/<pane>~<session id> at the first
    # prompt, so the file is there before the first Bash call.
    for file in "$(resolve_agent_state_dir)/$DASH_SERVER/agents/"*"~$SESSION_ID"; do
        [ -e "$file" ] || continue
        found="${file##*/}"
        DASH_PANE="${found%%'~'*}"
        break
    done
    if [ -z "$DASH_PANE" ]; then
        found=$(resolve_agents_pane_by_cwd "$PWD")
        DASH_PANE="${found##* }"
    fi
    [ -n "$DASH_PANE" ] || return 1
    # [inferred] list-panes, not display-message: display-message -p can exit
    # 0 for a pane that is gone.
    sessions=$(tmux -S "$DASH_SOCKET" list-panes -t "$DASH_PANE" -F '#{session_id}' 2>/dev/null) || return 1
    DASH_SESSION="${sessions%%$'\n'*}"
    [ -n "$DASH_SESSION" ]
}

open_command() {
    local mode=split size=30% socket pane shell
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --socket) mode=socket; shift ;;
            --size) [ "$#" -ge 2 ] || usage; size="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    case "$size" in
        [1-9]%|[1-9][0-9]%|100%) ;;
        *) fail 'size must be N%' 2 ;;
    esac
    terminal_init
    check_tmux_version
    mkdir -p "$ROOT"; chmod 700 "$ROOT"
    if [ "$OWNER_KIND" = session ]; then
        mkdir -p "$ROOT/sessions"; chmod 700 "$ROOT/sessions"
    fi
    # The lock of $D until open exits (dir_lock). A second open of this owner
    # waits here, then finds the companion of the first and uses it.
    dir_lock "$D" "$DIR_LOCK_WAIT" || refuse_dir_lock
    reap_companions
    if current_companion_alive; then
        laya_restart_if_down || return
        # [inferred] The companion is alive and stays. With no watchdog, open
        # says so and exits 1; the next open tries again. [inferred]
        watch_ensure || { [ "$?" -eq 5 ] && return 5; fail 'cannot start the companion watchdog' 1; }
        report_open
        return
    fi
    # [inferred] Two sessions can have the same first 8 characters (spec
    # 2026-09-30, section 6). The directory of another live session stays.
    if [ "$OWNER_KIND" = session ] && state_load && ! state_is_ours \
        && owner_alive "$S_OWNER_PID" "$S_OWNER_START"; then
        fail 'the companion directory belongs to another session' 2
    fi
    laya_open_check
    # [inferred] A dead companion of this owner can still own a Laya server,
    # so its directory goes through remove_companion_dir, not rm -rf.
    if [ -d "$D" ]; then
        remove_companion_dir "$D" 0
        [ "$OWNER_KIND" != session ] || watch_stop "$S_WATCH_PID" "${D##*/}"
        stop_reaped_servers
    fi
    umask 077; mkdir -p "$D"
    # The fields of a session owner (spec 2026-09-30, section 6). The old
    # state can have set them, so each one gets its value here.
    S_SESSION=; S_OWNER_PID=; S_OWNER_START=; S_SERVER=; S_WATCH_PID=
    if [ "$OWNER_KIND" = session ]; then
        S_SESSION="$SESSION_ID"
        S_OWNER_PID="$OWNER_PID"
        S_OWNER_START="$OWNER_START"
        # Placement (section 7): a window in the tmux session of the
        # dashboard, else a private server. --socket forces the private
        # server. [inferred] --size does not apply and gives no error.
        if [ "$mode" != socket ] && find_dashboard; then
            mode=window
        else
            mode=socket
        fi
    fi
    # The prompt has a random token, so output text that shows clux$ is not
    # the prompt (spec section 9).
    S_TOKEN=$(random_hex 4) || S_TOKEN=
    [ "${#S_TOKEN}" -eq 8 ] || S_TOKEN=$(printf '%04x%04x' "$RANDOM" "$RANDOM")
    PROMPT_MARK="clux-$S_TOKEN\$"
    CONT_MARK="clux-$S_TOKEN> "
    write_rc_file
    socket="$D/sock"
    if [ "$mode" = socket ] && [ "${#socket}" -gt 100 ]; then
        rm -rf "$D"
        fail 'the private tmux socket path is longer than 100 bytes' 2
    fi
    LAYA_PID=
    LAYA_URL="${CLUX_LAYA_URL:-}"
    LAYA_KEY="${CLUX_LAYA_KEY:-}"
    if [ -z "$LAYA_URL" ]; then
        : > "$D/laya.log"
        laya_start_server "$D/laya.log" 1 || open_abort 0 'laya not available: the server did not start'
    fi
    # [inferred] A session owner writes a first state before the pane: a
    # directory with a Laya server always has a record of its pid and its
    # owner, also when open stops early, so the reaper can stop the server.
    [ "$OWNER_KIND" != session ] || write_state "" "" "" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
    printf -v shell '%q --noprofile --rcfile %q -i' "$(command -v bash)" "$D/rc.bash"
    # [inferred] A pane or prompt failure keeps exit code 1, as in 3.9.0.
    case "$mode" in
        window)
            # -d keeps the focus of the user where it is. [inferred] -c: the
            # shell starts in the directory of the Bash call, as in socket mode.
            pane=$(tmux -S "$DASH_SOCKET" new-window -d -P -F '#{pane_id}' -t "$DASH_SESSION:" \
                -n "clux-terminal ${D##*/}" -c "$PWD" \
                -e "PATH=$PATH" -e BASH_SILENCE_DEPRECATION_WARNING=1 "$shell" 3>&-) \
                || open_abort 0 'cannot open companion' 1
            S_SERVER="$DASH_SERVER"
            write_state window "$pane" "$DASH_SOCKET" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
            # [inferred] The clux window rename must not change the name.
            tmux_state set-option -w -t "$pane" automatic-rename off >/dev/null 2>&1 || true
            ;;
        socket)
            pane=$(tmux -S "$socket" -f /dev/null new-session -d -P -F '#{pane_id}' -s clux-terminal \
                -e "PATH=$PATH" -e BASH_SILENCE_DEPRECATION_WARNING=1 "$shell" 3>&-) \
                || open_abort 0 'cannot open private companion' 1
            write_state socket "$pane" "$socket" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
            ;;
        *)
            pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" -v -l "$size" \
                -e "PATH=$PATH" -e BASH_SILENCE_DEPRECATION_WARNING=1 "$shell" 3>&-) \
                || open_abort 0 'cannot open companion' 1
            write_state split "$pane" "" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
            ;;
    esac
    # The mark of a session owner (section 8): the verbs and the reaper take
    # a pane with no mark as gone.
    if [ "$OWNER_KIND" = session ] \
        && ! tmux_state set-option -p -t "$pane" @clux-companion "$S_TOKEN" >/dev/null 2>&1; then
        # [inferred] The window arm of kill_companion kills only a pane with
        # the mark, so this pane goes here.
        [ "$S_MODE" != window ] || tmux_state kill-pane -t "$pane" >/dev/null 2>&1
        open_abort 1 'cannot mark the companion pane' 1
    fi
    tmux_state select-pane -t "$pane" -T clux-terminal
    if [ -n "$S_LAYA_PID" ]; then
        laya_wait_ready || open_abort 1 'laya not available: the server did not answer'
    fi
    wait_for_prompt 5 || open_abort 1 'the companion shell did not reach its prompt' 1
    # The watchdog of a session owner (spec 2026-09-30, section 9).
    # [inferred] A new companion with no watchdog is not safe: open undoes it
    # and exits 1, as for the other failures of a new companion. [inferred]
    watch_ensure || open_abort 1 'cannot start the companion watchdog' 1
    report_open
}

# ONE report for both the create and the reattach path, read from the state
# globals that write_state and state_load both fill. Printing it twice let the
# reattach path forget the attach= line a --socket caller needs.
report_open() {
    echo "pane=$S_PANE"
    echo "mode=$S_MODE"
    case "$S_MODE" in
        socket)
            echo "attach=tmux -S $S_SOCKET attach"
            # tmux refuses an attach from inside tmux when TMUX is set.
            echo "attach_in_tmux=TMUX= tmux -S $S_SOCKET attach"
            ;;
        window)
            echo "window=$(tmux_state display-message -p -t "$S_PANE" '#{session_name}:#{window_index}' 2>/dev/null)"
            ;;
    esac
}

ensure_open() {
    terminal_init
    current_companion_alive || fail 'no companion is open for this owner' 4
}

send_literal() { tmux_state send-keys -t "$S_PANE" -l -- "$1"; }
send_key() { tmux_state send-keys -t "$S_PANE" "$1"; }
# clear_line — remove all text of the prompt line. C-u removes only the text
# to the left of the cursor, so C-e goes to the end first: text to the right
# (after Home) must not join the typed __clux_ line.
clear_line() { send_key C-e; send_key C-u; }

# The busy lock is a directory. busy/owner names the run that holds it, so a
# reader of an older run cannot free the lock of a newer run.
release_busy() { rm -f "$D/busy/owner" "$D/busy/pid"; rmdir "$D/busy" 2>/dev/null || true; }

# busy_holder_dead — busy/pid names the run verb that holds the lock until it
# typed __clux_run: its pid and its start time. When that verb is gone (the
# Bash tool killed it during the gate), no run can start: the lock is free.
# The start time must match too: a pid alone can come back as another
# process, which would keep the lock for ever.
busy_holder_dead() {
    local pid= start=
    [ -f "$D/busy/pid" ] || return 1
    read -r pid start 2>/dev/null < "$D/busy/pid" || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    ! owner_alive "$pid" "$start"
}

# reader_live N — a wait --run or run of N is reporting its output now: a
# verb holds the reading lock of N (lock_take). With no file, no verb holds
# it. Else the test takes the lock one time and frees it at once; a reader
# waits READ_LOCK_WAIT for it, so this short test does not refuse a reader.
READ_LOCK_WAIT=2
reader_live() {
    [ -e "$D/$1.reading" ] || return 1
    ! lock_held "$D/$1.reading" || return 0
    lock_take "$D/$1.reading" 0 || return 0
    lock_drop "$D/$1.reading"
    return 1
}

# take_reading_lock N — while this verb reports the output of run N, no new
# run takes the busy lock or deletes the output, and no other verb reports
# the same run: one reader would delete the output that the other reads.
take_reading_lock() {
    lock_take "$D/$1.reading" "$READ_LOCK_WAIT" \
        || fail "another verb reads the output of run $1 now: try again" 5
}

TYPING_LOCK=0

# verb_exit — the EXIT trap of a verb: free each lock of the verb.
verb_exit() {
    lock_drop_all
    TYPING_LOCK=0
}

# run_not_started — after C-c: when the .cmd of the last run is still there,
# the pane shell never read the typed line (text came before it, or C-c
# came before its Enter), in plain and in confirm mode. The run ends as not
# started, so the verbs do not wait for a run that is not in the pane and a
# new run can take the busy lock. A __clux_run that comes later finds the
# .rc and refuses.
run_not_started() {
    local n="${S_SEQ:-0}"
    [ "$n" -gt 0 ] && [ -e "$D/$n.cmd" ] && [ ! -e "$D/$n.rc" ] || return 0
    sleep .3
    [ -e "$D/$n.cmd" ] && [ ! -e "$D/$n.rc" ] || return 0
    rm -f "$D/$n.cmd" "$D/$n.confirm"
    : > "$D/$n.notstarted"; : > "$D/$n.declined"; : > "$D/$n.done"
    printf '126\n' > "$D/$n.rc.tmp" && mv -f "$D/$n.rc.tmp" "$D/$n.rc"
}

# The locks of the verbs: the typing lock ($D/typing), the reading lock of a
# run ($D/<n>.reading) and the directory lock (DIR.lock, beside DIR). Each
# is a kernel lock (flock) on its file. A small perl process (LOCK_HELPER)
# holds it for the verb that started it. The kernel frees the lock when
# that process ends, and the process ends when its parent (the verb) ends,
# also after kill -9: it tests the parent pid each 0.2 s. So a verb that
# was killed never keeps a lock. There is no stale lock to take over, and
# no pid of a holder to test.
#
# A holder deletes the file first and then frees the lock. The helper takes
# a lock only when the path still names the file that it locked (the same
# device and inode). Else it tries again, so a verb that waited on a deleted
# file does not hold it together with a verb that made the new file. A
# symbolic link in the place of the file (the lock format of clux 4.0) is
# deleted, and the helper tries again.
#
# The helper prints "ok <its pid>", "busy" (the wait ended) or "error" (it
# cannot open the file).
LOCK_HELPER='use strict; use Fcntl qw(:flock O_RDWR O_CREAT O_NOFOLLOW);
my ($path, $wait) = @ARGV; my $parent = getppid(); my $end = time + $wait;
$| = 1;
while (1) {
    my $fh;
    unless (sysopen($fh, $path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600)) {
        if (-l $path) { unlink $path or do { print "error\n"; exit 1 }; next }
        print "error\n"; exit 1;
    }
    if (flock($fh, LOCK_EX | LOCK_NB)) {
        my @held = stat($fh); my @now = lstat($path);
        if (@now && $held[0] == $now[0] && $held[1] == $now[1]) {
            print "ok $$\n"; close STDOUT;
            select(undef, undef, undef, 0.2) while getppid() == $parent;
            exit 0;
        }
        close $fh; next;
    }
    close $fh;
    if (time >= $end || getppid() != $parent) { print "busy\n"; exit 1 }
    select(undef, undef, undef, 0.2);
}'

# LOCKS — the locks of this process: a line "<path> <helper pid>" for each,
# after a newline.
LOCKS=$'\n'

# lock_take PATH SECONDS — take the lock of PATH. Wait at most SECONDS while
# another verb holds it (0: try one time). Returns 1 when it is not free or
# the file cannot be opened. Call it in the verb itself, never in $(...) or
# in a pipe: the lock ends with the process that took it. The exec in the
# process substitution makes the verb the parent of the helper. The EXIT
# trap frees the lock.
lock_take() {
    local line
    exec 7< <(exec perl -e "$LOCK_HELPER" "$1" "$2" < /dev/null 2> /dev/null 3>&-)
    read -r line <&7 || line=
    exec 7<&-
    case "$line" in
        'ok '*)
            LOCKS="$LOCKS$1 ${line#ok }"$'\n'
            trap verb_exit EXIT
            return 0
            ;;
        busy) return 1 ;;
        error) printf 'clux: cannot open the lock file %s\n' "$1" >&2; return 1 ;;
    esac
    fail 'clux terminal needs perl' 2
}

# lock_held PATH — this process holds the lock of PATH.
lock_held() {
    case "$LOCKS" in *$'\n'"$1 "*) return 0 ;; esac
    return 1
}

# lock_drop PATH — free the lock of PATH when this process holds it: delete
# the file, then stop the helper.
lock_drop() {
    local rest pid nl=$'\n'
    lock_held "$1" || return 0
    rest="${LOCKS#*"$nl$1 "}"
    pid="${rest%%"$nl"*}"
    rm -f "$1"
    kill "$pid" 2>/dev/null || true
    LOCKS="${LOCKS%%"$nl$1 $pid$nl"*}$nl${LOCKS#*"$nl$1 $pid$nl"}"
}

# lock_drop_all — free each lock of this process (the EXIT trap).
lock_drop_all() {
    local line
    while IFS= read -r line; do
        [ -z "$line" ] || lock_drop "${line% *}"
    done <<< "$LOCKS"
}

# take_typing_lock — one verb at a time reads the cursor line, asks Laya
# and types (spec section 7). Without it, two sends in parallel read the
# same cursor line, Laya examines each piece alone, and the two pieces make
# one line that no gate examined. Returns 5 with the message when another
# verb holds it.
take_typing_lock() {
    lock_take "$D/typing" 0 || {
        printf '%s\n' 'another send or run is typing in the pane: try again' >&2
        return 5
    }
    TYPING_LOCK=1
}

# lock_and_load — take the typing lock, then read the state again: a run
# that another verb started before the lock has a new seq (and maybe a
# .confirm), and each decision after the lock needs it.
lock_and_load() {
    take_typing_lock || return 5
    state_load || fail 'no companion is open for this owner' 4
}

release_typing_lock() {
    [ "$TYPING_LOCK" -eq 1 ] || return 0
    lock_drop "$D/typing"
    TYPING_LOCK=0
}

# The directory lock: the ONE rule for the verbs that make or remove a
# companion directory (open, close, the watchdog and the reaper). Each one
# makes or removes DIR only while it holds DIR.lock. Without it, two opens
# of one owner (two parallel Bash calls, or a session and its subagent) both
# make DIR, and the one that fails removes the state of the other. The lock
# is beside DIR, not in it, because open and close remove DIR.
#
# dir_lock DIR SECONDS — take the lock of DIR. Wait at most SECONDS while
# another verb holds it (0: try one time). Returns 1 when it is not free.
dir_lock() {
    [ -d "${1%/*}" ] || return 1
    lock_take "$1.lock" "$2"
}

# dir_held DIR — this process holds the lock of DIR.
dir_held() { lock_held "$1.lock"; }

# dir_unlock DIR — free the lock of DIR when this process holds it.
dir_unlock() { lock_drop "$1.lock"; }

# refuse_dir_lock — the message when another verb holds the lock too long.
refuse_dir_lock() {
    fail 'another open or close of this companion is at work: try again' 5
}

# reap_stale_locks — delete the lock file of a directory that is gone. A
# holder deletes its file, so such a file stays only after a holder was
# killed. The file goes only under its lock, so a verb that holds it keeps
# it, and a verb that waits on it takes the new file (lock_take).
reap_stale_locks() {
    local file
    for file in "$ROOT"/*.lock "$ROOT"/sessions/*.lock; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        [ ! -e "${file%.lock}" ] || continue
        ! lock_held "$file" || continue
        ! lock_take "$file" 0 || lock_drop "$file"
    done
}

# line_unchanged — the cursor line is still the line that the gate
# examined (spec section 7). The gate can take some seconds; in that time
# a program can show a new prompt (Password: in ssh) or change the line.
# Returns 5 with the message when the line changed.
line_unchanged() {
    local gated="$CURSOR_LINE"
    if capture_cursor_line && [ "$CURSOR_LINE" = "$gated" ]; then
        return 0
    fi
    printf '%s\n' 'the line changed while Laya examined it: read, then send again' >&2
    return 5
}

# release_run N — free the lock only for the last run. wait --run on an older
# run must not free the lock of a run that continues.
release_run() {
    local owner=
    [ "$1" -eq "${S_SEQ:-0}" ] || return 0
    read -r owner 2>/dev/null < "$D/busy/owner" || owner=
    [ -z "$owner" ] || [ "$owner" = "$1" ] || return 0
    release_busy
}

# The last run has output that the guard could not examine (<n>.held). It
# keeps the lock, so no new run deletes that output, until wait --run gives
# it.
output_held() {
    [ "${S_SEQ:-0}" -gt 0 ] && [ -e "$D/$S_SEQ.held" ]
}

# seq_now — the seq in the state file now. Another verb can start a run
# while this verb waits, so the checks below read it again on each call and
# do not use the S_SEQ of the start of the verb. With no state file, S_SEQ.
seq_now() {
    local n
    n=$(state_load && printf '%s' "$S_SEQ") && [ -n "$n" ] || n="${S_SEQ:-0}"
    printf '%s' "$n"
}

# The last run was secret. Its text can still be on the screen, so read and
# wait --pattern refuse until the next run clears the screen and the history.
# SEQ (from seq_now) lets a loop read the seq one time for two checks.
last_run_secret() {
    local n="${1:-}"
    [ -n "$n" ] || n=$(seq_now)
    [ "${n:-0}" -gt 0 ] && [ -e "$D/$n.secret" ]
}

refuse_secret() {
    printf '%s\n' 'the last run was secret: do a plain run first, it clears the screen' >&2
    return 3
}

# A dangerous run waits for the answer of the user in the pane.
laya_confirm_pending() {
    local n="${1:-}"
    [ -n "$n" ] || n=$(seq_now)
    [ "${n:-0}" -gt 0 ] && [ -e "$D/$n.confirm" ]
}

refuse_confirm() {
    printf '%s\n' 'laya confirmation in the companion pane: the user must answer it there' >&2
    return 3
}

# A run that ended on its time limit keeps the lock. The first reader that
# finds its <n>.rc removes it.
release_if_done() {
    [ "${S_SEQ:-0}" -gt 0 ] && [ -f "$D/$S_SEQ.rc" ] && ! output_held \
        && ! reader_live "$S_SEQ" && release_run "$S_SEQ"
    return 0
}

# The single place a finished run is reported, so --secret cannot be honoured on
# one path and forgotten on the other.
#
# <n>.rc can come before <n>.done: a background process of the command keeps
# the tee pipe open. The grace here is one second, then the output that is
# present is reported with a note. The output goes through the Laya output
# guard after the cut to --max-lines. When the guard fails, no output text
# goes to Claude and the verb exits 6.
report_run() {
    local n="$1" max="$2" rc i=0 lines last reason guard=0
    # A declined run wrote .done before .rc, so there is no grace and no note.
    if [ -e "$D/$n.declined" ]; then
        read -r rc 2>/dev/null < "$D/$n.rc"
        if [ -e "$D/$n.notstarted" ]; then
            printf 'run %s did not start: the typed line changed\nexit=%s\n' "$n" "$rc"
        else
            printf 'laya: declined by the user\nexit=%s\n' "$rc"
        fi
        rm -f "$D/$n.out"
        release_run "$n"
        return 0
    fi
    # While this verb reports, no new run takes the lock or deletes the
    # output, and no other verb reports the same run: one reader would
    # delete the output that the other reads.
    take_reading_lock "$n"
    while [ ! -e "$D/$n.done" ] && [ "$i" -lt 5 ]; do sleep .2; i=$((i + 1)); done
    read -r rc 2>/dev/null < "$D/$n.rc"
    GUARD_HELD=0
    GUARD_LATE=0
    GUARD_TEXT=
    if [ ! -e "$D/$n.secret" ] && [ -s "$D/$n.out" ]; then
        last=$(tail -c 1 "$D/$n.out")
        lines=$(wc -l 2>/dev/null < "$D/$n.out")
        lines=$((lines + 0))
        [ -z "$last" ] || lines=$((lines + 1))
        if [ "$lines" -gt "$max" ]; then
            laya_guard <(tail -n "$max" "$D/$n.out") || guard=6
        else
            laya_guard "$D/$n.out" || guard=6
        fi
        if [ "$guard" -ne 0 ]; then
            # .out stays and the run keeps the lock, so wait --run gives the
            # output when Laya answers, and no new run deletes it.
            printf '%s\n' "output held: laya not available: use wait --run $n again" "exit=$rc"
            : > "$D/$n.held"
            printf 'laya not available: the output stays; use wait --run %s when Laya answers, or wait --run %s --discard\n' "$n" "$n" >&2
            lock_drop "$D/$n.reading"
            return 6
        fi
        [ "$lines" -le "$max" ] || printf 'output cut: the last %s of %s lines\n' "$max" "$lines"
        guard_cut_note
        [ -z "$GUARD_TEXT" ] || printf '%s\n' "$GUARD_TEXT"
        [ "$GUARD_HELD" -eq 0 ] || printf 'laya: held %s lines\n' "$GUARD_HELD"
        [ "$GUARD_LATE" -eq 0 ] \
            || printf 'laya: %s lines not examined in the time limit: use wait --run %s again\n' "$GUARD_LATE" "$n"
    fi
    [ -e "$D/$n.done" ] || printf '%s\n' 'output may be incomplete: a process still holds the output'
    if [ -s "$D/$n.caution" ]; then
        read -r reason 2>/dev/null < "$D/$n.caution"
        printf 'laya: caution (%s)\n' "$reason"
    fi
    printf 'exit=%s\n' "$rc"
    if [ "$GUARD_LATE" -gt 0 ]; then
        # The time limit left lines not examined (they can be the last
        # error). .out stays and the run keeps the lock, as when Laya
        # fails: wait --run gives them when Laya examines them.
        : > "$D/$n.held"
        # Limit: the guard starts at the last line, so the lines that are
        # not examined are the top lines, and a retry examines all lines
        # again from the bottom with the same time limit. A retry helps
        # only when Laya was slow for a short time; the message says so.
        printf 'laya did not examine all of the output in the time limit: it stays; use wait --run %s again (this helps only when Laya was slow for a short time), or wait --run %s --discard and run the command again with less output (for example | head -n 50): --max-lines keeps the last lines, which Laya examined\n' "$n" "$n" >&2
        lock_drop "$D/$n.reading"
        return 0
    fi
    rm -f "$D/$n.out" "$D/$n.held"
    lock_drop "$D/$n.reading"
    release_run "$n"
}

# The pane probe runs on each fifth step, not each step: the normal exit is
# the .rc test, and a credential prompt waits on a human, so one second of
# delay costs nothing. $3=0 skips the probe: wait --run on a secret run waits
# for the user. While <n>.confirm is present, the user answers the Laya
# question, so there is no probe. Returns 0 (done), 3 (credential), 6 (Laya
# failed) or 1.
wait_for_run_files() {
    local n="$1" probe="${3:-1}" deadline tick=0
    deadline=$((SECONDS + $2))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ -f "$D/$n.rc" ] && return 0
        tick=$(( (tick + 1) % 5 ))
        if [ "$probe" -eq 1 ] && [ "$tick" -eq 1 ] && [ ! -e "$D/$n.confirm" ]; then
            probe_pane
            case $? in
                6) return 6 ;;
                3) : > "$D/$n.secret"; return 3 ;;
            esac
        fi
        sleep .2
    done
    return 1
}

# Delete the output file of each completed run that no reader took.
remove_stale_output() {
    local out k
    for out in "$D"/*.out; do
        [ -e "$out" ] || continue
        k="${out##*/}"
        k="${k%.out}"
        [ ! -f "$D/$k.rc" ] || reader_live "$k" || rm -f "$out"
    done
}

run_command() {
    local timeout=$RUN_TIMEOUT_DEFAULT secret=0 max=200 command n sum mode
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) [ "$#" -ge 2 ] || usage; timeout="$2"; shift 2 ;;
            --max-lines) [ "$#" -ge 2 ] || usage; max="$2"; shift 2 ;;
            --secret) secret=1; shift ;;
            --) shift; command="$*"; break ;;
            *) usage ;;
        esac
    done
    [ -n "${command:-}" ] || usage
    case "$command" in *[![:space:]]*) ;; *) fail 'run needs a command' 2 ;; esac
    # A newline, another control character or a Unicode format character
    # can hide or reorder a part of the command in the question of a
    # dangerous run, and a control character can break the typed line.
    ! hides_text "$command" || fail 'run command must not contain a control character or a Unicode format character: give one line' 2
    positive_integer "$timeout" || usage
    positive_integer "$max" || usage
    reserved_word "$command"
    ensure_open
    # The typing lock first: only one run at a time decides on the busy lock.
    lock_and_load || return 5
    # run types __clux_run on the same line, after the hidden text.
    hidden_text && { refuse_hidden; return; }
    output_held && fail "the output of run $S_SEQ is held: use wait --run $S_SEQ, or wait --run $S_SEQ --discard" 5
    if ! mkdir "$D/busy" 2>/dev/null; then
        # The lock of a completed run that no reader takes now is free.
        { [ "${S_SEQ:-0}" -gt 0 ] && [ -f "$D/$S_SEQ.rc" ] && ! reader_live "$S_SEQ"; } \
            || busy_holder_dead || fail 'the companion is busy' 5
    fi
    process_start "$$" || { release_busy; fail 'cannot read the start time of this process' 1; }
    printf '%s %s\n' "$$" "$PROC_START" > "$D/busy/pid"
    printf 'pending\n' > "$D/busy/owner"
    # Two seconds, not one test: after a large output the pane shell draws its
    # prompt a moment after the last run reports.
    wait_for_prompt 2 || { release_busy; fail 'the pane is not at the prompt: use wait --idle, send or read' 5; }
    # The command gate (spec section 7). When the client fails, nothing runs.
    laya_gate < <(printf '%s' "$command")
    case $? in
        0) ;;
        2) release_busy; fail 'laya: bad input' 2 ;;
        3) release_busy; fail 'laya: the command is too long to examine: make it shorter' 2 ;;
        *) release_busy; refuse_laya; return ;;
    esac
    remove_stale_output
    if last_run_secret; then
        clear_line; send_literal __clux_clear; send_key Enter
        # Exit 5, not 1: no run started, so there is no <n> for wait --run.
        wait_for_clear 5 || { release_busy; fail 'cannot clear the screen after a secret run: use wait --idle, then run again' 5; }
        tmux_state clear-history -t "$S_PANE"
    fi
    # The typed line carries what the gate decided (spec section 7): the sum
    # of the command, and the mode. The pane shell refuses a .cmd with a
    # different sum, so a change of .cmd after the gate runs nothing.
    sum=$(command_sum "$command") || { release_busy; fail 'cannot make the sum of the command' 1; }
    mode=plain
    [ "$GATE_LEVEL" != dangerous ] || mode=confirm
    # The gate can take some seconds. The user can type in the pane in that
    # time: the typed line must not follow that text. C-u below removes text
    # that comes between this check and the typing.
    if ! capture_cursor_line || ! line_at_prompt; then
        release_busy
        fail 'the pane is not at an empty prompt: use read, then run again' 5
    fi
    n=$(( S_SEQ + 1 ))
    printf '%s\n' "$n" > "$D/busy/owner"
    write_state "$S_MODE" "$S_PANE" "$S_SOCKET" "$n"
    printf '%s' "$command" > "$D/$n.cmd"
    [ "$secret" -eq 0 ] || : > "$D/$n.secret"
    case "$GATE_LEVEL" in
        caution) printf '%s\n' "$GATE_REASON" > "$D/$n.caution" ;;
        dangerous)
            # The pane shell shows the reason in the question. .confirm
            # tells the verbs that the question is open.
            printf '%s\n' "$GATE_REASON" > "$D/$n.reason"
            : > "$D/$n.confirm"
            ;;
    esac
    printf 'run=%s\n' "$n"
    clear_line; send_literal "__clux_run $n $sum $mode"; send_key Enter
    rm -f "$D/busy/pid"
    release_typing_lock
    wait_for_run_files "$n" "$timeout" 1
    case $? in
        0) report_run "$n" "$max" ;;
        3) refuse_credential ;;
        6) refuse_laya_run "$n" ;;
        *)
            printf 'time limit: run %s continues in the pane; use wait --run %s\n' "$n" "$n" >&2
            return 1
            ;;
    esac
}

send_command() {
    local enter=0 key="" text="" before
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --enter) enter=1; shift ;;
            --key) [ "$#" -ge 2 ] || usage; key="$2"; shift 2 ;;
            --) shift; text="$*"; break ;;
            *) text="$*"; break ;;
        esac
    done
    # [inferred] A newline or a carriage return ends a line with no gate, and
    # other C0 control characters and DEL (for example \x0f, C-o on a bash
    # that binds operate-and-get-next) can end a line or act on the pane the
    # same way through send-keys -l; refuse all of them, not only \n and \r.
    # A Unicode format character (a bidi control, a zero width character)
    # can make the line on the pane read differently from the line that runs.
    ! hides_text "$text$key" || fail 'send text must not contain a control character or a Unicode format character: use --enter or --key' 2
    reserved_word "$text"
    [ -z "$key" ] || key_name "$key" || fail "not a key name: $key: send text with send -- TEXT" 2
    # No text and no key is a usage error before any pane request.
    [ -n "$text" ] || [ -n "$key" ] || usage
    ensure_open
    # An interrupt key cannot type a value, and it must work when Laya does
    # not: it skips the Laya pane check. It also works while a Laya question
    # is open: C-c there declines the run, it cannot accept it.
    if [ -n "$key" ] && interrupt_key "$key"; then
        [ -z "$text" ] && [ "$enter" -eq 0 ] || usage
        # Escape and then a key is a Meta key: at the clux prompt, M-C-e
        # (shell-expand-line) runs $(...) of the line in the pane shell. The
        # check needs tmux only, not Laya.
        # tmux reads a key name with no case (ESCAPE is Escape). In a nested
        # shell, Escape and then a key that the user types there (C-e) is
        # M-C-e too. While a command of the pane shell runs, the pane shell
        # drops the keys that wait when it shows its prompt (__clux_flush).
        if key_is "$key" Escape; then
            if ! capture_cursor_line || prompt_input; then
                fail 'at the clux prompt, Escape is not permitted: use send --key C-c' 2
            fi
            ! pane_nested_shell || fail 'in a nested shell, Escape is not permitted: use send --key C-c' 2
            refuse_meta_front
        fi
        send_key "$key"
        # C-c discards the line, so the text that the pane did not show goes too.
        case "$key" in [Cc]-[Cc]|'^'[Cc]) rm -f "$D/hidden" "$D/typed"; run_not_started ;; esac
        return
    fi
    lock_and_load || return
    laya_confirm_pending && { refuse_confirm; return; }
    hidden_text && { refuse_hidden; return; }
    check_pane || return
    # A continuation line (PS2) adds to a command that the gate did not
    # examine as one line.
    if [ -n "$CONT_MARK" ]; then
        case "$CURSOR_LINE" in
            *"$CONT_MARK"*|*"${CONT_MARK% }")
                fail 'the pane shell waits for the rest of a command: send --key C-c, then send the full command on one line' 5 ;;
        esac
    fi
    # Each send goes to the gate: text with no Enter too, and each key, because
    # bind can make any key end a line. The gate examines the cursor line plus
    # the text, so text typed in pieces is examined as one line.
    if [ -n "$key" ]; then
        [ -z "$text" ] && [ "$enter" -eq 0 ] || usage
        if prompt_input; then
            # At the clux prompt a key that ends the line goes through
            # __clux_line, as send --enter does. Only keys that edit the
            # line go to the pane: another key can run a readline command
            # (C-x C-e runs the line in this shell).
            if accept_key "$key"; then
                enter=1
            else
                edit_key "$key" || fail "at the clux prompt, only Enter and keys that edit the line work: $key: use send --enter or run" 2
            fi
        fi
    fi
    # A nested shell in front (bash, zsh, ssh, docker exec). A line that ends there runs in that
    # shell, and no list of words can find each line that changes the shell
    # for later lines. So clux does not end a line there: only the user
    # does (spec section 7). Text with no Enter, the edit keys and the
    # interrupt keys work. A pager or a menu is a program in front, not a
    # shell: Laya can call a shell prompt a menu.
    if ! prompt_input; then
        if pane_nested_shell; then
            [ "$PANE_STATE" != pager ] && [ "$PANE_STATE" != menu ] || PANE_STATE=other
            if [ "$enter" -eq 1 ] || { [ -n "$key" ] && ! edit_key "$key"; }; then
                fail 'at a nested shell prompt, only the user ends a line: send the text with no --enter, then ask the user to press Enter in the pane' 2
            fi
        fi
        # The pane shell itself is in front, but the capture shows no clux
        # prompt: a typed line longer than the pane put the prompt row in
        # the history, or the prompt did not come back yet. A line or a key
        # would then go to this shell with no __clux_line: refuse. Only the
        # interrupt keys (C-c clears the line) go.
        ! pane_shell_front || fail 'the clux prompt is not on the screen: send --key C-c, then try again' 5
    fi
    if [ -n "$key" ] && [ "$enter" -eq 0 ]; then
        case "$PANE_STATE" in
            pager|menu) nav_key "$key" && { send_key "$key"; return; } ;;
        esac
        # Each key goes to the gate as the end of the line: bind can make
        # any key end a line.
        send_gate "" || return
        line_unchanged || return
        send_key "$key"
        if accept_key "$key"; then rm -f "$D/typed"; else typed_edit; fi
        return
    fi
    # The gate examines the cursor line plus the text, so the text must go
    # at the end of the line. After Home or Left it goes in the middle. This
    # is true in each program, so the check runs on each send, and a send
    # that cannot tell refuses. A line that ends at the clux prompt with no
    # new text goes whole, so the cursor does not matter.
    if [ -n "$text" ]; then
        cursor_mid_line
        case $? in
            0) fail 'the cursor is not at the end of the line: send --key End or --key C-c first' 2 ;;
            1) ;;
            *) fail 'cannot read the cursor position: try again' 5 ;;
        esac
    fi
    before="$CURSOR_LINE"
    send_gate "$text" || return
    line_unchanged || return
    if [ "$enter" -eq 1 ] && prompt_input; then
        rm -f "$D/typed"
        send_line "$PROMPT_INPUT$text"
        return
    fi
    send_literal "$text"
    if [ "$enter" -eq 1 ]; then
        send_key Enter
        rm -f "$D/typed"
        return
    fi
    # The text that clux typed in this line, for the gate (typed_split), in
    # each state: the state can be wrong.
    typed_add "$before" "$text"
    # Text that the pane does not show (after stty -echo) cannot be examined
    # by the next gate, so each later send and run refuses until C-c. Only a
    # shell line must show the text: a pager or a menu takes a key and can
    # keep the same cursor line (space in less).
    shell_line || return 0
    wait_for_echo "$text" "$before" || { : > "$D/hidden"; refuse_hidden; return; }
}

read_command() {
    local lines=50 screen
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --lines) [ "$#" -ge 2 ] || usage; lines="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    positive_integer "$lines" || usage
    ensure_open
    release_if_done
    laya_confirm_pending && { refuse_confirm; return; }
    last_run_secret && { refuse_secret; return; }
    check_pane || return
    screen=$(tmux_state capture-pane -p -J -t "$S_PANE" -S "-$lines") || return 1
    laya_guard <(printf '%s\n' "$screen") || { refuse_laya; return; }
    guard_cut_note
    [ -z "$GUARD_TEXT" ] || printf '%s\n' "$GUARD_TEXT"
}

# new_screen_lines SEEN SCREEN — the lines of SCREEN that are not lines of
# SEEN, each with the line above it, in screen order. The first line gives
# the first line of each run of lines that are next to each other on the
# screen (0,4,9), so the guard does not join lines across a gap. Only an
# empty line when each line of SCREEN is in SEEN.
new_screen_lines() {
    awk 'NR == FNR { seen[$0]; next }
        { line[++n] = $0; fresh[n] = !($0 in seen) }
        END {
            k = 0; prev = -1; runs = ""
            for (i = 1; i <= n; i++) if (fresh[i] || (i < n && fresh[i + 1])) {
                if (prev != i - 1) runs = runs (runs == "" ? "" : ",") k
                out[k++] = line[i]; prev = i
            }
            print runs
            for (i = 0; i < k; i++) print out[i]
        }' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# held_lines TEXT GUARDED [KIND] — the lines of TEXT that the guard held:
# GUARDED has each line of TEXT, or a marker line in place of 1 or <k> held
# lines. When the two do not line up, each line that is left counts as
# held. With KIND, only the lines of the markers of that kind (and no
# line that is left): not_examined gives the lines that a later guard can
# show.
held_lines() {
    RE="$HELD_MARK_RE" KIND="${3:-}" awk 'NR == FNR { t[++n] = $0; next }
        { g[++m] = $0 }
        END {
            i = 1
            for (j = 1; j <= m && i <= n; j++) {
                if (g[j] == t[i]) { i++; continue }
                if (g[j] !~ ENVIRON["RE"]) break
                k = 1
                if (match(g[j], /, [0-9]+ lines\]$/)) k = substr(g[j], RSTART + 2) + 0
                show = ENVIRON["KIND"] == "" || index(g[j], "[held by laya: " ENVIRON["KIND"] "]") == 1 \
                    || index(g[j], "[held by laya: " ENVIRON["KIND"] ",") == 1
                for (; k > 0 && i <= n; k--) { if (show) print t[i]; i++ }
            }
            if (ENVIRON["KIND"] == "") for (; i <= n; i++) print t[i]
        }' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# drop_lines TEXT REMOVE — the lines of TEXT that are not lines of REMOVE,
# in order. An empty REMOVE removes nothing.
drop_lines() {
    [ -n "$2" ] || { printf '%s\n' "$1"; return; }
    awk 'NR == FNR { drop[$0]; next } !($0 in drop)' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}

# visible_lines GUARDED HELD — the lines of GUARDED that the pattern can
# see: no marker line, and no line that an earlier guard of the wait held.
visible_lines() {
    drop_lines "$1" "$2" | grep -vE "$HELD_MARK_RE"
}

# add_seen_lines SEEN SCREEN — SEEN with each line of SCREEN that it does
# not have, so the set grows by the new lines only.
add_seen_lines() {
    awk 'NR == FNR { seen[$0]; print; next } !($0 in seen) { seen[$0]; print }' \
        <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# guard_fresh FRESH DEADLINE RUNS — the guard of wait --pattern. One client
# guards all of FRESH in pieces of whole lines that fit in
# LAYA_GUARD_BYTES: a guard of a cut text starts inside a line, and
# held_lines cannot line it up. RUNS (from new_screen_lines) are the first
# lines of the runs of FRESH that are next to each other on the screen.
# Adds the held lines to held and tests the
# pattern (value) on the text that the pattern can see: both are locals of
# wait_command. Sets FRESH_FOUND=1 on a match, and FRESH_LATE to the lines
# that the time limit left not examined: they are not held, and the next
# tick sends them again. Returns 6 when the guard fails, and 1 at the
# DEADLINE: a guard can take 15 s, so none starts after the time limit of
# the wait, and a guard gets at most the time that is left (spec section 11).
FRESH_FOUND=0
FRESH_LATE=
guard_fresh() {
    local lines left=$(($2 - SECONDS))
    FRESH_FOUND=0
    FRESH_LATE=
    [ "$left" -gt 0 ] || return 1
    # The local value applies to laya_guard_call in this call only.
    [ "$left" -ge "$LAYA_GUARD_LIMIT" ] || local LAYA_GUARD_LIMIT="$left"
    laya_guard <(printf '%s\n' "$1") 1 "${3:-0}" || return 6
    lines=$(held_lines "$1" "$GUARD_TEXT")
    if [ "$GUARD_LATE" -gt 0 ]; then
        FRESH_LATE=$(held_lines "$1" "$GUARD_TEXT" not_examined)
        lines=$(drop_lines "$lines" "$FRESH_LATE")
    fi
    held=$(add_seen_lines "$held" "$lines")
    # The marker lines of held text are not pane text: the pattern does
    # not see them.
    visible_lines "$GUARD_TEXT" "$held" | grep -Eq -- "$value" && FRESH_FOUND=1
    return 0
}

wait_command() {
    local timeout=60 max=200 mode="" value="" probe deadline screen sum="" discard=0 rc guard_fails=0 fresh runs seq
    local hist="" hist_now hist_limit back
    # The lines of the last capture that a guard examined. The first line is
    # a mark that no screen line is, so the set is never empty.
    local seen=$'\001clux-seen'
    # The lines that a guard of this wait held. A line that the pair rule
    # held (hunter2 under Password:) can pass in a later window with other
    # context, so it stays held. Only held lines go in it.
    local held=$'\001clux-held'
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --discard) discard=1; shift ;;
            --timeout) [ "$#" -ge 2 ] || usage; timeout="$2"; shift 2 ;;
            --max-lines) [ "$#" -ge 2 ] || usage; max="$2"; shift 2 ;;
            --idle) [ -z "$mode" ] || usage; mode=idle; shift ;;
            --pattern) [ -z "$mode" ] && [ "$#" -ge 2 ] || usage; mode=pattern; value="$2"; shift 2 ;;
            --run) [ -z "$mode" ] && [ "$#" -ge 2 ] || usage; mode=run; value="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    positive_integer "$timeout" || usage
    positive_integer "$max" || usage
    [ -n "$mode" ] || usage
    [ "$mode" != run ] || positive_integer "$value" || usage
    [ "$discard" -eq 0 ] || [ "$mode" = run ] || usage
    ensure_open
    if [ "$discard" -eq 1 ]; then
        # Output that the guard cannot examine each time (a large secret
        # file) would keep the lock for ever: drop it, with no text.
        [ -e "$D/$value.held" ] || fail "run $value has no held output" 2
        # A verb that reads this output now keeps it.
        take_reading_lock "$value"
        read -r rc 2>/dev/null < "$D/$value.rc"
        rm -f "$D/$value.out" "$D/$value.held"
        printf 'output discarded: laya did not examine it\nexit=%s\n' "$rc"
        release_run "$value"
        return 0
    fi
    case "$mode" in
        run)
            # A secret run waits for the user at a credential prompt, so the
            # probe would stop this wait at once.
            probe=1
            [ ! -e "$D/$value.secret" ] || probe=0
            wait_for_run_files "$value" "$timeout" "$probe"
            case $? in
                0) report_run "$value" "$max" ;;
                3) refuse_credential ;;
                6) refuse_laya_run "$value" ;;
                *) return 1 ;;
            esac
            ;;
        idle)
            laya_confirm_pending && { refuse_confirm; return; }
            wait_for_prompt "$timeout" 1
            case $? in
                0) return 0 ;;
                3) refuse_credential ;;
                6) refuse_laya ;;
                8) refuse_confirm ;;
                *) printf 'pane=%s\n' "${PANE_STATE:-other}"; return 1 ;;
            esac
            ;;
        pattern)
            last_run_secret && { refuse_secret; return; }
            # The pattern is tested on the guarded text, so it cannot find a
            # held secret. The guard runs again only when the screen changes.
            deadline=$((SECONDS + timeout))
            while :; do
                # One read of the seq for the two checks of this tick.
                seq=$(seq_now)
                laya_confirm_pending "$seq" && { refuse_confirm; return; }
                # A secret run that another verb started during the wait.
                last_run_secret "$seq" && { refuse_secret; return; }
                # A probe can take 11 s: it gets at most the time that is
                # left, and none starts after the time limit.
                [ "$SECONDS" -lt "$deadline" ] || return 1
                PANE_LIMIT=$((deadline - SECONDS)) probe_pane
                case $? in
                    3) refuse_credential; return ;;
                    6) refuse_laya; return ;;
                esac
                # The guard runs on each new screen, and the pattern sees
                # only the guarded text. No test reads the raw screen: a
                # raw test that decides whether the guard runs tells, by
                # the time the verb takes, that a held line matches.
                # [inferred] A pattern that matches only a held marker line
                # is not found.
                # A failed guard counts as a failed probe: 3 in a row end
                # the wait with exit 6. The same screen is guarded again.
                # Only lines that no earlier guard examined go to Laya, each
                # with the line above it for context: a progress bar sends
                # 2 lines, not the full screen, each second. A line that
                # an earlier guard examined did not match.
                # The lines that scrolled off since the last guarded capture
                # come too (at most --max-lines): a fast build must not
                # scroll the pattern line away between two captures.
                # A full history drops a tenth of history-limit at one time,
                # so a smaller size is also new lines.
                back=
                hist_now=$(tmux_state display-message -p -t "$S_PANE" '#{history_size} #{history_limit}') || hist_now=
                read -r hist_now hist_limit <<< "$hist_now"
                case "$hist_now" in ''|*[!0-9]*) hist_now= ;; esac
                case "$hist_limit" in ''|*[!0-9]*) hist_limit=0 ;; esac
                if [ -n "$hist_now" ]; then
                    [ -n "$hist" ] || hist="$hist_now"
                    if [ "$hist_now" -gt "$hist" ]; then
                        back=$((hist_now - hist))
                    elif [ "$hist_now" -lt "$hist" ]; then
                        back=$((hist_now - hist + (hist_limit / 10 > 0 ? hist_limit / 10 : 1)))
                    fi
                    [ -z "$back" ] || [ "$back" -gt 0 ] || back=
                    [ -z "$back" ] || [ "$back" -le "$max" ] || back="$max"
                fi
                if screen=$(tmux_state capture-pane -p -J -t "$S_PANE" ${back:+-S "-$back"}); then
                    if [ "$screen" != "$sum" ]; then
                        fresh=$(new_screen_lines "$seen" "$screen")
                        runs="${fresh%%$'\n'*}"
                        fresh="${fresh#"$runs"}"
                        fresh="${fresh#$'\n'}"
                        if [ -z "$fresh" ]; then
                            sum="$screen"
                            [ -z "$hist_now" ] || hist="$hist_now"
                        else
                            guard_fresh "$fresh" "$deadline" "$runs"
                            case $? in
                                0)
                                    guard_fails=0
                                    [ "$FRESH_FOUND" -eq 0 ] || return 0
                                    # Only the lines of the last guarded
                                    # capture: the set does not grow over a
                                    # long wait.
                                    seen=$'\001clux-seen'$'\n'"$screen"
                                    if [ -n "$FRESH_LATE" ]; then
                                        # Lines that the time limit left not
                                        # examined are not seen: the next
                                        # tick sends them again, from the
                                        # same capture start.
                                        seen=$(drop_lines "$seen" "$FRESH_LATE")
                                    else
                                        sum="$screen"
                                        [ -z "$hist_now" ] || hist="$hist_now"
                                    fi
                                    ;;
                                1) return 1 ;;
                                *)
                                    guard_fails=$((guard_fails + 1))
                                    [ "$guard_fails" -lt 3 ] || { refuse_laya; return; }
                                    ;;
                            esac
                        fi
                    fi
                fi
                [ "$SECONDS" -lt "$deadline" ] || return 1
                sleep 1
            done
            ;;
    esac
}

# hook_session_id JSON — the session_id field of a hook payload in
# HOOK_SESSION_ID, read with parameter expansion as hooks/agent-state.sh
# does. Empty when the field is not there. The caller checks the UUID form.
# [inferred] Spaces before and after the colon are accepted.
HOOK_SESSION_ID=
hook_session_id() {
    local rest="${1#*\"session_id\"}"
    HOOK_SESSION_ID=
    [ "$rest" != "$1" ] || return 0
    rest="${rest#"${rest%%[![:space:]]*}"}"
    rest="${rest#:}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    rest="${rest#\"}"
    HOOK_SESSION_ID="${rest%%\"*}"
}

# watch_is_ours PID SHORT — PID is the watchdog of sessions/SHORT: its
# command line ends with "terminal.sh watch --session SHORT". A new process
# can get the pid of a watchdog that ended.
watch_is_ours() {
    local command
    positive_integer "${1:-}" || return 1
    command=$(ps -ww -o command= -p "$1" 2>/dev/null) || return 1
    rtrim "$command"
    case "$RTRIM" in *"terminal.sh watch --session $2") return 0 ;; esac
    return 1
}

# watch_stop PID SHORT — stop the watchdog of sessions/SHORT.
watch_stop() {
    watch_is_ours "${1:-}" "${2:-}" || return 0
    kill "$1" 2>/dev/null || true
}

# close_session_dir DIR [WHO] — the close steps for the companion of a
# session owner in DIR (sessions/<short>). WHO is "watchdog" when the
# watchdog calls it: it does not stop itself. WHO is "hook" when the
# SessionEnd hook calls it: a separate process stops the Laya server,
# because the hook has 5 s. The screen, the pane and DIR go first, as in
# close_command. [inferred] clear-history goes only to a pane with the mark.
close_session_dir() {
    D="$1"
    state_load || { rm -rf "$D"; return 0; }
    if companion_pane_is_ours "$S_SOCKET" "$S_PANE"; then
        tmux -S "$S_SOCKET" clear-history -t "$S_PANE" >/dev/null 2>&1 || true
    fi
    kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" 1
    rm -rf "$D"
    [ "${2:-}" = watchdog ] || watch_stop "$S_WATCH_PID" "${D##*/}"
    if [ "${2:-}" = hook ]; then
        laya_stop_server_later "$S_LAYA_PID"
    else
        laya_stop_server "$S_LAYA_PID"
    fi
}

# watch_start — start the watchdog of this directory and write its pid to
# state. nohup, stdin and stdout to /dev/null and fd 3 closed: the end of
# the Bash call does not stop it. [inferred] SCRIPT_DIR can be relative,
# so the watchdog gets the absolute path. [inferred] It returns 1, with no
# change to state, when the script directory is not known. Otherwise it
# returns the status of write_state. [inferred] It prints nothing when the
# directory is not known: the callers print the message. [inferred]
watch_start() {
    local dir
    dir=$(cd "$SCRIPT_DIR" 2>/dev/null && pwd) || return 1
    nohup "$BASH" "$dir/terminal.sh" watch --session "${D##*/}" < /dev/null > /dev/null 2>&1 3>&- &
    S_WATCH_PID=$!
    write_state "$S_MODE" "$S_PANE" "$S_SOCKET" "$S_SEQ"
}

# watch_ensure — for a session owner, start the watchdog when the one in
# state is not alive (spec 2026-09-30, section 9). [inferred] The typing
# lock, then the state again: no run writes its seq at the same time.
# [inferred] The status is 5 when the lock is not free, 1 when watch_start
# fails, and 0 otherwise. The lock is released in each path. A companion with
# no watchdog can stay after a crash of the session (spec section 13), so the
# callers do not ignore status 1. [inferred]
watch_ensure() {
    local rc=0
    [ "$OWNER_KIND" = session ] || return 0
    ! watch_is_ours "$S_WATCH_PID" "${D##*/}" || return 0
    lock_and_load || return 5
    watch_is_ours "$S_WATCH_PID" "${D##*/}" || watch_start || rc=1
    release_typing_lock
    return "$rc"
}

# watch_command --session SHORT — the hidden watchdog of sessions/SHORT.
# Each WATCH_INTERVAL seconds it reads state (a whole file: write_state
# renames it). No state, or another watch_pid: a close or a new open came
# first, so it exits. When the owner process is gone or has another start
# time, it runs the close steps for its directory, then exits. It never
# reads the Laya key. It does not use require_owner: the owner is gone.
watch_command() {
    local short dir
    [ "$#" -eq 2 ] && [ "$1" = --session ] || usage
    short="$2"
    valid_short_id "$short" || fail 'invalid Claude session id' 2
    trap '' HUP INT
    resolve_root
    dir="$ROOT/sessions/$short"
    while sleep "$WATCH_INTERVAL"; do
        state_load "$dir" || exit 0
        [ "$S_WATCH_PID" = "$$" ] || exit 0
        owner_alive "$S_OWNER_PID" "$S_OWNER_START" && continue
        # An open or a close at work holds the lock: try again after the
        # next pause. Under the lock, read the state again.
        dir_lock "$dir" 0 || continue
        state_load "$dir" || exit 0
        [ "$S_WATCH_PID" = "$$" ] || exit 0
        close_session_dir "$dir" watchdog
        exit 0
    done
}

# session_env_command --hook — the SessionStart hook (spec 2026-09-30,
# section 5). It reads session_id from the payload on stdin and appends
# `export CLUX_SESSION_ID=<id>` to CLAUDE_ENV_FILE, so the Bash calls of the
# session and of its subagents get the id from a documented source. It
# appends, because other hooks write the same file. [inferred] No
# CLAUDE_ENV_FILE, or an id that is not in the UUID form: nothing to do.
# main runs it in a subshell that prints nothing and exits 0.
session_env_command() {
    local input
    [ "$#" -eq 1 ] && [ "$1" = --hook ] || return 0
    input=$(cat)
    [ -n "${CLAUDE_ENV_FILE:-}" ] || return 0
    hook_session_id "$input"
    valid_session_id "$HOOK_SESSION_ID" || return 0
    printf 'export CLUX_SESSION_ID=%s\n' "$HOOK_SESSION_ID" >> "$CLAUDE_ENV_FILE"
}

# close_session ID [WHO] — close the companion of the session ID: for the
# hook and for close --session. The state must name the same full id: two
# sessions can have the same first 8 characters. The hook has 5 s, so it
# waits DIR_LOCK_HOOK_WAIT for the lock; when the lock stays busy, the
# watchdog or the reaper closes the companion later.
close_session() {
    local wait="$DIR_LOCK_WAIT"
    [ "${2:-}" != hook ] || wait="$DIR_LOCK_HOOK_WAIT"
    resolve_root
    D="$ROOT/sessions/${1:0:8}"
    [ -d "$ROOT/sessions" ] || return 0
    dir_lock "$D" "$wait" || refuse_dir_lock
    state_load || return 0
    [ "$S_SESSION" = "$1" ] || return 0
    close_session_dir "$D" "${2:-}"
}

close_command() {
    local hook=0 owner="" session="" input
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --hook) hook=1; shift ;;
            --owner) [ "$#" -ge 2 ] || usage; owner="$2"; shift 2 ;;
            --session) [ "$#" -ge 2 ] || usage; session="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    # --hook makes this a Claude SessionEnd hook: read stdin and say nothing.
    # With no tmux, the owner is the session of the payload (spec
    # 2026-09-30, section 9). A bad session_id is nothing to do.
    if [ "$hook" -eq 1 ]; then
        input=$(cat)
        if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
            hook_session_id "$input"
            valid_session_id "$HOOK_SESSION_ID" || return 0
            close_session "$HOOK_SESSION_ID" hook
            return 0
        fi
    fi
    # [inferred] close --session ID is for internal use. main runs it before
    # require_owner: the owner comes from the argument and from state.
    if [ -n "$session" ]; then
        valid_session_id "$session" || fail 'invalid Claude session id' 2
        close_session "$session"
        return 0
    fi
    # No require_owner here: main already ran it on the verb path, and the
    # two arms above find their owner their own way.
    # $ROOT needs no tmux, so an absent root answers the whole question before
    # paying for a server-key round trip.
    resolve_root
    [ -d "$ROOT" ] || return 0
    if [ -n "$owner" ]; then
        TMUX_PANE="%${owner#%}"
        OWNER_KIND=pane
    fi
    terminal_init
    # The lock of $D (dir_lock), then the state under it. The SessionEnd
    # hook has 5 s, so it waits less. With no parent directory there is no
    # companion, and no lock can be made.
    [ -d "${D%/*}" ] || return 0
    if [ "$hook" -eq 1 ]; then
        dir_lock "$D" "$DIR_LOCK_HOOK_WAIT" || refuse_dir_lock
    else
        dir_lock "$D" "$DIR_LOCK_WAIT" || refuse_dir_lock
    fi
    state_load || return 0
    if [ "$OWNER_KIND" = session ]; then
        # [inferred] The state of another session: exit 4, touch nothing.
        state_is_ours || fail 'no companion is open for this owner' 4
        close_session_dir "$D"
        return 0
    fi
    # The screen, the pane and $D (with the key) go first: the SessionEnd
    # hook has 5 s, and the server can be slow to stop. In --hook mode a
    # separate process stops the server (kill -9 after 3 s), because $D
    # with the pid is gone and the reaper cannot find it again.
    tmux_state clear-history -t "$S_PANE" >/dev/null 2>&1 || true
    kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" 1
    rm -rf "$D"
    if [ "$hook" -eq 1 ]; then
        laya_stop_server_later "$S_LAYA_PID"
    else
        laya_stop_server "$S_LAYA_PID"
    fi
}

# Install step 1. [inferred] The first of these names that is Python 3.10 or
# later. PyTorch wheels come later than new Python releases, so 3.12 is first.
laya_find_python() {
    local name
    for name in python3.12 python3.13 python3.11 python3.10 python3; do
        command -v "$name" >/dev/null 2>&1 || continue
        "$name" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1 || continue
        LAYA_BASE_PY="$name"
        return 0
    done
    return 1
}

LAYA_INSTALL_PID=
LAYA_INSTALL_LOG=

laya_install_cleanup() {
    laya_stop_server "$LAYA_INSTALL_PID"
    LAYA_INSTALL_PID=
    [ -z "$LAYA_INSTALL_LOG" ] || rm -f "$LAYA_INSTALL_LOG"
    LAYA_INSTALL_LOG=
}

# Print the failure and the end of the server output less each line that
# matches secret-values.txt, then stop the server and exit 1. The venv stays,
# so the next install goes straight to the download.
laya_download_failed() {
    printf 'laya install: the checkpoint download failed: %s\n' "$1" >&2
    [ -z "$LAYA_INSTALL_LOG" ] \
        || tail -n 20 "$LAYA_INSTALL_LOG" | "$LAYA_VENV/bin/python3" "$LAYA_CLIENT" scrub >&2
    laya_install_cleanup
    trap - EXIT INT TERM HUP
    exit 1
}

# Install step 3: one start of laya-serve without HF_HUB_OFFLINE downloads
# the English checkpoint. The server output goes to a temp file. The traps
# stop the server and delete the file when the verb ends early.
laya_download() {
    local deadline=$(($1 + LAYA_INSTALL_BUDGET))
    [ "$SECONDS" -lt "$deadline" ] || laya_download_failed 'the time limit ended'
    trap laya_install_cleanup EXIT
    trap 'laya_install_cleanup; exit 1' INT TERM HUP
    LAYA_INSTALL_LOG=$(mktemp "${TMPDIR:-/tmp}/clux-laya-install.XXXXXX") \
        || laya_download_failed 'cannot make a temp file'
    laya_start_server "$LAYA_INSTALL_LOG" 0 || laya_download_failed 'no free port'
    LAYA_INSTALL_PID=$LAYA_PID
    laya_wait_health "$deadline"
    case $? in
        2) laya_download_failed 'laya-serve ended before it answered' ;;
        1) laya_download_failed 'the time limit ended' ;;
    esac
    laya_install_cleanup
    trap - EXIT INT TERM HUP
    # [inferred] A server that answers with no checkpoint in the cache is a
    # failed download too.
    laya_checkpoint_present || laya_download_failed 'the checkpoint is not in the Hugging Face cache'
}

laya_install() {
    local start=$SECONDS version
    # open uses the client Python: install cannot make CLUX_LAYA_PYTHON
    # ready, so it says so, and open and install do not send the user in a
    # circle.
    if [ -n "${CLUX_LAYA_PYTHON:-}" ] && ! laya_python_ready "$LAYA_PY"; then
        fail "CLUX_LAYA_PYTHON cannot import laya: install laya $LAYA_VERSION in that Python, or unset CLUX_LAYA_PYTHON" 2
    fi
    # A venv that does not run is made again: its marker goes.
    [ ! -f "$LAYA_MARKER" ] || laya_python_ready "$LAYA_VENV/bin/python3" || rm -f "$LAYA_MARKER"
    # An installed venv needs no base python3.
    if [ -f "$LAYA_MARKER" ] && laya_checkpoint_present; then
        version=$("$LAYA_VENV/bin/python3" "$LAYA_CLIENT" version 2>/dev/null) || version=unknown
        printf 'laya %s is already installed\nvenv=%s\n' "$version" "$LAYA_VENV"
        return 0
    fi
    if [ ! -f "$LAYA_MARKER" ]; then
        # Only a new venv needs a base python3: with the marker, only the
        # checkpoint download remains, and it uses the venv python.
        laya_find_python || fail 'laya install needs python3 3.10 or later' 2
        # [inferred] A venv with no marker is partial: make it again.
        rm -rf "$LAYA_VENV"
        mkdir -p "${LAYA_VENV%/*}"
        "$LAYA_BASE_PY" -m venv "$LAYA_VENV" || { rm -rf "$LAYA_VENV"; fail 'laya install: python3 -m venv failed' 1; }
        "$LAYA_VENV/bin/python3" "$LAYA_CLIENT" pip-install \
            "$((LAYA_INSTALL_BUDGET - (SECONDS - start)))" "laya[serve]==$LAYA_VERSION"
        case $? in
            0)
                # [inferred] laya-serve needs fastapi and uvicorn, which come
                # only from the serve extra; check them before the marker.
                "$LAYA_VENV/bin/python3" -c 'import fastapi, uvicorn' >/dev/null 2>&1 \
                    || { rm -rf "$LAYA_VENV"; fail 'laya install: pip install failed' 1; }
                : > "$LAYA_MARKER"
                ;;
            124) rm -rf "$LAYA_VENV"; fail 'laya install: the time limit ended during pip install' 1 ;;
            *) rm -rf "$LAYA_VENV"; fail 'laya install: pip install failed' 1 ;;
        esac
    fi
    laya_download "$start"
    printf 'venv=%s\n' "$LAYA_VENV"
    printf 'disk=%s\n' "$(du -sh "$LAYA_VENV" 2>/dev/null | cut -f1)"
}

# The server of the companion of this owner: none, or "owned" or "external"
# with the health answer. A subshell, because require_owner and
# terminal_init can exit. With no owner, the subshell prints nothing and
# laya_status gives none.
laya_status_server() {
    (
        require_owner 2>/dev/null
        terminal_init 2>/dev/null
        state_load && state_is_ours && [ -n "$S_LAYA_URL" ] || { echo none; exit 0; }
        owner=external
        [ -z "$S_LAYA_PID" ] || owner=owned
        if laya_call health >/dev/null; then
            echo "$owner health=ok"
        else
            echo "$owner health=failed"
        fi
    )
}

laya_status() {
    local version=none checkpoint=missing server=none
    if [ -f "$LAYA_MARKER" ]; then
        version=$("$LAYA_VENV/bin/python3" "$LAYA_CLIENT" version 2>/dev/null) || version=unknown
    fi
    laya_checkpoint_present && checkpoint=present
    server=$(laya_status_server 2>/dev/null) || server=none
    [ -n "$server" ] || server=none
    printf 'venv=%s\nversion=%s\ncheckpoint=%s\nserver=%s\n' "$LAYA_VENV" "$version" "$checkpoint" "$server"
}

laya_command() {
    [ "$#" -eq 1 ] || usage
    case "$1" in
        install) laya_install ;;
        status) laya_status ;;
        *) usage ;;
    esac
}

main() {
    [ "$#" -gt 0 ] || usage
    case "$1" in
        check-line) shift; check_line_command "$@"; return $? ;;
        # No require_owner: install and status operate outside tmux too.
        laya) shift; laya_command "$@"; return $? ;;
        # The hidden verbs find the owner from their arguments and from
        # state, not from CLAUDE_PID (spec 2026-09-30, section 5).
        watch) shift; watch_command "$@"; return $? ;;
        session-env)
            shift
            ( session_env_command "$@" ) >/dev/null 2>&1 || true
            return 0
            ;;
    esac
    if [ "$1" = close ] && [ "${2:-}" = --hook ]; then
        shift
        ( close_command "$@" ) >/dev/null 2>&1 || true
        return 0
    fi
    # close --session finds its owner from its argument and from state.
    if [ "$1" = close ] && [ "${2:-}" = --session ]; then
        shift
        close_command "$@"
        return $?
    fi
    require_owner
    case "$1" in
        open) shift; open_command "$@" ;;
        run) shift; run_command "$@" ;;
        send) shift; send_command "$@" ;;
        read) shift; read_command "$@" ;;
        wait) shift; wait_command "$@" ;;
        close) shift; close_command "$@" ;;
        list) list_command ;;
        *) usage ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
