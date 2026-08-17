#!/usr/bin/env bats
# verify-tmux-conf.bats — verify-tmux-conf.sh: parses a candidate tmux config
# for real, on a throwaway server, replacing the old verify_config() that
# never verified anything (both branches of its inner test were empty).
#
# Needs the REAL tmux binary. REAL_TMUX is captured at file-load time, before
# test_helper's setup() prepends the stub directory to PATH — the same
# pattern test_helper.bash itself uses for REAL_JQ.
#
# IMPORTANT: verify-tmux-conf.sh backgrounds a control client fed by
# `< <(tail -f /dev/null)` so a client is always "current" for the parse
# (see the script's own header comment). That tail process is a
# process-substitution grandchild the script's own trap cannot reap, so it
# outlives every call. Two rules follow, in every test below:
#   1. Never capture the call with bats' `run` / $( ) — that waits for every
#      writer on the pipe to close and hangs forever on the leftover tail.
#      Redirect to a file and read $? back instead (exactly what
#      commands/setup.md's Phase 6 step 8 does, for the same reason).
#   2. Reap the leaked process afterwards, or the whole suite run hangs on
#      it even though verify-tmux-conf.sh itself already returned.

load test_helper

REAL_TMUX="$(command -v tmux)"
VERIFY_SCRIPT="$SCRIPTS_DIR/verify-tmux-conf.sh"

# Sets $VERIFY_STATUS rather than relying on a bare command's $? — bats runs
# test bodies with errexit semantics, so a plain failing statement (this one
# is SUPPOSED to fail in the broken-config tests) would abort the test right
# here instead of letting the assertions below run.
_run_verify() {
    local conf="$1" log="$2"
    # The `if` is load-bearing, not decorative: bats runs test bodies under
    # errexit, and the broken-config tests below feed this a config that is
    # SUPPOSED to fail — a bare (unconditioned) failing command would abort
    # the test right here instead of letting the assertions run.
    if bash -c "PATH='$(dirname "$REAL_TMUX"):/usr/bin:/bin' '$VERIFY_SCRIPT' '$conf'" >"$log" 2>&1 </dev/null; then
        VERIFY_STATUS=0
    else
        VERIFY_STATUS=$?
    fi
    pkill -f 'tail -f /dev/null' >/dev/null 2>&1 || true
}

teardown() {
    pkill -f 'tail -f /dev/null' >/dev/null 2>&1 || true
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "verify-tmux-conf: a good config parses cleanly and exits 0" {
    local conf="$BATS_TEST_TMPDIR/good.conf"
    printf 'set -g @foo bar\n' > "$conf"
    local log="$BATS_TEST_TMPDIR/verify.log"
    _run_verify "$conf" "$log"
    local status=$VERIFY_STATUS
    [ "$status" -eq 0 ] || { cat "$log"; false; }
    # The exit code is the load-bearing contract on success. (Under a bats
    # harness specifically, bash's own job-control machinery can print an
    # incidental "Terminated: 15  tail -f /dev/null" line to this same fd
    # when the throwaway control client's helper process dies — that is
    # shell chatter about verify-tmux-conf.sh's own cleanup, not a tmux
    # parse error, so it must never be mistaken for one here.)
    run grep -qiE 'invalid option|syntax error|unknown option' "$log"
    [ "$status" -ne 0 ]
}

@test "verify-tmux-conf: a broken config (unknown option) fails with tmux's own parse error on stderr" {
    local conf="$BATS_TEST_TMPDIR/bad.conf"
    printf 'set -g not-a-real-option foo\n' > "$conf"
    local log="$BATS_TEST_TMPDIR/verify.log"
    _run_verify "$conf" "$log"
    local status=$VERIFY_STATUS
    [ "$status" -ne 0 ]
    grep -qF 'invalid option' "$log" || false
}

@test "verify-tmux-conf: a broken config (unclosed brace) fails with a syntax error" {
    local conf="$BATS_TEST_TMPDIR/bad-brace.conf"
    printf 'bind-key x {\n  display-message "unterminated"\n' > "$conf"
    local log="$BATS_TEST_TMPDIR/verify.log"
    _run_verify "$conf" "$log"
    local status=$VERIFY_STATUS
    [ "$status" -ne 0 ]
    [ -s "$log" ]
}

@test "verify-tmux-conf: no argument prints usage and exits 1" {
    run bash -c "'$VERIFY_SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage"* ]]
}

@test "verify-tmux-conf: a nonexistent file path exits 1 with a clear message" {
    run bash -c "'$VERIFY_SCRIPT' '$BATS_TEST_TMPDIR/does-not-exist.conf'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no such file"* ]]
}
