#!/usr/bin/env bash
# terminal.sh — the companion terminal. One private directory per Claude
# session, keyed by tmux server and owner pane, driving a known interactive
# Bash through tmux.
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

usage() {
    printf '%s\n' 'usage: terminal.sh open|run|send|read|wait|close|list|check-line|laya install|laya status' >&2
    exit 2
}

fail() {
    printf '%s\n' "$1" >&2
    exit "${2:-2}"
}

require_tmux() {
    [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] \
        || fail 'clux terminal must run inside tmux' 2
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
    _CLUX_USER_PATTERNS=$(tmux show-option -gqv '@clux-terminal-patterns' 2>/dev/null || true)
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
laya_call() {
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

laya_installed() {
    [ -f "$LAYA_MARKER" ] && laya_checkpoint_present
}

# The Laya checks of open, before it makes $D. Each refusal exits 6.
laya_open_check() {
    if [ -n "${CLUX_LAYA_URL:-}" ]; then
        laya_url_is_loopback "$CLUX_LAYA_URL" \
            || fail 'CLUX_LAYA_URL must name a loopback host: 127.0.0.1, localhost or ::1' 6
        S_LAYA_URL="$CLUX_LAYA_URL"
        S_LAYA_KEY="${CLUX_LAYA_KEY:-}"
        laya_call health >/dev/null || fail 'laya not available at CLUX_LAYA_URL' 6
        return 0
    fi
    laya_installed || fail 'laya not installed: run terminal.sh laya install' 6
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
    key=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    [ "${#key}" -eq 64 ] || return 1
    [ "$2" -eq 0 ] || offline=HF_HUB_OFFLINE=1
    env LAYA_HOST=127.0.0.1 LAYA_PORT="$port" LAYA_API_KEY="$key" LAYA_LOG_LEVEL=warning \
        LAYA_MODELS=english USE_TF=0 ${offline:+"$offline"} \
        nohup "$LAYA_VENV/bin/laya-serve" >> "$1" 2>&1 < /dev/null 3>&- &
    LAYA_PID=$!
    LAYA_URL="http://127.0.0.1:$port"
    LAYA_KEY="$key"
}

# laya_wait_health DEADLINE — health each 0.5 s until SECONDS reaches
# DEADLINE, for the server of LAYA_PID, LAYA_URL and LAYA_KEY. Returns 2
# when the server process ends, 1 when the time ends.
laya_wait_health() {
    until CLUX_LAYA_URL="$LAYA_URL" CLUX_LAYA_KEY="$LAYA_KEY" "$LAYA_PY" "$LAYA_CLIENT" health >/dev/null 2>&1; do
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
# lsof, else ss. [inferred] With neither tool it cannot check and returns 0.
laya_owns_port() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -a -p "$1" -iTCP:"$2" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        ss -ltnpH "sport = :$2" 2>/dev/null | grep -q "pid=$1,"
    fi
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

# open_abort PANE_MADE MESSAGE — undo a failed open and exit 6 (spec section
# 6, step 8). PANE_MADE is 1 when the pane exists.
open_abort() {
    laya_stop_server "$LAYA_PID"
    [ "$1" -eq 0 ] || kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" 1
    rm -rf "$D"
    fail "$2" 6
}

resolve_root() {
    ROOT="${CLUX_TERMINAL_DIR:-}"
    [ -n "$ROOT" ] || ROOT="${TMPDIR:-/tmp}/clux-terminal-$EUID"
}

terminal_init() {
    # Every file and directory this process makes ($D, state, busy, <n>.cmd)
    # is private. The pane shell keeps the user's own umask.
    umask 077
    resolve_root
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
    S_LAYA_PID=''; S_LAYA_URL=''; S_LAYA_KEY=''
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
        esac
    done < "$dir/state"
    return 0
}

# Whole-row test against a listing already in memory: the newline delimiters are
# what keep %1 from matching %10, exactly as grep -qxF did.
listing_has_pane() {
    case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
    return 1
}

# The one place that decides how a companion is torn down. A private server
# goes as a whole; a split pane goes only when the caller owns it.
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
    local listing dir base server owner pid
    listing=$(companion_listing)
    [ -n "$listing" ] || return 0
    for dir in "$ROOT"/*; do
        [ -d "$dir" ] || continue
        base="${dir##*/}"
        server="${base%-*}"
        owner="${base##*-}"
        _clux_valid_server_key "$server" || continue
        case "$owner" in ''|*[!0-9]*) continue ;; esac
        if [ "$server" = "$SERVER_KEY" ]; then
            listing_has_pane "$listing" "%$owner" || remove_companion_dir "$dir" 1
        else
            # kill -0 is the whole liveness test for a foreign server: had the
            # kernel reused that pid, the start time in the key could not match.
            pid="${server%%-*}"
            kill -0 "$pid" 2>/dev/null || remove_companion_dir "$dir" 0
        fi
    done
    [ "${#REAP_PIDS[@]}" -eq 0 ] || laya_stop_server "${REAP_PIDS[@]}"
    REAP_PIDS=()
}

