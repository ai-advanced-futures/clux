#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

_pattern_file_matches() {
    local line="$1" file="$2" kind="$3" raw clean pattern
    [ -r "$file" ] || return 1
    while IFS= read -r raw || [ -n "$raw" ]; do
        clean=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//')
        case "$clean" in
            ''|'#'*) continue ;;
        esac
        case "$kind:$clean" in
            exclude:'!'*) pattern="${clean#\!}" ;;
            include:'!'*) continue ;;
            include:*) pattern="$clean" ;;
            *) continue ;;
        esac
        printf '%s\n' "$line" | grep -E -i -q -- "$pattern" && return 0
    done < "$file"
    return 1
}

line_is_credential() {
    local line="$1" override="${2:-}" trimmed user_patterns
    trimmed=$(printf '%s' "$line" | sed 's/[[:space:]]*$//')
    case "$trimmed" in
        *:|*\?|*\]) ;;
        *) return 1 ;;
    esac
    if [ -n "$override" ]; then
        _pattern_file_matches "$trimmed" "$override" exclude && return 1
        _pattern_file_matches "$trimmed" "$override" include
        return $?
    fi

    _pattern_file_matches "$trimmed" "$SHIPPED_PATTERNS" exclude && return 1
    user_patterns=$(tmux show-option -gqv '@clux-terminal-patterns' 2>/dev/null || true)
    [ -n "$user_patterns" ] && _pattern_file_matches "$trimmed" "$user_patterns" exclude && return 1
    _pattern_file_matches "$trimmed" "$SHIPPED_PATTERNS" include && return 0
    [ -n "$user_patterns" ] && _pattern_file_matches "$trimmed" "$user_patterns" include && return 0
    return 1
}

check_line_command() {
    local patterns="" line=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --patterns) [ "$#" -ge 2 ] || usage; patterns="$2"; shift 2 ;;
            --) shift; line="$*"; break ;;
            *) usage ;;
        esac
    done
    [ -n "$patterns" ] || patterns="$SHIPPED_PATTERNS"
    line_is_credential "$line" "$patterns"
}

terminal_init() {
    local owner_source="$1"
    ROOT="$CLUX_TERMINAL_DIR"
    [ -n "$ROOT" ] || ROOT="${TMPDIR:-/tmp}/clux-terminal-$(id -u)"
    SERVER_KEY=$(resolve_agent_server_key)
    _clux_valid_server_key "$SERVER_KEY" || fail 'cannot identify the tmux server' 2
    [ -n "$owner_source" ] || owner_source="$TMUX_PANE"
    OWNER_PANE=$(printf '%s' "$owner_source" | sed 's/^%//')
    case "$OWNER_PANE" in ''|*[!0-9]*) fail 'invalid owner pane' 2 ;; esac
    D="$ROOT/$SERVER_KEY-$OWNER_PANE"
}

state_get() { sed -n "s/^$1=//p" "$D/state" 2>/dev/null | head -n 1; }
state_get_from() { sed -n "s/^$2=//p" "$1/state" 2>/dev/null | head -n 1; }

