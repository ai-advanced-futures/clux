#!/usr/bin/env bats
# helpers.bats — unit tests for helpers.sh additions (Task 3)

load test_helper

# ---------------------------------------------------------------------------
# Case 1: map_event_to_type SessionEnd
# ---------------------------------------------------------------------------
@test "map_event_to_type SessionEnd returns sessionend" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        map_event_to_type SessionEnd
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "sessionend" ]] || false
}

# ---------------------------------------------------------------------------
# Case 1b: _get_notification_default_sound for sessionend returns off
# ---------------------------------------------------------------------------
@test "map_event_to_type SessionEnd -> _get_notification_default_sound returns off" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        type_val=\$(map_event_to_type SessionEnd)
        _get_notification_default_sound \"\$type_val\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "off" ]] || false
}

# ---------------------------------------------------------------------------
# Case 2: recompute_lock_target
# ---------------------------------------------------------------------------
@test "recompute_lock_target sets LOCKDIR from NOTIFY_FILE" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        NOTIFY_FILE=/tmp/foo/bar
        recompute_lock_target
        echo \"\$LOCKDIR\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "/tmp/foo/bar.lock" ]] || false
}

# ---------------------------------------------------------------------------
# Case 3: _agent_remove_entry removes matching line, leaves other intact
# ---------------------------------------------------------------------------
@test "_agent_remove_entry removes matching line and leaves other intact" {
    local qfile="$BATS_TEST_TMPDIR/queue"
    printf '⚡ task done|||agent:abc-123\n⚡ other task|||agent:xyz-999\n' > "$qfile"

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        NOTIFY_FILE='$qfile'
        recompute_lock_target
        _agent_remove_entry 'abc-123'
    "
    [ "$status" -eq 0 ]
    # abc-123 line is gone (falsifiable: must NOT match)
    ! grep -qF "|||agent:abc-123" "$qfile"
    # xyz-999 line is still there
    grep -qF "|||agent:xyz-999" "$qfile" || false
}

# ---------------------------------------------------------------------------
# Case 4: _agent_remove_entry end-anchored — no partial match
# ---------------------------------------------------------------------------
@test "_agent_remove_entry does not remove line with longer id (end-anchored)" {
    local qfile="$BATS_TEST_TMPDIR/queue"
    printf '⚡ task done|||agent:abc-123\n⚡ longer|||agent:abc-123-extra\n' > "$qfile"

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        NOTIFY_FILE='$qfile'
        recompute_lock_target
        _agent_remove_entry 'abc-123'
    "
    [ "$status" -eq 0 ]
    # The end-anchored abc-123 line is gone (falsifiable: no line ending in agent:abc-123)
    ! grep -qE '\|\|\|agent:abc-123$' "$qfile"
    # abc-123-extra is preserved (it must NOT have been removed by a prefix match)
    grep -qF "|||agent:abc-123-extra" "$qfile" || false
}

# ---------------------------------------------------------------------------
# Case 5: _agent_remove_entry empty id is skipped
# ---------------------------------------------------------------------------
@test "_agent_remove_entry with empty id is no-op" {
    local qfile="$BATS_TEST_TMPDIR/queue"
    printf '⚡ task done|||agent:abc-123\n' > "$qfile"

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        NOTIFY_FILE='$qfile'
        recompute_lock_target
        _agent_remove_entry ''
    "
    [ "$status" -eq 0 ]
    # Queue file must be unchanged
    grep -qF "|||agent:abc-123" "$qfile" || false
}

# ---------------------------------------------------------------------------
# Case 6: _agent_remove_entry dedup — removes both duplicate lines, queue empties.
# REGRESSION GUARD: against the old `grep -v ... && mv` form, grep -v exits 1 when
# every line matches, so mv was skipped and the file kept its stale duplicates —
# this test would FAIL on that buggy code.
# ---------------------------------------------------------------------------
@test "_agent_remove_entry removes both duplicate lines and empties the queue" {
    local qfile="$BATS_TEST_TMPDIR/queue"
    printf '⚡ task done|||agent:abc-123\n⚡ task done|||agent:abc-123\n' > "$qfile"

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        NOTIFY_FILE='$qfile'
        recompute_lock_target
        _agent_remove_entry 'abc-123'
    "
    [ "$status" -eq 0 ]
    # Both lines are gone (falsifiable)
    ! grep -qF "|||agent:abc-123" "$qfile"
    # Queue file is now empty (zero bytes) — the core bug-exposing assertion
    [ ! -s "$qfile" ]
}

# ---------------------------------------------------------------------------
# Case 6b: _agent_remove_entry on a single-entry queue empties the file.
# REGRESSION GUARD: the single-line-all-match case that the old `&& mv` silently
# no-op'd. After removal the file must exist and be empty.
# ---------------------------------------------------------------------------
@test "_agent_remove_entry on single matching entry empties the queue" {
    local qfile="$BATS_TEST_TMPDIR/queue"
    printf '⚡ only entry|||agent:abc-123\n' > "$qfile"

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        NOTIFY_FILE='$qfile'
        recompute_lock_target
        _agent_remove_entry 'abc-123'
    "
    [ "$status" -eq 0 ]
    ! grep -qF "|||agent:abc-123" "$qfile"
    [ ! -s "$qfile" ]
}

# ---------------------------------------------------------------------------
# Case 7: get_agent_visual_enabled default
# ---------------------------------------------------------------------------
@test "get_agent_visual_enabled default is on" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_visual_enabled
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "on" ]] || false
}

# ---------------------------------------------------------------------------
# Case 8: get_agent_osc_code default
# ---------------------------------------------------------------------------
@test "get_agent_osc_code default is 9" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_osc_code
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "9" ]] || false
}

# ---------------------------------------------------------------------------
# Case 9: agent_jump — dashboard found
# ---------------------------------------------------------------------------
@test "agent_jump with dashboard found calls switch-client and select-window" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Write a custom tmux stub that emits the dashboard pane for list-panes
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
# Emit dashboard line for list-panes
if [ "$1" = "list-panes" ]; then
    printf '\$sess1\t@win2\tclaude agents\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        agent_jump
    "
    [ "$status" -eq 0 ]
    grep -qF "switch-client" "$stub_log" || false
    grep -qF "select-window" "$stub_log" || false
}

# ---------------------------------------------------------------------------
# Case 10: agent_jump — no dashboard found
# ---------------------------------------------------------------------------
@test "agent_jump with no dashboard calls new-window with agents" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Default tmux stub returns empty for list-panes (already does nothing)
    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        agent_jump
    "
    [ "$status" -eq 0 ]
    grep -qF "new-window" "$stub_log" || false
    grep -qF "agents" "$stub_log" || false
}