list_command() {
    local listing dir base server state
    terminal_init
    listing=$(companion_listing)
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
}

write_rc_file() {
    cat > "$D/rc.bash" <<'EOF'
unset HISTFILE
set +o history
PS1='clux$ '
PROMPT_COMMAND=
# An alias could change what a safe-list word runs (spec section 7).
shopt -u expand_aliases
__clux_refuse() { printf '%s\n' 'refused: this word closes the companion'; return 1; }
exit() { __clux_refuse; }
exec() { __clux_refuse; }
logout() { __clux_refuse; }
__clux_clear() { printf '\033[2J\033[H'; }
# A dangerous run asks the user first. Only "y" runs it. The INT trap keeps
# Ctrl-C from ending the question: without it, Ctrl-C ends this function and
# leaves <n>.confirm, and each verb refuses until close. Each <n>.cmd runs
# one time: a run with no .cmd, or with an .rc, is refused, and .cmd is
# deleted when it is read. Thus a declined run cannot run again.
__clux_run() {
  local __clux_n="$1" __clux_d="$CLUX_TERMINAL_D" __clux_cmd __clux_rc __clux_i __clux_reason __clux_answer
  if [ ! -f "$__clux_d/$__clux_n.cmd" ] || [ -e "$__clux_d/$__clux_n.rc" ]; then
    printf '%s\n' 'refused: this run is not waiting to start'
    return 1
  fi
  __clux_cmd=$(<"$__clux_d/$__clux_n.cmd")
  command rm -f "$__clux_d/$__clux_n.cmd"
  # A safe-list run skipped Laya because of its first word, so that word
  # must be a program or a builtin, not an alias or a function.
  if [ -e "$__clux_d/$__clux_n.safe" ]; then
    __clux_i="${__clux_cmd#"${__clux_cmd%%[![:space:]]*}"}"
    case "$(builtin type -t -- "${__clux_i%%[[:space:]]*}")" in
      file|builtin) ;;
      *) __clux_cmd='printf "%s\n" "refused: the first word is an alias or a function in the companion shell"; (builtin exit 126)' ;;
    esac
  fi
  if [ -e "$__clux_d/$__clux_n.confirm" ]; then
    __clux_reason=$(<"$__clux_d/$__clux_n.reason")
    printf 'laya: dangerous (%s)\n$ %s\n' "$__clux_reason" "$__clux_cmd"
    __clux_answer=
    trap : INT
    builtin read -r -p 'run? [y/N] ' __clux_answer
    trap - INT
    command rm -f "$__clux_d/$__clux_n.confirm"
    if [ "$__clux_answer" != y ]; then
      (umask 077; printf 'declined\n' > "$__clux_d/$__clux_n.declined"; : > "$__clux_d/$__clux_n.done"
        printf '126\n' > "$__clux_d/$__clux_n.rc.tmp") \
        && command mv -f "$__clux_d/$__clux_n.rc.tmp" "$__clux_d/$__clux_n.rc"
      return 126
    fi
  else
    printf '$ %s\n' "$__clux_cmd"
  fi
  { eval "$__clux_cmd"; } > >(umask 077; tee "$__clux_d/$__clux_n.out"; : > "$__clux_d/$__clux_n.done") 2>&1
  __clux_rc=$?
  __clux_i=0
  while [ ! -e "$__clux_d/$__clux_n.done" ] && [ "$__clux_i" -lt 20 ]; do sleep .05; __clux_i=$((__clux_i + 1)); done
  (umask 077; printf '%s\n' "$__clux_rc" > "$__clux_d/$__clux_n.rc.tmp") \
    && command mv -f "$__clux_d/$__clux_n.rc.tmp" "$__clux_d/$__clux_n.rc"
}
EOF
}

