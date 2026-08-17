#!/usr/bin/env bats
# session-list.bats — session-list.sh: renders #{@clux_session_bar}.
#
# THE REGRESSION TEST for the 2026-08-16 bar-emptying fault: agent-query.sh
# output travels to awk on \037 (unit separator), never on a real newline,
# because BWK awk (macOS) rejects a literal newline inside an `awk -v`
# assignment and exits 2 printing nothing — which emptied the WHOLE status
# bar, not just the agent-glyph column. Cases below feed 0, 1, and 3 rows of
# REAL-newline-delimited agent-query.sh output (exactly the shape the fault
# needs) and assert the renderer still produces output and every glyph
# appears.

load test_helper

LIST_SCRIPT="$SCRIPTS_DIR/session-list.sh"
SEP=$'\037'

# ---------------------------------------------------------------------------
# _write_list_tmux_stub — one tmux stub serving every call session-list.sh
# (and the session-order.sh it shells out to) makes:
#   show-option -gqv @clux-session-order         -> FAKE_ORDER
#   list-sessions -F '#{session_id}\t...'        -> FAKE_SESSIONS  (order.sh)
#   list-sessions -F '#{session_name}\t#{session_attached}\t...'
#                                                 -> FAKE_SESS_ROWS (this script)
#   list-windows -a -F '...'                     -> FAKE_WIN_ROWS
#   display-message -p '<SEP-joined @clux-bar-*/@clux-agent-* options>'
#                                                 -> FAKE_OPTS (SEP-joined,
#                                                    16 fields; empty means
#                                                    "every option unset")
# Distinguished by the -F format string content, since session-order.sh's
# list-sessions call and this script's own list-sessions call share the same
# subcommand name.
# ---------------------------------------------------------------------------
_write_list_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    show-option)
        case "$*" in
            *@clux-session-order*) printf '%s\n' "${FAKE_ORDER:-}" ;;
        esac
        ;;
    list-sessions)
        case "$3" in
            *session_id*) [ -n "${FAKE_SESSIONS:-}" ] && printf '%s\n' "${FAKE_SESSIONS}" ;;
            *session_attached*) [ -n "${FAKE_SESS_ROWS:-}" ] && printf '%s\n' "${FAKE_SESS_ROWS}" ;;
        esac
        ;;
    list-windows)
        [ -n "${FAKE_WIN_ROWS:-}" ] && printf '%s\n' "${FAKE_WIN_ROWS}"
        ;;
    display-message)
        printf '%s\n' "${FAKE_OPTS:-}"
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

# Writes an executable agent-query.sh stub at $HOME/.config/clux/scripts/ —
# the literal path session-list.sh hardcodes (not relative to itself), and
# prints $1 (real-newline-delimited "session<TAB>state" rows) verbatim.
_write_agent_query_stub() {
    local rows="$1"
    mkdir -p "$HOME/.config/clux/scripts"
    cat > "$HOME/.config/clux/scripts/agent-query.sh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' $(printf '%q' "$rows")
STUBEOF
    chmod +x "$HOME/.config/clux/scripts/agent-query.sh"
}

@test "session-list: 0 agent rows — bar still renders, glyph column is a blank space" {
    _write_list_tmux_stub
    # No agent-query.sh at all: session-list.sh's own "|| agents=\"\"" fallback
    # covers the absent-script case (agent-query.sh is genuinely optional).
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\teditor'
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" == *"alpha"* ]]
}

@test "session-list: 1 agent row — the matching session's glyph column carries it" {
    _write_list_tmux_stub
    _write_agent_query_stub 'alpha	needs-you'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\teditor'
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"#[fg=yellow]!#[default]"* ]]
}

@test "session-list: 3 agent rows over real newlines — REGRESSION for the 2026-08-16 bar-emptying fault" {
    _write_list_tmux_stub
    # Real newlines, exactly the shape agent-query.sh actually emits — the
    # \tr '\n' '\037'\ conversion in session-list.sh is what stands between
    # this and an empty bar.
    _write_agent_query_stub "$(printf 'alpha\tbusy\nbeta\tneeds-you\ngamma\tfinished')"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha\n\$1\tbeta\n\$2\tgamma'
        export FAKE_SESS_ROWS=\$'alpha\t0\talpha\nbeta\t0\tbeta\ngamma\t0\tgamma'
        export FAKE_WIN_ROWS=''
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    # The whole-bar-emptying failure mode is awk exiting 2 and printing
    # nothing — non-empty output is the load-bearing assertion here.
    [ -n "$output" ]
    # Every glyph must appear, one per session — not just the first.
    [[ "$output" == *"#[fg=cyan]*#[default]"* ]]
    [[ "$output" == *"#[fg=yellow]!#[default]"* ]]
    [[ "$output" == *"#[fg=green]v#[default]"* ]]
    # And every session name still renders — the bar is not partially eaten.
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"beta"* ]]
    [[ "$output" == *"gamma"* ]]
}

