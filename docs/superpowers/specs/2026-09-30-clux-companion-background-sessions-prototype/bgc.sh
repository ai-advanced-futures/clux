#!/usr/bin/env bash
# bgc.sh — prototype of the background-session owner for the clux companion.
# Not terminal.sh: no Laya, no gate. It tests only the new mechanics of the
# spec 2026-09-30-clux-companion-background-sessions-design.md:
# owner identity, private directory, dashboard lookup, window/socket placement,
# pane marker, watchdog, close (verb and hook).
set -u
SELF="$(cd "${BASH_SOURCE[0]%/*}" && pwd)/${BASH_SOURCE[0]##*/}"
ROOT="${CLUX_TERMINAL_DIR:-${TMPDIR:-/tmp}/clux-terminal-$EUID}"
STATE_DIR="${CLUX_AGENT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/clux/agents}"
WATCH_EVERY="${BGC_WATCH_EVERY:-10}"

fail() { printf '%s\n' "$1" >&2; exit "${2:-2}"; }
rtrim() { RTRIM="${1%"${1##*[![:space:]]}"}"; }
valid_sid() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
proc_start() { local s; s=$(ps -o lstart= -p "$1" 2>/dev/null) || return 1; rtrim "$s"; [ -n "$RTRIM" ] || return 1; printf '%s' "$RTRIM"; }

owner_init() {
    SID="${CLUX_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
    [ -n "$SID" ] || fail 'clux terminal must run inside tmux or in a Claude Code session'
    valid_sid "$SID" || fail 'invalid Claude session id'
    D="$ROOT/sessions/${SID:0:8}"
}
owner_proc() {
    case "${CLAUDE_PID:-}" in ''|*[!0-9]*) fail 'cannot identify the Claude session process' ;; esac
    OWNER_START=$(proc_start "$CLAUDE_PID") || fail 'cannot identify the Claude session process'
}

state_load() {
    local dir="${1:-$D}" k v
    S_SESSION= S_MODE= S_PANE= S_SOCKET= S_TOKEN= S_OWNER_PID= S_OWNER_START= S_WATCH_PID=
    [ -f "$dir/state" ] || return 1
    while IFS='=' read -r k v; do
        case "$k" in
            session) S_SESSION=$v ;; mode) S_MODE=$v ;; pane) S_PANE=$v ;; socket) S_SOCKET=$v ;;
            token) S_TOKEN=$v ;; owner_pid) S_OWNER_PID=$v ;; owner_start) S_OWNER_START=$v ;;
            watch_pid) S_WATCH_PID=$v ;;
        esac
    done < "$dir/state"
}
write_state() {
    printf 'session=%s\nmode=%s\npane=%s\nsocket=%s\ntoken=%s\nowner_pid=%s\nowner_start=%s\nwatch_pid=%s\n' \
        "$S_SESSION" "$S_MODE" "$S_PANE" "$S_SOCKET" "$S_TOKEN" "$S_OWNER_PID" "$S_OWNER_START" "$S_WATCH_PID" > "$D/state.new" \
        && mv "$D/state.new" "$D/state"
}

# The pane marker: the pane on that socket holds our token.
pane_is_ours() { [ "$(tmux -S "$1" display-message -p -t "$2" '#{@clux-companion}' 2>/dev/null)" = "$3" ]; }
alive() { state_load && [ "$S_SESSION" = "$SID" ] && pane_is_ours "$S_SOCKET" "$S_PANE" "$S_TOKEN"; }

kill_companion() {
    case "$S_MODE" in
        socket) [ -z "$S_SOCKET" ] || tmux -S "$S_SOCKET" kill-server >/dev/null 2>&1 || true ;;
        window) # never kill-server: this is the user's server
            [ -z "$S_SOCKET" ] || [ -z "$S_PANE" ] || ! pane_is_ours "$S_SOCKET" "$S_PANE" "$S_TOKEN" \
                || tmux -S "$S_SOCKET" kill-pane -t "$S_PANE" >/dev/null 2>&1 || true ;;
    esac
}
close_dir() { # DIR [from-watchdog]
    D="$1"; state_load "$D" || { rm -rf "$D"; return 0; }
    kill_companion
    [ -n "${2:-}" ] || [ -z "$S_WATCH_PID" ] || kill "$S_WATCH_PID" 2>/dev/null || true
    rm -rf "$D"
}

