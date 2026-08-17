#!/usr/bin/env bats
# session-bar-refresh.bats — session-bar-refresh.sh: the single refresh entry
# point for both @clux_session_bar and @clux_status. Sets each option only
# when its renderer exits 0 and prints something, and skips the forced
# redraw when called with "quiet".

load test_helper

REFRESH_SCRIPT="$SCRIPTS_DIR/session-bar-refresh.sh"

# session-list.sh (called by session-bar-refresh.sh) renders nothing when
# there are no live sessions, and session-bar-refresh.sh only sets the option
# when its renderer prints something — so this stub answers list-sessions
# with one live session, enough for session-list.sh to produce non-empty
# output.
_write_one_session_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    list-sessions)
        case "$3" in
            *session_id*) printf '$0\talpha\n' ;;
            *session_attached*) printf 'alpha\t1\talpha\n' ;;
        esac
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "session-bar-refresh: sets @clux_session_bar from session-list.sh output" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$REFRESH_SCRIPT'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux_session_bar' "$log" || false
}

@test "session-bar-refresh: quiet skips the forced redraw" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$REFRESH_SCRIPT' quiet
    "
    [ "$status" -eq 0 ]
    run grep -qF 'refresh-client -S' "$log"
    [ "$status" -ne 0 ]
}

@test "session-bar-refresh: without quiet, issues refresh-client -S" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$REFRESH_SCRIPT'
    "
    [ "$status" -eq 0 ]
    grep -qF 'refresh-client -S' "$log" || false
}
