#!/usr/bin/env bats
# notify-tmux.bats — hook agent branch tests (Task 4)

load test_helper

# ---------------------------------------------------------------------------
# Case 1: session_id extracted (jq path) — permission_prompt
# ---------------------------------------------------------------------------
@test "agent path: Notification permission_prompt writes queue entry and calls osascript" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    export STUB_LOG="$stub_log"
    local JSON='{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s-abc-123","message":"needs your permission"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF "osascript" "$stub_log" || false
    grep -qF "|||agent:s-abc-123" "$QUEUE_FILE" || false
}

# ---------------------------------------------------------------------------
# Case 2: notification_type idle_prompt is eligible
# ---------------------------------------------------------------------------
@test "agent path: Notification idle_prompt writes queue entry" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    export STUB_LOG="$stub_log"
    local JSON='{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"s-idle-456","message":"waiting for you"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF "|||agent:s-idle-456" "$QUEUE_FILE" || false
}

# ---------------------------------------------------------------------------
# Case 3: notification_type auth_success is skipped (jq path)
# ---------------------------------------------------------------------------
@test "agent path: Notification auth_success is skipped (queue not written)" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"Notification","notification_type":"auth_success","session_id":"s-skip-789","message":"auth done"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    # Queue must NOT be written (falsifiable: file does not exist or does not contain the id)
    ! grep -qF "|||agent:s-skip-789" "$QUEUE_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Case 4: Notification with no-jq fallback (grep path) writes queue entry
# ---------------------------------------------------------------------------
@test "agent path: Notification with no jq falls back to grep and writes queue entry" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"Notification","session_id":"s-nojq-111","message":"fallback test"}'

    # Remove the jq stub to simulate jq absent
    rm -f "$BATS_TEST_TMPDIR/stubs/jq"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF "|||agent:s-nojq-111" "$QUEUE_FILE" || false
}

# ---------------------------------------------------------------------------
# Case 5: Two Notifications same session_id → exactly one queue line
# ---------------------------------------------------------------------------
@test "agent path: duplicate Notification same session_id yields exactly one queue line" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s-abc-123","message":"needs input"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    local count
    count=$(grep -cF "|||agent:s-abc-123" "$QUEUE_FILE" 2>/dev/null || echo 0)
    [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Case 6: UserPromptSubmit removes entry
# ---------------------------------------------------------------------------
@test "agent path: UserPromptSubmit removes queue entry" {
    # Prime the queue
    printf '⚡ needs you|||agent:s-abc-123\n' > "$QUEUE_FILE"

    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"UserPromptSubmit","session_id":"s-abc-123"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    # Entry must be gone (falsifiable)
    ! grep -qF "|||agent:s-abc-123" "$QUEUE_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Case 7: Stop removes entry
# ---------------------------------------------------------------------------
@test "agent path: Stop removes queue entry" {
    printf '⚡ needs you|||agent:s-stop-456\n' > "$QUEUE_FILE"

    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"Stop","session_id":"s-stop-456"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    ! grep -qF "|||agent:s-stop-456" "$QUEUE_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Case 8: SessionEnd removes entry
# ---------------------------------------------------------------------------
@test "agent path: SessionEnd removes queue entry" {
    printf '⚡ needs you|||agent:s-end-789\n' > "$QUEUE_FILE"

    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"SessionEnd","session_id":"s-end-789"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    ! grep -qF "|||agent:s-end-789" "$QUEUE_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Case 9: Remove for unqueued id is no-op (no crash)
# ---------------------------------------------------------------------------
@test "agent path: remove for unknown session_id exits 0 and leaves queue unchanged" {
    printf '⚡ other|||agent:s-other-999\n' > "$QUEUE_FILE"
    local before
    before=$(cat "$QUEUE_FILE")

    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"UserPromptSubmit","session_id":"s-unknown-000"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    local after
    after=$(cat "$QUEUE_FILE")
    [[ "$after" == "$before" ]] || false
}

# ---------------------------------------------------------------------------
# Case 10: Remove with empty session_id is skipped
# ---------------------------------------------------------------------------
@test "agent path: remove event with no session_id is a no-op" {
    printf '⚡ something|||agent:s-abc-123\n' > "$QUEUE_FILE"
    local before
    before=$(cat "$QUEUE_FILE")

    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"UserPromptSubmit"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    local after
    after=$(cat "$QUEUE_FILE")
    [[ "$after" == "$before" ]] || false
}

# ---------------------------------------------------------------------------
# Case 11: stdout is valid JSON with terminalSequence key
# ---------------------------------------------------------------------------
@test "agent path: Notification stdout is valid JSON with terminalSequence key" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s-ts-001","message":"needs input"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *'"terminalSequence"'* ]] || false
    # Must parse as valid JSON
    printf '%s' "$output" | "$REAL_JQ" . > /dev/null
    [ "$?" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Case 12: No stray stdout on remove events (Stop / UserPromptSubmit)
# ---------------------------------------------------------------------------
@test "agent path: Stop event emits nothing on stdout" {
    printf '⚡ needs you|||agent:s-nostdout-111\n' > "$QUEUE_FILE"

    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"Stop","session_id":"s-nostdout-111"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    [[ -z "$output" ]] || false
}

# ---------------------------------------------------------------------------
# Case 13: Sanitization — control chars stripped from label in terminalSequence
# ---------------------------------------------------------------------------
@test "agent path: control chars stripped from message in terminalSequence" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Embed ESC (0x1b) in the message
    local ESC=$'\x1b'
    local JSON="{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"s-san-222\",\"message\":\"${ESC}[31m evil\"}"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *'"terminalSequence"'* ]] || false
    # The raw ESC byte must NOT appear in the terminalSequence JSON value
    # (it can appear as the unicode escape  but not as a literal 0x1b)
    # Check: the output string does NOT contain literal ESC byte embedded in the JSON value
    [[ "$output" != *$'\x1b[31m'* ]] || false
}

# ---------------------------------------------------------------------------
# Case 14: No lost lines under concurrent writes (cross-path same-lock)
# ---------------------------------------------------------------------------
@test "agent path: concurrent writes contend on same lock and all land in queue" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local J1='{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s-con-001","message":"concurrent 1"}'
    local J2='{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s-con-002","message":"concurrent 2"}'
    local J3='{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s-con-003","message":"concurrent 3"}'

    # Custom tmux stub: return $QUEUE_FILE for @claude-notify-file, provide display-message
    # for the interactive path, and return empty for everything else. All paths must use the
    # SAME lock dir (${QUEUE_FILE}.lock) — the agent path recomputes it after resolve_notify_file,
    # the interactive path gets it from helpers.sh source-time LOCKDIR="${NOTIFY_FILE}.lock".
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "\${STUB_LOG:-/dev/null}"
case "\$*" in
  *@claude-notify-file*) echo "$QUEUE_FILE" ;;
  *display-message*) echo "main|||editor|||s-int-dummy|||@win1" ;;
  *@claude-notify-notification-visual*) echo "on" ;;
  *@clux_muted*) echo "" ;;
