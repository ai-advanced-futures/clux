#!/usr/bin/env bats

load test_helper

REAL_TMUX="$(command -v tmux)"
TERMINAL="$SCRIPTS_DIR/terminal.sh"

# test_helper's setup() is deliberately NOT reused here: it calls
# install_stubs, and the committed tmux stub would shadow the real tmux that
# these end-to-end tests exist to drive. Everything else it does is repeated
# below, including its teardown cleanup.
setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    # A short root, not BATS_TEST_TMPDIR: `open --socket` puts its socket
    # inside this directory and tmux caps that path at ~100 bytes.
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
    local sock
    for sock in "$CLUX_TERMINAL_DIR"/*/sock; do
        [ -S "$sock" ] && "$REAL_TMUX" -S "$sock" kill-server >/dev/null 2>&1
    done
    "$REAL_TMUX" -S "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$CLUX_TERMINAL_DIR" "$BATS_TEST_TMPDIR"
}

# The private directory of this owner. One owner per test, so one match.
companion_dir() {
    local dir
    for dir in "$CLUX_TERMINAL_DIR"/*-"${TMUX_PANE#%}"; do
        printf '%s' "$dir"
    done
}

companion_pane() {
    sed -n 's/^pane=//p' "$(companion_dir)/state"
}

file_mode() {
    stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

# 1
@test "open makes a split pane and a second open re-uses it" {
    run "$TERMINAL" open
    [ "$status" -eq 0 ]
    [[ "$output" == *'mode=split'* ]] || false
    local first="$output"
    run "$TERMINAL" open
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
}

# 2
@test "run returns the output and the exit code, also after a large output" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'echo hi'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'hi\nexit=0' ]] || false
    run "$TERMINAL" run -- false
    [ "$status" -eq 0 ]
    [[ "$output" == *'exit=1' ]] || false
    run "$TERMINAL" run -- 'seq 1 30000'
    [ "$status" -eq 0 ]
    [[ "$output" == *'30000'* ]] || false
    [[ "$output" == *'output cut'* ]] || false
    [ "$(printf '%s\n' "$output" | grep -c '^[0-9]*$')" -le 200 ]
    run "$TERMINAL" run -- 'echo hi'
    [ "$status" -eq 0 ] || { echo "after large output: $status $output"; false; }
}

# 2b
@test "run --max-lines cuts the output" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run --max-lines 3 -- 'seq 1 10'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'8\n9\n10\nexit=0' ]] || false
    [[ "$output" != *$'\n7\n'* ]] || false
}

# 3
@test "the working directory stays from one run to the next" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" run -- 'cd /tmp' >/dev/null
    run "$TERMINAL" run -- 'pwd'
    [[ "$output" == *$'/tmp\nexit=0' ]] || false
}

# 4
@test "an exported variable stays from one run to the next" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" run -- 'export X=1' >/dev/null
    run "$TERMINAL" run -- 'echo $X'
    [[ "$output" == *$'1\nexit=0' ]] || false
}

# 5
@test "the output file is deleted and the private files are private" {
    "$TERMINAL" open >/dev/null
    local d
    d=$(companion_dir)
    "$TERMINAL" run -- "touch '$BATS_TEST_TMPDIR/made'" >/dev/null
    [ "$(file_mode "$d")" = 700 ]
    [ "$(file_mode "$d/state")" = 600 ]
    [ "$(file_mode "$d/1.rc")" = 600 ]
    [ ! -e "$d/1.out" ]
    [ "$(file_mode "$BATS_TEST_TMPDIR/made")" != 600 ]
}

# 6
@test "run stops at its time limit and wait --run gets the result" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run --timeout 1 -- 'echo early; sleep 3; echo late'
    [ "$status" -eq 1 ]
    [[ "$output" == 'run=1'* ]] || false
    [ "$(file_mode "$(companion_dir)/1.out")" = 600 ]
    run "$TERMINAL" wait --timeout 10 --max-lines 1 --run 1
    [ "$status" -eq 0 ]
    [[ "$output" == $'output cut: the last 1 of 2 lines\nlate\nexit=0' ]] || false
    [ ! -d "$(companion_dir)/busy" ]
}

# 7
@test "a second run while the first is not complete exits 5" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run --timeout 1 -- 'sleep 3'
    [ "$status" -eq 1 ]
    run "$TERMINAL" run -- 'echo no'
    [ "$status" -eq 5 ]
}

# 7b
@test "a lock left by a completed run does not block the next run" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run --timeout 1 -- 'sleep 2'
    [ "$status" -eq 1 ]
    sleep 3
    run "$TERMINAL" run -- 'echo next'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'next\nexit=0' ]] || false
}

# 8
@test "a credential prompt stops run, read and wait until the user answers" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'read -s -p "Password: " p; echo "got:$p"'
    [ "$status" -eq 3 ]
    [[ "$output" != *'Password'* ]] || false
    run "$TERMINAL" read
    [ "$status" -eq 3 ]
    [[ "$output" != *'Password'* ]] || false
    local start=$SECONDS
    run "$TERMINAL" wait --timeout 3 --run 1
    [ "$status" -eq 1 ]
    [ $((SECONDS - start)) -ge 2 ]
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" 'hunter2' Enter
    run "$TERMINAL" wait --timeout 10 --run 1
    [ "$status" -eq 0 ]
    [ "$output" = 'exit=0' ]
}

# 9
@test "run --secret returns only the exit code and blocks wait --pattern" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run --secret -- 'echo token'
    [ "$status" -eq 0 ]
    [ "$output" = $'run=1\nexit=0' ]
    run "$TERMINAL" wait --timeout 2 --pattern token
    [ "$status" -eq 3 ]
    run "$TERMINAL" read
    [ "$status" -eq 3 ]
}

# 10
@test "send, wait and read control interactive work" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send --enter -- 'read -p "Name? " name; echo "hello:$name"'
    [ "$status" -eq 0 ]
    run "$TERMINAL" wait --timeout 5 --pattern 'Name\?'
    [ "$status" -eq 0 ]
    "$TERMINAL" send --enter -- Ada
    run "$TERMINAL" wait --timeout 5 --idle
    [ "$status" -eq 0 ]
    run "$TERMINAL" read --lines 20
    [[ "$output" == *'hello:Ada'* ]] || false
}

# wait --idle must actually wait. A `wait` that returns 0 immediately also
# passes the case above, so this case pins the busy answer.
@test "wait --idle reports busy while a command runs, idle once it ends" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'sleep 4' >/dev/null
    run "$TERMINAL" wait --timeout 1 --idle
    [ "$status" -eq 1 ] || { echo "expected busy (1), got $status"; false; }
    run "$TERMINAL" wait --timeout 10 --idle
    [ "$status" -eq 0 ] || { echo "expected idle (0), got $status"; false; }
}

# 11
@test "close removes the pane and the directory, close --hook is silent" {
    "$TERMINAL" open >/dev/null
    local pane
    pane=$(companion_pane)
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ -z "$(find "$CLUX_TERMINAL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]
    ! "$REAL_TMUX" -S "$TMUX_SOCKET" list-panes -t "$pane" >/dev/null 2>&1 || false
    run bash -c "printf x | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# 11b
@test "close --owner closes the companion of another owner pane" {
    "$TERMINAL" open >/dev/null
    local owner="$TMUX_PANE"
    run env TMUX_PANE=%999 "$TERMINAL" close --owner "$owner"
    [ "$status" -eq 0 ]
    [ -z "$(find "$CLUX_TERMINAL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

# 12
@test "the reaper removes a gone owner and keeps a live foreign server" {
    local key
    key=$("$REAL_TMUX" -S "$TMUX_SOCKET" display-message -p '#{pid}-#{start_time}')
    mkdir -p "$CLUX_TERMINAL_DIR/$key-999" "$CLUX_TERMINAL_DIR/$$-1-3"
    "$TERMINAL" open >/dev/null
    [ ! -e "$CLUX_TERMINAL_DIR/$key-999" ]
    [ -d "$CLUX_TERMINAL_DIR/$$-1-3" ]
}

# 14
@test "a completed run keeps output that looks like a credential line" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'echo token: abc'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'token: abc\nexit=0' ]] || false
}

# 15
@test "a background process that holds the output gives a note and no lock" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'sleep 4 & echo started'
    [ "$status" -eq 0 ]
    [[ "$output" == *'started'* ]] || false
    [[ "$output" == *'output may be incomplete'* ]] || false
    [[ "$output" == *'exit=0' ]] || false
    [ ! -d "$(companion_dir)/busy" ]
}

# 16
@test "open makes a new companion after the pane is killed" {
    "$TERMINAL" open >/dev/null
    "$REAL_TMUX" -S "$TMUX_SOCKET" kill-pane -t "$(companion_pane)"
    run "$TERMINAL" open
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'echo hi'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'hi\nexit=0' ]] || false
}

# 17
@test "exit cannot close the pane shell" {
    "$TERMINAL" open >/dev/null
    local pane
    pane=$(companion_pane)
    run "$TERMINAL" run -- 'exit'
    [ "$status" -eq 2 ]
    run "$TERMINAL" run -- 'echo a; exit'
    [ "$status" -eq 0 ]
    [[ "$output" == *'a'* ]] || false
    "$REAL_TMUX" -S "$TMUX_SOCKET" list-panes -t "$pane" >/dev/null
    run "$TERMINAL" run -- 'echo alive'
    [[ "$output" == *$'alive\nexit=0' ]] || false
}

# 18
@test "output with no final newline keeps exit on its own line" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'printf hi'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nhi\nexit=0' ]] || false
    run "$TERMINAL" run -- 'echo after'
    [ "$status" -eq 0 ]
}

# 19
@test "the next plain run clears a secret from the screen and the history" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" run --secret -- 'echo token' >/dev/null
    run "$TERMINAL" run -- true
    [ "$status" -eq 0 ]
    run "$TERMINAL" read
    [ "$status" -eq 0 ]
    [[ "$output" != *'token'* ]] || false
    run "$REAL_TMUX" -S "$TMUX_SOCKET" capture-pane -p -t "$(companion_pane)" -S -50
    [[ "$output" != *'token'* ]] || false
}

# 20
@test "a command cannot change the wrapper variables or leave the wrapper" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'for n in 7 8; do echo $n; done'
    [[ "$output" == *$'7\n8\nexit=0' ]] || false
    run "$TERMINAL" run -- 'echo hi'
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'D=oops; echo hi'
    [[ "$output" == *$'hi\nexit=0' ]] || false
    run "$TERMINAL" run -- 'return'
    [ "$status" -eq 2 ]
}

# 21
@test "wait --idle stops on a credential prompt" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'read -s -p "Password: " p' >/dev/null
    run "$TERMINAL" wait --timeout 5 --idle
    [ "$status" -eq 3 ]
}

@test "socket mode opens a private server and close stops it" {
    run "$TERMINAL" open --socket
    [ "$status" -eq 0 ]
    [[ "$output" == *'mode=socket'* ]] || false
    [[ "$output" == *'attach=tmux -S '* ]] || false
    local sock
    sock="$(companion_dir)/sock"
    run "$TERMINAL" open --socket
    [[ "$output" == *'attach=tmux -S '* ]] || false
    run "$TERMINAL" run -- 'echo private'
    [[ "$output" == *$'private\nexit=0' ]] || false
    "$TERMINAL" close
    ! "$REAL_TMUX" -S "$sock" list-sessions >/dev/null 2>&1 || false
}
