#!/usr/bin/env bats
# agent-state.bats — writer (hooks/agent-state.sh), readers (agent-query.sh,
# agent-bar.sh) and the clear writer (agent-clear.sh) for the clux agent-state
# feature.
#
# GOVERNING PRINCIPLE under test: STATE LIVES IN FILES. HOOKS WRITE THOSE
# FILES. THE BAR ONLY READS. The reader never writes and never deletes, not
# even a stale file. Several tests below are written to be falsifiable against
# exactly that principle (case 17, case 20).

load test_helper

AGENT_HOOK="$HOOKS_DIR/agent-state.sh"
AGENT_QUERY="$SCRIPTS_DIR/agent-query.sh"
AGENT_BAR="$SCRIPTS_DIR/agent-bar.sh"
AGENT_CLEAR="$SCRIPTS_DIR/agent-clear.sh"

# ---------------------------------------------------------------------------
# _write_agent_tmux_stub — canned tmux answering list-panes (full join row,
# bare pane-id row, and windowed row), display-message, and show-option, from
# env vars the calling test exports before `run bash -c`.
#
# TRAP: the '|' in the list-panes join format is a case-pattern alternation
# separator in an UNQUOTED case pattern, so every pattern below is written
# fully double-quoted (quoting suppresses '|' as an operator).
#
# Quoted heredoc ('STUBEOF') so $* / $STUB_LOG / $FAKE_* are NOT expanded
# while this function writes the stub — they must survive to be evaluated by
# the stub script itself, at run time, against its own environment. Precedent:
# _write_tmux_stub in e2e-agent-lifecycle.bats.
# ---------------------------------------------------------------------------
_write_agent_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
    "list-panes -a -F #{pane_id}|#{session_name}|#{pane_current_command}")
        [ -n "${FAKE_PANES_FULL:-}" ] && printf '%s\n' "$FAKE_PANES_FULL"
        ;;
    "list-panes -a -F #{pane_id}")
        [ -n "${FAKE_PANE_IDS:-}" ] && printf '%s\n' "$FAKE_PANE_IDS"
        ;;
    "list-panes -t "*)
        [ -n "${FAKE_WINDOW_PANES:-}" ] && printf '%s\n' "$FAKE_WINDOW_PANES"
        ;;
    "display-message "*)
        [ -n "${FAKE_WINDOW_ID:-}" ] && printf '%s\n' "$FAKE_WINDOW_ID"
        ;;
    "show-option "*)
        _all="$*"
        _opt="${_all##* }"
        printf '%s\n' "${FAKE_OPTS:-}" | sed -n "s|^${_opt}=||p"
        ;;
    *) ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

# ===========================================================================
# WRITER — hooks/agent-state.sh
# ===========================================================================

@test "writer: busy writes 'busy' to <state-dir>/<pane-id>" {
    local dir="$BATS_TEST_TMPDIR/agents"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ "$(cat "$dir/%1")" = "busy" ]
}

@test "writer: Notification permission_prompt writes needs-you" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local JSON='{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s1"}'
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX=dummy TMUX_PANE=%2 '$AGENT_HOOK' needs-you
    "
    [ "$status" -eq 0 ]
    [ "$(cat "$dir/%2")" = "needs-you" ]
}

@test "writer: Notification idle_prompt writes needs-you" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local JSON='{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"s1"}'
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX=dummy TMUX_PANE=%2 '$AGENT_HOOK' needs-you
    "
    [ "$status" -eq 0 ]
    [ "$(cat "$dir/%2")" = "needs-you" ]
}

@test "writer: Notification auth_success is a no-op (existing state untouched)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'busy\n' > "$dir/%3"
    local JSON='{"hook_event_name":"Notification","notification_type":"auth_success","session_id":"s1"}'
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX=dummy TMUX_PANE=%3 '$AGENT_HOOK' needs-you
    "
    [ "$status" -eq 0 ]
    # Falsifiable: must still read 'busy', not 'needs-you' and not deleted.
    [ "$(cat "$dir/%3")" = "busy" ]
}

@test "writer: Notification with no notification_type field writes needs-you (grep-fallback parity)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local JSON='{"hook_event_name":"Notification","session_id":"s1"}'
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX=dummy TMUX_PANE=%4 '$AGENT_HOOK' needs-you
    "
    [ "$status" -eq 0 ]
    [ "$(cat "$dir/%4")" = "needs-you" ]
}

