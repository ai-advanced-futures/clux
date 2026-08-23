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
# Case 9: agent_jump — dashboard found (window convention)
# ---------------------------------------------------------------------------
@test "agent_jump with dashboard found calls switch-client and select-window" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Write a custom tmux stub that emits the dashboard window for list-windows.
    # agent_jump uses -F '#{session_id} #{window_id}' → space-separated "<sid> <wid>".
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
# Emit dashboard line for list-windows
if [ "$1" = "list-windows" ]; then
    printf '$sess1 @win2\n'
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
# Case 9b: agent_jump — dashboard found sends the nav-key (default "Left")
# ---------------------------------------------------------------------------
@test "agent_jump with dashboard found sends nav-key Left to the matched window" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-windows" ]; then
    printf '$sess1 @win2\n'
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
    # send-keys with the default nav-key "Left" must have been issued to the window
    grep -qF "send-keys" "$stub_log" || false
    grep -qF "Left" "$stub_log" || false
}

# ---------------------------------------------------------------------------
# Case 9c: agent_jump — empty @clux-agent-nav-key skips send-keys
# ---------------------------------------------------------------------------
@test "agent_jump does NOT send-keys when nav-key option is empty" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # show-option for @clux-agent-nav-key returns empty → nav_key empty → no send-keys.
    # Other show-option calls (e.g. @clux-agent-window) return empty too, so
    # get_agent_window falls back to its default "agents".
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-windows" ]; then
    printf '$sess1 @win2\n'
fi
# show-option -gqv returns empty for every option (including @clux-agent-nav-key)
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        # Force nav-key empty regardless of helper defaults
        get_agent_nav_key() { printf ''; }
        # agent_jump's last statement is the short-circuited '[ -n nav_key ] && send-keys';
        # with an empty nav_key that returns 1, so don't gate the test on its exit code.
        agent_jump || true
    "
    [ "$status" -eq 0 ]
    # Dashboard was found (switch-client fired) but no send-keys was issued
    grep -qF "switch-client" "$stub_log" || false
    run grep -qF "send-keys" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Case 9d: agent_jump — dashboard detected by pane (NOT by window name)
# Regression: on hosts where the `claude agents` window is NOT named "agents"
# (e.g. automatic-rename off, or launched in a project-named window), detection
# must still find the dashboard via the pane running `claude agents`.
# ---------------------------------------------------------------------------
@test "agent_jump detects dashboard via list-panes when no window is named agents" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # list-windows emits NOTHING (no window named "agents").
    # list-panes emits the dashboard pane: "<sid> <wid> <pid>".
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '$sess9 @win9 %%pane9\n'
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
    # Dashboard found via pane → switch + select + nav-key to the matched pane.
    grep -qF "switch-client" "$stub_log" || false
    grep -qF "select-window" "$stub_log" || false
    grep -qF "send-keys" "$stub_log" || false
    grep -qF "%pane9" "$stub_log" || false
    # Must NOT fall through to opening a brand-new dashboard window.
    run grep -qF "new-window" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Case 10: agent_jump — no dashboard found
# ---------------------------------------------------------------------------
@test "agent_jump with no dashboard calls new-window with agents" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Default tmux stub returns empty for list-windows (already does nothing)
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

# ---------------------------------------------------------------------------
# Case 10b: agent_jump — no dashboard branch does NOT send-keys
# ---------------------------------------------------------------------------
@test "agent_jump no-dashboard branch does NOT call send-keys" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Default tmux stub emits nothing for list-windows → new-window fallback
    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        agent_jump
    "
    [ "$status" -eq 0 ]
    grep -qF "new-window" "$stub_log" || false
    # send-keys belongs only to the dashboard-found path — must be absent here
    run grep -qF "send-keys" "$stub_log"
    [ "$status" -ne 0 ]
}

# ===========================================================================
# REMOVE-REGEX WIDENING (R1-R3) — _agent_remove_entry must clear new @@ format.
# ===========================================================================

