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
    "show-options -g")
        [ -n "${FAKE_GLOBAL_OPTS:-}" ] && printf '%s\n' "$FAKE_GLOBAL_OPTS"
        ;;
    "show-option -gqv status-format"*)
        # Trailing '*' on purpose, never the literal 'status-format[0]' — '[0]'
        # in a case pattern is a glob character class matching the single
        # character '0', so a literal-looking pattern would silently never
        # match. Same trap the generic branch below already has with its sed.
        [ -n "${FAKE_STATUS_FORMAT0:-}" ] && printf '%s\n' "$FAKE_STATUS_FORMAT0"
        ;;
    "show-option -gv status-right")
        [ -n "${FAKE_STATUS_RIGHT:-}" ] && printf '%s\n' "$FAKE_STATUS_RIGHT"
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

# ===========================================================================
# SELF-INSTALL — clux_ensure_installed() / _clux_install_bar_segment()
# (scripts/path.sh), wired in from hooks/agent-state.sh and
# scripts/agent-clear.sh. CLUX_VERSION is hard-coded as 3.2.0 below —
# test/path.bats separately enforces it equals plugin.json.
# ===========================================================================

@test "self-install: registers both indexed hooks and records @clux-installed when the marker is absent" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='status-right \"L R\"'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    grep -qF "set-hook -g after-select-window[90]" "$log" || false
    grep -qF "set-hook -g client-session-changed[90]" "$log" || false
    # SELF_DIR resolves to the running copy (proves it, not a deployed path)
    # and is single-quoted for sh — see the space-in-path test below for why.
    grep -qF "'$SCRIPTS_DIR'/agent-clear.sh" "$log" || false
    grep -qF "set-option -g @clux-installed 3.2.0" "$log" || false
}

@test "self-install: skips every install call when the marker matches and the segment is present" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS=\$'@clux-installed 3.2.0\nstatus-right \"L #{@clux-agent-bar} R\"'
        export FAKE_PANES_FULL='%1|alpha|claude'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' needs-you
    "
    [ "$status" -eq 0 ]
    run grep -c "set-hook" "$log"
    [ "$output" = "0" ]
    run grep -c "set-option -g @clux-installed" "$log"
    [ "$output" = "0" ]
    grep -qF "set-option -g @clux-agent-bar " "$log" || false
}

@test "self-install: Tier A appends with tmux's own -a and never rewrites status-right" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='status-right \"L R\"'
        export FAKE_STATUS_FORMAT0='xxx #{status-right} yyy'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    grep -qF "set-option -ag status-right  #{@clux-agent-bar}" "$log" || false
    run grep -c "tmux set-option -g status-right" "$log"
    [ "$output" = "0" ]
    run grep -c "#{status-right}" "$log"
    [ "$output" = "0" ]
}

@test "self-install: Tier A raises status-right-length when it would truncate the segment" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='status-right \"L R\"'
        export FAKE_STATUS_FORMAT0='xxx #{status-right} yyy'
        export FAKE_STATUS_RIGHT='L R #{@clux-agent-bar}'
        export FAKE_OPTS='status-right-length=40'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    # want = len('L R #{@clux-agent-bar}') [22] + 40 margin = 62, comfortably
    # above the default 40 that would otherwise silently cut the segment.
    grep -qF "set-option -g status-right-length 62" "$log" || false
}

@test "self-install: Tier A never shrinks a status-right-length the user set larger already" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='status-right \"L R\"'
        export FAKE_STATUS_FORMAT0='xxx #{status-right} yyy'
        export FAKE_STATUS_RIGHT='L R #{@clux-agent-bar}'
        export FAKE_OPTS='status-right-length=200'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    run grep -c "tmux set-option -g status-right-length" "$log"
    [ "$output" = "0" ]
}

@test "self-install: a clux segment anywhere in the dump suppresses the append" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS=\$'status-format[0] \"... #{@clux-agent-bar} ...\"\nstatus-right \"L R\"'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    grep -qF "set-hook -g after-select-window[90]" "$log" || false
    grep -qF "set-hook -g client-session-changed[90]" "$log" || false
    run grep -c "set-option -ag status-right" "$log"
    [ "$output" = "0" ]
}