@test "writer: finished overwrites busy in place — exactly one file, atomic (no .tmp leftover)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%5 '$AGENT_HOOK' busy
        printf '' | TMUX=dummy TMUX_PANE=%5 '$AGENT_HOOK' finished
    "
    [ "$status" -eq 0 ]
    [ "$(cat "$dir/%5")" = "finished" ]
    # Atomicity proxy: no orphaned temp file, exactly one entry in the dir.
    [ "$(find "$dir" -maxdepth 1 -type f | wc -l)" -eq 1 ]
    run bash -c "find '$dir' -maxdepth 1 -name '.tmp.*'"
    [ -z "$output" ]
}

@test "writer: remove deletes the pane file; 'end' behaves identically" {
    local dir="$BATS_TEST_TMPDIR/agents"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%6 '$AGENT_HOOK' busy
        printf '' | TMUX=dummy TMUX_PANE=%6 '$AGENT_HOOK' remove
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/%6" ]

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%7 '$AGENT_HOOK' busy
        printf '' | TMUX=dummy TMUX_PANE=%7 '$AGENT_HOOK' end
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/%7" ]
}

@test "writer: unknown argument is a silent no-op and exits 0" {
    local dir="$BATS_TEST_TMPDIR/agents"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%8 '$AGENT_HOOK' bogus
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # No word is recognised for an unknown arg, so no pane file is ever written.
    [ ! -f "$dir/%8" ]
}

@test "writer: TMUX unset — exits 0, silent, writes nothing, no state dir created" {
    local dir="$BATS_TEST_TMPDIR/agents"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX= TMUX_PANE=%9 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "$dir" ]
}

@test "writer: TMUX_PANE unset — exits 0, silent, writes nothing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE= '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "$dir" ]
}

@test "writer: every invocation is silent on stdout" {
    local dir="$BATS_TEST_TMPDIR/agents"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%10 '$AGENT_HOOK' finished
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "writer: reaps state files for dead panes" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'busy\n' > "$dir/%1"
    printf 'busy\n' > "$dir/%2"
    printf 'finished\n' > "$dir/%99"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS=\$'%1\n%2'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/%1" ]
    [ -f "$dir/%2" ]
    [ ! -f "$dir/%99" ]
}

@test "writer: does NOT reap when tmux list-panes returns empty (wipe-everything guard)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'finished\n' > "$dir/%99"
    _write_agent_tmux_stub
    # FAKE_PANE_IDS deliberately unset — stub answers empty for list-panes -a.
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/%99" ]
}

@test "writer: default refresh command is run after a write" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    grep -qF "tmux refresh-client -S" "$log" || false
}

@test "writer: multi-word @clux-agent-refresh-command is run unquoted" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_OPTS='@clux-agent-refresh-command=refresh-client -C 80x24'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    grep -qF "tmux refresh-client -C 80x24" "$log" || false
}

# ===========================================================================
# READER — agent-query.sh
# ===========================================================================

@test "reader: rollup precedence needs-you > busy > finished, idle unlisted" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'needs-you\n' > "$dir/%1"
    printf 'busy\n' > "$dir/%2"
    printf 'finished\n' > "$dir/%3"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL=\$'%1|alpha|claude\n%2|beta|claude\n%3|gamma|claude'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'alpha\tneeds-you\nbeta\tbusy\ngamma\tfinished')" ]
}

@test "reader: drops a state file whose pane is gone from the listing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'busy\n' > "$dir/%5"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%6|other|claude'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # Ignored, not deleted.
    [ -f "$dir/%5" ]
}

@test "reader: drops a pane whose pane_current_command is not claude" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'finished\n' > "$dir/%7"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%7|gamma|vim'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$dir/%7" ]
}

@test "reader: missing state directory prints nothing, exits 0, and creates no directory" {
    local dir="$BATS_TEST_TMPDIR/agents_absent"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "$dir" ]
}

