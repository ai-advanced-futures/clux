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

# The time budget of run. The sum of the gate with its retry (10.2 s), the
# prompt wait (2 s), the clear (5 s), this run limit, the last pane probe
# (10.2 s), the report grace (1 s), one late SECONDS tick (1 s) and the guard
# limit stays 10 s under the 120 s limit of the Bash tool. test/terminal.bats
# checks the sum. test/laya-live.bats measures the guard time.
RUN_TIMEOUT_DEFAULT=65
LAYA_GUARD_LIMIT=15

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

# Run the client with the server of this companion. The URL and the key come
# from state, not from the environment, so all verbs of one companion use one
# server. The client stderr has only fixed messages; each verb prints its own.
laya_call() {
    CLUX_LAYA_URL="$S_LAYA_URL" CLUX_LAYA_KEY="$S_LAYA_KEY" "$LAYA_PY" "$LAYA_CLIENT" "$@" 2>/dev/null
}

# The same rule as the client: http, a loopback host, and no user part.
laya_url_is_loopback() {
    local rest="${1#http://}" host
    [ "$rest" != "$1" ] || return 1
    rest="${rest%%/*}"
    case "$rest" in *@*) return 1 ;; esac
    case "$rest" in '[::1]'|'[::1]:'*) return 0 ;; esac
    host="${rest%%:*}"
    case "$host" in 127.0.0.1|localhost) return 0 ;; esac
    return 1
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

# kill, then kill -9 after 3 s.
laya_stop_server() {
    local pid="${1:-}" i=0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    laya_pid_is_server "$pid" || return 0
    kill "$pid" 2>/dev/null || return 0
    while [ "$i" -lt 15 ] && laya_pid_is_server "$pid"; do sleep .2; i=$((i + 1)); done
    ! laya_pid_is_server "$pid" || kill -9 "$pid" 2>/dev/null || true
}

# Start laya-serve for this companion (spec section 6, steps 3 and 4). Sets
# LAYA_PID, LAYA_URL and LAYA_KEY. The key is 32 random bytes in hex. The
# server output goes to $D/laya.log (0600, umask 077).
laya_start_server() {
    local port key
    port=$("$LAYA_PY" "$LAYA_CLIENT" port 2>/dev/null) || return 1
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    key=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    [ "${#key}" -eq 64 ] || return 1
    : > "$D/laya.log"
    LAYA_HOST=127.0.0.1 LAYA_PORT="$port" LAYA_API_KEY="$key" LAYA_LOG_LEVEL=warning \
        LAYA_MODELS=english HF_HUB_OFFLINE=1 USE_TF=0 \
        nohup "$LAYA_VENV/bin/laya-serve" >> "$D/laya.log" 2>&1 < /dev/null 3>&- &
    LAYA_PID=$!
    LAYA_URL="http://127.0.0.1:$port"
    LAYA_KEY="$key"
}

# Spec section 6, step 7: health each 0.5 s for at most 60 s, then one
# warm-up request, because the first call after a start takes about 1.4 s.
laya_wait_ready() {
    local deadline=$((SECONDS + 60))
    until laya_call health >/dev/null; do
        kill -0 "$S_LAYA_PID" 2>/dev/null || return 1
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep .5
    done
    printf '%s\n' 'clux$' | laya_call pane >/dev/null
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

remove_companion_dir() {
    local dir="$1" kill_split="${2:-0}"
    state_load "$dir" || { rm -rf "$dir"; return; }
    laya_stop_server "$S_LAYA_PID"
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
__clux_refuse() { printf '%s\n' 'refused: this word closes the companion'; return 1; }
exit() { __clux_refuse; }
exec() { __clux_refuse; }
logout() { __clux_refuse; }
__clux_clear() { printf '\033[2J\033[H'; }
# A dangerous run asks the user first. Only "y" runs it. The INT trap keeps
# Ctrl-C from ending the question: without it, Ctrl-C ends this function and
# leaves <n>.confirm, and each verb refuses until close.
__clux_run() {
  local __clux_n="$1" __clux_d="$CLUX_TERMINAL_D" __clux_cmd __clux_rc __clux_i __clux_reason __clux_answer
  __clux_cmd=$(<"$__clux_d/$__clux_n.cmd")
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
    local cy text
    cy=$(tmux_state display-message -p -t "$S_PANE" '#{cursor_y}') || return 1
    text=$(tmux_state capture-pane -p -J -t "$S_PANE" -S 0 -E "$cy") || return 1
    CURSOR_LINE="${text##*$'\n'}"
}

# A suffix test on the line capture_cursor_line already holds, so one poll
# step can ask both "at the prompt" and "credential prompt" for one capture.
line_at_prompt() {
    rtrim "$CURSOR_LINE"
    case "$RTRIM" in *'clux$') return 0 ;; esac
    return 1
}

PANE_STATE=
SCREEN_ABOVE=
PANE_RE='"state": "(credential|yes_no|menu|pager|shell_prompt|other)"'

# pane_state — the prompt type on the cursor line (spec section 9). Sets
# CURSOR_LINE, SCREEN_ABOVE (the 4 lines above it) and PANE_STATE. Returns 1
# when the capture fails and 6 when the client fails. The 3.9.0 regular
# expressions (line_is_credential) can only add "credential". This call
# forks the client, so the poll loops call it only on each fifth step.
pane_state() {
    local cy text window out
    cy=$(tmux_state display-message -p -t "$S_PANE" '#{cursor_y}') || return 1
    text=$(tmux_state capture-pane -p -J -t "$S_PANE" -S 0 -E "$cy") || return 1
    CURSOR_LINE="${text##*$'\n'}"
    window=$(printf '%s\n' "$text" | tail -n 5)
    case "$window" in
        *$'\n'*) SCREEN_ABOVE="${window%$'\n'*}" ;;
        *) SCREEN_ABOVE= ;;
    esac
    out=$(printf '%s\n' "$window" | laya_call pane) || return 6
    [[ "$out" =~ $PANE_RE ]] || return 6
    PANE_STATE="${BASH_REMATCH[1]}"
    [ "$PANE_STATE" = credential ] || ! line_is_credential "$CURSOR_LINE" || PANE_STATE=credential
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
LEVEL_RE='"level": "(safe|caution|dangerous)", "reason": "([^"]*)"'

