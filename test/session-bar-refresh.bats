#!/usr/bin/env bats
# session-bar-refresh.bats — session-bar-refresh.sh: the single refresh entry
# point for both @clux_session_bar and @clux_status. Neither option is written
# when its renderer FAILS, and the forced redraw is skipped when called with
# "quiet".
#
# The two tokens differ on an exit-0-with-empty result, and the staged tests
# at the bottom pin that difference down:
#   @clux_status  empty IS the answer ("no notification pending"), so it must
#                 be written — otherwise a dismissed notification stays on the
#                 bar until an unrelated one replaces it.
#   @clux_session_bar  empty is never a real answer while tmux runs, so it is
#                 treated as a silent failure and the previous bar is kept.

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

# ---------------------------------------------------------------------------
# Staged copy with stub siblings, so each renderer's exit status and output
# can be dictated exactly. session-bar-refresh.sh resolves both renderers
# through $CURRENT_DIR, so a copy in a temp dir picks up the stubs beside it.
# _stage <bar-exit> <bar-output> <status-exit> <status-output>
_stage() {
    STAGED_DIR="$BATS_TEST_TMPDIR/staged"
    mkdir -p "$STAGED_DIR"
    cp "$SCRIPTS_DIR/session-bar-refresh.sh" "$STAGED_DIR/"
    chmod +x "$STAGED_DIR/session-bar-refresh.sh"

    printf '#!/usr/bin/env bash\nprintf %%s %s\nexit %s\n' \
        "$(printf '%q' "$2")" "$1" > "$STAGED_DIR/session-list.sh"
    printf '#!/usr/bin/env bash\nprintf %%s %s\nexit %s\n' \
        "$(printf '%q' "$4")" "$3" > "$STAGED_DIR/show-notification.sh"
    chmod +x "$STAGED_DIR/session-list.sh" "$STAGED_DIR/show-notification.sh"
}

@test "session-bar-refresh: an empty notification CLEARS @clux_status — the dismissed-badge regression" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    # show-notification.sh exits 0 printing nothing: its normal "nothing
    # pending" path, reached every time a notification is dismissed.
    _stage 0 'BAR' 0 ''
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    # The option must be written, with an empty value. Guarding on non-empty
    # here is exactly what stranded the badge on the bar.
    grep -qF 'set-option -g @clux_status' "$log" || false
}

@test "session-bar-refresh: a FAILING show-notification.sh leaves @clux_status untouched" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    _stage 0 'BAR' 1 ''
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    run grep -qF 'set-option -g @clux_status' "$log"
    [ "$status" -ne 0 ]
}

@test "session-bar-refresh: an empty session bar leaves @clux_session_bar untouched" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    _stage 0 '' 0 'NOTIF'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    run grep -qF 'set-option -g @clux_session_bar' "$log"
    [ "$status" -ne 0 ]
}

@test "session-bar-refresh: one renderer failing does not skip the other" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    _stage 1 '' 0 'NOTIF'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux_status NOTIF' "$log" || false
    grep -qF 'refresh-client -S' "$log" || false
}