# ---------------------------------------------------------------------------
# R1: new-format removal — drop the abc-123 @@ line, leave an unrelated @@ line.
# FAILS on the end-anchored grep (the @@ suffix means it never matches).
# ---------------------------------------------------------------------------
@test "_agent_remove_entry removes new @@-format line, leaves unrelated @@ line" {
    local qfile="$BATS_TEST_TMPDIR/queue"
    printf '⚡ agents / x|||agent:abc-123@@$s:@w:%%p@@/c\n⚡ agents / y|||agent:xyz-999@@$s:@w:%%p@@/d\n' > "$qfile"

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        NOTIFY_FILE='$qfile'
        recompute_lock_target
        _agent_remove_entry 'abc-123'
    "
    [ "$status" -eq 0 ]
    run grep -qF "|||agent:abc-123@@" "$qfile"
    [ "$status" -ne 0 ]
    grep -qF "|||agent:xyz-999@@" "$qfile" || false
}

# ---------------------------------------------------------------------------
# R2: mixed legacy + new for the same SID — removing abc-123 clears BOTH.
# FAILS on the end-anchored grep (the new @@ line survives).
# ---------------------------------------------------------------------------
@test "_agent_remove_entry clears both legacy and new @@ lines for same SID" {
    local qfile="$BATS_TEST_TMPDIR/queue"
    printf '⚡ legacy|||agent:abc-123\n⚡ new|||agent:abc-123@@$s:@w:%%p@@/c\n' > "$qfile"

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        NOTIFY_FILE='$qfile'
        recompute_lock_target
        _agent_remove_entry 'abc-123'
    "
    [ "$status" -eq 0 ]
    run grep -qF "|||agent:abc-123" "$qfile"
    [ "$status" -ne 0 ]
    [ ! -s "$qfile" ]
}

# ---------------------------------------------------------------------------
# R3: no over-match on a longer id — abc-123 must NOT clear abc-123-extra.
# Guards the ([@]{2}|$) boundary against prefix over-match in the widened regex.
# ---------------------------------------------------------------------------
@test "_agent_remove_entry widened regex does not over-match longer @@ id" {
    local qfile="$BATS_TEST_TMPDIR/queue"
    printf '⚡ a|||agent:abc-123@@$s:@w:%%p@@/c\n⚡ b|||agent:abc-123-extra@@$s:@w:%%p@@/d\n' > "$qfile"

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        NOTIFY_FILE='$qfile'
        recompute_lock_target
        _agent_remove_entry 'abc-123'
    "
    [ "$status" -eq 0 ]
    run grep -qF "|||agent:abc-123@@" "$qfile"
    [ "$status" -ne 0 ]
    grep -qF "|||agent:abc-123-extra@@" "$qfile" || false
}

# ===========================================================================
# SHARED RESOLVER (RS1-RS4) — resolve_agents_pane_by_cwd(cwd) -> "SID WID PID".
# The tmux stub emits TAB-delimited list-panes rows in the resolver's -F order:
#   session_id \t window_id \t pane_id \t pane_current_path \t pane_current_command \t window_name
# ===========================================================================

# ---------------------------------------------------------------------------
# RS1: longest-prefix wins. Two agents panes (/home/jazz/dev and
# /home/jazz/dev/proj); resolving a cwd under .../proj/sub picks .../proj.
# FAILS now — the helper does not exist (command-not-found).
# ---------------------------------------------------------------------------
# Resolver enumeration stub format (v5, process-based):
#   tmux list-panes -F → "pane_pid\tsession_id\twindow_id\tpane_id\tpane_current_path"
#   ps  -eo pid=,ppid=,args= → "<pid> <ppid> <args...>"
# A dashboard is a process whose own binary basename is `claude` carrying the
# `agents` subcommand; it maps to its tmux pane via the ppid chain (pid->pane_pid).

@test "resolve_agents_pane_by_cwd picks the longest-prefix dashboard" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '1001\t$s1\t@w1\t%%p1\t/home/jazz/dev\n'
    printf '1002\t$s2\t@w2\t%%p2\t/home/jazz/dev/proj\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    # Leading pad mimics real `ps` right-justified pid column (exercises ltrim).
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '  2001 1001 claude agents --cwd /home/jazz/dev\n'
printf '  2002 1002 claude agents --cwd /home/jazz/dev/proj\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        resolve_agents_pane_by_cwd /home/jazz/dev/proj/sub
    "
    [ "$status" -eq 0 ]
    [[ "$output" == '$s2 @w2 %p2' ]] || false
}

