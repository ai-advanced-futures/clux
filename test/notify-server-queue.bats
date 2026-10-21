#!/usr/bin/env bats
# notify-server-queue.bats — each tmux server has its own notification queue.
#
# Before 5.5.0 every server read and wrote one queue file, so server A showed
# the notifications of the sessions of server B. Now the queue of the server
# named "default" keeps the old path, and any other server adds "-<name>".
#
# The server-level cases use REAL tmux and REAL ps on two sockets: which
# server holds a pane, and which `tmux` process names which socket, are facts
# about tmux and the process table that a stub cannot prove. The desktop
# banner and the sound stay stubbed.

load test_helper

REAL_TMUX="$(command -v tmux)"
REAL_PS="$(command -v ps)"
PATH_SH="$SCRIPTS_DIR/path.sh"

_sock() { printf 'cluxq-%s-%s' "$$" "$1"; }
# The path the server itself reports, as the other real-tmux tests ask it.
_sock_path() { "$REAL_TMUX" -L "$(_sock "$1")" display -p '#{socket_path}'; }

# _start TAG [SERVER_NAME] — a server on its own socket. SERVER_NAME sets
# @server_name, as prefix + T does after a rename.
_start() {
    local tag="$1" sock; sock="$(_sock "$tag")"
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    "$REAL_TMUX" -L "$sock" -f /dev/null new-session -d -s "sess-$tag" -x 80 -y 24 "${3:-sleep 300}"
    "$REAL_TMUX" -L "$sock" set -g @claude-notify-stop-visual on
    [ -z "${2:-}" ] || "$REAL_TMUX" -L "$sock" set -s @server_name "$2"
}

setup() {
    # The shared setup: stubs first on PATH, HOME and CLUX_NOTIFY_FILE per test.
    clux_setup
    unset TMUX TMUX_PANE
    # Real tmux and ps in front of their stubs.
    mkdir -p "$BATS_TEST_TMPDIR/real"
    ln -s "$REAL_TMUX" "$BATS_TEST_TMPDIR/real/tmux"
    ln -s "$REAL_PS" "$BATS_TEST_TMPDIR/real/ps"
    export REAL_PATH="$BATS_TEST_TMPDIR/real:$PATH"
}

teardown() {
    local t sock
    for t in a b; do
        sock=$(_sock_path "$t" 2>/dev/null)
        "$REAL_TMUX" -L "$(_sock "$t")" kill-server >/dev/null 2>&1 || true
        [ -z "$sock" ] || rm -f "$sock"
    done
    clux_teardown
}

# ---------------------------------------------------------------------------
# The name rule
# ---------------------------------------------------------------------------

@test "notify_file_for_server: default and no name keep the base, a name adds -NAME" {
    run bash -c "
        source '$PATH_SH'
        for n in '' default work lock; do notify_file_for_server /q/base \"\$n\"; done
    "
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "/q/base" ]
    [ "${lines[1]}" = "/q/base" ]
    [ "${lines[2]}" = "/q/base-work" ]
    [ "${lines[3]}" = "/q/base-lock" ]
}

@test "notify_file_for_server: a name rename-server.sh refuses keeps the base" {
    run bash -c "
        source '$PATH_SH'
        for n in 'a b' 'a/b' 'a;b' 'a:b' 'a#b' 'a\"b' \"a'b\" 'a\\\\b'; do notify_file_for_server /q/base \"\$n\"; done
    "
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 8 ]
    for l in "${lines[@]}"; do [ "$l" = "/q/base" ]; done
}

@test "resolve_notify_file NAME adds the name to the tier-1 base" {
    run bash -c "source '$PATH_SH'; resolve_notify_file work; resolve_notify_file"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$QUEUE_FILE-work" ]
    [ "${lines[1]}" = "$QUEUE_FILE" ]
}

@test "clux_server_name outside tmux with no socket is empty and calls no tmux" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "export STUB_LOG='$stub_log'; source '$PATH_SH'; clux_server_name"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$stub_log" ]
}

@test "clux_server_name: @server_name wins over the socket name" {
    _start a
    _start b renamed
    run env PATH="$REAL_PATH" bash -c "
        source '$PATH_SH'
        clux_server_name '$(_sock_path a)'
        clux_server_name '$(_sock_path b)'
    "
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$(_sock a)" ]
    [ "${lines[1]}" = "renamed" ]
}

# ---------------------------------------------------------------------------
# The writers
# ---------------------------------------------------------------------------

@test "interactive path: a Claude in a pane of server A writes only the queue of A" {
    _start a alpha
    _start b beta
    local pane; pane=$("$REAL_TMUX" -L "$(_sock a)" display -p -t sess-a '#{pane_id}')
    local JSON='{"hook_event_name":"Stop","session_id":"s-int","cwd":"/tmp"}'
    mkdir -p "$HOME/.config/tmux"
    run env PATH="$REAL_PATH" TMUX="$(_sock_path a),1,0" TMUX_PANE="$pane" \
        bash -c "printf '%s' '$JSON' | '$NOTIFY_HOOK'"
    [ "$status" -eq 0 ]
    # The pane path reads its base from @claude-notify-file (unset: HOME default).
    grep -qF "sess-a:" "$HOME/.config/tmux/claude_notification-alpha"
    [ ! -e "$HOME/.config/tmux/claude_notification-beta" ]
    [ ! -e "$HOME/.config/tmux/claude_notification" ]
}