# Dashboard: the agent-state cache first, then nothing (the real code falls
# back to resolve_agents_pane_by_cwd). Prints "<socket> <pane>" or nothing.
find_dashboard() {
    local info sock key f pane
    info=$(tmux display-message -p '#{socket_path} #{pid}-#{start_time}' 2>/dev/null) || return 0
    sock=${info% *}; key=${info##* }
    for f in "$STATE_DIR/$key/agents/"*"~$SID"; do
        [ -e "$f" ] || continue
        pane=${f##*/}; pane=${pane%%~*}
        tmux -S "$sock" display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1 || continue
        printf '%s %s\n' "$sock" "$pane"; return 0
    done
}

open_cmd() {
    local force_socket=0 dash sock pane sess win
    [ "${1:-}" = --socket ] && force_socket=1
    owner_init; owner_proc
    reap
    if alive; then
        if [ -z "$S_WATCH_PID" ] || ! kill -0 "$S_WATCH_PID" 2>/dev/null; then start_watch; fi
        report; return 0
    fi
    if state_load && [ "$S_SESSION" != "$SID" ] && [ -n "$S_OWNER_PID" ] \
        && [ "$(proc_start "$S_OWNER_PID")" = "$S_OWNER_START" ]; then
        fail 'the companion directory belongs to another session'
    fi
    [ -d "$D" ] && close_dir "$D"
    umask 077; mkdir -p "$D"; chmod 700 "$ROOT" "$ROOT/sessions" 2>/dev/null
    S_SESSION=$SID S_TOKEN=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n') S_OWNER_PID=$CLAUDE_PID S_OWNER_START=$OWNER_START S_WATCH_PID=
    dash=$([ "$force_socket" -eq 1 ] || find_dashboard)
    if [ -n "$dash" ]; then
        sock=${dash% *}; pane=${dash#* }
        sess=$(tmux -S "$sock" display-message -p -t "$pane" '#{session_id}') || fail 'cannot read the dashboard session' 1
        S_PANE=$(tmux -S "$sock" new-window -d -P -F '#{pane_id}' -t "$sess:" -n "clux-terminal ${SID:0:8}" \
            'bash --noprofile --norc -i') || fail 'cannot open companion' 1
        win=$(tmux -S "$sock" display-message -p -t "$S_PANE" '#{window_id}')
        tmux -S "$sock" set-option -w -t "$win" automatic-rename off
        S_MODE=window S_SOCKET=$sock
    else
        S_SOCKET="$D/sock"
        [ "${#S_SOCKET}" -le 100 ] || { rm -rf "$D"; fail 'the private tmux socket path is longer than 100 bytes'; }
        S_PANE=$(tmux -S "$S_SOCKET" -f /dev/null new-session -d -P -F '#{pane_id}' -s clux-terminal \
            'bash --noprofile --norc -i') || fail 'cannot open private companion' 1
        S_MODE=socket
    fi
    tmux -S "$S_SOCKET" set-option -p -t "$S_PANE" @clux-companion "$S_TOKEN"
    write_state
    start_watch
    report
}
start_watch() {
    nohup bash "$SELF" watch "${SID:0:8}" < /dev/null > /dev/null 2>&1 3>&- &
    S_WATCH_PID=$!; write_state
}
report() {
    echo "pane=$S_PANE"; echo "mode=$S_MODE"
    if [ "$S_MODE" = window ]; then
        echo "window=$(tmux -S "$S_SOCKET" display-message -p -t "$S_PANE" '#{session_name}:#{window_index}')"
    else
        echo "attach=tmux -S $S_SOCKET attach"; echo "attach_in_tmux=TMUX= tmux -S $S_SOCKET attach"
    fi
}

run_cmd() { # prototype of the typing path only: marker check, type, read back
    owner_init; alive || fail 'no companion is open for this owner' 4
    tmux -S "$S_SOCKET" send-keys -t "$S_PANE" -l -- "$1"; tmux -S "$S_SOCKET" send-keys -t "$S_PANE" Enter
    sleep 0.5; tmux -S "$S_SOCKET" capture-pane -p -t "$S_PANE" | grep -v '^\s*$' | tail -3
}

watch_cmd() {
    trap '' HUP INT
    local dir="$ROOT/sessions/$1" me=$$
    while sleep "$WATCH_EVERY"; do
        state_load "$dir" || exit 0
        [ "$S_WATCH_PID" = "$me" ] || exit 0
        if [ "$(proc_start "$S_OWNER_PID")" != "$S_OWNER_START" ]; then close_dir "$dir" watchdog; exit 0; fi
    done
}

close_cmd() {
    local in sid
    if [ "${1:-}" = --hook ]; then
        in=$(cat); sid=${in#*\"session_id\":\"}; sid=${sid%%\"*}
        valid_sid "$sid" || return 0
        CLUX_SESSION_ID=$sid owner_init
        state_load && [ "$S_SESSION" = "$sid" ] && close_dir "$D"
        return 0
    fi
    owner_init; state_load || return 0
    [ "$S_SESSION" = "$SID" ] || fail 'no companion is open for this owner' 4
    close_dir "$D"
}

reap() {
    local dir
    for dir in "$ROOT/sessions/"*; do
        [ -d "$dir" ] || continue
        state_load "$dir" || { rm -rf "$dir"; continue; }
        # One Claude process runs one session at a time: a companion of this
        # process under another session id is left from a /clear whose
        # SessionEnd hook did not run.
        if [ "$(proc_start "$S_OWNER_PID")" != "$S_OWNER_START" ] || ! pane_is_ours "$S_SOCKET" "$S_PANE" "$S_TOKEN" \
            || { [ "$S_OWNER_PID" = "${CLAUDE_PID:-}" ] && [ "$S_OWNER_START" = "${OWNER_START:-}" ] && [ "$S_SESSION" != "$SID" ]; }; then
            close_dir "$dir"
        fi
    done
    D="$ROOT/sessions/${SID:0:8}"
}

case "${1:-}" in
    open) shift; open_cmd "$@" ;;
    run) shift; run_cmd "$@" ;;
    close) shift; close_cmd "$@" ;;
    watch) shift; watch_cmd "$@" ;;
    *) fail 'usage: bgc.sh open [--socket] | run TEXT | close [--hook] | watch SHORT' ;;
esac