@test "self-install: Tier B sets the unreachable flag, warns once, and leaves status-right alone" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='status-left \"hi\"'
        export FAKE_STATUS_FORMAT0='a big custom format with no bar reference'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -qF "set-option -g @clux-agent-bar-unreachable 3.2.0" "$log" || false
    run grep -c "display-message" "$log"
    [ "$output" = "1" ]
    run grep -c "set-option -ag status-right" "$log"
    [ "$output" = "0" ]
    # display-message expands #{...} in its OWN argument, so the literal
    # token must be escaped as ##{...} or tmux deletes it and the warning's
    # only actionable word vanishes for the user.
    grep -qF "Add ##{@clux-agent-bar} to your bar manually" "$log" || false
}

@test "self-install: Tier B is not fooled by status-right-style/status-right-length siblings" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='status-left \"hi\"'
        export FAKE_STATUS_FORMAT0='#[range=right #{status-right-style}]#{status-right-length}stuff'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    # A format that references only the *-style/*-length siblings, never
    # `#{status-right}` itself, must still classify as Tier B — the bare
    # substring "status-right" is present twice here but neither is a real
    # reference to the status-right option.
    grep -qF "set-option -g @clux-agent-bar-unreachable 3.2.0" "$log" || false
    run grep -c "set-option -ag status-right" "$log"
    [ "$output" = "0" ]
}

@test "self-install: the Tier B warning is not repeated once the flag is recorded" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS=\$'@clux-installed 3.2.0\n@clux-agent-bar-unreachable 3.2.0'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    run grep -c "display-message" "$log"
    [ "$output" = "0" ]
    run grep -c "set-hook" "$log"
    [ "$output" = "0" ]
    run grep -c "set-option -ag status-right" "$log"
    [ "$output" = "0" ]
}

@test "self-install: an unreachable flag from an older version is re-evaluated, not trusted" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS=\$'@clux-installed 3.2.0\n@clux-agent-bar-unreachable 3.1.0'
        export FAKE_STATUS_FORMAT0='a big custom format with no bar reference'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    # Stale (older-version) flag does not suppress re-evaluation: Tier B runs
    # again, records the CURRENT version, and warns again. A flag that
    # latched forever would show none of this.
    grep -qF "set-option -g @clux-agent-bar-unreachable 3.2.0" "$log" || false
    run grep -c "display-message" "$log"
    [ "$output" = "1" ]
    # need_hooks was already 0 (marker matched) — only need_bar fired.
    run grep -c "set-hook" "$log"
    [ "$output" = "0" ]
}

@test "self-install: a dropped bar segment is re-installed even though @clux-installed still matches" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='@clux-installed 3.2.0'
        export FAKE_STATUS_FORMAT0='xxx #{status-right} yyy'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    grep -qF "set-option -ag status-right  #{@clux-agent-bar}" "$log" || false
    run grep -c "set-hook" "$log"
    [ "$output" = "0" ]
    run grep -c "set-option -g @clux-installed" "$log"
    [ "$output" = "0" ]
}

@test "self-install: an empty option dump installs nothing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    # FAKE_GLOBAL_OPTS deliberately unset — the stub answers empty.
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    run grep -c "set-hook" "$log"
    [ "$output" = "0" ]
    run grep -c "set-option -g @clux-installed" "$log"
    [ "$output" = "0" ]
    run grep -c "set-option -g @clux-agent-bar" "$log"
    [ "$output" = "0" ]
}

@test "self-install: nothing runs when TMUX is unset" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='status-right \"L R\"'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX= TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/%1" ]
    # Not one tmux process spawned: the log is never even created.
    [ ! -f "$log" ]
}

