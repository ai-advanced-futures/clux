#!/usr/bin/env bats
# verify-tmux-conf.bats — verify-tmux-conf.sh: parses a candidate tmux config
# for real, on a throwaway server, replacing the old verify_config() that
# never verified anything (both branches of its inner test were empty).
#
# Needs the REAL tmux binary. REAL_TMUX is captured at file-load time, before
# test_helper's setup() prepends the stub directory to PATH — the same
# pattern test_helper.bash itself uses for REAL_JQ.
#
# IMPORTANT: verify-tmux-conf.sh backgrounds a control client so a client is
# always "current" for the parse (see the script's own header comment). Never
# capture the call with bats' `run` / $( ) — that waits for every writer on
# the pipe to close. Redirect to a file and read the status back instead
# (exactly what commands/setup.md's Phase 6 step 8 does, for the same reason).
#
# There is no longer a process to reap. The script fed that client from
# `< <(tail -f /dev/null)`, and bash 3.2 (macOS) does not report a process
# substitution's pid in $!, so the tail could not be killed and one leaked per
# call. These tests used to clean up with `pkill -f 'tail -f /dev/null'`, which
# would equally have killed an unrelated process of the user's sharing that
# command line. The script now holds its own fifo open and leaves nothing
# behind, so the pkill is gone.

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
}

teardown() {
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

@test "verify-tmux-conf: it removes its own throwaway socket file" {
    # tmux does NOT unlink a socket when its server exits — verified directly.
    # With the per-invocation socket name (clux-verify-$$) that costs one stale
    # file per call: a single run of this suite left 175 of them sitting in the
    # tmux directory. cleanup() now removes the file it made.
    local dir="/tmp/tmux-$(id -u)"
    local before after
    before="$(ls "$dir" 2>/dev/null | grep -c '^clux-verify-' || true)"

    local conf="$BATS_TEST_TMPDIR/good.conf"
    printf 'set -g @foo bar\n' > "$conf"
    _run_verify "$conf" "$BATS_TEST_TMPDIR/verify.log"
    [ "$VERIFY_STATUS" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/verify.log"; false; }

    after="$(ls "$dir" 2>/dev/null | grep -c '^clux-verify-' || true)"
    [ "$after" -le "$before" ] \
        || { echo "left $((after - before)) socket file(s) behind in $dir"; false; }
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