# The ONE state-file writer. seq is the only field that changes after open.
# write_state MODE PANE SOCKET SEQ [LAYA_PID LAYA_URL LAYA_KEY]: with four
# arguments the laya fields keep the values that state_load read. A laya
# field that is empty is not written.
write_state() {
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
        [ -z "$S_LAYA_PID" ] || printf 'laya_pid=%s\n' "$S_LAYA_PID"
        [ -z "$S_LAYA_URL" ] || printf 'laya_url=%s\n' "$S_LAYA_URL"
        [ -z "$S_LAYA_KEY" ] || printf 'laya_key=%s\n' "$S_LAYA_KEY"
    } > "$D/state"
}

tmux_state() {
    if [ "$S_MODE" = socket ]; then
        tmux -S "$S_SOCKET" "$@"
    else
        tmux "$@"
    fi
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
capture_to_cursor() {
    local cy
    cy=$(tmux_state display-message -p -t "$S_PANE" '#{cursor_y}') || return 1
    CAPTURE=$(tmux_state capture-pane -p -J -t "$S_PANE" -S 0 -E "$cy" && printf x) || return 1
    CAPTURE="${CAPTURE%x}"
    CAPTURE="${CAPTURE%$'\n'}"
}

# A suffix test on the line capture_cursor_line already holds, so one poll
# step can ask both "at the prompt" and "credential prompt" for one capture.
line_at_prompt() {
    rtrim "$CURSOR_LINE"
    case "$RTRIM" in *'clux$') return 0 ;; esac
    return 1
}

PANE_STATE=
PANE_TEXT=
SCREEN_ABOVE=
PANE_RE='"state": "(credential|yes_no|menu|pager|shell_prompt|other)"'

# pane_state — the prompt type on the cursor line (spec section 9). Sets
# CURSOR_LINE, SCREEN_ABOVE (the 4 lines above it) and PANE_STATE. Returns 1
# when the capture fails and 6 when the client fails. The 3.9.0 regular
# expressions (line_is_credential) can only add "credential". This call
# forks the client, so the poll loops call it only on each fifth step, and
# it sends no request when the screen is the same as at the last answer.
pane_state() {
    local window out
    capture_to_cursor || return 1
    CURSOR_LINE="${CAPTURE##*$'\n'}"
    [ -z "$PANE_STATE" ] || [ "$CAPTURE" != "$PANE_TEXT" ] || return 0
    # The x keeps a blank cursor line through the command substitution.
    window=$(printf '%s\n' "$CAPTURE" | tail -n 5 && printf x)
    window="${window%x}"
    window="${window%$'\n'}"
    case "$window" in
        *$'\n'*) SCREEN_ABOVE="${window%$'\n'*}" ;;
        *) SCREEN_ABOVE= ;;
    esac
    PANE_STATE=
    out=$(printf '%s\n' "$window" | laya_call pane) || return 6
    [[ "$out" =~ $PANE_RE ]] || return 6
    PANE_STATE="${BASH_REMATCH[1]}"
    [ "$PANE_STATE" = credential ] || ! line_is_credential "$CURSOR_LINE" || PANE_STATE=credential
    PANE_TEXT="$CAPTURE"
    return 0
}

PROBE_FAILS=0

# probe_pane — one pane probe of a wait loop. Returns 3 on a credential
# prompt and 6 after 3 failed probes in a row, else 0. One failed probe
# (a slow machine, or a 503 while a guard uses the server) does not end the
# wait, and it still applies the local credential patterns.
probe_pane() {
    pane_state
    case $? in
        0)
            PROBE_FAILS=0
            [ "$PANE_STATE" != credential ] || return 3
            ;;
        6)
            PROBE_FAILS=$((PROBE_FAILS + 1))
            ! line_is_credential "$CURSOR_LINE" || return 3
            [ "$PROBE_FAILS" -lt 3 ] || return 6
            ;;
    esac
    return 0
}