# ---------------------------------------------------------------------------
# RS2: a split window (bash pane + claude pane) — the dashboard process's
# parent is the CLAUDE pane's shell, so we land on the claude pane.
# ---------------------------------------------------------------------------
@test "resolve_agents_pane_by_cwd lands on the claude pane in a split window" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '1001\t$s1\t@w1\t%%pbash\t/home/jazz/dev/proj\n'
    printf '1002\t$s1\t@w1\t%%pclaude\t/home/jazz/dev/proj\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '2001 1002 claude agents --cwd /home/jazz/dev/proj\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        resolve_agents_pane_by_cwd /home/jazz/dev/proj
    "
    [ "$status" -eq 0 ]
    [[ "$output" == '$s1 @w1 %pclaude' ]] || false
}

# ---------------------------------------------------------------------------
# RS3: panes + dashboard exist but the cwd is outside every dashboard root →
# resolver echoes empty.
# ---------------------------------------------------------------------------
@test "resolve_agents_pane_by_cwd echoes empty when no dashboard root matches" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '1001\t$s1\t@w1\t%%p1\t/home/jazz/dev/other\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '2001 1001 claude agents --cwd /home/jazz/dev/other\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        resolve_agents_pane_by_cwd /home/jazz/dev/proj
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# RS4 (REAL-BUG REGRESSION): the dashboard lives in a PROJECT-named window
# (not "agents"); tmux reports pane_current_command "claude" (never the args).
# Only the process table reveals it. A worktree cwd nested under the dashboard
# root must still resolve to that pane. FAILS against window-name/command
# filtering — the exact failure observed live.
# ---------------------------------------------------------------------------
@test "resolve_agents_pane_by_cwd detects a dashboard in a project-named window" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '1001\t$s1\t@marina\t%%p1\t/home/jazz/dev/marina\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '2001 1001 claude --allow-dangerously-skip-permissions agents --cwd /home/jazz/dev/marina\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        resolve_agents_pane_by_cwd /home/jazz/dev/marina/.claude/worktrees/gus-double-send
    "
    [ "$status" -eq 0 ]
    [[ "$output" == '$s1 @marina %p1' ]] || false
}

# ---------------------------------------------------------------------------
# RS5: ppid multi-hop — a wrapper process sits between the pane shell and the
# claude dashboard; the chain walk must climb through it to the pane.
# ---------------------------------------------------------------------------
@test "resolve_agents_pane_by_cwd walks a multi-hop ppid chain to the pane" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '1001\t$s1\t@w1\t%%p1\t/home/jazz/dev/proj\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '3001 2001 claude agents --cwd /home/jazz/dev/proj\n'
printf '2001 1001 script -qfc claude\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        resolve_agents_pane_by_cwd /home/jazz/dev/proj/x
    "
    [ "$status" -eq 0 ]
    [[ "$output" == '$s1 @w1 %p1' ]] || false
}

# ---------------------------------------------------------------------------
# RS6: dashboard launched WITHOUT --cwd → root falls back to the owning pane's
# current path.
# ---------------------------------------------------------------------------
@test "resolve_agents_pane_by_cwd falls back to pane path when --cwd is absent" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '1001\t$s1\t@w1\t%%p1\t/home/jazz/dev/proj\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '2001 1001 claude agents\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        resolve_agents_pane_by_cwd /home/jazz/dev/proj/x
    "
    [ "$status" -eq 0 ]
    [[ "$output" == '$s1 @w1 %p1' ]] || false
}

