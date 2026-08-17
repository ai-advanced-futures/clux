#!/usr/bin/env bats
# switch-session.bats — switch-session.sh: prefix + N / P move to the
# next/previous session in session-order.sh's order, wrapping at the edges.

load test_helper

SWITCH_SCRIPT="$SCRIPTS_DIR/switch-session.sh"

_write_switch_tmux_stub() {
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

@test "switch-session: next moves to the following session in bar order" {
    _write_switch_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_CURRENT='a'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$SWITCH_SCRIPT' next
    "
    [ "$status" -eq 0 ]
    grep -qF 'switch-client -t b' "$log" || false
}

@test "switch-session: prev moves to the preceding session in bar order" {
    _write_switch_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_CURRENT='b'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$SWITCH_SCRIPT' prev
    "
    [ "$status" -eq 0 ]
    grep -qF 'switch-client -t a' "$log" || false
}

@test "switch-session: next wraps around from the last session to the first" {
    _write_switch_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_CURRENT='c'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$SWITCH_SCRIPT' next
    "
    [ "$status" -eq 0 ]
    grep -qF 'switch-client -t a' "$log" || false
}

@test "switch-session: prev wraps around from the first session to the last" {
    _write_switch_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_CURRENT='a'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$SWITCH_SCRIPT' prev
    "
    [ "$status" -eq 0 ]
    grep -qF 'switch-client -t c' "$log" || false
}

@test "switch-session: a single live session is a silent no-op — no switch-client call" {
    _write_switch_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_CURRENT='a'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\ta'
        '$SWITCH_SCRIPT' next
    "
    [ "$status" -eq 0 ]
    run grep -qF 'switch-client' "$log"
    [ "$status" -ne 0 ]
}