# check_pane — pane_state for a verb that must not act on a credential
# prompt. Returns 3 (with the message) on a credential prompt, 6 (with the
# message) when Laya fails, else 0. A failed capture is not a refusal, as in
# 3.9.0.
check_pane() {
    pane_state
    case $? in
        6) refuse_laya; return ;;
        0) [ "$PANE_STATE" != credential ] || { refuse_credential; return; } ;;
    esac
    return 0
}

GATE_LEVEL=
GATE_REASON=
GATE_SAFE_LIST=0
LEVEL_RE='"level": "(safe|caution|dangerous)", "reason": "([^"]*)", "safe_list": (true|false)'

# laya_gate [--screen] [--no-safe-list] < TEXT — the command gate of the
# client (spec section 7). Sets GATE_LEVEL and GATE_REASON. Returns 2 when
# the client refuses the input (exit 2) and 6 when it fails. [inferred] terminal.sh reads the fixed JSON shape with a
# bash regular expression, because jq is only recommended for clux.
laya_gate() {
    local out rc=0
    out=$(laya_call command "$@") || rc=$?
    [ "$rc" -ne 2 ] || return 2
    [ "$rc" -eq 0 ] || return 6
    [[ "$out" =~ $LEVEL_RE ]] || return 6
    GATE_LEVEL="${BASH_REMATCH[1]}"
    GATE_REASON="${BASH_REMATCH[2]}"
    GATE_SAFE_LIST=0
    [ "${BASH_REMATCH[3]}" != true ] || GATE_SAFE_LIST=1
}

GUARD_HELD=0
GUARD_TEXT=
GUARD_CUT=0

# laya_guard FILE — the output guard (spec section 8). Sets GUARD_TEXT (the
# guarded text), GUARD_HELD (the count of held lines) and GUARD_CUT (1 when
# only the last LAYA_GUARD_BYTES went to the guard). Returns 6 when the
# client fails or its time limit ends. [inferred] The command substitution
# removes blank lines at the end of the text. A cut can split a UTF-8
# character; the client decodes with "replace", so that is not an error.
laya_guard() {
    local out data LC_ALL=C
    # The x keeps the newlines at the end, so the byte count is exact.
    data=$(tail -c "$((LAYA_GUARD_BYTES + 1))" "$1" && printf x) || return 6
    data="${data%x}"
    GUARD_CUT=0
    if [ "${#data}" -gt "$LAYA_GUARD_BYTES" ]; then
        GUARD_CUT=1
        data="${data: -$LAYA_GUARD_BYTES}"
    fi
    out=$(printf '%s' "$data" | laya_call output --render --limit "$LAYA_GUARD_LIMIT") || return 6
    case "$out" in held=*) ;; *) return 6 ;; esac
    GUARD_HELD="${out%%$'\n'*}"
    GUARD_HELD="${GUARD_HELD#held=}"
    case "$GUARD_HELD" in ''|*[!0-9]*) return 6 ;; esac
    case "$out" in
        *$'\n'*) GUARD_TEXT="${out#*$'\n'}" ;;
        *) GUARD_TEXT= ;;
    esac
    return 0
}

# reserved_word TEXT — the functions of rc.bash start with __clux_. Only
# run itself types them, so send and run refuse them with no Laya request.
reserved_word() {
    case "$1" in
        *__clux_*) fail 'refused: __clux_ names are for the companion only' 2 ;;
    esac
}

# key_name KEY — a tmux key name: a named key (Enter, Up, F5 and more), or
# a modifier (C-, M-, S-) with one character or a named key, or ^X. tmux
# types any other argument as text, with no echo check, so send refuses it
# (exit 2). One character alone is text too: send it with send -- TEXT.
key_name() {
    local k="$1" mods=0 rc=1 nocase
    # tmux reads a key name with no case (enter is Enter).
    nocase=$(shopt -p nocasematch)
    shopt -s nocasematch
    while :; do
        case "$k" in
            [CcMmSs]-?*) k="${k#??}"; mods=1 ;;
            *) break ;;
        esac
    done
    case "$k" in
        Enter|Escape|Tab|BTab|Space|BSpace|Up|Down|Left|Right|Home|End) rc=0 ;;
        PageUp|PgUp|PageDown|PgDn|NPage|PPage|Insert|IC|Delete|DC) rc=0 ;;
        F[1-9]|F1[0-2]) rc=0 ;;
        '^'?) [ "$mods" -ne 0 ] || rc=0 ;;
        ?) [ "$mods" -ne 1 ] || rc=0 ;;
    esac
    $nocase
    return "$rc"
}

