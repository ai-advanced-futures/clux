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

# State files live under a directory named for the tmux server that owns the
# pane, because a pane id repeats across servers (path.sh,
# resolve_agent_server_key). The stub below reports this key for every server
# question, so the tests address "$dir/$SRV/%1". Cross-server behaviour needs
# two real servers and is covered in agent-state-server-scope.bats.
SRV="4242-1700000000"

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
#
# Every pane listing now leads with the server key. The stub PREPENDS it rather
# than making each test carry it, so the FAKE_* fixtures stay readable and say
# only what their test is about. FAKE_SERVER_KEY overrides it, which is how a
# test can present a listing from a different server.
# ---------------------------------------------------------------------------
_write_agent_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
_srv="${FAKE_SERVER_KEY:-4242-1700000000}"
# Prepend the server key to each row of a listing, with the given separator.
_lead() {
    local sep="$1" line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s%s%s\n' "$_srv" "$sep" "$line"
    done
}
case "$*" in
    "display-message -p #{pid}-#{start_time}")
        # resolve_agent_server_key. Matched BEFORE the generic display-message
        # arm below, which answers a different question entirely.
        printf '%s\n' "$_srv"
        ;;
    "list-panes -a -F #{pid}-#{start_time}|#{pane_id}|#{session_name}")
        [ -n "${FAKE_PANES_FULL:-}" ] && printf '%s\n' "$FAKE_PANES_FULL" | _lead '|'
        ;;
    "list-panes -a -F #{pane_pid}"*)
        # resolve_agents_pane_by_cwd's 5-column tab-joined format. Matched by
        # its unique #{pane_pid} prefix, NOT the full string: the real format
        # contains literal tabs, which are fragile to carry in a case pattern.
        [ -n "${FAKE_PANES_RESOLVE:-}" ] && printf '%s\n' "$FAKE_PANES_RESOLVE"
        ;;
    "list-panes -a -F #{pid}-#{start_time} #{pane_id}")
        # the reaper's listing — one round-trip for the key and the live panes
        [ -n "${FAKE_PANE_IDS:-}" ] && printf '%s\n' "$FAKE_PANE_IDS" | _lead ' '
        ;;
    "list-panes -t "*)
        [ -n "${FAKE_WINDOW_PANES:-}" ] && printf '%s\n' "$FAKE_WINDOW_PANES" | _lead '|'
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

# _write_agent_ps_stub — canned `ps` for the detached-writer tests. The
# resolver (resolve_agents_pane_by_cwd) snapshots the process table once;
# FAKE_PS supplies "<pid> <ppid> <args...>" rows. Every stub call is logged so
# a test can assert the CACHE path never scanned (`! grep '^ps '`).
_write_agent_ps_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/ps" <<'STUBEOF'
#!/usr/bin/env bash
echo "ps $*" >> "${STUB_LOG:-/dev/null}"
[ -n "${FAKE_PS:-}" ] && printf '%s\n' "$FAKE_PS"
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/ps"
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
    [ "$(cat "$dir/$SRV/%1")" = "busy" ]
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
    [ "$(cat "$dir/$SRV/%2")" = "needs-you" ]
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
    [ "$(cat "$dir/$SRV/%2")" = "needs-you" ]
}

@test "writer: Notification auth_success is a no-op (existing state untouched)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'busy\n' > "$dir/$SRV/%3"
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
    [ "$(cat "$dir/$SRV/%3")" = "busy" ]
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
    [ "$(cat "$dir/$SRV/%4")" = "needs-you" ]
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
    [ "$(cat "$dir/$SRV/%5")" = "finished" ]
    # Atomicity proxy: no orphaned temp file, exactly one entry in the dir.
    [ "$(find "$dir/$SRV" -maxdepth 1 -type f | wc -l)" -eq 1 ]
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
    [ ! -f "$dir/$SRV/%6" ]

    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%7 '$AGENT_HOOK' busy
        printf '' | TMUX=dummy TMUX_PANE=%7 '$AGENT_HOOK' end
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/$SRV/%7" ]
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
    [ ! -f "$dir/$SRV/%8" ]
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
    mkdir -p "$dir/$SRV"
    printf 'busy\n' > "$dir/$SRV/%1"
    printf 'busy\n' > "$dir/$SRV/%2"
    printf 'finished\n' > "$dir/$SRV/%99"
    _write_agent_tmux_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS=\$'%1\n%2'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/$SRV/%1" ]
    [ -f "$dir/$SRV/%2" ]
    [ ! -f "$dir/$SRV/%99" ]
}

