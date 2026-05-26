#!/usr/bin/env bats
# e2e-agent-lifecycle.bats — integration tests chaining notify-tmux.sh,
# show-notification.sh, and jump-to-notification.sh through a complete
# agent-notification lifecycle.  Only external binaries (tmux/jq/osascript/
# afplay/fzf) are stubbed via PATH; internal script logic is NOT mocked.

load test_helper

# ---------------------------------------------------------------------------
# Helper: write a dashboard-aware tmux stub into the per-test stubs dir.
# $1 = pane-title line to emit for list-panes (tab-separated: sid TAB wid TAB title).
#      Leave empty to produce a stub that emits nothing for list-panes (no dashboard).
# The stub also returns a dummy display-message value required by show-notification.sh.
# Uses printf '%q' to safely embed any tab-containing string into the generated script.
# ---------------------------------------------------------------------------
_write_tmux_stub() {
    local pane_line="${1:-}"
    # Produce a safely shell-quoted literal for embedding inside the generated script.
    # When pane_line is empty the quoted form is '' which is harmless.
    local quoted_pane
    quoted_pane=$(printf '%q' "$pane_line")
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<STUBEOF
#!/usr/bin/env bash
echo "tmux \$*" >> "\${STUB_LOG:-/dev/null}"
case "\$1" in
    list-panes)
        [ -n $quoted_pane ] && printf '%s\n' $quoted_pane
        ;;
    display-message)
        # show-notification.sh needs: session_id|||window_id|||session_name|||window_name
        echo "\$sess_dummy|||\${wdummy}|||dummy-session|||dummy-window"
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

# ---------------------------------------------------------------------------
# Flow 1: Full happy-path lifecycle
#   a. Notification arrives → queue written, terminalSequence emitted
#   b. show-notification.sh renders the marker+label
#   c. jump-to-notification.sh finds dashboard → switch-client + select-window
#   d. UserPromptSubmit clears queue
#   e. show-notification.sh sees empty queue → exits 0 / renders nothing
# ---------------------------------------------------------------------------

@test "e2e lifecycle a: Notification writes queue entry and emits valid JSON with terminalSequence" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local SID="s-e2e-001"
    local MSG="needs your permission"
    local JSON="{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"$SID\",\"message\":\"$MSG\"}"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]

    # Queue must contain the agent entry (falsifiable: correct session id present)
    grep -qF "|||agent:$SID" "$QUEUE_FILE" || false

    # Queue line must include the marker and message
    grep -qF "⚡ $MSG|||agent:$SID" "$QUEUE_FILE" || false

    # osascript stub must have been called (desktop ping)
    grep -qF "osascript" "$stub_log" || false

    # stdout must be valid JSON containing terminalSequence
    [[ "$output" == *'"terminalSequence"'* ]] || false
    printf '%s' "$output" | "$REAL_JQ" . > /dev/null
    [ "$?" -eq 0 ]
}

@test "e2e lifecycle b: show-notification renders marker+label (suffix stripped)" {
    local SID="s-e2e-001"
    local MSG="needs your permission"
    # Pre-populate queue as notify-tmux.sh would have written it
    printf '⚡ %s|||agent:%s\n' "$MSG" "$SID" > "$QUEUE_FILE"

    # show-notification.sh calls tmux display-message; stub must return a value that
    # does NOT match the queue line's id (so no auto-dismiss fires).
    _write_tmux_stub ""

    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/show-notification.sh'
    "
    [ "$status" -eq 0 ]

    # Rendered output must contain the marker and message (falsifiable: would fail
    # if show-notification emits the raw |||agent: suffix or nothing at all)
    [[ "$output" == *"⚡ $MSG"* ]] || false

    # The |||agent: suffix must NOT appear in the rendered output
    [[ "$output" != *"|||agent:"* ]] || false
}

@test "e2e lifecycle c: jump-to-notification finds dashboard and routes switch-client + select-window" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local SID="s-e2e-001"
    local MSG="needs your permission"
    printf '⚡ %s|||agent:%s\n' "$MSG" "$SID" > "$QUEUE_FILE"

    # Stub emits a dashboard pane line for list-panes
    local SESS_ID="\$sess1"
    local WIN_ID="@win2"
    _write_tmux_stub "${SESS_ID}	${WIN_ID}	claude agents"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]

    # Dashboard found path: switch-client AND select-window must be called
    grep -qF "switch-client" "$stub_log" || false
    grep -qF "select-window" "$stub_log" || false

    # Generic ||| branch must NOT have fired (it would call select-window -t agent:...)
    run grep -F "select-window -t agent:" "$stub_log"
    [ "$status" -ne 0 ]
}

