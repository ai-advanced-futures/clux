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
REAL_TMUX="$(command -v tmux)"
# Must match session-list.sh's own SEP. U+E001, not a control byte: tmux 3.4
# escapes control bytes out of `display-message -p`, so \037 never split there.
SEP=$'\356\200\201'

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

    # Run the renderer from a staged copy, not from the plugin tree, so every
    # sibling it resolves ($CURRENT_DIR/session-order.sh, $CURRENT_DIR/
    # agent-query.sh) is one this test controls. This is also what proves the
    # script is location-independent: nothing here sits at the deploy path.
    STAGED_DIR="$BATS_TEST_TMPDIR/staged"
    mkdir -p "$STAGED_DIR"
    cp "$SCRIPTS_DIR/session-list.sh" "$SCRIPTS_DIR/session-order.sh" "$STAGED_DIR/"
    chmod +x "$STAGED_DIR/session-list.sh" "$STAGED_DIR/session-order.sh"
    LIST_SCRIPT="$STAGED_DIR/session-list.sh"
}

# Writes an executable agent-query.sh stub NEXT TO the staged session-list.sh,
# printing $1 (real-newline-delimited "session<TAB>state" rows) verbatim.
#
# Next to the script, never at a literal $HOME/.config/clux/scripts path. An
# earlier version of this helper wrote to that deploy path because the script
# hardcoded it, which made the suite structurally unable to catch the very bug
# it had: with agent-query.sh resolved through $HOME instead of through the
# script's own directory, the glyph column silently blanked everywhere clux is
# NOT deployed to exactly ~/.config/clux/scripts — the plugin tree, and any
# `render-clux-conf.sh --scripts-dir` install. A test that encodes the defect
# can only ever confirm it.
_write_agent_query_stub() {
    local rows="$1"
    cat > "$STAGED_DIR/agent-query.sh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' $(printf '%q' "$rows")
STUBEOF
    chmod +x "$STAGED_DIR/agent-query.sh"
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

@test "session-list: resolves agent-query.sh next to itself, not at the deploy path" {
    _write_list_tmux_stub
    _write_agent_query_stub 'alpha	busy'

    # The staged copy is NOT at ~/.config/clux/scripts, and $HOME is an empty
    # tmp dir, so a script that reaches for the literal deploy path finds
    # nothing and renders a blank glyph column instead of the busy glyph. That
    # is the whole failure: clux running from the plugin tree, or from any
    # `render-clux-conf.sh --scripts-dir` install, silently loses agent state.
    [ ! -e "$HOME/.config/clux/scripts/agent-query.sh" ]

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
    [[ "$output" == *"#[fg=cyan]*#[default]"* ]]
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

@test "session-list: failed (3.8.0) draws the fail glyph — fields 17/18 of the batched read, defaults x / red" {
    _write_list_tmux_stub
    _write_agent_query_stub 'alpha	failed'
    # Same sixteen fields as above, then glyph_fail and fail_color LAST, so a
    # sixteen-field stub keeps splitting exactly as before.
    local opts
    opts="30${SEP}bg=red,fg=white${SEP}fg=red${SEP}bg=green,fg=black${SEP}bg=black,fg=green${SEP}fg=red${SEP}fg=white${SEP}<${SEP}>${SEP}~${SEP}B${SEP}N${SEP}D${SEP}orange${SEP}pink${SEP}teal${SEP}F${SEP}purple"
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
    [[ "$output" == *"#[fg=purple]F#[default]"* ]]
    # Unset: the defaults.
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
    [[ "$output" == *"#[fg=red]x#[default]"* ]]
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

# ---------------------------------------------------------------------------
# CLUX_AGENT_GLYPH_BUSY env override (animated busy glyph, 2026-08-23 design).
# session-list.sh deliberately does not source helpers.sh, so it cannot pick
# up get_agent_glyph_busy()'s override — it applies the same override to its
# own field, right after its existing batched read.
# ---------------------------------------------------------------------------

@test "session-list: CLUX_AGENT_GLYPH_BUSY overrides the busy column" {
    _write_list_tmux_stub
    _write_agent_query_stub 'alpha	busy'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_AGENT_GLYPH_BUSY='ZZ'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\teditor'
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"#[fg=cyan]ZZ#[default]"* ]]
    [[ "$output" != *"#[fg=cyan]*#[default]"* ]]
}

@test "session-list: unset CLUX_AGENT_GLYPH_BUSY still honours the @clux-agent-glyph-busy option" {
    _write_list_tmux_stub
    _write_agent_query_stub 'alpha	busy'
    local opts
    opts="${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}${SEP}@${SEP}${SEP}${SEP}${SEP}${SEP}"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        unset CLUX_AGENT_GLYPH_BUSY
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\teditor'
        export FAKE_OPTS='$opts'
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"#[fg=cyan]@#[default]"* ]]
}

