#!/usr/bin/env bats

load test_helper

REAL_TMUX="$(command -v tmux)"
TERMINAL="$SCRIPTS_DIR/terminal.sh"

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export CLUX_TERMINAL_DIR
    CLUX_TERMINAL_DIR=$(mktemp -d /tmp/ct.XXXX)
    export TMUX_SOCKET="$BATS_TEST_TMPDIR/owner.sock"
    mkdir -p "$HOME"
    "$REAL_TMUX" -S "$TMUX_SOCKET" -f /dev/null new-session -d -s owner -x 120 -y 40 3>&-
    local pid
    pid=$("$REAL_TMUX" -S "$TMUX_SOCKET" display-message -p '#{pid}')
    export TMUX="$TMUX_SOCKET,$pid,0"
    export TMUX_PANE
    TMUX_PANE=$("$REAL_TMUX" -S "$TMUX_SOCKET" list-panes -F '#{pane_id}')
}

teardown() {
    "$REAL_TMUX" -S "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$CLUX_TERMINAL_DIR"
}

@test "open creates a split and run returns file-backed output" {
    run "$TERMINAL" open
    [ "$status" -eq 0 ]
    [[ "$output" == *'mode=split'* ]]

    run "$TERMINAL" run -- 'echo companion-ok'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'companion-ok\nexit=0'* ]]
}

@test "send, wait, and read control interactive work" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send --enter -- 'read -p "Name? " name; echo "hello:$name"'
    [ "$status" -eq 0 ]
    run "$TERMINAL" wait --timeout 5 --pattern 'Name\?'
    [ "$status" -eq 0 ]
    "$TERMINAL" send --enter -- Ada
    run "$TERMINAL" wait --timeout 5 --idle
    [ "$status" -eq 0 ]
    run "$TERMINAL" read --lines 20
    [[ "$output" == *'hello:Ada'* ]]
}

@test "close removes the companion state" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ -z "$(find "$CLUX_TERMINAL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]
}