# interrupt_key KEY — C-c, C-d, C-z, C-\ or Escape (spec section 7).
interrupt_key() {
    case "$1" in
        [Cc]-[CcDdZz]|[Cc]-'\'|'^'[CcDdZz]|'^\'|[Ee]scape) return 0 ;;
    esac
    return 1
}

# send_gate TEXT — the command gate for a send that ends a line (spec
# section 7). check_pane must run first: it sets CURSOR_LINE and
# SCREEN_ABOVE. The line is the cursor line plus TEXT. At the clux$ prompt
# the prompt goes off and the safe list applies. In any other program (ssh,
# python3, psql) the full cursor line goes, with the 4 lines above it as the
# screen, and the safe list does not apply. [inferred] The cursor line is the
# text that tmux shows, so cells that readline erased show as spaces.
send_gate() {
    local line prompt=0
    case "$CURSOR_LINE" in
        'clux$ '*) line="${CURSOR_LINE#'clux$ '}$1"; prompt=1 ;;
        'clux$') line="$1"; prompt=1 ;;
        *) line="$CURSOR_LINE$1" ;;
    esac
    [ "$prompt" -eq 0 ] || line="${line#"${line%%[![:space:]]*}"}"
    reserved_word "$line"
    # [inferred] A blank line runs nothing, so it needs no request.
    case "$line" in *[![:space:]]*) ;; *) return 0 ;; esac
    # [inferred] No safe list for send: only run checks that the first word
    # is a program or a builtin (the .safe marker), so on send a function of
    # the same name would skip Laya.
    laya_gate --screen --no-safe-list < <(printf '%s\n%s\n' "$SCREEN_ABOVE" "$line")
    case $? in
        0) ;;
        2) fail 'laya: bad input' 2 ;;
        *) refuse_laya; return ;;
    esac
    case "$GATE_LEVEL" in
        caution) printf 'laya: caution (%s)\n' "$GATE_REASON" >&2 ;;
        dangerous)
            printf 'laya: dangerous (%s): use run, it asks the user\n' "$GATE_REASON" >&2
            return 6
            ;;
    esac
    return 0
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
    case "$CURSOR_LINE" in 'clux$'*) return 0 ;; esac
    [ "$PANE_STATE" = shell_prompt ]
}

# cursor_mid_line — there is text after the cursor on the cursor row.
# cursor_x counts screen cells, and a wide character takes 2, so the client
# counts the cells of the row.
cursor_mid_line() {
    local pos x y row
    pos=$(tmux_state display-message -p -t "$S_PANE" '#{cursor_x} #{cursor_y}') || return 1
    x="${pos% *}"
    y="${pos#* }"
    row=$(tmux_state capture-pane -p -t "$S_PANE" -S "$y" -E "$y") || return 1
    printf '%s\n' "$row" | "$LAYA_PY" "$LAYA_CLIENT" after-cursor "$x" >/dev/null 2>&1
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
            [ "$RTRIM" = 'clux$' ] && return 0
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
    tmux_state list-panes -t "$S_PANE" >/dev/null 2>&1
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
    mkdir -p "$ROOT"; chmod 700 "$ROOT"; reap_companions
    current_companion_alive && { report_open; return; }
    laya_open_check
    # [inferred] A dead companion of this owner can still own a Laya server,
    # so its directory goes through remove_companion_dir, not rm -rf.
    [ ! -d "$D" ] || remove_companion_dir "$D" 0
    umask 077; mkdir -p "$D"; write_rc_file
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
    printf -v shell '%q --noprofile --rcfile %q -i' "$(command -v bash)" "$D/rc.bash"
    # [inferred] A pane or prompt failure keeps exit code 1, as in 3.9.0.
    if [ "$mode" = socket ]; then
        pane=$(tmux -S "$socket" -f /dev/null new-session -d -P -F '#{pane_id}' -s clux-terminal \
            -e "PATH=$PATH" -e BASH_SILENCE_DEPRECATION_WARNING=1 -e "CLUX_TERMINAL_D=$D" "$shell" 3>&-) \
            || { laya_stop_server "$LAYA_PID"; rm -rf "$D"; fail 'cannot open private companion' 1; }
        write_state socket "$pane" "$socket" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
    else
        pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" -v -l "$size" \
            -e "PATH=$PATH" -e BASH_SILENCE_DEPRECATION_WARNING=1 -e "CLUX_TERMINAL_D=$D" "$shell" 3>&-) \
            || { laya_stop_server "$LAYA_PID"; rm -rf "$D"; fail 'cannot open companion' 1; }
        write_state split "$pane" "" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
    fi
    tmux_state select-pane -t "$pane" -T clux-terminal
    if [ -n "$S_LAYA_PID" ]; then
        laya_wait_ready || open_abort 1 'laya not available: the server did not answer'
    fi
    wait_for_prompt 5 || {
        laya_stop_server "$S_LAYA_PID"
        kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" 1
        rm -rf "$D"
        fail 'the companion shell did not reach its prompt' 1
    }
    report_open
}