@test "reader: never creates or deletes anything (falsifiable byte-identical snapshot)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'busy\n' > "$dir/%1"          # live, claude — will be printed
    printf 'finished\n' > "$dir/%99"     # stale (pane gone) — must survive, untouched
    printf 'needs-you\n' > "$dir/%8"     # live pane but not claude — must survive
    _write_agent_tmux_stub

    local before after
    before="$(find "$dir" -maxdepth 1 -type f | LC_ALL=C sort)$(cat "$dir"/*)"

    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL=\$'%1|alpha|claude\n%8|alpha|vim'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]

    after="$(find "$dir" -maxdepth 1 -type f | LC_ALL=C sort)$(cat "$dir"/*)"
    [ "$before" = "$after" ]
    [ -f "$dir/%99" ]
    [ -f "$dir/%8" ]
}

# ===========================================================================
# RENDERER — agent-bar.sh
# ===========================================================================

@test "renderer: one-argument mode prints exactly the coloured glyph for a needs-you session" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'needs-you\n' > "$dir/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%1|alpha|claude'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_BAR' alpha
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=yellow]!#[default]' ]
}

@test "renderer: one-argument mode prints a single space for an idle/unknown session" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        out=\$('$AGENT_BAR' idle-session)
        printf '[%s]' \"\${#out}\"
    "
    [ "$status" -eq 0 ]
    [ "$output" = "[1]" ]
}

@test "renderer: glyph/color options are honoured" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'needs-you\n' > "$dir/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%1|alpha|claude'
        export FAKE_OPTS=\$'@clux-agent-glyph-needs=N\n@clux-agent-needs-color=red'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_BAR' alpha
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=red]N#[default]' ]
}

@test "renderer: no-argument rollup is empty when every session is idle" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_BAR'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ===========================================================================
# CLEAR — agent-clear.sh (a writer, driven by tmux hooks)
# ===========================================================================

@test "clear: removes only 'finished' files for panes in the given window; busy and out-of-window files survive" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'finished\n' > "$dir/%1"   # in-window, finished -> must be removed
    printf 'busy\n' > "$dir/%2"       # in-window, busy -> must survive
    printf 'finished\n' > "$dir/%3"   # NOT in window -> must survive
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_WINDOW_PANES=\$'%1\n%2'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' '@1'
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/%1" ]
    [ -f "$dir/%2" ]
    [ -f "$dir/%3" ]
}

@test "clear: refreshes the bar after it removes a mark, honouring the refresh option" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$dir"
    printf 'finished\n' > "$dir/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export STUB_LOG='$log'
        export FAKE_WINDOW_PANES='%1'
        export FAKE_OPTS='@clux-agent-refresh-command=run-shell -b /rebuild-bar'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' '@1'
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/%1" ]
    grep -qF "tmux run-shell -b /rebuild-bar" "$log" || false
}

@test "clear: does NOT refresh when it removed nothing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$dir"
    printf 'busy\n' > "$dir/%1"   # not 'finished' -> nothing to clear
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export STUB_LOG='$log'
        export FAKE_WINDOW_PANES='%1'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' '@1'
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/%1" ]
    # A window switch that changes nothing must cost no rebuild of the bar.
    run grep -cF "refresh-client" "$log"
    [ "$output" = "0" ]
}

@test "clear: empty argument falls back to display-message and still clears" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'finished\n' > "$dir/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export FAKE_WINDOW_ID='@1'
        export FAKE_WINDOW_PANES='%1'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' ''
    "
    [ "$status" -eq 0 ]
    grep -qF "display-message" "$BATS_TEST_TMPDIR/stub.log" || false
    [ ! -f "$dir/%1" ]
}

@test "clear: unresolvable window exits 0 and deletes nothing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'finished\n' > "$dir/%1"
    _write_agent_tmux_stub
    # FAKE_WINDOW_ID deliberately unset — display-message answers empty.
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' ''
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/%1" ]
}

@test "clear --reap: deletes only dead-pane files server-wide" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'busy\n' > "$dir/%1"
    printf 'busy\n' > "$dir/%2"
    printf 'finished\n' > "$dir/%99"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS=\$'%1\n%2'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' --reap
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/%1" ]
    [ -f "$dir/%2" ]
    [ ! -f "$dir/%99" ]
}

@test "clear --reap: an empty pane listing deletes nothing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'finished\n' > "$dir/%99"
    _write_agent_tmux_stub
    # FAKE_PANE_IDS deliberately unset.
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' --reap
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/%99" ]
}
