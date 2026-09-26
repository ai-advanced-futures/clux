#!/usr/bin/env bash
# terminal.sh — the companion terminal. One private directory per Claude
# session, keyed by tmux server and owner pane, driving a known interactive
# Bash through tmux.
#
# THREE poll loops here run every 0.2 s for the whole of a command's timeout
# (wait_for_prompt, wait_for_run_files, wait --pattern). Everything they touch
# is therefore written fork-free, and the two caches below exist for them:
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

usage() {
    printf '%s\n' 'usage: terminal.sh open|run|send|read|wait|close|list|check-line' >&2
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
# because a command substitution would fork a subshell and both callers sit on
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

resolve_root() {
    ROOT="${CLUX_TERMINAL_DIR:-}"
    [ -n "$ROOT" ] || ROOT="${TMPDIR:-/tmp}/clux-terminal-$EUID"
}

terminal_init() {
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

# The ONE state-file reader. $1 defaults to the current companion's directory;
# reap_companions and list_command pass a foreign one. Fails when there is no
# state file, which is the same question "is a companion open" asks.
#
# Clearing the globals first is load-bearing, not defensive: the two loops call
# this once per directory, so a field missing from the second file would
# otherwise keep the first file's value. Both loops run before any S_* is used
# for tmux, so the clobber is safe.
state_load() {
    local dir="${1:-$D}" key value
    S_MODE=''; S_PANE=''; S_SOCKET=''; S_SEQ=''
    [ -f "$dir/state" ] || return 1
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in
            mode) S_MODE="$value" ;;
            pane) S_PANE="$value" ;;
            socket) S_SOCKET="$value" ;;
            seq) S_SEQ="$value" ;;
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
kill_companion() {
    local mode="$1" pane="$2" socket="$3" kill_split="${4:-0}"
    if [ "$mode" = socket ] && [ -n "$socket" ]; then
        tmux -S "$socket" kill-server >/dev/null 2>&1 || true
    elif [ "$kill_split" -eq 1 ] && [ -n "$pane" ]; then
        tmux kill-pane -t "$pane" >/dev/null 2>&1 || true
    fi
}

remove_companion_dir() {
    local dir="$1" kill_split="${2:-0}"
    state_load "$dir" || { rm -rf "$dir"; return; }
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
__clux_run() {
  local __clux_n="$1" __clux_d="$CLUX_TERMINAL_D" __clux_cmd __clux_rc __clux_i
  __clux_cmd=$(<"$__clux_d/$__clux_n.cmd")
  printf '$ %s\n' "$__clux_cmd"
  { eval "$__clux_cmd"; } > >(umask 077; tee "$__clux_d/$__clux_n.out"; : > "$__clux_d/$__clux_n.done") 2>&1
  __clux_rc=$?
  __clux_i=0
  while [ ! -e "$__clux_d/$__clux_n.done" ] && [ "$__clux_i" -lt 20 ]; do sleep .05; __clux_i=$((__clux_i + 1)); done
  printf '%s\n' "$__clux_rc" > "$__clux_d/$__clux_n.rc"
}
EOF
}

# The ONE state-file writer. seq is the only mutable field, and every caller
# that bumps it already holds the other three in memory (state_load put them
# there), so rewriting the whole file costs one printf — no re-read, no sed, no
# temp file, and only one place that knows the format.
write_state() {
    S_MODE="$1"
    S_PANE="$2"
    S_SOCKET="$3"
    S_SEQ="${4:-0}"
    printf 'mode=%s\npane=%s\nsocket=%s\nseq=%s\n' "$1" "$2" "$3" "$S_SEQ" > "$D/state"
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

at_prompt() {
    capture_cursor_line || return 1
    rtrim "$CURSOR_LINE"
    case "$RTRIM" in *'clux$') return 0 ;; esac
    return 1
}

credential_on_cursor() {
    capture_cursor_line || return 1
    line_is_credential "$CURSOR_LINE"
}

