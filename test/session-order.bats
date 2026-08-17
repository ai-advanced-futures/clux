#!/usr/bin/env bats
# session-order.bats — session-order.sh: the single source of truth for
# display order, shared by session-list.sh (render), session-reorder.sh
# (mutate) and switch-session.sh (next/previous).

load test_helper

ORDER_SCRIPT="$SCRIPTS_DIR/session-order.sh"

# ---------------------------------------------------------------------------
# _write_order_tmux_stub — answers show-option -gqv @clux-session-order (from
# FAKE_ORDER) and list-sessions -F '#{session_id}\t#{session_name}' (from
# FAKE_SESSIONS, "$id<TAB>name" rows, id WITHOUT the leading "$" the real
# tmux format emits — session-order.sh's own sed strips that, so the stub
# must supply it exactly as real tmux would: "$0", "$1", ...).
# ---------------------------------------------------------------------------
_write_order_tmux_stub() {
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
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "session-order: stored order is honoured for every live session it names" {
    _write_order_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export FAKE_ORDER='b,a,c'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$ORDER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'b\na\nc')" ]
}

@test "session-order: a stored name for a dead session is dropped, live ones self-correct" {
    _write_order_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export FAKE_ORDER='b,ghost,a'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb'
        '$ORDER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'b\na')" ]
    # Falsifiable: the dead name never leaks into the output.
    [[ "$output" != *ghost* ]]
}

@test "session-order: a live session absent from stored order is appended in creation (session id) order" {
    _write_order_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export FAKE_ORDER='b'
        export FAKE_SESSIONS=\$'\$0\ta\n\$1\tb\n\$2\tc'
        '$ORDER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    # b first (stored), then a (id 0) before c (id 2) — creation order, not
    # tmux's own listing order.
    [ "$output" = "$(printf 'b\na\nc')" ]
}

@test "session-order: empty stored order falls back to plain creation order" {
    _write_order_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\ta\n\$2\tc\n\$1\tb'
        '$ORDER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'a\nb\nc')" ]
}

@test "session-order: a comma inside a stored name splits into unmatched fragments and self-corrects" {
    _write_order_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export FAKE_ORDER='a,b,c'
        export FAKE_SESSIONS=\$'\$0\ta,b\n\$1\tc'
        '$ORDER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    # "a,b" (the real live session) matches neither fragment "a" nor "b", so
    # it falls through to the creation-order fallback instead of vanishing.
    [ "$output" = "$(printf 'c\na,b')" ]
}

@test "session-order: no live sessions at all prints nothing and exits 0" {
    _write_order_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export FAKE_ORDER='a,b'
        export FAKE_SESSIONS=''
        '$ORDER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