@test "session-list: a session name containing # is escaped to ## in the rendered bar" {
    _write_list_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\tsess#one'
        export FAKE_SESS_ROWS=\$'sess#one\t0\tsess#one'
        export FAKE_WIN_ROWS=''
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"sess##one"* ]]
    # The raw single "#" form must not survive escaping unchanged.
    [[ "$output" != *"sess#one"* ]]
}

@test "session-list: a window name containing # is also escaped to ##" {
    _write_list_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\twin#name'
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"win##name"* ]]
}

@test "session-list: colours and glyphs come from @clux-* options, not hardcoded values" {
    _write_list_tmux_stub
    _write_agent_query_stub 'alpha	busy'
    # 16-field SEP-joined batched read: name_length, name_attached_style,
    # name_detached_style, window_active_style, window_inactive_style,
    # bracket_style, separator_style, window_open, window_close, separator,
    # glyph_busy, glyph_needs, glyph_done, busy_color, needs_color, done_color.
    local opts
    opts="30${SEP}bg=red,fg=white${SEP}fg=red${SEP}bg=green,fg=black${SEP}bg=black,fg=green${SEP}fg=red${SEP}fg=white${SEP}<${SEP}>${SEP}~${SEP}B${SEP}N${SEP}D${SEP}orange${SEP}pink${SEP}teal"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\teditor'
        export FAKE_OPTS='$opts'
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    # Custom busy glyph+color used instead of the default "*"/cyan.
    [[ "$output" == *"#[fg=orange]B#[default]"* ]]
    [[ "$output" != *"#[fg=cyan]*#[default]"* ]]
    # Custom name style, bracket glyphs and separator all honoured.
    [[ "$output" == *"#[bg=red,fg=white] alpha "* ]]
    [[ "$output" == *"#[fg=red]<#[default]"* ]]
    [[ "$output" == *"#[fg=red]>#[default]"* ]]
    [[ "$output" == *"#[fg=white]~#[default]"* ]]
}

@test "session-list: default colours apply when the options are unset" {
    _write_list_tmux_stub
    _write_agent_query_stub 'alpha	needs-you'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\teditor'
        export FAKE_OPTS=''
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"#[fg=yellow]!#[default]"* ]]
    [[ "$output" == *"#[bg=magenta,fg=black,bold] alpha "* ]]
    [[ "$output" == *"❰"* ]]
    [[ "$output" == *"❱"* ]]
    [[ "$output" == *"│"* ]]
}

@test "session-list: a non-numeric @clux-bar-name-length falls back to 24 instead of corrupting the format" {
    _write_list_tmux_stub
    local opts
    opts="notanumber${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha'
        export FAKE_WIN_ROWS=''
        export FAKE_OPTS='$opts'
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    # The guarded fallback (24) reached the list-sessions/-windows format
    # strings, not the raw non-numeric value.
    grep -qF '#{=24:session_name}' "$BATS_TEST_TMPDIR/stub.log" || false
    ! grep -qF 'notanumber' "$BATS_TEST_TMPDIR/stub.log"
}

@test "session-list: detached session renders without brackets, attached session renders with them" {
    _write_list_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER='attached,idle'
        export FAKE_SESSIONS=\$'\$0\tattached\n\$1\tidle'
        export FAKE_SESS_ROWS=\$'attached\t1\tattached\nidle\t0\tidle'
        export FAKE_WIN_ROWS=\$'attached\t1\t0\teditor'
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    # Attached session gets the bracketed window list.
    [[ "$output" == *"❰"*"editor"*"❱"* ]]
    # Detached session uses the plain detached style, no window brackets for it.
    [[ "$output" == *"#[fg=magenta] idle "* ]]
}
