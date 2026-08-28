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
# Case 6: UserPromptSubmit does NOT remove entry (clear-on-jump-only)
# ---------------------------------------------------------------------------
@test "agent path: UserPromptSubmit does NOT clear queue entry" {
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
    # Entry must REMAIN (clear-on-jump-only; UserPromptSubmit is a no-op)
    grep -qF "|||agent:s-abc-123" "$QUEUE_FILE" || false
}

# ---------------------------------------------------------------------------
# Case 7: Stop does NOT remove entry (clear-on-jump-only)
# ---------------------------------------------------------------------------
@test "agent path: Stop does NOT clear queue entry" {
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
    # Entry must REMAIN (clear-on-jump-only; Stop is a no-op)
    grep -qF "|||agent:s-stop-456" "$QUEUE_FILE" || false
}

# ---------------------------------------------------------------------------
# Case 8: SessionEnd does NOT remove entry (clear-on-jump-only)
# ---------------------------------------------------------------------------
@test "agent path: SessionEnd does NOT clear queue entry" {
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
    # Entry must REMAIN (clear-on-jump-only; SessionEnd is a no-op)
    grep -qF "|||agent:s-end-789" "$QUEUE_FILE" || false
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

# ===========================================================================
# 3.8.0 — more hook events reach the queue (Stop, StopFailure, TeammateIdle,
# and the Notification sub-types the agents dashboard emits). Every new
# entry is gated on the SAME @claude-notify-<type>-visual option the
# interactive path reads, so one answer in /clux:setup governs both paths.
# ===========================================================================

# A tmux stub that answers show-option for the per-type visual options from
# the NOTIFY_VISUAL env var ("stop=on failure=off ..."); everything else
# comes back empty, exactly like the committed stub.
_write_visual_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
    *"show-option -gqv @claude-notify-"*-visual)
        # Copy $* first: ${*##pat} strips each positional parameter on its
        # own, so applied directly it would leave "show-option -gqv stop".
        _all="$*"; _opt="${_all##*@claude-notify-}"; _type="${_opt%-visual}"
        for pair in ${NOTIFY_VISUAL:-}; do
            [ "${pair%%=*}" = "$_type" ] && printf '%s\n' "${pair#*=}"
        done
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "agent path: Stop with @claude-notify-stop-visual on writes a finished entry" {
    _write_visual_tmux_stub
    local JSON='{"hook_event_name":"Stop","session_id":"s-fin-001","cwd":"/fake/proj"}'
    run bash -c "
        export NOTIFY_VISUAL='stop=on'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF "|||agent:s-fin-001" "$QUEUE_FILE" || false
    # A finished entry carries the ✓ marker, never the needs-you ⚡.
    grep -qF "✓ agents / proj|||agent:s-fin-001" "$QUEUE_FILE" || false
    [[ "$output" == *'"terminalSequence"'* ]] || false
}

@test "agent path: Stop with the option unset (default off) writes nothing — 3.7.0 behaviour kept" {
    _write_visual_tmux_stub
    local JSON='{"hook_event_name":"Stop","session_id":"s-fin-002","cwd":"/fake/proj"}'
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    ! grep -qF "|||agent:s-fin-002" "$QUEUE_FILE" 2>/dev/null
    [ -z "$output" ]
}

@test "agent path: Stop replaces an older needs-you entry for the same session — one line" {
    _write_visual_tmux_stub
    printf '⚡ agents / proj|||agent:s-fin-003@@@@/fake/proj\n' > "$QUEUE_FILE"
    local JSON='{"hook_event_name":"Stop","session_id":"s-fin-003","cwd":"/fake/proj"}'
    run bash -c "
        export NOTIFY_VISUAL='stop=on'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    [ "$(grep -cF '|||agent:s-fin-003' "$QUEUE_FILE")" -eq 1 ]
    grep -qF "✓ agents / proj" "$QUEUE_FILE" || false
    ! grep -qF "⚡" "$QUEUE_FILE"
}