# ---------------------------------------------------------------------------
# RS7 (basename guard): a non-claude process carrying "agents" in its argv
# (e.g. `script -qfc claude agents …`) must NOT be treated as a dashboard.
# ---------------------------------------------------------------------------
@test "resolve_agents_pane_by_cwd ignores non-claude processes that mention agents" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '1001\t$s1\t@w1\t%%p1\t/home/jazz/dev/proj\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '2001 1001 script -qfc claude agents --cwd /home/jazz/dev/proj\n'
printf '2002 1001 node /usr/lib/agents-server.js --cwd /home/jazz/dev/proj\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        resolve_agents_pane_by_cwd /home/jazz/dev/proj
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ===========================================================================
# AGENT_JUMP ROUTING (J1-J6) — fast-path / re-resolve / fallback / no-arg.
# These tests drive agent_jump through the jump parser to exercise the full
# parse + route path. The tmux stub distinguishes the resolver enumeration
# (-F contains pane_current_path → TAB rows) from the fast-path existence
# probe (-F is '#{pane_id} #{window_name}' → space rows).
# ===========================================================================

# ---------------------------------------------------------------------------
# J1 (P6 GUARD, falsifiable): the pane id is seg2's LAST colon token, NOT seg1.
# Drive jump with agent:abc-123@@$s:@w:%pane3@@/c. The value sent to
# `send-keys -t` must be %pane3 — and abc-123 must NEVER reach send-keys -t.
# FAILS against a naive rest%%@@* parse (which yields seg1=abc-123).
# ---------------------------------------------------------------------------
@test "jump: P6 guard — send-keys targets seg2 last colon token, never the SID" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Fast-path probe must confirm %pane3 exists in an agents-tagged window.
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    case "$*" in
        *pane_current_path*)
            : ;;  # resolver enumeration — emit nothing (force fast-path use)
        *)
            # fast-path existence probe: one pane id per line
            printf '%%pane3\n' ;;
    esac
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    printf '⚡ agents / x|||agent:abc-123@@$s:@w:%%pane3@@/c\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    # send-keys -t targets the embedded pane id (seg2 last colon token).
    grep -qF "send-keys -t %pane3" "$stub_log" || false
    # The SID must never be a send-keys target.
    run grep -F "send-keys -t abc-123" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# J2 fast-path hit: embedded pane exists and is agents-tagged → switch +
# select + send-keys to the embedded pane; NO new-window.
# ---------------------------------------------------------------------------
@test "jump: fast-path hit routes to embedded pane, no new-window" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
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
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF "switch-client" "$stub_log" || false
    grep -qF "select-window" "$stub_log" || false
    grep -qF "send-keys -t %pane3" "$stub_log" || false
    run grep -qF "new-window" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# J3 fast-path miss → re-resolve: probe returns nothing for the embedded pane,
# but seg3 cwd is present and the resolver yields a pane → route to it.
# NO new-window.
# ---------------------------------------------------------------------------
@test "jump: fast-path miss re-resolves by cwd, routes to resolved pane" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    case "$*" in
        *pane_current_path*)
            # resolver enumeration — a live dashboard pane at the cwd
            printf '1001\t$s2\t@w2\t%%pfresh\t/home/jazz/dev/proj\n' ;;
        *)
            : ;;  # fast-path probe: embedded pane is GONE (emit nothing)
    esac
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '2001 1001 claude agents --cwd /home/jazz/dev/proj\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    printf '⚡ agents / x|||agent:abc-123@@$sOld:@wOld:%%pdead@@/home/jazz/dev/proj/sub\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF "send-keys -t %pfresh" "$stub_log" || false
    # The dead embedded pane must NOT be a send-keys target.
    run grep -F "send-keys -t %pdead" "$stub_log"
    [ "$status" -ne 0 ]
    run grep -qF "new-window" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# J4 empty seg2 → re-resolve: agent:abc-123@@@@/c parses seg2 empty, seg3=/c;
# fast-path is skipped, resolver runs, routes to the resolved pane.
# ---------------------------------------------------------------------------
@test "jump: empty seg2 skips fast-path and re-resolves by cwd" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    case "$*" in
        *pane_current_path*)
            printf '1001\t$s2\t@w2\t%%presolved\t/home/jazz/dev/proj\n' ;;
        *) : ;;
    esac
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '2001 1001 claude agents --cwd /home/jazz/dev/proj\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    printf '⚡ agents / x|||agent:abc-123@@@@/home/jazz/dev/proj\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF "send-keys -t %presolved" "$stub_log" || false
    run grep -qF "new-window" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# J5 legacy entry → v3 fallback: agent:abc-123 (no @@), no dashboard →
