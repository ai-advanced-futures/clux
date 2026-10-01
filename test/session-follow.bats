#!/usr/bin/env bats
# session-follow.bats — session-follow.sh: mirror mode. When one client changes
# session, the other clients go to the same session.
#
# These tests use REAL tmux on a private socket, not the stub. The two faults
# this script exists to avoid are facts about tmux itself, both seen on tmux
# 3.5a: client-session-changed also fires for a switch to the session a client
# is on already, and a format in the hook line gives the old session for a
# client that the hook moved. Each made an endless loop. A stub cannot show
# either one.
#
# The clients are control-mode clients (`tmux -C attach`). They need no
# terminal, and tmux treats them as clients for switch-client and for the hook.
#
# The script calls bare `tmux`. A one-line shim, first on PATH, points it at the
# test server. Inside the hook, run-shell sets $TMUX, so the shim and $TMUX name
# the same server.

load test_helper

REAL_TMUX="$(command -v tmux)"
FOLLOW="$SCRIPTS_DIR/session-follow.sh"

_sock() { printf 'cluxfollow-%s' "$$"; }

_t() { "$REAL_TMUX" -L "$(_sock)" "$@"; }

# _follow <args...> — run the script against the test server.
_follow() { env PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$FOLLOW" "$@"; }

# _attach <n> <session> — attach control-mode client <n>. A fifo holds its
# stdin open; without one the client exits at once.
_attach() {
    local fifo="$BATS_TEST_TMPDIR/fifo-$1"
    mkfifo "$fifo"
    # disown: bash then prints no "Terminated" line when teardown stops them.
    sleep 60 > "$fifo" 3>&- &
    echo $! >> "$BATS_TEST_TMPDIR/pids"; disown
    _t -C attach -t "$2" < "$fifo" > /dev/null 2>&1 3>&- &
    echo $! >> "$BATS_TEST_TMPDIR/pids"; disown
    _wait_for "[ \"\$(_t list-clients | wc -l | tr -d ' ')\" -ge $1 ]"
}

# _client <n> — the name of the client that attached as number <n>.
_client() { _t list-clients -F '#{client_created} #{client_pid} #{client_name}' | sort -n | sed -n "${1}p" | cut -d' ' -f3; }

# _sessions — the session of each client, sorted, on one line.
_sessions() { _t list-clients -F '#{client_session}' | sort | tr '\n' ' ' | sed 's/ $//'; }

# _wait_for <shell test> — poll up to 5 s. A hook runs after the command that
# fired it returns, so an assertion that follows a switch must wait.
_wait_for() {
    local i=0
    while [ "$i" -lt 50 ]; do
        eval "$1" && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}

setup() {
    _t kill-server >/dev/null 2>&1 || true
    _t -f /dev/null new-session -d -s a -x 80 -y 24
    _t new-session -d -s b -x 80 -y 24
    _t new-session -d -s c -x 80 -y 24
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$(_sock)" \
        > "$BATS_TEST_TMPDIR/bin/tmux"
    chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
    : > "$BATS_TEST_TMPDIR/pids"
}

teardown() {
    local sockpath pid
    sockpath="$(_t display-message -p '#{socket_path}' 2>/dev/null || true)"
    _t kill-server >/dev/null 2>&1 || true
    [ -n "$sockpath" ] && rm -f "$sockpath" 2>/dev/null
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$BATS_TEST_TMPDIR/pids"
    return 0
}

@test "session-follow: a new server has mirror mode off and no [92] hook" {
    run _follow status
    [ "$status" -eq 0 ]
    [[ "$output" == *"follow: off"* ]]
    ! _t show-hooks -g | grep -F 'client-session-changed[92]'
}

@test "session-follow: with no argument it gives the status, the sessions and the clients" {
    _attach 1 a
    run _follow
    [ "$status" -eq 0 ]
    [[ "$output" == *"follow: off"* ]]
    [[ "$output" == *"sessions:"* ]]
    [[ "$output" == *"  b  1 windows"* ]]
    [[ "$output" == *"clients:"* ]]
    [[ "$output" == *"$(_client 1)  a  "* ]]
}

@test "session-follow: on sets the [92] hook one time, also when it runs twice" {
    run _follow on
    [ "$status" -eq 0 ]
    [[ "$output" == *"follow: on"* ]]
    _follow on >/dev/null
    local n
    n=$(_t show-hooks -g | grep -cF 'client-session-changed[92]')
    [ "$n" -eq 1 ] || { echo "[92] lines: $n"; false; }
    _t show-hooks -g | grep -F 'client-session-changed[92]' | grep -qF "'$FOLLOW' sync"
}

@test "session-follow: off removes the [92] hook and keeps the other hooks" {
    _t set-hook -g 'client-session-changed[90]' 'run-shell "true"'
    _t set-hook -g 'client-session-changed[91]' 'run-shell "true"'
    _follow on >/dev/null
    run _follow off
    [ "$status" -eq 0 ]
    [[ "$output" == *"follow: off"* ]]
    ! _t show-hooks -g | grep -F 'client-session-changed[92]'
    _t show-hooks -g | grep -qF 'client-session-changed[90]'
    _t show-hooks -g | grep -qF 'client-session-changed[91]'
}

@test "session-follow: when one client changes session, the other client follows" {
    _attach 1 a; _attach 2 a
    _follow on >/dev/null

    _t switch-client -c "$(_client 1)" -t b
    _wait_for '[ "$(_sessions)" = "b b" ]' || { echo "after client 1 -> b: $(_sessions)"; false; }

    # The other direction: mirror mode has no leader.
    _t switch-client -c "$(_client 2)" -t c
    _wait_for '[ "$(_sessions)" = "c c" ]' || { echo "after client 2 -> c: $(_sessions)"; false; }
}

@test "session-follow: a switch makes no loop" {
    # Counts each client-session-changed. Without the difference test in sync,
    # tmux 3.5a ran this hook hundreds of times in one second.
    _attach 1 a; _attach 2 a
    _follow on >/dev/null
    local log="$BATS_TEST_TMPDIR/fired"
    : > "$log"
    _t set-hook -g 'client-session-changed[93]' "run-shell \"echo x >> $log\""

    _t switch-client -c "$(_client 1)" -t b
    _wait_for '[ "$(_sessions)" = "b b" ]'
    sleep 1

    local n
    n=$(wc -l < "$log" | tr -d ' ')
    # One for the client that changed, one for the client that followed.
    [ "$n" -le 4 ] || { echo "client-session-changed fired $n times"; false; }
    [ "$(_sessions)" = "b b" ] || { echo "did not stay: $(_sessions)"; false; }
}

@test "session-follow: on brings clients on different sessions to one session" {
    _attach 1 a; _attach 2 b
    [ "$(_sessions)" = "a b" ]
    _follow on >/dev/null
    _wait_for '[ "$(_sessions)" = "a a" ] || [ "$(_sessions)" = "b b" ]' \
        || { echo "after on: $(_sessions)"; false; }
}

@test "session-follow: after off, a client that changes session moves alone" {
    _attach 1 a; _attach 2 a
    _follow on >/dev/null
    _follow off >/dev/null

    _t switch-client -c "$(_client 1)" -t b
    sleep 1
    [ "$(_sessions)" = "a b" ] || { echo "after off: $(_sessions)"; false; }
}

# A session name is not a safe tmux target. Each name below made the follow
# step fail with no message while the status said "follow: on".
_follows_to_name() {
    _t new-session -d -s "$1" -x 80 -y 24
    local id
    # tmux before 3.6 changes `.` and `:` in a name to `_`; the test then runs
    # with the name that tmux kept.
    id=$(_t list-sessions -F '#{session_id}' | sort -t'$' -k2 -n | tail -1)
    _attach 1 a; _attach 2 a
    _follow on >/dev/null
    _t switch-client -c "$(_client 1)" -t "$id"
    _wait_for '[ "$(_t list-clients -F "#{session_id}" | sort -u | tr -d "\n")" = "$id" ]' \
        || { echo "session [$1]: clients on $(_sessions)"; false; }
}

@test "session-follow: a session name with a dot is followed" {
    _follows_to_name 'a.c'
}

@test "session-follow: a session name with a colon is followed" {
    _follows_to_name 'a:c'
}

@test "session-follow: a session name that looks like a session id is followed" {
    _follows_to_name '$9'
}

@test "session-follow: a session name that looks like a pane id is followed" {
    _follows_to_name '%2'
}

# The hook holds the path of the script. The path goes through sh, run-shell
# and the tmux parser, so each character that one of them reads must be quoted.
_follows_from_dir() {
    local dir="$BATS_TEST_TMPDIR/$1"
    mkdir -p "$dir"
    cp "$FOLLOW" "$dir/session-follow.sh"
    _attach 1 a; _attach 2 a
    env PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$dir/session-follow.sh" on >/dev/null
    _t switch-client -c "$(_client 1)" -t b
    _wait_for '[ "$(_sessions)" = "b b" ]' || { echo "script in [$1]: clients on $(_sessions)"; false; }
}

@test "session-follow: the hook works when the script path has a space" {
    _follows_from_dir 'my dir'
}

@test "session-follow: the hook works when the script path has quote characters" {
    _follows_from_dir "it's \"q\""
}

@test "session-follow: the hook works when the script path has #, \$, % and a backslash" {
    _follows_from_dir '#{x} #1 $HOME 50% b\n'
}

@test "session-follow: the hook works with bash 3.2 quoting rules" {
    # macOS ships bash 3.2 as /bin/bash. Its pattern replacement differs from
    # bash 5 for quote characters, and hook_command depends on it.
    [ -x /bin/bash ] || skip "no /bin/bash"
    local dir="$BATS_TEST_TMPDIR/it's \"q\" #1 \$x"
    mkdir -p "$dir"
    cp "$FOLLOW" "$dir/session-follow.sh"
    _attach 1 a; _attach 2 a
    env PATH="$BATS_TEST_TMPDIR/bin:$PATH" /bin/bash "$dir/session-follow.sh" on >/dev/null
    _t switch-client -c "$(_client 1)" -t b
    _wait_for '[ "$(_sessions)" = "b b" ]' || { echo "clients on $(_sessions)"; false; }
}

@test "session-follow: sync for a client that is gone does nothing and gives exit code 0" {
    _attach 1 a
    run _follow sync 'no-such-client'
    [ "$status" -eq 0 ]
    [ "$(_sessions)" = "a" ]
}

@test "session-follow: an unknown argument gives the usage and exit code 2" {
    run _follow sideways
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
}