@test "writer: does NOT reap when tmux list-panes returns empty (wipe-everything guard)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'finished\n' > "$dir/$SRV/%99"
    _write_agent_tmux_stub
    # FAKE_PANE_IDS deliberately unset — stub answers empty for list-panes -a.
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/$SRV/%99" ]
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
# DETACHED WRITER — hooks/agent-state.sh with TMUX/TMUX_PANE unset
# (`claude agents` background sessions). Key = agents/<dashboard-pane>~<sid>.
# ===========================================================================

@test "writer(detached): resolves the dashboard pane by cwd, writes agents/<pane>~<sid>" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local JSON='{"hook_event_name":"UserPromptSubmit","session_id":"abcd-1234","cwd":"/fake/proj"}'
    _write_agent_tmux_stub
    _write_agent_ps_stub
    # Pane %9 (pane_pid 100) hosts a `claude agents --cwd /fake/proj`
    # dashboard (pid 200, ppid 100 -> one ppid-chain step to the pane).
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_RESOLVE=\$'100\t\$5\t@2\t%9\t/fake/proj'
        export FAKE_PS='200 100 claude agents --cwd /fake/proj'
        export FAKE_PANE_IDS='%9'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | env -u TMUX -u TMUX_PANE '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$dir/$SRV/agents/%9~abcd-1234")" = "busy" ]
    # The resolve path did scan the process table.
    grep -q "^ps " "$BATS_TEST_TMPDIR/stub.log"
}

@test "writer(detached): a cached file makes the next event skip ps entirely" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'busy\n' > "$dir/$SRV/agents/%9~abcd-1234"
    local JSON='{"hook_event_name":"Stop","session_id":"abcd-1234","cwd":"/fake/proj"}'
    _write_agent_tmux_stub
    _write_agent_ps_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS='%9'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | env -u TMUX -u TMUX_PANE '$AGENT_HOOK' finished
    "
    [ "$status" -eq 0 ]
    [ "$(cat "$dir/$SRV/agents/%9~abcd-1234")" = "finished" ]
    # The pane came from the file NAME — the per-session ps scan must not
    # repeat on every event. This is the once-per-agent-session guarantee.
    ! grep -q "^ps " "$BATS_TEST_TMPDIR/stub.log"
}

@test "writer(detached): remove deletes the cached file and never scans" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'busy\n' > "$dir/$SRV/agents/%9~abcd-1234"
    local JSON='{"hook_event_name":"SessionEnd","session_id":"abcd-1234","cwd":"/fake/proj"}'
    _write_agent_tmux_stub
    _write_agent_ps_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS='%9'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | env -u TMUX -u TMUX_PANE '$AGENT_HOOK' remove
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/$SRV/agents/%9~abcd-1234" ]
    ! grep -q "^ps " "$BATS_TEST_TMPDIR/stub.log"
}

@test "writer(detached): remove with no cached file is a silent no-op — no resolve, no dir" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local JSON='{"hook_event_name":"SessionEnd","session_id":"abcd-1234","cwd":"/fake/proj"}'
    _write_agent_tmux_stub
    _write_agent_ps_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PS='200 100 claude agents --cwd /fake/proj'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | env -u TMUX -u TMUX_PANE '$AGENT_HOOK' remove
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "$dir" ]
    ! grep -q "^ps " "$BATS_TEST_TMPDIR/stub.log"
}

@test "writer(detached): payload without session_id writes nothing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local JSON='{"hook_event_name":"UserPromptSubmit","cwd":"/fake/proj"}'
    _write_agent_tmux_stub
    _write_agent_ps_stub
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PS='200 100 claude agents --cwd /fake/proj'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | env -u TMUX -u TMUX_PANE '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "$dir" ]
}

@test "writer(detached): no dashboard owns the cwd — no column, nothing written" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local JSON='{"hook_event_name":"UserPromptSubmit","session_id":"abcd-1234","cwd":"/fake/proj"}'
    _write_agent_tmux_stub
    _write_agent_ps_stub
    # FAKE_PS deliberately unset — the process table holds no dashboard.
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_RESOLVE=\$'100\t\$5\t@2\t%9\t/fake/proj'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | env -u TMUX -u TMUX_PANE '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "$dir" ]
}