@test "agent path: StopFailure writes an entry naming the error type (failure defaults to on)" {
    local JSON='{"hook_event_name":"StopFailure","session_id":"s-fail-001","cwd":"/fake/proj","error_type":"rate_limit","error_message":"429"}'
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF "|||agent:s-fail-001" "$QUEUE_FILE" || false
    grep -qF "rate_limit" "$QUEUE_FILE" || false
    [[ "$output" == *'"terminalSequence"'* ]] || false
}

@test "agent path: StopFailure with @claude-notify-failure-visual off writes nothing" {
    _write_visual_tmux_stub
    local JSON='{"hook_event_name":"StopFailure","session_id":"s-fail-002","cwd":"/fake/proj","error_type":"overloaded"}'
    run bash -c "
        export NOTIFY_VISUAL='failure=off'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    ! grep -qF "|||agent:s-fail-002" "$QUEUE_FILE" 2>/dev/null
}

@test "agent path: TeammateIdle is off by default and on when asked" {
    _write_visual_tmux_stub
    local JSON='{"hook_event_name":"TeammateIdle","session_id":"s-team-001","cwd":"/fake/proj","teammate_name":"reviewer"}'
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    ! grep -qF "|||agent:s-team-001" "$QUEUE_FILE" 2>/dev/null
    run bash -c "
        export NOTIFY_VISUAL='teammate=on'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF "|||agent:s-team-001" "$QUEUE_FILE" || false
    grep -qF "reviewer" "$QUEUE_FILE" || false
}

@test "agent path: Notification agent_needs_input and elicitation_dialog are eligible (needs-you)" {
    local t
    for t in agent_needs_input elicitation_dialog elicitation_url_dialog; do
        local JSON="{\"hook_event_name\":\"Notification\",\"notification_type\":\"$t\",\"session_id\":\"s-$t\",\"message\":\"m\"}"
        run bash -c "
            export CLUX_NOTIFY_FILE='$QUEUE_FILE'
            export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
            printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
        "
        [ "$status" -eq 0 ]
        grep -qF "|||agent:s-$t" "$QUEUE_FILE" || { echo "$t not queued"; false; }
    done
}

@test "agent path: Notification agent_completed follows the stop preference" {
    _write_visual_tmux_stub
    local JSON='{"hook_event_name":"Notification","notification_type":"agent_completed","session_id":"s-done-001","cwd":"/fake/proj","message":"agent finished"}'
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    ! grep -qF "|||agent:s-done-001" "$QUEUE_FILE" 2>/dev/null
    run bash -c "
        export NOTIFY_VISUAL='stop=on'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF "|||agent:s-done-001" "$QUEUE_FILE" || false
}

@test "agent path: Notification quota_auto_resume_disabled is queued under the quota type (default on)" {
    local JSON='{"hook_event_name":"Notification","notification_type":"quota_auto_resume_disabled","session_id":"s-quota-001","cwd":"/fake/proj"}'
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF "|||agent:s-quota-001" "$QUEUE_FILE" || false
    grep -qiF "quota" "$QUEUE_FILE" || false
}

@test "agent path: Notification auth_success plays no sound and queues nothing" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local JSON='{"hook_event_name":"Notification","notification_type":"auth_success","session_id":"s-auth-001","message":"auth done"}'
    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    ! grep -qF "|||agent:s-auth-001" "$QUEUE_FILE" 2>/dev/null
    # 3.7.0 played the notification sound on every Notification before the
    # eligibility check; an ineligible type must now be silent.
    ! grep -qE "afplay|paplay|pw-play|aplay|ffplay" "$stub_log" 2>/dev/null
}

@test "interactive path: StopFailure with TMUX set writes a window entry naming the error" {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "\${STUB_LOG:-/dev/null}"
case "\$*" in
  *@clux_muted*) echo "" ;;
  *display-message*) echo "main|||editor|||\$1|||@win1" ;;
  *@claude-notify-file*) echo "$QUEUE_FILE" ;;
esac
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    local JSON='{"hook_event_name":"StopFailure","session_id":"s-int-fail","error_type":"billing_error"}'
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export TMUX='/dev/null,1234,0'
        export TMUX_PANE='%1'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF "main:editor" "$QUEUE_FILE" || false
    grep -qF "billing_error" "$QUEUE_FILE" || false
}