# ONE report for both the create and the reattach path, read from the state
# globals that write_state and state_load both fill. Printing it twice let the
# reattach path forget the attach= line a --socket caller needs.
report_open() {
    echo "pane=$S_PANE"
    echo "mode=$S_MODE"
    [ "$S_MODE" != socket ] || echo "attach=tmux -S $S_SOCKET attach"
}

ensure_open() {
    terminal_init
    current_companion_alive || fail 'no companion is open for this owner' 4
}

send_literal() { tmux_state send-keys -t "$S_PANE" -l -- "$1"; }
send_key() { tmux_state send-keys -t "$S_PANE" "$1"; }

release_busy() { rmdir "$D/busy" 2>/dev/null || true; }

# release_run N — free the lock only for the last run. wait --run on an older
# run must not free the lock of a run that continues.
release_run() {
    [ "$1" -ne "${S_SEQ:-0}" ] || release_busy
}

# The last run has output that the guard could not examine (<n>.held). It
# keeps the lock, so no new run deletes that output, until wait --run gives
# it.
output_held() {
    [ "${S_SEQ:-0}" -gt 0 ] && [ -e "$D/$S_SEQ.held" ]
}

# The last run was secret. Its text can still be on the screen, so read and
# wait --pattern refuse until the next run clears the screen and the history.
last_run_secret() {
    [ "${S_SEQ:-0}" -gt 0 ] && [ -e "$D/$S_SEQ.secret" ]
}

refuse_secret() {
    printf '%s\n' 'the last run was secret: do a plain run first, it clears the screen' >&2
    return 3
}

# A dangerous run waits for the answer of the user in the pane.
laya_confirm_pending() {
    [ "${S_SEQ:-0}" -gt 0 ] && [ -e "$D/$S_SEQ.confirm" ]
}

refuse_confirm() {
    printf '%s\n' 'laya confirmation in the companion pane: the user must answer it there' >&2
    return 3
}

# A run that ended on its time limit keeps the lock. The first reader that
# finds its <n>.rc removes it.
release_if_done() {
    [ "${S_SEQ:-0}" -gt 0 ] && [ -f "$D/$S_SEQ.rc" ] && ! output_held && release_busy
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
        read -r rc < "$D/$n.rc"
        printf 'laya: declined by the user\nexit=%s\n' "$rc"
        rm -f "$D/$n.out"
        release_run "$n"
        return 0
    fi
    while [ ! -e "$D/$n.done" ] && [ "$i" -lt 5 ]; do sleep .2; i=$((i + 1)); done
    read -r rc < "$D/$n.rc"
    GUARD_HELD=0
    GUARD_TEXT=
    if [ ! -e "$D/$n.secret" ] && [ -s "$D/$n.out" ]; then
        last=$(tail -c 1 "$D/$n.out")
        lines=$(wc -l < "$D/$n.out")
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
            printf 'laya not available: the output stays; use wait --run %s when Laya answers\n' "$n" >&2
            return 6
        fi
        [ "$lines" -le "$max" ] || printf 'output cut: the last %s of %s lines\n' "$max" "$lines"
        [ "$GUARD_CUT" -eq 0 ] || printf 'output cut: the last %s bytes\n' "$LAYA_GUARD_BYTES"
        [ -z "$GUARD_TEXT" ] || printf '%s\n' "$GUARD_TEXT"
        [ "$GUARD_HELD" -eq 0 ] || printf 'laya: held %s lines\n' "$GUARD_HELD"
    fi
    [ -e "$D/$n.done" ] || printf '%s\n' 'output may be incomplete: a process still holds the output'
    if [ -s "$D/$n.caution" ]; then
        read -r reason < "$D/$n.caution"
        printf 'laya: caution (%s)\n' "$reason"
    fi
    printf 'exit=%s\n' "$rc"
    rm -f "$D/$n.out" "$D/$n.held"
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
        [ ! -f "$D/$k.rc" ] || rm -f "$out"
    done
}

