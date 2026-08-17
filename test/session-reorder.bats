#!/usr/bin/env bats
# session-reorder.bats — session-reorder.sh: prefix + { / } moves the current
# session left/right in the order session-order.sh resolves, no-ops at the
# edges, then writes @clux-session-order and redraws immediately.

load test_helper

REORDER_SCRIPT="$SCRIPTS_DIR/session-reorder.sh"

# Serves display-message -p '#S' (FAKE_CURRENT), session-order.sh's own
# show-option/list-sessions pair (FAKE_ORDER/FAKE_SESSIONS), and logs
# set-option so the new order can be asserted. session-bar-refresh.sh (which
# session-reorder.sh calls at the end) shells out further — session-list.sh
# and agent-query.sh — but with no agent-query.sh on $HOME and empty
# tmux answers everywhere else, those calls degrade harmlessly and are not
# under test here.
_write_reorder_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    show-option)
        case "$*" in
            *@clux-session-order*) printf '%s\n' "${FAKE_ORDER:-}" ;;
        esac
        ;;
    list-sessions)
        [ -n "${FAKE_SESSIONS:-}" ] && printf '%s\n' "${FAKE_SESSIONS}"
        ;;
    display-message)
        [ -n "${FAKE_CURRENT:-}" ] && printf '%s\n' "${FAKE_CURRENT}"
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "session-reorder: right swaps the current session with its right neighbour" {
    _write_reorder_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        export FAKE_CURRENT='b'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$REORDER_SCRIPT' right
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux-session-order a,c,b' "$log" || false
}

@test "session-reorder: left swaps the current session with its left neighbour" {
    _write_reorder_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        export FAKE_CURRENT='b'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$REORDER_SCRIPT' left
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux-session-order b,a,c' "$log" || false
}

@test "session-reorder: left at the left edge is a no-op — order is written back unchanged" {
    _write_reorder_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        export FAKE_CURRENT='a'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$REORDER_SCRIPT' left
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux-session-order a,b,c' "$log" || false
}

@test "session-reorder: right at the right edge is a no-op — order is written back unchanged" {
    _write_reorder_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        export FAKE_CURRENT='c'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$REORDER_SCRIPT' right
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux-session-order a,b,c' "$log" || false
}

@test "session-reorder: redraws immediately by shelling out to session-bar-refresh.sh" {
    _write_reorder_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        export FAKE_CURRENT='b'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$REORDER_SCRIPT' right
    "
    [ "$status" -eq 0 ]
    # session-bar-refresh.sh's non-quiet path ends with refresh-client -S.
    grep -qF 'tmux refresh-client -S' "$log" || false
}