@test "writer(detached): a stale cached pane self-heals — write, then the reap deletes it" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'busy\n' > "$dir/$SRV/agents/%9~abcd-1234"
    local JSON='{"hook_event_name":"UserPromptSubmit","session_id":"abcd-1234","cwd":"/fake/proj"}'
    _write_agent_tmux_stub
    _write_agent_ps_stub
    # %9 is NOT in the live listing (tmux restarted); the listing is non-empty
    # so the reap runs. The cache hit writes to the stale name, the reap in the
    # same invocation removes it, and the NEXT event would re-resolve.
    run bash -c "
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS='%1'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | env -u TMUX -u TMUX_PANE '$AGENT_HOOK' busy
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/$SRV/agents/%9~abcd-1234" ]
}

# ===========================================================================
# READER — agent-query.sh
# ===========================================================================

@test "reader: rollup precedence needs-you > busy > finished, idle unlisted" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'needs-you\n' > "$dir/$SRV/%1"
    printf 'busy\n' > "$dir/$SRV/%2"
    printf 'finished\n' > "$dir/$SRV/%3"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL=\$'%1|alpha\n%2|beta\n%3|gamma'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'alpha\tneeds-you\nbeta\tbusy\ngamma\tfinished')" ]
}

@test "reader: drops a state file whose pane is gone from the listing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'busy\n' > "$dir/$SRV/%5"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%6|other'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # Ignored, not deleted.
    [ -f "$dir/$SRV/%5" ]
}

@test "reader: pane in listing with no state file is not reported" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'busy\n' > "$dir/$SRV/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL=\$'%1|alpha\n%9|beta'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'alpha\tbusy')" ]
}

@test "reader: never asks tmux for pane_current_command (the always-empty-bar regression)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'busy\n' > "$dir/$SRV/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%1|alpha'
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'alpha\tbusy')" ]
    # The state file alone decides inclusion. `pane_current_command` reports the
    # Claude binary's own name, which is a version string (e.g. `2.1.233`) on
    # most installs and never the literal `claude`, so the filter that read it
    # dropped every pane and the bar was empty for everyone. Not requesting the
    # field is what keeps that filter from coming back.
    ! grep -q "pane_current_command" "$BATS_TEST_TMPDIR/stub.log"
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
    mkdir -p "$dir/$SRV"
    printf 'busy\n' > "$dir/$SRV/%1"          # live pane — will be printed
    printf 'finished\n' > "$dir/$SRV/%99"     # stale (pane gone) — must survive, untouched
    printf 'needs-you\n' > "$dir/$SRV/%8"     # live pane — reported, and still never touched
    _write_agent_tmux_stub

    local before after
    before="$(find "$dir/$SRV" -maxdepth 1 -type f | LC_ALL=C sort)$(cat "$dir/$SRV"/*)"

    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL=\$'%1|alpha\n%8|alpha'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    # %1=busy and %8=needs-you both roll up under session "alpha"; needs-you wins.
    [ "$output" = "$(printf 'alpha\tneeds-you')" ]

    after="$(find "$dir/$SRV" -maxdepth 1 -type f | LC_ALL=C sort)$(cat "$dir/$SRV"/*)"
    [ "$before" = "$after" ]
    [ -f "$dir/$SRV/%99" ]
    [ -f "$dir/$SRV/%8" ]
}

@test "reader: dashboard column rolls up its agents — needs-you beats busy beats finished" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'needs-you\n' > "$dir/$SRV/agents/%47~aa11"
    printf 'busy\n'      > "$dir/$SRV/agents/%47~bb22"
    printf 'finished\n'  > "$dir/$SRV/agents/%47~cc33"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%47|config'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    # The confirmed rule: needs-you if any, else busy if any, else finished.
    [ "$output" = "$(printf 'config\tneeds-you')" ]
}

@test "reader: dashboard shows finished only when every agent finished" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'finished\n' > "$dir/$SRV/agents/%47~aa11"
    printf 'finished\n' > "$dir/$SRV/agents/%47~bb22"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%47|config'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'config\tfinished')" ]
}

@test "reader: interactive pane files and agent files join in one listing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'busy\n'     > "$dir/$SRV/%26"
    printf 'finished\n' > "$dir/$SRV/agents/%47~aa11"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL=\$'%26|clux\n%47|config'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'clux\tbusy\nconfig\tfinished')" ]
}

@test "reader: agent file whose pane left the listing is skipped, never deleted" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'busy\n' > "$dir/$SRV/agents/%9~aa11"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%1|alpha'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # Ignored, not deleted — reaping is a writer's job.
    [ -f "$dir/$SRV/agents/%9~aa11" ]
}