@test "self-install: a copy outside the plugin tree never installs" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    local deployed="$BATS_TEST_TMPDIR/deployed"
    mkdir -p "$deployed/scripts" "$deployed/hooks"
    cp "$SCRIPTS_DIR"/*.sh "$deployed/scripts/"
    cp "$HOOKS_DIR/agent-state.sh" "$deployed/hooks/agent-state.sh"
    chmod +x "$deployed/hooks/agent-state.sh" "$deployed/scripts/"*.sh
    # No <deployed>/.claude-plugin — this is the deployed-copy shape.
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='status-right \"L R\"'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$deployed/hooks/agent-state.sh' busy
    "
    [ "$status" -eq 0 ]
    run grep -c "show-options" "$log"
    [ "$output" = "0" ]
    run grep -c "set-hook" "$log"
    [ "$output" = "0" ]
    run grep -c "tmux set-option" "$log"
    [ "$output" = "0" ]
}

@test "self-install: a plugin path containing a space is shell-quoted in the hook command" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    local spaced="$BATS_TEST_TMPDIR/clux app/current"
    mkdir -p "$spaced/scripts" "$spaced/hooks" "$spaced/.claude-plugin"
    cp "$SCRIPTS_DIR"/*.sh "$spaced/scripts/"
    cp "$HOOKS_DIR/agent-state.sh" "$spaced/hooks/agent-state.sh"
    printf '{}' > "$spaced/.claude-plugin/plugin.json"
    chmod +x "$spaced/hooks/agent-state.sh" "$spaced/scripts/"*.sh
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS='status-right \"L R\"'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$spaced/hooks/agent-state.sh' busy
    "
    [ "$status" -eq 0 ]
    # The path segment is wrapped in its own single quotes for sh, so sh does
    # not word-split on the space in 'clux app'. An UNQUOTED occurrence of
    # the raw path (no leading quote before it) would be the bug: sh would
    # treat "clux" as the command name and exit 127 on every window switch.
    grep -qF "run-shell \"'$spaced/scripts'/agent-clear.sh '#{window_id}'\"" "$log" || false
    run grep -c "run-shell \"$spaced/scripts/agent-clear.sh" "$log"
    [ "$output" = "0" ]
}

# ===========================================================================
# PUBLISH — refresh_agent_bar() writing @clux-agent-bar (path.sh)
# ===========================================================================

@test "publish: the rendered bar is written into @clux-agent-bar before the redraw" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$dir"
    printf 'needs-you\n' > "$dir/%1"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS=\$'@clux-installed 3.2.0\nstatus-right \"L #{@clux-agent-bar} R\"'
        export FAKE_PANES_FULL='%1|alpha|claude'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' needs-you
    "
    [ "$status" -eq 0 ]
    local set_line refresh_line
    set_line=$(grep -nF 'set-option -g @clux-agent-bar #[fg=yellow]!#[default]alpha' "$log" | head -1 | cut -d: -f1)
    refresh_line=$(grep -n 'refresh-client -S' "$log" | head -1 | cut -d: -f1)
    [ -n "$set_line" ]
    [ -n "$refresh_line" ]
    [ "$set_line" -lt "$refresh_line" ]
}

@test "publish: the renderer is not run when no clux segment is on the bar" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_GLOBAL_OPTS=\$'@clux-installed 3.2.0\n@clux-agent-bar-unreachable 3.2.0'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    run grep -c "set-option -g @clux-agent-bar " "$log"
    [ "$output" = "0" ]
    run grep -c "list-panes -a -F #{pane_id}|#{session_name}|#{pane_current_command}" "$log"
    [ "$output" = "0" ]
    grep -qF "refresh-client -S" "$log" || false
}

# ===========================================================================
# RENDERER escaping — agent-bar.sh
# ===========================================================================

@test "renderer: a '#' in a session name is emitted as '##'" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'needs-you\n' > "$dir/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%1|we#ird|claude'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_BAR'
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=yellow]!#[default]we##ird' ]
}

@test "renderer: one-column mode is unchanged by the escaping fix" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir"
    printf 'needs-you\n' > "$dir/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%1|we#ird|claude'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_BAR' 'we#ird'
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=yellow]!#[default]' ]
}

# ===========================================================================
# CLEAR --reap self-install bootstrap
# ===========================================================================

@test "clear --reap: bootstraps the tmux wiring at config load" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$dir"
    printf 'busy\n' > "$dir/%1"
    printf 'finished\n' > "$dir/%99"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS='%1'
        export FAKE_GLOBAL_OPTS='status-right \"L R\"'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        TMUX=dummy '$AGENT_CLEAR' --reap
    "
    [ "$status" -eq 0 ]
    grep -qF "set-hook -g after-select-window[90]" "$log" || false
    grep -qF "set-hook -g client-session-changed[90]" "$log" || false
    grep -qF "set-option -g @clux-installed 3.2.0" "$log" || false
    [ -f "$dir/%1" ]
    [ ! -f "$dir/%99" ]
}