# laya_gate [--screen] [--no-safe-list] < TEXT — the command gate of the
# client (spec section 7). Sets GATE_LEVEL and GATE_REASON. Returns 6 when
# the client fails. [inferred] terminal.sh reads the fixed JSON shape with a
# bash regular expression, because jq is only recommended for clux.
laya_gate() {
    local out
    out=$(laya_call command "$@") || return 6
    [[ "$out" =~ $LEVEL_RE ]] || return 6
    GATE_LEVEL="${BASH_REMATCH[1]}"
    GATE_REASON="${BASH_REMATCH[2]}"
}

GUARD_HELD=0
GUARD_TEXT=

# laya_guard FILE — the output guard (spec section 8). Sets GUARD_TEXT (the
# guarded text) and GUARD_HELD (the count of held lines). Returns 6 when the
# client fails or its time limit ends. [inferred] The command substitution
# removes blank lines at the end of the text.
laya_guard() {
    local out
    out=$(laya_call output --render --limit "$LAYA_GUARD_LIMIT" < "$1") || return 6
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

# A key that ends a line in the pane: Enter and KPEnter with any modifier,
# C-m, C-j and C-o (bash operate-and-get-next) with any other modifier, ^M,
# ^J, ^O, and a 0x key code. [inferred] tmux reads key names with no regard
# to letter case, so this test does the same.
key_ends_line() {
    local base="${1##*-}" mods="${1%-*}"
    [ "$mods" != "$1" ] || mods=
    case "$base" in
        [Ee][Nn][Tt][Ee][Rr]|[Kk][Pp][Ee][Nn][Tt][Ee][Rr]) return 0 ;;
        '^'[MmJjOo]|0[xX]*) return 0 ;;
        [MmJjOo]) case "-$mods-" in *-[Cc]-*) return 0 ;; esac ;;
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
    local line flag=--no-safe-list
    case "$CURSOR_LINE" in
        'clux$ '*) line="${CURSOR_LINE#'clux$ '}$1"; flag= ;;
        'clux$') line="$1"; flag= ;;
        *) line="$CURSOR_LINE$1" ;;
    esac
    [ -n "$flag" ] || line="${line#"${line%%[![:space:]]*}"}"
    # [inferred] A blank line runs nothing, so it needs no request.
    case "$line" in *[![:space:]]*) ;; *) return 0 ;; esac
    laya_gate --screen ${flag:+"$flag"} < <(printf '%s\n%s\n' "$SCREEN_ABOVE" "$line") \
        || { refuse_laya; return; }
    case "$GATE_LEVEL" in
        caution) printf 'laya: caution (%s)\n' "$GATE_REASON" >&2 ;;
        dangerous)
            printf 'laya: dangerous (%s): use run, it asks the user\n' "$GATE_REASON" >&2
            return 6
            ;;
    esac
    return 0
}