@test "e2e lifecycle d: UserPromptSubmit clears the single queue entry" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local SID="s-e2e-001"
    local MSG="needs your permission"
    printf '⚡ %s|||agent:%s\n' "$MSG" "$SID" > "$QUEUE_FILE"

    local JSON="{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\"}"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]

    # Entry must be gone (falsifiable: grep must fail)
    ! grep -qF "|||agent:$SID" "$QUEUE_FILE" 2>/dev/null

    # Queue was the only entry so the file must now be empty or absent
    [ ! -s "$QUEUE_FILE" ]
}

@test "e2e lifecycle e: show-notification on empty queue exits 0 and renders nothing" {
    # Queue file does not exist (cleared by previous lifecycle step)
    rm -f "$QUEUE_FILE"

    _write_tmux_stub ""

    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/show-notification.sh'
    "
    [ "$status" -eq 0 ]

    # Nothing rendered (falsifiable: would fail if show-notification outputs any marker)
    [[ -z "$output" ]] || false
}

# ---------------------------------------------------------------------------
# Flow 2: Dedup-then-clear lifecycle
#   Two Notifications with same session_id → exactly one queue line.
#   Stop clears it → queue empty.
# ---------------------------------------------------------------------------

@test "e2e dedup-then-clear: two Notifications same session_id yield exactly one line, Stop clears" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local SID="s-e2e-dup"
    local MSG="waiting for you"
    local JSON="{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"$SID\",\"message\":\"$MSG\"}"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]

    # Exactly one entry for this session_id (falsifiable: would be 0 or 2 if dedup broke)
    local count
    count=$(grep -cF "|||agent:$SID" "$QUEUE_FILE" 2>/dev/null || echo 0)
    [ "$count" -eq 1 ]

    # Now send Stop to clear it
    local STOP_JSON="{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\"}"
    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$STOP_JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]

    # Queue must now be empty (falsifiable)
    ! grep -qF "|||agent:$SID" "$QUEUE_FILE" 2>/dev/null
    [ ! -s "$QUEUE_FILE" ]
}

# ---------------------------------------------------------------------------
# Flow 3: Two distinct sessions, selective clear
#   Notification(S1) + Notification(S2) → two lines.
#   UserPromptSubmit(S1) → only S1 removed, S2 remains.
# ---------------------------------------------------------------------------

@test "e2e selective-clear: UserPromptSubmit(S1) removes S1 but leaves S2 intact" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local S1="s-e2e-sel1"
    local S2="s-e2e-sel2"
    local JSON1="{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"$S1\",\"message\":\"session 1 needs input\"}"
    local JSON2="{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"$S2\",\"message\":\"session 2 needs input\"}"

    # Enqueue both sessions
    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON1' | TMUX= '$NOTIFY_HOOK'
        printf '%s' '$JSON2' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]

    # Both entries must be present before clear
    grep -qF "|||agent:$S1" "$QUEUE_FILE" || false
    grep -qF "|||agent:$S2" "$QUEUE_FILE" || false

    # Clear only S1 via UserPromptSubmit
    local UPS_JSON="{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$S1\"}"
    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$UPS_JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]

    # S1 must be gone (falsifiable: grep must fail)
    ! grep -qF "|||agent:$S1" "$QUEUE_FILE" 2>/dev/null

    # S2 must still be present (falsifiable: grep must succeed)
    grep -qF "|||agent:$S2" "$QUEUE_FILE" || false
}

# ---------------------------------------------------------------------------
# Flow 4: No-dashboard jump fallback
#   Queue holds an agent: entry; tmux list-panes emits nothing (no dashboard).
#   jump-to-notification.sh must call new-window -n agents.
# ---------------------------------------------------------------------------

@test "e2e no-dashboard fallback: jump opens new-window when list-panes is empty" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local SID="s-e2e-nd"
    printf '⚡ waiting|||agent:%s\n' "$SID" > "$QUEUE_FILE"

    # Stub emits nothing for list-panes (no dashboard pane)
    _write_tmux_stub ""

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]

    # new-window must be called (fallback path — falsifiable: would be absent if
    # dashboard was found and switch-client/select-window were used instead)
    grep -qF "new-window" "$stub_log" || false
    grep -qF "agents" "$stub_log" || false

    # switch-client must NOT have been called (that belongs to the dashboard-found path)
    run grep -F "switch-client" "$stub_log"
    [ "$status" -ne 0 ]
}