@test "agent path: the notification goes to the server that holds the dashboard" {
    local proj="$BATS_TEST_TMPDIR/proj"; mkdir -p "$proj/sub"
    # A process that ps shows as `claude … agents --cwd <proj>`, the shape
    # resolve_agents_pane_by_cwd looks for.
    printf '#!/usr/bin/env bash\nexec -a claude awk '\''BEGIN{system("sleep 300")}'\'' agents --cwd "$1"\n' \
        > "$BATS_TEST_TMPDIR/dash.sh"
    chmod +x "$BATS_TEST_TMPDIR/dash.sh"
    _start a alpha
    _start b beta "$BATS_TEST_TMPDIR/dash.sh $proj"
    local i=0
    until "$REAL_PS" -A -ww -o args= | grep -qF "agents --cwd $proj"; do
        i=$((i + 1)); [ "$i" -lt 50 ] || false; sleep 0.1
    done

    local JSON="{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"ag-1\",\"cwd\":\"$proj/sub\",\"message\":\"needs you\"}"
    run env PATH="$REAL_PATH" bash -c "printf '%s' '$JSON' | '$NOTIFY_HOOK'"
    [ "$status" -eq 0 ]
    grep -qF "|||agent:ag-1@@" "$QUEUE_FILE-beta"
    [ ! -e "$QUEUE_FILE-alpha" ]
    [ ! -e "$QUEUE_FILE" ]
}

@test "agent path: with no dashboard and no default server the base queue gets it" {
    export TMUX_TMPDIR="$BATS_TEST_TMPDIR/tt"; mkdir -p "$TMUX_TMPDIR"
    local JSON='{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"ag-2","cwd":"/nowhere","message":"needs you"}'
    run env PATH="$REAL_PATH" bash -c "printf '%s' '$JSON' | '$NOTIFY_HOOK'"
    [ "$status" -eq 0 ]
    grep -qF "|||agent:ag-2@@" "$QUEUE_FILE"
}

# ---------------------------------------------------------------------------
# The readers
# ---------------------------------------------------------------------------

@test "status bar: each server shows only its own queue" {
    _start a alpha
    _start b beta
    printf 'other:win alpha-only|||$9:@9\n' > "$QUEUE_FILE-alpha"
    printf 'other:win beta-only|||$9:@9\n' > "$QUEUE_FILE-beta"
    run env PATH="$REAL_PATH" TMUX="$(_sock_path a),1,0" bash "$SCRIPTS_DIR/show-notification.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha-only"* ]]
    [[ "$output" != *"beta-only"* ]]
    run env PATH="$REAL_PATH" TMUX="$(_sock_path b),1,0" bash "$SCRIPTS_DIR/notification-line.sh" path
    [ "$output" = "$QUEUE_FILE-beta" ]
}

@test "dismiss: removes the top line of this server's queue only" {
    _start a alpha
    printf 'one|||$9:@9\ntwo|||$9:@9\n' > "$QUEUE_FILE-alpha"
    printf 'keep|||$9:@9\n' > "$QUEUE_FILE"
    run env PATH="$REAL_PATH" TMUX="$(_sock_path a),1,0" bash "$SCRIPTS_DIR/dismiss-notification.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$QUEUE_FILE-alpha")" = 'two|||$9:@9' ]
    [ "$(cat "$QUEUE_FILE")" = 'keep|||$9:@9' ]
}

# ---------------------------------------------------------------------------
# rename-notify-file.sh
# ---------------------------------------------------------------------------

@test "rename-notify-file: moves the queue and its lock files to the new name" {
    printf 'line\n' > "$QUEUE_FILE-old"
    mkdir "$QUEUE_FILE-old.lock"; : > "$QUEUE_FILE-old.flock"
    run bash "$SCRIPTS_DIR/rename-notify-file.sh" old new
    [ "$status" -eq 0 ]
    [ "$(cat "$QUEUE_FILE-new")" = "line" ]
    [ ! -e "$QUEUE_FILE-old" ]
    [ ! -e "$QUEUE_FILE-old.lock" ]
    [ ! -e "$QUEUE_FILE-old.flock" ]
}

@test "rename-notify-file: appends to a queue the new name already has" {
    printf 'new-1\n' > "$QUEUE_FILE-new"
    printf 'old-1\n' > "$QUEUE_FILE"
    run bash "$SCRIPTS_DIR/rename-notify-file.sh" default new
    [ "$status" -eq 0 ]
    [ "$(cat "$QUEUE_FILE-new")" = $'new-1\nold-1' ]
    [ ! -e "$QUEUE_FILE" ]
}

@test "rename-notify-file: the same queue for both names changes nothing" {
    printf 'line\n' > "$QUEUE_FILE"
    run bash "$SCRIPTS_DIR/rename-notify-file.sh" default ''
    [ "$status" -eq 0 ]
    [ "$(cat "$QUEUE_FILE")" = "line" ]
}

@test "rename-notify-file: a wrong argument count exits 2" {
    run bash "$SCRIPTS_DIR/rename-notify-file.sh" one
    [ "$status" -eq 2 ]
}