reap_companions() {
    local listing dir base server owner pane socket pid
    listing=$(tmux list-panes -a -F '#{pid}-#{start_time} #{pane_id}' 2>/dev/null)
    [ -n "$listing" ] || return 0
    for dir in "$ROOT"/*; do
        [ -d "$dir" ] || continue
        base=$(basename "$dir")
        server=$(printf '%s' "$base" | sed 's/-[^-]*$//')
        owner=$(printf '%s' "$base" | sed 's/^.*-//')
        _clux_valid_server_key "$server" || continue
        case "$owner" in ''|*[!0-9]*) continue ;; esac
        if [ "$server" = "$SERVER_KEY" ]; then
            printf '%s\n' "$listing" | grep -qxF "$server %$owner" && continue
            pane=$(state_get_from "$dir" pane)
            socket=$(state_get_from "$dir" socket)
            [ -n "$socket" ] && tmux -S "$socket" kill-server >/dev/null 2>&1 || tmux kill-pane -t "$pane" >/dev/null 2>&1 || true
            rm -rf "$dir"
        else
            pid=$(printf '%s' "$server" | cut -d- -f1)
            kill -0 "$pid" 2>/dev/null || rm -rf "$dir"
        fi
    done
}

list_command() {
    local dir base server mode pane state
    terminal_init
    for dir in "$ROOT"/*; do
        [ -f "$dir/state" ] || continue
        base=$(basename "$dir"); server=$(printf '%s' "$base" | sed 's/-[^-]*$//')
        mode=$(state_get_from "$dir" mode); pane=$(state_get_from "$dir" pane)
        state=foreign
        [ "$server" != "$SERVER_KEY" ] || { tmux list-panes -a -F '#{pane_id}' | grep -qxF "$pane" && state=alive || state=gone; }
        printf 'owner=%s mode=%s pane=%s state=%s\n' "$base" "$mode" "$pane" "$state"
    done
}

write_rc_file() {
    cat > "$D/rc.bash" <<'EOF'
unset HISTFILE
set +o history
PS1='clux$ '
PROMPT_COMMAND=
exit() { printf '%s\n' 'refused: this word closes the companion'; return 1; }
exec() { printf '%s\n' 'refused: this word closes the companion'; return 1; }
logout() { printf '%s\n' 'refused: this word closes the companion'; return 1; }
__clux_clear() { printf '\033[2J\033[H'; }
__clux_run() {
  local __clux_n="$1" __clux_d="$CLUX_TERMINAL_D" __clux_cmd __clux_rc __clux_i
  __clux_cmd=$(cat "$__clux_d/$__clux_n.cmd")
  printf '$ %s\n' "$__clux_cmd"
  { eval "$__clux_cmd"; } > >(umask 077; tee "$__clux_d/$__clux_n.out"; : > "$__clux_d/$__clux_n.done") 2>&1
  __clux_rc=$?
  __clux_i=0
  while [ ! -e "$__clux_d/$__clux_n.done" ] && [ "$__clux_i" -lt 20 ]; do sleep .05; __clux_i=$((__clux_i + 1)); done
  printf '%s\n' "$__clux_rc" > "$__clux_d/$__clux_n.rc"
}
EOF
}

write_state() {
    {
        echo "mode=$1"
        echo "pane=$2"
        echo "socket=$3"
        echo 'seq=0'
    } > "$D/state"
}

tmux_state() {
    if [ "$(state_get mode)" = socket ]; then
        tmux -S "$(state_get socket)" "$@"
    else
        tmux "$@"
    fi
}

capture_cursor_line() {
    local pane cy
    pane=$(state_get pane)
    cy=$(tmux_state display-message -p -t "$pane" '#{cursor_y}') || return 1
    tmux_state capture-pane -p -J -t "$pane" -S 0 -E "$cy" | tail -n 1
}

at_prompt() {
    local line
    line=$(capture_cursor_line) || return 1
    line=$(printf '%s' "$line" | sed 's/[[:space:]]*$//')
    case "$line" in *'clux$') return 0 ;; esac
    return 1
}

credential_on_cursor() {
    local line
    line=$(capture_cursor_line) || return 1
    line_is_credential "$line"
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

current_companion_alive() {
    [ -f "$D/state" ] || return 1
    if [ "$(state_get mode)" = socket ]; then
        tmux -S "$(state_get socket)" list-panes -a -F '#{pane_id}' | grep -qxF "$(state_get pane)"
    else
        tmux list-panes -a -F '#{pane_id}' | grep -qxF "$(state_get pane)"
    fi
}

check_tmux_version() {
    local version major minor
    version=$(tmux -V 2>/dev/null) || fail 'tmux is required' 2
    version=$(printf '%s' "$version" | sed 's/^tmux //; s/[^0-9.].*$//')
    major=$(printf '%s' "$version" | cut -d. -f1)
    minor=$(printf '%s' "$version" | cut -d. -f2)
    case "$major:$minor" in *[!0-9:]*|:) fail 'cannot read the tmux version' 2 ;; esac
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
    printf '%s\n' "$size" | grep -Eq '^([1-9]|[1-9][0-9]|100)%$' || fail 'size must be N%' 2
    terminal_init
    check_tmux_version
    mkdir -p "$ROOT"; chmod 700 "$ROOT"; reap_companions
    current_companion_alive && { echo "pane=$(state_get pane)"; echo "mode=$(state_get mode)"; return; }
    rm -rf "$D"; umask 077; mkdir -p "$D"; write_rc_file
    printf -v shell '%q --noprofile --rcfile %q -i' "$(command -v bash)" "$D/rc.bash"
    if [ "$mode" = socket ]; then
        socket="$D/sock"
        [ "$(printf '%s' "$socket" | wc -c | tr -d ' ')" -le 100 ] || fail 'the private tmux socket path is longer than 100 bytes' 2
        pane=$(tmux -S "$socket" -f /dev/null new-session -d -P -F '#{pane_id}' -s clux-terminal -e "CLUX_TERMINAL_D=$D" "$shell" 3>&-) || fail 'cannot open private companion' 1
        write_state socket "$pane" "$socket"
        tmux -S "$socket" select-pane -t "$pane" -T clux-terminal
    else
        pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" -v -l "$size" -e "CLUX_TERMINAL_D=$D" "$shell" 3>&-) || fail 'cannot open companion' 1
        write_state split "$pane" ""
        tmux select-pane -t "$pane" -T clux-terminal
    fi
    wait_for_prompt 5 || fail 'the companion shell did not reach its prompt' 1
    echo "pane=$pane"
    echo "mode=$mode"
    [ "$mode" != socket ] || echo "attach=tmux -S $socket attach"
}

ensure_open() {
    terminal_init
    current_companion_alive || fail 'no companion is open for this owner' 4
}

send_literal() { tmux_state send-keys -t "$(state_get pane)" -l -- "$1"; }
send_key() { tmux_state send-keys -t "$(state_get pane)" "$1"; }

wait_for_run_files() {
    local n="$1" deadline
    deadline=$((SECONDS + $2))
    while [ "$SECONDS" -lt "$deadline" ]; do
        [ -f "$D/$n.rc" ] && return 0
        credential_on_cursor && { : > "$D/$n.secret"; return 3; }
        sleep .2
    done
    return 1
}

run_command() {
    local timeout=100 secret=0 command n rc wait_status
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) [ "$#" -ge 2 ] || usage; timeout="$2"; shift 2 ;;
            --secret) secret=1; shift ;;
            --) shift; command="$*"; break ;;
            *) usage ;;
        esac
    done
    [ -n "$command" ] || usage
    positive_integer "$timeout" || usage
    case "$(printf '%s' "$command" | awk '{print $1}')" in
        exit|exec|logout|return) fail 'refused command first word' 2 ;;
    esac
    ensure_open
    mkdir "$D/busy" 2>/dev/null || fail 'the companion is busy' 5
    at_prompt || { rmdir "$D/busy"; fail 'the pane is not at the prompt: use wait --idle, send or read' 5; }
    n=$(( $(state_get seq) + 1 ))
    sed "s/^seq=.*/seq=$n/" "$D/state" > "$D/state.tmp" && mv "$D/state.tmp" "$D/state"
    umask 077; printf '%s' "$command" > "$D/$n.cmd"
    [ "$secret" -eq 0 ] || : > "$D/$n.secret"
    printf 'run=%s\n' "$n"
    send_literal "__clux_run $n"; send_key Enter
    wait_for_run_files "$n" "$timeout"
    wait_status=$?
    [ "$wait_status" -eq 0 ] || {
        [ "$wait_status" -ne 3 ] || { echo 'credential prompt in the companion pane: the user must answer it there' >&2; return 3; }
        return 1
    }
    [ -e "$D/$n.secret" ] || cat "$D/$n.out"
    rc=$(cat "$D/$n.rc")
    printf 'exit=%s\n' "$rc"
    rm -f "$D/$n.out"
    rmdir "$D/busy" 2>/dev/null || true
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
    credential_on_cursor && { echo 'credential prompt in the companion pane: the user must answer it there' >&2; return 3; }
    [ -n "$key" ] && { [ -z "$text" ] && [ "$enter" -eq 0 ] || usage; send_key "$key"; return; }
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
    credential_on_cursor && { echo 'credential prompt in the companion pane: the user must answer it there' >&2; return 3; }
    tmux_state capture-pane -p -J -t "$(state_get pane)" -S "-$lines"
}

