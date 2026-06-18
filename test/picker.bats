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
# Case 3b: ENTER on NEW-format agent line → fast-path routes to embedded pane
# AND clears the entry on jump. REGRESSION GUARD (P6 parse in the picker):
# the old picker took the full tail after '|||agent:' as _sid, called agent_jump
# with NO args (ignoring the embedded coords) and fed _agent_remove_entry a
# garbage value ('abc-123@@$s9:@w9:%pane3@@/c'), whose literal '$s9' expanded as
# an unset shell var inside the remove regex → the entry was NEVER cleared.
# This test FAILS on that buggy picker (no send-keys -t %pane3; entry survives).
# ---------------------------------------------------------------------------
@test "picker: ENTER on new-format agent line fast-paths to embedded pane and clears it" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Fast-path existence probe must confirm %pane3 still exists (pane id per
    # line); resolver enumeration (has pane_current_path) emits nothing to force
    # the fast-path.
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    case "$*" in
        *pane_current_path*) : ;;
        *) printf '%%pane3\n' ;;
    esac
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    printf '⚡ agents / x|||agent:abc-123@@$s9:@w9:%%pane3@@/c\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FZF_STUB_KEY=''
        export FZF_STUB_LINE='⚡ agents / x|||agent:abc-123@@\$s9:@w9:%pane3@@/c'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    # Routed via the embedded pane id (seg2 last colon token), not the SID.
    grep -qF "send-keys -t %pane3" "$stub_log" || false
    run grep -F "send-keys -t abc-123" "$stub_log"
    [ "$status" -ne 0 ]
    # Clear-on-jump actually removed the entry (the core regression assertion).
    run grep -qF "|||agent:abc-123@@" "$QUEUE_FILE"
    [ "$status" -ne 0 ]
    [ ! -s "$QUEUE_FILE" ]
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