esac
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$J1' | TMUX= '$NOTIFY_HOOK' &
        printf '%s' '$J2' | TMUX= '$NOTIFY_HOOK' &
        printf '%s' '$J3' | TMUX=dummy '$NOTIFY_HOOK' &
        wait
    "
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$QUEUE_FILE")" -eq 3 ]
    [ ! -d "${QUEUE_FILE}.lock" ]
}

# ---------------------------------------------------------------------------
# Case 15: LOCKDIR recomputed after resolve_notify_file
# ---------------------------------------------------------------------------
@test "agent path: LOCKDIR recomputed and no orphaned lock dir after write" {
    local agent_queue="$BATS_TEST_TMPDIR/agent_queue"
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s-lock-333","message":"lock test"}'

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$agent_queue'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    # Queue file must be the agent_queue path (not some HOME default)
    grep -qF "|||agent:s-lock-333" "$agent_queue" || false
    # No orphaned .lock directory must remain
    [ ! -d "${agent_queue}.lock" ]
}

# ---------------------------------------------------------------------------
# Case 16: Interactive path unchanged — SessionEnd with TMUX set does not write queue
# ---------------------------------------------------------------------------
@test "interactive path: SessionEnd with TMUX set does not write queue and afplay not called" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"SessionEnd","session_id":"s-int-444"}'

    # Custom tmux stub: return values for what interactive path needs
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "\${STUB_LOG:-/dev/null}"
case "\$*" in
  *@clux_muted*) echo "" ;;
  *display-message*) echo "main|||editor|||s-int-444|||@win1" ;;
  *@claude-notify-file*) echo "$QUEUE_FILE" ;;
  *"@claude-notify-notification-visual"*) echo "off" ;;
esac
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export TMUX='/dev/null,1234,0'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    # Queue file must NOT be written with a sessionend entry
    ! grep -qF "|||agent:s-int-444" "$QUEUE_FILE" 2>/dev/null
    # afplay must NOT have been called (sessionend sound defaults to off)
    ! grep -qF "afplay" "$stub_log" 2>/dev/null
}
