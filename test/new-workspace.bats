#!/usr/bin/env bats
# new-workspace.bats — new-workspace.sh: builds the clux workspace ("---" at
# index 0 running the editor, "claude" at index 1 running the agents
# dashboard). Run with TMUX unset so the script uses the plain "tmux" socket
# and prints the session name to stdout instead of switching a client — the
# documented detached-run path this script exists to support (also how bats
# itself runs it).

load test_helper

NEW_WORKSPACE="$SCRIPTS_DIR/new-workspace.sh"

# _write_workspace_tmux_stub — answers show-option (@clux-new-workspace-name,
# base-index, @clux-editor, @clux-agents-command, @clux-dir-resolver, and
# every other option helpers.sh reads at source time), has-session (fails
# unless FAKE_SESSION_EXISTS is set — the exact "=name" exact-match bug this
# script fixes), display-message -p pane_current_path, and hands back
# window ids from new-session/new-window's "-P -F '#{window_id}'".
_write_workspace_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    show-option)
        case "$*" in
            *@clux-new-workspace-name*) printf '%s\n' "${FAKE_WORKSPACE_NAME:-}" ;;
            *base-index*) printf '%s\n' "${FAKE_BASE_INDEX:-}" ;;
            *@clux-editor*) printf '%s\n' "${FAKE_EDITOR_OPT-}" ;;
            *@clux-agents-command*) printf '%s\n' "${FAKE_AGENTS_OPT-}" ;;
            *@clux-dir-resolver*) printf '%s\n' "${FAKE_RESOLVER_OPT-}" ;;
            *) : ;;
        esac
        ;;
    has-session)
        [ -n "${FAKE_SESSION_EXISTS:-}" ] && exit 0
        exit 1
        ;;
    display-message)
        case "$*" in
            *pane_current_path*) printf '%s\n' "${FAKE_PANE_PATH:-}" ;;
        esac
        ;;
    new-session)
        printf '%s\n' "${FAKE_WIN_ID_EDITOR:-@1}"
        ;;
    new-window)
        printf '%s\n' "${FAKE_WIN_ID_CLAUDE:-@2}"
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "new-workspace: creates '---' at index 0 and 'claude' at index 1, addressed by window id, with base-index move-window" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    local project_dir="$BATS_TEST_TMPDIR/project"
    mkdir -p "$project_dir"
    _write_workspace_tmux_stub
    run bash -c "
        unset TMUX
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_WORKSPACE_NAME='work1'
        export FAKE_BASE_INDEX='1'
        export FAKE_WIN_ID_EDITOR='@10'
        export FAKE_WIN_ID_CLAUDE='@11'
        '$NEW_WORKSPACE' '$project_dir'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "work1" ]
    grep -qF -- "-n --- " "$log" || grep -qF -- "-n ---" "$log" || false
    grep -qF -- "-n claude" "$log" || false
    grep -qF 'set-option -w -t @10 automatic-rename off' "$log" || false
    grep -qF 'set-option -w -t @11 automatic-rename off' "$log" || false
    # base-index > 0 -> the editor window is moved to index 0.
    grep -qF 'move-window -s @10 -t work1:0' "$log" || false
    grep -qF 'select-window -t @10' "$log" || false
}

@test "new-workspace: base-index 0 never issues a move-window call" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    local project_dir="$BATS_TEST_TMPDIR/project"
    mkdir -p "$project_dir"
    _write_workspace_tmux_stub
    run bash -c "
        unset TMUX
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_WORKSPACE_NAME='work0'
        export FAKE_BASE_INDEX='0'
        '$NEW_WORKSPACE' '$project_dir'
    "
    [ "$status" -eq 0 ]
    run grep -qF 'move-window' "$log"
    [ "$status" -ne 0 ]
}

@test "new-workspace: editor sentinel 'none' creates the '---' window but sends nothing to it" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    local project_dir="$BATS_TEST_TMPDIR/project"
    mkdir -p "$project_dir"
    _write_workspace_tmux_stub
    run bash -c "
        unset TMUX
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_WORKSPACE_NAME='noeditor'
        export FAKE_BASE_INDEX='0'
        export FAKE_EDITOR_OPT='none'
        export FAKE_WIN_ID_EDITOR='@20'
        export FAKE_WIN_ID_CLAUDE='@21'
        '$NEW_WORKSPACE' '$project_dir'
    "
    [ "$status" -eq 0 ]
    # The editor window is still created and pinned...
    grep -qF -- "-n ---" "$log" || false
    grep -qF 'set-option -w -t @20 automatic-rename off' "$log" || false
    # ...but nothing is send-keys'd into it.
    run grep -qF 'send-keys -t @20' "$log"
    [ "$status" -ne 0 ]
    # The claude window still gets its command (default agents command).
    grep -qF 'send-keys -t @21' "$log" || false
}

@test "new-workspace: an unresolvable folder creates nothing, reports clearly, and exits 1" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_workspace_tmux_stub
    run bash -c "
        unset TMUX
        cd '$BATS_TEST_TMPDIR'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_WORKSPACE_NAME='ghost'
        export FAKE_RESOLVER_OPT='path'
        '$NEW_WORKSPACE' 'does-not-exist-anywhere'
    "
    [ "$status" -eq 1 ]
    grep -qF "clux: no directory for 'does-not-exist-anywhere'" "$log" || false
    # No session was ever created.
    run grep -qF 'new-session' "$log"
    [ "$status" -ne 0 ]
}

@test "new-workspace: an existing session with the exact name switches to it instead of creating a duplicate" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    local project_dir="$BATS_TEST_TMPDIR/project"
    mkdir -p "$project_dir"
    _write_workspace_tmux_stub
    run bash -c "
        unset TMUX
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_WORKSPACE_NAME='already'
        export FAKE_SESSION_EXISTS='1'
        '$NEW_WORKSPACE' '$project_dir'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "already" ]
    # The exact-match check ("=name") is what makes this branch fire.
    grep -qF 'has-session -t =already' "$log" || false
    run grep -qF 'new-session' "$log"
    [ "$status" -ne 0 ]
}

@test "new-workspace: no @clux-new-workspace-name set is a silent no-op" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_workspace_tmux_stub
    run bash -c "
        unset TMUX
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_WORKSPACE_NAME=''
        '$NEW_WORKSPACE' 'anything'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -qF 'new-session' "$log"
    [ "$status" -ne 0 ]
}