# agent_jump "" "" → new-window; remove_key abc-123 still clears the line.
# ---------------------------------------------------------------------------
@test "jump: legacy entry (no @@) falls back to v3 new-window and clears" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Default tmux stub: no list-panes output anywhere → v3 fallback new-window.
    printf '⚡ legacy|||agent:abc-123\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF "new-window" "$stub_log" || false
    # The legacy line was cleared via the widened remove-regex.
    run grep -qF "|||agent:abc-123" "$QUEUE_FILE"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# J6 backward-compat no-arg: agent_jump with NO args reproduces Case 9/10.
# window match → switch+select+send-keys; no match → new-window.
# ---------------------------------------------------------------------------
@test "agent_jump no-arg reproduces v3 behavior (window match + no-match)" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # Window-name match path (list-windows emits the dashboard window).
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-windows" ]; then
    printf '$sess1 @win2 %%pane2\n'
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

    # No-match path → new-window (fresh default stub emits nothing).
    local stub_log2="$BATS_TEST_TMPDIR/stub2.log"
    run bash -c "
        export STUB_LOG='$stub_log2'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        # default committed stub emits nothing for list-windows/list-panes
        cat > '$BATS_TEST_TMPDIR/stubs/tmux' <<'EOS'
#!/usr/bin/env bash
echo \"tmux \$*\" >> \"\${STUB_LOG:-/dev/null}\"
exit 0
EOS
        chmod +x '$BATS_TEST_TMPDIR/stubs/tmux'
        agent_jump
    "
    [ "$status" -eq 0 ]
    grep -qF "new-window" "$stub_log2" || false
}

# ---------------------------------------------------------------------------
# RS5: path canonicalization. A dashboard whose --cwd carries a trailing "/." or
# "/" names the same directory as the bare path, so the prefix match must still
# fire. Before canonicalization these compared as plain strings and missed,
# dropping the caller into the server-wide fallback guess.
# ---------------------------------------------------------------------------
@test "resolve_agents_pane_by_cwd matches despite trailing slash or /. in --cwd" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '1001\t$s1\t@w1\t%%p1\t/home/jazz/dev/proj\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    # Every spelling of the same directory must resolve to the same pane.
    for suffix in '/.' '/' ''; do
        cat > "$BATS_TEST_TMPDIR/stubs/ps" <<STUBEOF
#!/usr/bin/env bash
echo "ps \$*" >> "\${STUB_LOG:-/dev/null}"
printf '2001 1001 claude agents --cwd /home/jazz/dev/proj${suffix}\n'
STUBEOF
        chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

        run bash -c "
            export STUB_LOG='$stub_log'
            export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
            source '$SCRIPTS_DIR/helpers.sh'
            resolve_agents_pane_by_cwd /home/jazz/dev/proj/sub
        "
        [ "$status" -eq 0 ] || { echo "nonzero status for --cwd suffix [$suffix]"; false; }
        [[ "$output" == '$s1 @w1 %p1' ]] || { echo "wrong pane for --cwd suffix [$suffix]: $output"; false; }
    done
}

# ---------------------------------------------------------------------------
# RS6: the ps snapshot must select ALL processes and must not be width-clipped.
# -e means "show the environment" on BSD/macOS (only -A selects every process),
# and BSD ps clips args to 80 columns when stdout is not a tty — which lands
# mid-path on a real `claude agents --cwd …` line.
# ---------------------------------------------------------------------------
@test "resolve_agents_pane_by_cwd invokes ps with -A and -ww" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    printf '1001\t$s1\t@w1\t%%p1\t/home/jazz/dev/proj\n'
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        resolve_agents_pane_by_cwd /home/jazz/dev/proj
    "
    [ "$status" -eq 0 ]
    grep '^ps ' "$stub_log" | grep -qE ' -A( |$)' || false
    grep '^ps ' "$stub_log" | grep -qE ' -ww( |$)' || false
    # -e would mean "display the environment" on macOS; it must be gone.
    run bash -c "grep '^ps ' '$stub_log' | grep -qE ' -e( |\$)'"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# J7: a cwd was supplied but no dashboard owns it. clux must NOT fall through to