@test "session-list: both unset falls back to the plain * default" {
    _write_list_tmux_stub
    _write_agent_query_stub 'alpha	busy'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        unset CLUX_AGENT_GLYPH_BUSY
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\talpha'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\teditor'
        '$LIST_SCRIPT'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"#[fg=cyan]*#[default]"* ]]
}

@test "session-list: the env override changes only the busy column — rest of the bar is unaffected" {
    _write_list_tmux_stub
    _write_agent_query_stub $'alpha\tbusy\nbeta\tneeds-you'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER='alpha,beta'
        export FAKE_SESSIONS=\$'\$0\talpha\n\$1\tbeta'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha\nbeta\t1\tbeta'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\teditor\nbeta\t1\t0\teditor'
        unset CLUX_AGENT_GLYPH_BUSY
        '$LIST_SCRIPT'
    " > "$BATS_TEST_TMPDIR/plain.out"
    [ "$status" -eq 0 ]

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FAKE_ORDER='alpha,beta'
        export FAKE_SESSIONS=\$'\$0\talpha\n\$1\tbeta'
        export FAKE_SESS_ROWS=\$'alpha\t1\talpha\nbeta\t1\tbeta'
        export FAKE_WIN_ROWS=\$'alpha\t1\t0\teditor\nbeta\t1\t0\teditor'
        export CLUX_AGENT_GLYPH_BUSY='Q'
        '$LIST_SCRIPT'
    " > "$BATS_TEST_TMPDIR/overridden.out"
    [ "$status" -eq 0 ]

    # Only the busy glyph itself should differ between the two renders.
    local plain overridden expect
    plain="$(cat "$BATS_TEST_TMPDIR/plain.out")"
    overridden="$(cat "$BATS_TEST_TMPDIR/overridden.out")"
    expect="${plain//\#\[fg=cyan\]\*\#\[default\]/\#[fg=cyan]Q\#[default]}"
    [ "$overridden" = "$expect" ]
}

# ---------------------------------------------------------------------------
# Real-server option round-trip. Every case above feeds the batched option read
# through a tmux STUB, which hands FAKE_OPTS back verbatim — so a stub can
# never catch a tmux build that MANGLES the separator on the way out, and one
# does: tmux 3.4 escapes control bytes out of `display-message -p`, turning a
# literal 0x1F into the four characters \037. The read then never split, every
# field but the first came back empty, the bar silently fell back to its
# hardcoded defaults, and "\037" leaked onto the status line.
#
# This case sets the options on a REAL server and asserts the configured values
# actually arrive. It fails on any separator the running tmux does not pass
# through byte for byte.
# ---------------------------------------------------------------------------
@test "session-list: real-server — configured @clux-bar-* values reach the bar, separator intact" {
    local sock="clux-list-$$-${BATS_TEST_NUMBER}"
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    "$REAL_TMUX" -L "$sock" new-session -d -s alpha -x 80 -y 24
    local sockpath
    sockpath="$("$REAL_TMUX" -L "$sock" display-message -p '#{socket_path}')"

    # Three fields spread across the batched read — first third, middle, and
    # near the end — so a split that fails anywhere is caught. The session is
    # detached, so it is the DETACHED name style that renders here.
    "$REAL_TMUX" -L "$sock" set-option -g @clux-bar-name-detached-style "fg=#B48EAD,bold"
    "$REAL_TMUX" -L "$sock" set-option -g @clux-bar-separator-style     "fg=#4C566A"
    "$REAL_TMUX" -L "$sock" set-option -g @clux-bar-separator           "SEPGLYPH"

    local out
    out="$(env TMUX="$sockpath,0,0" PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin" \
        CLUX_AGENT_STATE_DIR="$BATS_TEST_TMPDIR/store" "$LIST_SCRIPT" 2>/dev/null)"

    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    rm -f "$sockpath" >/dev/null 2>&1 || true

    [ -n "$out" ] || { echo "renderer produced no output"; false; }

    # The configured values arrived — i.e. the batched read really split.
    [[ "$out" == *"fg=#B48EAD,bold"* ]] || { echo "detached name style missing: $out"; false; }
    [[ "$out" == *"fg=#4C566A"*      ]] || { echo "separator style missing: $out"; false; }
    [[ "$out" == *"SEPGLYPH"*        ]] || { echo "separator glyph missing: $out"; false; }

    # No default leaked in as the symptom of an unsplit read...
    [[ "$out" != *"fg=magenta"*     ]] || { echo "fell back to the default name style: $out"; false; }
    [[ "$out" != *"fg=brightblack"* ]] || { echo "fell back to the default separator style: $out"; false; }
    # ...and no separator, raw or escaped, reached the screen.
    [[ "$out" != *'\037'* ]] || { echo "escaped separator leaked into the bar: $out"; false; }
    [[ "$out" != *"$SEP"* ]] || { echo "raw separator leaked into the bar: $out"; false; }
}
