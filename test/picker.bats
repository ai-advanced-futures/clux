#!/usr/bin/env bats
# picker.bats — notification-picker.sh ENTER agent: routing tests (Task 8)

load test_helper

# ---------------------------------------------------------------------------
# Case 1: ENTER on agent: line → agent_jump (dashboard found)
# ---------------------------------------------------------------------------
@test "picker: ENTER on agent line calls agent_jump when dashboard found" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Custom tmux stub: emit dashboard window for list-windows
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-windows" ]; then
    printf '$sess1 @win2\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    printf '⚡ needs input|||agent:s-abc-123\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FZF_STUB_KEY=''
        export FZF_STUB_LINE='⚡ needs input|||agent:s-abc-123'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF "switch-client" "$stub_log" || false
}

# ---------------------------------------------------------------------------
# Case 2: ENTER on agent: line → new-window fallback (no dashboard)
# ---------------------------------------------------------------------------
@test "picker: ENTER on agent line opens new-window when no dashboard" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Default tmux stub emits nothing for list-panes

    printf '⚡ needs input|||agent:s-abc-123\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FZF_STUB_KEY=''
        export FZF_STUB_LINE='⚡ needs input|||agent:s-abc-123'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF "new-window" "$stub_log" || false
    grep -qF "agents" "$stub_log" || false
}

# ---------------------------------------------------------------------------
# Case 3: ENTER on interactive line → SESSION:WINDOW parse unchanged
# Falsifiable: assert "select-window -t" was called with the parsed session:window
# and that agent_jump (new-window/switch-client from list-panes) was NOT invoked.
# ---------------------------------------------------------------------------
@test "picker: ENTER on interactive line uses session:window parse" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    printf 'main:editor Task done|||$sess1:@win3\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FZF_STUB_KEY=''
        export FZF_STUB_LINE='main:editor Task done|||\$sess1:@win3'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    # The select-window call must have used main:editor (the session:window parse)
    grep -qF "select-window -t main:editor" "$stub_log" || false
    # agent_jump's new-window must NOT have been called (no mis-routing)
    run grep -qF "new-window" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Case 4: Ctrl-D on agent: line → line removed from queue
# ---------------------------------------------------------------------------
@test "picker: Ctrl-D on agent line dismisses (removes) it from queue" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local agent_line='⚡ needs input|||agent:s-abc-123'
    printf '%s\n' "$agent_line" > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FZF_STUB_KEY='ctrl-d'
        export FZF_STUB_LINE='⚡ needs input|||agent:s-abc-123'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    # Agent line must be absent from queue (falsifiable)
    run grep -qF "|||agent:s-abc-123" "$QUEUE_FILE"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Case 5: Ctrl-D on interactive line → line removed from queue
# ---------------------------------------------------------------------------
@test "picker: Ctrl-D on interactive line removes it from queue" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local interactive_line='main:editor Task done|||$sess1:@win3'
    printf '%s\n' "$interactive_line" > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FZF_STUB_KEY='ctrl-d'
        export FZF_STUB_LINE='main:editor Task done|||\$sess1:@win3'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    # Interactive line must be absent from queue (falsifiable)
    run grep -qF '$sess1:@win3' "$QUEUE_FILE"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Case 6: fzf exit 130 (Esc) → exit 0, queue unchanged
# ---------------------------------------------------------------------------
@test "picker: fzf exit 130 (Esc) exits 0 and leaves queue unchanged" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    printf '⚡ needs input|||agent:s-abc-123\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FZF_STUB_EXIT='130'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    # Queue must be unchanged
    grep -qF "|||agent:s-abc-123" "$QUEUE_FILE" || false
    # No tmux calls made
    run grep -qF "switch-client" "$stub_log"
    [ "$status" -ne 0 ]
}