run_command() {
    local timeout=$RUN_TIMEOUT_DEFAULT secret=0 max=200 command first n
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
    positive_integer "$timeout" || usage
    positive_integer "$max" || usage
    first="${command#"${command%%[![:space:]]*}"}"
    case "${first%%[[:space:]]*}" in
        exit|exec|logout|return) fail 'refused command first word' 2 ;;
    esac
    reserved_word "$command"
    ensure_open
    # run types __clux_run on the same line, after the hidden text.
    hidden_text && { refuse_hidden; return; }
    output_held && fail "the output of run $S_SEQ is held: use wait --run $S_SEQ first" 5
    if ! mkdir "$D/busy" 2>/dev/null; then
        # The lock of a completed run that no reader took is free.
        [ "${S_SEQ:-0}" -gt 0 ] && [ -f "$D/$S_SEQ.rc" ] || fail 'the companion is busy' 5
    fi
    # Two seconds, not one test: after a large output the pane shell draws its
    # prompt a moment after the last run reports.
    wait_for_prompt 2 || { release_busy; fail 'the pane is not at the prompt: use wait --idle, send or read' 5; }
    # The command gate (spec section 7). When the client fails, nothing runs.
    laya_gate < <(printf '%s' "$command")
    case $? in
        0) ;;
        2) release_busy; fail 'laya: bad input' 2 ;;
        *) release_busy; refuse_laya; return ;;
    esac
    remove_stale_output
    if last_run_secret; then
        send_literal __clux_clear; send_key Enter
        # Exit 5, not 1: no run started, so there is no <n> for wait --run.
        wait_for_clear 5 || { release_busy; fail 'cannot clear the screen after a secret run: use wait --idle, then run again' 5; }
        tmux_state clear-history -t "$S_PANE"
    fi
    n=$(( S_SEQ + 1 ))
    write_state "$S_MODE" "$S_PANE" "$S_SOCKET" "$n"
    printf '%s' "$command" > "$D/$n.cmd"
    [ "$secret" -eq 0 ] || : > "$D/$n.secret"
    [ "$GATE_SAFE_LIST" -eq 0 ] || : > "$D/$n.safe"
    case "$GATE_LEVEL" in
        caution) printf '%s\n' "$GATE_REASON" > "$D/$n.caution" ;;
        dangerous)
            # The reason first: the pane shell reads it when it finds .confirm.
            printf '%s\n' "$GATE_REASON" > "$D/$n.reason"
            : > "$D/$n.confirm"
            ;;
    esac
    printf 'run=%s\n' "$n"
    send_literal "__clux_run $n"; send_key Enter
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
    case "$text$key" in
        *[[:cntrl:]]*) fail 'send text must not contain a control character: use --enter or --key' 2 ;;
    esac
    reserved_word "$text"
    [ -z "$key" ] || key_name "$key" || fail "not a key name: $key: send text with send -- TEXT" 2
    ensure_open
    laya_confirm_pending && { refuse_confirm; return; }
    # An interrupt key cannot type a value, and it must work when Laya does
    # not: it skips the Laya pane check.
    if [ -n "$key" ] && interrupt_key "$key"; then
        [ -z "$text" ] && [ "$enter" -eq 0 ] || usage
        send_key "$key"
        # C-c discards the line, so the text that the pane did not show goes too.
        case "$key" in [Cc]-[Cc]|'^'[Cc]) rm -f "$D/hidden" ;; esac
        return
    fi
    hidden_text && { refuse_hidden; return; }
    check_pane || return
    # Each send goes to the gate: text with no Enter too, and each key, because
    # bind can make any key end a line. The gate examines the cursor line plus
    # the text, so text typed in pieces is examined as one line.
    if [ -n "$key" ]; then
        [ -z "$text" ] && [ "$enter" -eq 0 ] || usage
        send_gate "" || return
        send_key "$key"
        return
    fi
    [ -n "$text" ] || usage
    # The gate examines the cursor line plus the text, so the text must go
    # at the end of the line. After Home or Left in a shell it goes in the
    # middle.
    if shell_line && cursor_mid_line; then
        fail 'the cursor is not at the end of the line: send --key End or --key C-c first' 2
    fi
    before="$CURSOR_LINE"
    send_gate "$text" || return
    send_literal "$text"
    if [ "$enter" -eq 1 ]; then
        send_key Enter
        return
    fi
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
    [ "$GUARD_CUT" -eq 0 ] || printf 'output cut: the last %s bytes\n' "$LAYA_GUARD_BYTES"
    [ -z "$GUARD_TEXT" ] || printf '%s\n' "$GUARD_TEXT"
}