wait_command() {
    local timeout=60 mode="" value="" deadline
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
    case "$mode" in
        run) positive_integer "$value" || usage; ensure_open; wait_for_run_files "$value" "$timeout" || return 1; cat "$D/$value.out"; echo "exit=$(cat "$D/$value.rc")"; rm -f "$D/$value.out"; rmdir "$D/busy" 2>/dev/null || true ;;
        idle|pattern)
            ensure_open; deadline=$((SECONDS + timeout))
            while [ "$SECONDS" -lt "$deadline" ]; do
                [ "$mode" != idle ] || { at_prompt && return 0; }
                [ "$mode" != pattern ] || tmux_state capture-pane -p -J -t "$(state_get pane)" -S -50 | grep -Eq -- "$value" && return 0
                sleep .2
            done
            return 1 ;;
        *) usage ;;
    esac
}

close_command() {
    local mode pane socket
    [ "$1" != --hook ] || { cat >/dev/null; [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0; }
    require_tmux
    terminal_init
    [ -f "$D/state" ] || return 0
    mode=$(state_get mode); pane=$(state_get pane); socket=$(state_get socket)
    if [ "$mode" = socket ]; then
        tmux -S "$socket" clear-history -t "$pane" >/dev/null 2>&1 || true
        tmux -S "$socket" kill-server >/dev/null 2>&1 || true
    else
        tmux clear-history -t "$pane" >/dev/null 2>&1 || true
        tmux kill-pane -t "$pane" >/dev/null 2>&1 || true
    fi
    rm -rf "$D"
}

main() {
    [ "$#" -gt 0 ] || usage
    case "$1" in
        check-line) shift; check_line_command "$@"; return $? ;;
    esac
    if [ "$1" = close ] && [ "$2" = --hook ]; then
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