# the server-wide `head -1` guess — with several dashboards open that lands on an
# arbitrary project and is indistinguishable from a correct jump. Expect a
# reported no-op instead: display-message, and no switch-client/new-window.
# ---------------------------------------------------------------------------
@test "agent_jump with a known cwd and no owning dashboard reports instead of guessing" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # list-panes WITHOUT -f  -> resolver enumeration (dashboard rooted elsewhere)
    # list-panes WITH    -f  -> fallback guess; emits a decoy we must NOT jump to
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    case "$*" in
        *-f*) printf '$sDECOY @wDECOY %%pDECOY\n' ;;
        *)    printf '1001\t$s1\t@w1\t%%p1\t/home/jazz/dev/other\n' ;;
    esac
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
printf '2001 1001 claude agents --cwd /home/jazz/dev/other\n'
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        agent_jump '' /home/jazz/dev/proj
    "
    [ "$status" -eq 0 ]
    grep -qF "display-message" "$stub_log" || false
    run grep -qF "switch-client" "$stub_log"
    [ "$status" -ne 0 ]
    run grep -qF "new-window" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# J8: the no-arg path is unchanged by J7's gate — with no cwd to go on, guessing
# is the only option and must still happen.
# ---------------------------------------------------------------------------
@test "agent_jump with no cwd still uses the fallback guess" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    case "$*" in
        *-f*) printf '$sX @wX %%pX\n' ;;
    esac
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
}

# ---------------------------------------------------------------------------
# Animated busy glyph (2026-08-23 design): CLUX_AGENT_GLYPH_BUSY overrides
# get_agent_glyph_busy() so session-bar-refresh.sh (and anything else that
# ever needs to) can drive agent-bar.sh-style renderers to draw the sentinel
# without writing the user-owned @clux-agent-glyph-busy option.
# ---------------------------------------------------------------------------

@test "get_agent_glyph_busy: CLUX_AGENT_GLYPH_BUSY overrides the tmux option" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_AGENT_GLYPH_BUSY=Z
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_glyph_busy
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "Z" ]] || false
}

@test "get_agent_glyph_busy: unset CLUX_AGENT_GLYPH_BUSY falls back to the tmux option default" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        unset CLUX_AGENT_GLYPH_BUSY
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_glyph_busy
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "*" ]] || false
}

@test "get_agent_glyph_busy: an empty CLUX_AGENT_GLYPH_BUSY is not an override" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_AGENT_GLYPH_BUSY=''
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_glyph_busy
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "*" ]] || false
}

@test "get_agent_glyph_busy: CLUX_AGENT_GLYPH_BUSY does not leak into needs/done getters" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_AGENT_GLYPH_BUSY=Z
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_glyph_needs
        get_agent_glyph_done
    "
    [ "$status" -eq 0 ]
    [[ "$output" == $'!\nv' ]] || false
}

# ---------------------------------------------------------------------------
# get_agent_glyph_busy_frames() / get_agent_frame(): the frame list used ONLY
# by agent-bar.sh, deliberately not routed through get_tmux_option — its body
# is `echo "${value:-$default}"`, and this option's default contains a
# backslash that a hostile echo (xpg_echo) would eat.
# ---------------------------------------------------------------------------

@test "get_agent_glyph_busy_frames: default is four ASCII frames, backslash intact" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_glyph_busy_frames
    "
    [ "$status" -eq 0 ]
    [[ "$output" == '- \ | /' ]] || false
}

@test "get_agent_glyph_busy_frames: survives xpg_echo (the backslash is not eaten)" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        shopt -s xpg_echo 2>/dev/null || true
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_glyph_busy_frames
    "
    [ "$status" -eq 0 ]
    [[ "$output" == '- \ | /' ]] || false
}

@test "get_agent_frame: parses the default frame list by index, modulo wrap" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_frame 0; echo
        get_agent_frame 1; echo
        get_agent_frame 2; echo
        get_agent_frame 3; echo
        get_agent_frame 4
    "
    [ "$status" -eq 0 ]
    [[ "$output" == $'-\n\\\n|\n/\n-' ]] || false
}