# ===========================================================================
# RENDERER — agent-bar.sh
# ===========================================================================

@test "renderer: one-argument mode prints exactly the coloured glyph for a needs-you session" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'needs-you\n' > "$dir/$SRV/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%1|alpha'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_BAR' alpha
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=yellow]!#[default]' ]
}

@test "renderer: one-argument mode prints a single space for an idle/unknown session" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
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
    mkdir -p "$dir/$SRV"
    printf 'needs-you\n' > "$dir/$SRV/%1"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%1|alpha'
        export FAKE_OPTS=\$'@clux-agent-glyph-needs=N\n@clux-agent-needs-color=red'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_BAR' alpha
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=red]N#[default]' ]
}

@test "renderer: no-argument rollup is empty when every session is idle" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
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
    mkdir -p "$dir/$SRV"
    printf 'finished\n' > "$dir/$SRV/%1"   # in-window, finished -> must be removed
    printf 'busy\n' > "$dir/$SRV/%2"       # in-window, busy -> must survive
    printf 'finished\n' > "$dir/$SRV/%3"   # NOT in window -> must survive
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_WINDOW_PANES=\$'%1\n%2'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' '@1'
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/$SRV/%1" ]
    [ -f "$dir/$SRV/%2" ]
    [ -f "$dir/$SRV/%3" ]
}

@test "clear: refreshes the bar after it removes a mark, honouring the refresh option" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$dir/$SRV"
    printf 'finished\n' > "$dir/$SRV/%1"
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
    [ ! -f "$dir/$SRV/%1" ]
    grep -qF "tmux run-shell -b /rebuild-bar" "$log" || false
}

@test "clear: does NOT refresh when it removed nothing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local log="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$dir/$SRV"
    printf 'busy\n' > "$dir/$SRV/%1"   # not 'finished' -> nothing to clear
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export STUB_LOG='$log'
        export FAKE_WINDOW_PANES='%1'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' '@1'
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/$SRV/%1" ]
    # A window switch that changes nothing must cost no rebuild of the bar.
    run grep -cF "refresh-client" "$log"
    [ "$output" = "0" ]
}

@test "clear: empty argument falls back to display-message and still clears" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'finished\n' > "$dir/$SRV/%1"
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
    [ ! -f "$dir/$SRV/%1" ]
}

@test "clear: unresolvable window exits 0 and deletes nothing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'finished\n' > "$dir/$SRV/%1"
    _write_agent_tmux_stub
    # FAKE_WINDOW_ID deliberately unset — display-message answers empty.
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' ''
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/$SRV/%1" ]
}

@test "clear --reap: deletes only dead-pane files server-wide" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'busy\n' > "$dir/$SRV/%1"
    printf 'busy\n' > "$dir/$SRV/%2"
    printf 'finished\n' > "$dir/$SRV/%99"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS=\$'%1\n%2'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' --reap
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/$SRV/%1" ]
    [ -f "$dir/$SRV/%2" ]
    [ ! -f "$dir/$SRV/%99" ]
}

@test "clear --reap: an empty pane listing deletes nothing" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'finished\n' > "$dir/$SRV/%99"
    _write_agent_tmux_stub
    # FAKE_PANE_IDS deliberately unset.
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' --reap
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/$SRV/%99" ]
}

@test "clear: finished agent files clear on window view; busy and out-of-window survive" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'finished\n' > "$dir/$SRV/agents/%1~aa11"   # in-window, finished -> removed
    printf 'busy\n'     > "$dir/$SRV/agents/%1~bb22"   # in-window, busy -> survives
    printf 'finished\n' > "$dir/$SRV/agents/%2~cc33"   # NOT in window -> survives
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_WINDOW_PANES='%1'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' '@1'
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/$SRV/agents/%1~aa11" ]
    [ -f "$dir/$SRV/agents/%1~bb22" ]
    [ -f "$dir/$SRV/agents/%2~cc33" ]
}

@test "clear --reap: sweeps agent files of dead dashboard panes, keeps live ones" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'busy\n' > "$dir/$SRV/agents/%1~aa11"
    printf 'busy\n' > "$dir/$SRV/agents/%99~bb22"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS='%1'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' --reap
    "
    [ "$status" -eq 0 ]
    [ -f "$dir/$SRV/agents/%1~aa11" ]
    [ ! -f "$dir/$SRV/agents/%99~bb22" ]
    # The agents/ directory entry itself never trips the flat loop.
    [ -d "$dir/$SRV/agents" ]
}

