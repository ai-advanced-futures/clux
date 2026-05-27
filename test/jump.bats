#!/usr/bin/env bats
# jump.bats — jump-to-notification.sh agent: branch tests (Task 7)

load test_helper

# ---------------------------------------------------------------------------
# Case 1: agent: line → agent_jump called (dashboard found)
# ---------------------------------------------------------------------------
@test "jump: agent line routes to agent_jump when dashboard found" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Write a tmux stub that logs all calls and emits the dashboard window for list-windows
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-windows" ]; then
    printf '$sess1 @win2\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    # Write queue with an agent: entry on the top line
    printf '⚡ needs input|||agent:s-abc-123\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF "switch-client" "$stub_log" || false
    grep -qF "select-window" "$stub_log" || false
}

# ---------------------------------------------------------------------------
# Case 2: agent: line → agent_jump called (no dashboard, new-window)
# ---------------------------------------------------------------------------
@test "jump: agent line with no dashboard opens new-window" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Default tmux stub logs calls but emits nothing for list-panes (no dashboard)

    printf '⚡ needs input|||agent:s-abc-123\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF "new-window" "$stub_log" || false
    grep -qF "agents" "$stub_log" || false
}

# ---------------------------------------------------------------------------
# Case 3: agent: prefix check runs BEFORE generic ||| branch
# Falsifiable: STUB_LOG must NOT contain "select-window" with the agent id (which
# the generic ||| branch would produce by trying tmux select-window -t "agent:s-abc-123").
# ---------------------------------------------------------------------------
@test "jump: agent: prefix check runs before generic ||| branch (no mis-routing)" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Use default tmux stub (no dashboard) — new-window path, not select-window

    printf '⚡ label|||agent:s-abc-123\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    # Generic ||| branch would have called: tmux select-window -t "agent:s-abc-123"
    # Falsifiable: assert that string does NOT appear in the stub log
    run grep -F "select-window -t agent:" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Case 4: Interactive line still works (generic ||| branch used)
# ---------------------------------------------------------------------------
@test "jump: interactive |||session_id:window_id line routes via generic branch" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    printf 'main:editor Task done|||$sess1:@win3\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF "select-window" "$stub_log" || false
    grep -qF "switch-client" "$stub_log" || false
    # Must have used the parsed session_id and window_id
    grep -qF '$sess1:@win3' "$stub_log" || false
}

# ---------------------------------------------------------------------------
# Case 5: No queue file → exit 0 (no tmux calls)
# ---------------------------------------------------------------------------
@test "jump: no queue file exits 0 and makes no tmux calls" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Ensure queue file does NOT exist
    rm -f "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    # No tmux calls should have been made (stub log either absent or empty)
    [ ! -f "$stub_log" ] || [ ! -s "$stub_log" ]
}