wait_command() {
    local timeout=60 max=200 mode="" value="" probe deadline screen sum=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
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
    ensure_open
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
                laya_confirm_pending && { refuse_confirm; return; }
                probe_pane
                case $? in
                    3) refuse_credential; return ;;
                    6) refuse_laya; return ;;
                esac
                # The guard runs only when the screen changed and the raw
                # screen matches: the guarded text is the raw text with
                # some lines replaced, so it cannot match when the raw text
                # does not. [inferred] A pattern that matches only a held
                # marker line is not found.
                if screen=$(tmux_state capture-pane -p -J -t "$S_PANE"); then
                    if [ "$screen" != "$sum" ] && printf '%s\n' "$screen" | grep -Eq -- "$value"; then
                        sum="$screen"
                        laya_guard <(printf '%s\n' "$screen") || { refuse_laya; return; }
                        printf '%s\n' "$GUARD_TEXT" | grep -Eq -- "$value" && return 0
                    fi
                fi
                [ "$SECONDS" -lt "$deadline" ] || return 1
                sleep 1
            done
            ;;
    esac
}

close_command() {
    local hook=0 owner=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --hook) hook=1; shift ;;
            --owner) [ "$#" -ge 2 ] || usage; owner="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    # --hook makes this a Claude SessionEnd hook: drain stdin, say nothing, and
    # treat "no tmux" as nothing to do.
    if [ "$hook" -eq 1 ]; then
        while read -r _; do :; done
        [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
    fi
    # No require_tmux here: main already ran it on the verb path, and the --hook
    # arm above makes the same two tests its own way.
    # $ROOT needs no tmux, so an absent root answers the whole question before
    # paying for a server-key round trip.
    resolve_root
    [ -d "$ROOT" ] || return 0
    [ -z "$owner" ] || TMUX_PANE="%${owner#%}"
    terminal_init
    state_load || return 0
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
    laya_find_python || fail 'laya install needs python3 3.10 or later' 2
    if [ -f "$LAYA_MARKER" ] && laya_checkpoint_present; then
        version=$("$LAYA_VENV/bin/python3" "$LAYA_CLIENT" version 2>/dev/null) || version=unknown
        printf 'laya %s is already installed\nvenv=%s\n' "$version" "$LAYA_VENV"
        return 0
    fi
    if [ ! -f "$LAYA_MARKER" ]; then
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

# The server of the companion of this owner pane: none, or "owned" or
# "external" with the health answer. A subshell, because terminal_init can
# exit.
laya_status_server() {
    (
        terminal_init 2>/dev/null
        state_load && [ -n "$S_LAYA_URL" ] || { echo none; exit 0; }
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
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
        server=$(laya_status_server) || server=none
        [ -n "$server" ] || server=none
    fi
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
        # No require_tmux: install and status operate outside tmux too.
        laya) shift; laya_command "$@"; return $? ;;
    esac
    if [ "$1" = close ] && [ "${2:-}" = --hook ]; then
        shift
        ( close_command "$@" ) >/dev/null 2>&1 || true
        return 0
    fi
    require_tmux
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