# After a send with no Enter, wait at most 1 s until the cursor line ends
# with the text. [inferred] The next send --enter reads the cursor line for
# its gate, so the text must be on the screen first.
wait_for_echo() {
    local i=0
    while [ "$i" -lt 5 ]; do
        capture_cursor_line && case "$CURSOR_LINE" in *"$1") return 0 ;; esac
        sleep .2
        i=$((i + 1))
    done
    return 0
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
                pane_state
                case $? in
                    6) return 6 ;;
                    0) [ "$PANE_STATE" != credential ] || return 3 ;;
                esac
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
        laya_start_server || open_abort 0 'laya not available: the server did not start'
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
    [ "${S_SEQ:-0}" -gt 0 ] && [ -f "$D/$S_SEQ.rc" ] && release_busy
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
        release_busy
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
            printf '%s\n' 'output held: laya not available' "exit=$rc"
            rm -f "$D/$n.out"
            release_busy
            refuse_laya
            return
        fi
        [ "$lines" -le "$max" ] || printf 'output cut: the last %s of %s lines\n' "$max" "$lines"
        [ -z "$GUARD_TEXT" ] || printf '%s\n' "$GUARD_TEXT"
        [ "$GUARD_HELD" -eq 0 ] || printf 'laya: held %s lines\n' "$GUARD_HELD"
    fi
    [ -e "$D/$n.done" ] || printf '%s\n' 'output may be incomplete: a process still holds the output'
    if [ -s "$D/$n.caution" ]; then
        read -r reason < "$D/$n.caution"
        printf 'laya: caution (%s)\n' "$reason"
    fi
    printf 'exit=%s\n' "$rc"
    rm -f "$D/$n.out"
    release_busy
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
            pane_state
            case $? in
                6) return 6 ;;
                0)
                    if [ "$PANE_STATE" = credential ]; then
                        : > "$D/$n.secret"
                        return 3
                    fi
                    ;;
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
    positive_integer "$timeout" || usage
    positive_integer "$max" || usage
    first="${command#"${command%%[![:space:]]*}"}"
    case "${first%%[[:space:]]*}" in
        exit|exec|logout|return) fail 'refused command first word' 2 ;;
    esac
    ensure_open
    if ! mkdir "$D/busy" 2>/dev/null; then
        # The lock of a completed run that no reader took is free.
        [ "${S_SEQ:-0}" -gt 0 ] && [ -f "$D/$S_SEQ.rc" ] || fail 'the companion is busy' 5
    fi
    # Two seconds, not one test: after a large output the pane shell draws its
    # prompt a moment after the last run reports.
    wait_for_prompt 2 || { release_busy; fail 'the pane is not at the prompt: use wait --idle, send or read' 5; }
    # The command gate (spec section 7). When the client fails, nothing runs.
    laya_gate < <(printf '%s' "$command") || { release_busy; refuse_laya; return; }
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
        6) refuse_laya ;;
        *)
            printf 'time limit: run %s continues in the pane; use wait --run %s\n' "$n" "$n" >&2
            return 1
            ;;
    esac
}

send_command() {
    local enter=0 key="" text=""
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
    ensure_open
    laya_confirm_pending && { refuse_confirm; return; }
    check_pane || return
    if [ -n "$key" ]; then
        [ -z "$text" ] && [ "$enter" -eq 0 ] || usage
        ! key_ends_line "$key" || send_gate "" || return
        send_key "$key"
        return
    fi
    [ -n "$text" ] || usage
    if [ "$enter" -eq 1 ]; then
        send_gate "$text" || return
        send_literal "$text"
        send_key Enter
        return
    fi
    send_literal "$text"
    wait_for_echo "$text"
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
    [ -z "$GUARD_TEXT" ] || printf '%s\n' "$GUARD_TEXT"
}

wait_command() {
    local timeout=60 max=200 mode="" value="" probe deadline screen sum="" now
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
                6) refuse_laya ;;
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
                check_pane || return
                if screen=$(tmux_state capture-pane -p -J -t "$S_PANE"); then
                    now=$(printf '%s\n' "$screen" | cksum)
                    if [ "$now" != "$sum" ]; then
                        sum="$now"
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
    laya_stop_server "$S_LAYA_PID"
    tmux_state clear-history -t "$S_PANE" >/dev/null 2>&1 || true
    kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" 1
    rm -rf "$D"
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
    local deadline=$(($1 + LAYA_INSTALL_BUDGET)) port key
    [ "$SECONDS" -lt "$deadline" ] || laya_download_failed 'the time limit ended'
    trap laya_install_cleanup EXIT
    trap 'laya_install_cleanup; exit 1' INT TERM HUP
    LAYA_INSTALL_LOG=$(mktemp "${TMPDIR:-/tmp}/clux-laya-install.XXXXXX") \
        || laya_download_failed 'cannot make a temp file'
    port=$("$LAYA_VENV/bin/python3" "$LAYA_CLIENT" port 2>/dev/null) || laya_download_failed 'no free port'
    key=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    LAYA_HOST=127.0.0.1 LAYA_PORT="$port" LAYA_API_KEY="$key" LAYA_LOG_LEVEL=warning \
        LAYA_MODELS=english USE_TF=0 \
        nohup "$LAYA_VENV/bin/laya-serve" >> "$LAYA_INSTALL_LOG" 2>&1 < /dev/null 3>&- &
    LAYA_INSTALL_PID=$!
    until CLUX_LAYA_URL="http://127.0.0.1:$port" CLUX_LAYA_KEY="$key" \
            "$LAYA_VENV/bin/python3" "$LAYA_CLIENT" health >/dev/null 2>&1; do
        kill -0 "$LAYA_INSTALL_PID" 2>/dev/null || laya_download_failed 'laya-serve ended before it answered'
        [ "$SECONDS" -lt "$deadline" ] || laya_download_failed 'the time limit ended'
        sleep .5
    done
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