@test "get_agent_frame: single-glyph fallback when -frames is unset but -busy is set" {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
    *@clux-agent-glyph-busy-frames*) printf '\n' ;;
    *@clux-agent-glyph-busy*) printf '@\n' ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_frame 2
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "@" ]] || false
}

@test "get_agent_frame: an all-whitespace frame list falls back to the busy glyph, never empty" {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
    *@clux-agent-glyph-busy-frames*) printf '   \n' ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_frame 0
    "
    [ "$status" -eq 0 ]
    [[ -n "$output" ]] || false
    [[ "$output" == "*" ]] || false
}

@test "get_agent_frame: a frame containing # is doubled before it is printed" {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
    *@clux-agent-glyph-busy-frames*) printf '%s\n' 'a#b c' ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_frame 0
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "a##b" ]] || false
}

@test "get_agent_frame: a non-numeric index falls back to frame 0, never errors" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_frame notanumber
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "-" ]] || false
}

@test "get_agent_frame: a missing index falls back to frame 0" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_agent_frame
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "-" ]] || false
}

# ---------------------------------------------------------------------------
# clux_ansi — tmux style string to ANSI escape, for the prefix + A popup.
# A popup runs a real shell, so it cannot use a tmux `#[...]` format; these
# translate the SAME style options the bar draws with.
# ---------------------------------------------------------------------------

# `run` strips nothing, but an ESC in $output is awkward to compare against, so
# every case below asks for the escape with the ESC replaced by "E".
_ansi() {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        clux_ansi '$1' | tr '\033' 'E'
    "
    [ "$status" -eq 0 ]
}

@test "clux_ansi: a full bar style becomes bg, fg and bold in one sequence" {
    _ansi 'bg=#B48EAD,fg=#2E3440,bold'
    [ "$output" = 'E[48;2;180;142;173;38;2;46;52;64;1m' ] \
        || { echo "got: $output"; false; }
}

@test "clux_ansi: named and bright named colours map to the 30/90 ranges" {
    _ansi 'fg=magenta'
    [ "$output" = 'E[35m' ] || { echo "magenta: $output"; false; }
    _ansi 'fg=brightblack'
    [ "$output" = 'E[90m' ] || { echo "brightblack: $output"; false; }
    _ansi 'bg=brightwhite'
    [ "$output" = 'E[107m' ] || { echo "bg brightwhite: $output"; false; }
}

@test "clux_ansi: colourN and a bare number both use the 256-colour form" {
    _ansi 'fg=colour208'
    [ "$output" = 'E[38;5;208m' ] || { echo "colour208: $output"; false; }
    _ansi 'fg=208'
    [ "$output" = 'E[38;5;208m' ] || { echo "bare 208: $output"; false; }
}

@test "clux_ansi: an empty style prints nothing at all" {
    _ansi ''
    [ -z "$output" ] || { echo "expected no output, got: $output"; false; }
}

@test "clux_ansi: an unknown term is skipped, never emitted literally" {
    # The failure this guards against is a broken screen: a style clux cannot
    # translate must not reach the popup as a stray escape fragment.
    _ansi 'fg=chartreuse,bold'
    [ "$output" = 'E[1m' ] || { echo "got: $output"; false; }
    _ansi 'fg=chartreuse'
    [ -z "$output" ] || { echo "expected no output, got: $output"; false; }
}

@test "clux_ansi: the popup style accessors fall back to the bar's own defaults" {
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source '$SCRIPTS_DIR/helpers.sh'
        get_bar_name_attached_style; get_bar_bracket_style; get_bar_separator_style
    "
    [ "$status" -eq 0 ]
    # Same literals session-list.sh states for its hot path.
    [[ "$output" == *"bg=magenta,fg=black,bold"* ]] || { echo "$output"; false; }
    [[ "$output" == *"fg=magenta"* ]]               || { echo "$output"; false; }
    [[ "$output" == *"fg=brightblack"* ]]           || { echo "$output"; false; }
}