# ===========================================================================
# 3.8.0 — the fourth state `failed` (StopFailure), the Notification
# sub-types the agents dashboard emits, and SessionStart housekeeping.
# ===========================================================================

@test "writer: failed writes 'failed' to <state-dir>/<pane-id>" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local JSON='{"hook_event_name":"StopFailure","session_id":"s1","error_type":"rate_limit"}'
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX=dummy TMUX_PANE=%1 '$AGENT_HOOK' failed
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$dir/$SRV/%1")" = "failed" ]
}

@test "writer: Notification agent_completed writes finished under the needs-you argument" {
    local dir="$BATS_TEST_TMPDIR/agents"
    local JSON='{"hook_event_name":"Notification","notification_type":"agent_completed","session_id":"s1"}'
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX=dummy TMUX_PANE=%2 '$AGENT_HOOK' needs-you
    "
    [ "$status" -eq 0 ]
    [ "$(cat "$dir/$SRV/%2")" = "finished" ]
}

@test "writer: Notification agent_needs_input, elicitation_dialog, elicitation_url_dialog, quota stale/disabled write needs-you" {
    local dir="$BATS_TEST_TMPDIR/agents" t
    _write_agent_tmux_stub
    for t in agent_needs_input elicitation_dialog elicitation_url_dialog quota_auto_resume_stale quota_auto_resume_disabled; do
        rm -f "$dir/$SRV/%2"
        local JSON="{\"hook_event_name\":\"Notification\",\"notification_type\":\"$t\",\"session_id\":\"s1\"}"
        run bash -c "
            export CLUX_AGENT_STATE_DIR='$dir'
            export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
            printf '%s' '$JSON' | TMUX=dummy TMUX_PANE=%2 '$AGENT_HOOK' needs-you
        "
        [ "$status" -eq 0 ]
        [ "$(cat "$dir/$SRV/%2")" = "needs-you" ] || { echo "$t did not write needs-you"; false; }
    done
}

@test "writer: Notification quota_auto_resume_fired is a no-op (Claude resumed on its own)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'busy\n' > "$dir/$SRV/%3"
    local JSON='{"hook_event_name":"Notification","notification_type":"quota_auto_resume_fired","session_id":"s1"}'
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX=dummy TMUX_PANE=%3 '$AGENT_HOOK' needs-you
    "
    [ "$status" -eq 0 ]
    [ "$(cat "$dir/$SRV/%3")" = "busy" ]
}

@test "writer: SessionStart remove drops the pane's stale file (a restart in the same pane)" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'finished\n' > "$dir/$SRV/%4"
    local JSON='{"hook_event_name":"SessionStart","source":"startup","session_id":"s9"}'
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANE_IDS='%4'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX=dummy TMUX_PANE=%4 '$AGENT_HOOK' remove
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$dir/$SRV/%4" ]
}

@test "reader: failed ranks above needs-you in the roll-up" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV"
    printf 'needs-you\n' > "$dir/$SRV/%1"
    printf 'failed\n' > "$dir/$SRV/%2"
    printf 'busy\n' > "$dir/$SRV/%3"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL=\$'%1|alpha\n%2|beta\n%3|gamma'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'beta\tfailed\nalpha\tneeds-you\ngamma\tbusy')" ]
}

@test "reader: a dashboard with one failed agent and one busy agent shows failed" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'busy\n'   > "$dir/$SRV/agents/%47~aa11"
    printf 'failed\n' > "$dir/$SRV/agents/%47~bb22"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_PANES_FULL='%47|config'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_QUERY'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'config\tfailed')" ]
}

@test "clear: removes failed files on view, exactly like finished; busy survives" {
    local dir="$BATS_TEST_TMPDIR/agents"
    mkdir -p "$dir/$SRV/agents"
    printf 'failed\n' > "$dir/$SRV/%1"
    printf 'busy\n'   > "$dir/$SRV/%2"
    printf 'failed\n' > "$dir/$SRV/agents/%1~aa11"
    _write_agent_tmux_stub
    run bash -c "
        export CLUX_AGENT_STATE_DIR='$dir'
        export FAKE_WINDOW_PANES=\$'%1\n%2'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        '$AGENT_CLEAR' '@1'
    "
    [ "$status" -eq 0 ]
    [ ! -f "$dir/$SRV/%1" ]
    [ -f "$dir/$SRV/%2" ]
    [ ! -f "$dir/$SRV/agents/%1~aa11" ]
}