wait_for_prompt() {
    local deadline
    deadline=$((SECONDS + $1))
    while [ "$SECONDS" -lt "$deadline" ]; do
        at_prompt && return 0
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
    rm -rf "$D"; umask 077; mkdir -p "$D"; write_rc_file
    printf -v shell '%q --noprofile --rcfile %q -i' "$(command -v bash)" "$D/rc.bash"
    if [ "$mode" = socket ]; then
        socket="$D/sock"
        [ "${#socket}" -le 100 ] || fail 'the private tmux socket path is longer than 100 bytes' 2
        pane=$(tmux -S "$socket" -f /dev/null new-session -d -P -F '#{pane_id}' -s clux-terminal -e "CLUX_TERMINAL_D=$D" "$shell" 3>&-) || fail 'cannot open private companion' 1
        write_state socket "$pane" "$socket"
    else
        pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" -v -l "$size" -e "CLUX_TERMINAL_D=$D" "$shell" 3>&-) || fail 'cannot open companion' 1
        write_state split "$pane" ""
    fi
    tmux_state select-pane -t "$pane" -T clux-terminal
    wait_for_prompt 5 || fail 'the companion shell did not reach its prompt' 1
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

# The single place a finished run is reported, so --secret cannot be honoured on
# one path and forgotten on the other.
report_run() {
    local n="$1" rc
    [ -e "$D/$n.secret" ] || cat "$D/$n.out"
    read -r rc < "$D/$n.rc"
    printf 'exit=%s\n' "$rc"
    rm -f "$D/$n.out"
    release_busy
}

# The credential probe costs a tmux round trip plus a grep, while the normal
# exit is the .rc test above it — so probe every fifth tick, not every tick. A
# credential prompt waits on a human, so one second of detection latency is
# free, and the loop's common case drops to a single file test.
wait_for_run_files() {
    local n="$1" deadline tick=0
    deadline=$((SECONDS + $2))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ -f "$D/$n.rc" ] && return 0
        tick=$(( (tick + 1) % 5 ))
        if [ "$tick" -eq 1 ] && credential_on_cursor; then
            : > "$D/$n.secret"
            return 3
        fi
        sleep .2
    done
    return 1
}

run_command() {
    local timeout=100 secret=0 command first n
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) [ "$#" -ge 2 ] || usage; timeout="$2"; shift 2 ;;
            --secret) secret=1; shift ;;
            --) shift; command="$*"; break ;;
            *) usage ;;
        esac
    done
    [ -n "${command:-}" ] || usage
    positive_integer "$timeout" || usage
    first="${command#"${command%%[![:space:]]*}"}"
    case "${first%%[[:space:]]*}" in
        exit|exec|logout|return) fail 'refused command first word' 2 ;;
    esac
    ensure_open
    mkdir "$D/busy" 2>/dev/null || fail 'the companion is busy' 5
    at_prompt || { release_busy; fail 'the pane is not at the prompt: use wait --idle, send or read' 5; }
    n=$(( S_SEQ + 1 ))
    write_state "$S_MODE" "$S_PANE" "$S_SOCKET" "$n"
    umask 077; printf '%s' "$command" > "$D/$n.cmd"
    [ "$secret" -eq 0 ] || : > "$D/$n.secret"
    printf 'run=%s\n' "$n"
    send_literal "__clux_run $n"; send_key Enter
    wait_for_run_files "$n" "$timeout"
    case $? in
        0) report_run "$n" ;;
        3) refuse_credential ;;
        *) return 1 ;;
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
    ensure_open
    credential_on_cursor && { refuse_credential; return; }
    if [ -n "$key" ]; then
        [ -z "$text" ] && [ "$enter" -eq 0 ] || usage
        send_key "$key"
        return
    fi
    [ -n "$text" ] || usage
    send_literal "$text"
    [ "$enter" -eq 0 ] || send_key Enter
}

read_command() {
    local lines=50
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --lines) [ "$#" -ge 2 ] || usage; lines="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    positive_integer "$lines" || usage
    ensure_open
    credential_on_cursor && { refuse_credential; return; }
    tmux_state capture-pane -p -J -t "$S_PANE" -S "-$lines"
}

wait_command() {
    local timeout=60 mode="" value=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) [ "$#" -ge 2 ] || usage; timeout="$2"; shift 2 ;;
            --idle) [ -z "$mode" ] || usage; mode=idle; shift ;;
            --pattern) [ -z "$mode" ] && [ "$#" -ge 2 ] || usage; mode=pattern; value="$2"; shift 2 ;;
            --run) [ -z "$mode" ] && [ "$#" -ge 2 ] || usage; mode=run; value="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    positive_integer "$timeout" || usage
    [ -n "$mode" ] || usage
    [ "$mode" != run ] || positive_integer "$value" || usage
    ensure_open
    case "$mode" in
        run)
            wait_for_run_files "$value" "$timeout" || return 1
            report_run "$value"
            ;;
        idle) wait_for_prompt "$timeout" ;;
        pattern)
            local deadline=$((SECONDS + timeout))
            while [ "$SECONDS" -lt "$deadline" ]; do
                tmux_state capture-pane -p -J -t "$S_PANE" -S -50 | grep -Eq -- "$value" && return 0
                sleep .2
            done
            return 1
            ;;
    esac
}

close_command() {
    local hook=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --hook) hook=1; shift ;;
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
    terminal_init
    state_load || return 0
    tmux_state clear-history -t "$S_PANE" >/dev/null 2>&1 || true
    kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" 1
    rm -rf "$D"
}

main() {
    [ "$#" -gt 0 ] || usage
    case "$1" in
        check-line) shift; check_line_command "$@"; return $? ;;
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
