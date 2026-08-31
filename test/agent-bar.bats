#!/usr/bin/env bats
# agent-bar.bats — agent-bar.sh: the standalone renderer backing SKILL.md
# §3.7's own-bar installs.
#
# Two modes, chosen by argument COUNT: zero args is roll-up, one arg (even an
# explicit empty string) is one-column. That dispatch is why the `--frame N`
# pair (animated busy glyph, 2026-08-23 design) must be shifted off BEFORE the
# dispatch runs — a leading option pair is exactly the thing that breaks a
# count-based dispatch, and an unshifted `--frame` would turn
# `agent-bar.sh --frame 2` into one-column mode for a session literally named
# `--frame`.
#
# Cases 1-1b (no `--frame`) are written and MUST PASS against the unmodified
# script first — they pin "byte-identical to today" down before any change
# lands.

load test_helper

BAR_SCRIPT_SRC="$SCRIPTS_DIR/agent-bar.sh"

# _stage <agent-query-output> — a staged copy of agent-bar.sh with helpers.sh/
# path.sh copied beside it (agent-bar.sh sources helpers.sh through
# $CURRENT_DIR) and a stubbed agent-query.sh that just prints the given rows.
# STUB_LOG (if exported) records every agent-query.sh invocation, so a test
# can assert agent-bar.sh never reads @clux_frame_idx through it.
_stage() {
    STAGED_DIR="$BATS_TEST_TMPDIR/staged"
    mkdir -p "$STAGED_DIR"
    cp "$SCRIPTS_DIR/agent-bar.sh" "$STAGED_DIR/"
    cp "$SCRIPTS_DIR/helpers.sh" "$STAGED_DIR/"
    cp "$SCRIPTS_DIR/path.sh" "$STAGED_DIR/"
    chmod +x "$STAGED_DIR/agent-bar.sh"
    printf '#!/usr/bin/env bash\necho "agent-query $*" >> "${STUB_LOG:-/dev/null}"\nprintf %%s %s\n' \
        "$(printf '%q' "$1")" > "$STAGED_DIR/agent-query.sh"
    chmod +x "$STAGED_DIR/agent-query.sh"
}

# ---------------------------------------------------------------------------
# Case 1 / 1b: no --frame is byte-identical to today. Run against the
# UNMODIFIED script (not staged) first, then again staged, so both prove it.
# ---------------------------------------------------------------------------
@test "agent-bar: no --frame, roll-up mode, one busy session (unmodified script)" {
    _stage $'alpha\tbusy'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh'
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=cyan]*#[default]alpha' ]
}

@test "agent-bar: no --frame, one-column mode for a named session (unmodified script)" {
    _stage $'alpha\tneeds-you'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' alpha
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=yellow]!#[default]' ]
}

@test "agent-bar: --frame 2 stays roll-up mode (zero args after the shift), busy glyph is frame 2" {
    _stage $'alpha\tbusy'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' --frame 2
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=cyan]|#[default]alpha' ]
}

@test "agent-bar: --frame 2 <session> stays one-column mode, busy glyph is frame 2" {
    _stage $'my-session\tbusy'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' --frame 2 my-session
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=cyan]|#[default]' ]
}

@test "agent-bar: --frame 3 '' is one-column mode with an explicitly empty name" {
    _stage ''
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' --frame 3 ''
    "
    [ "$status" -eq 0 ]
    [ "$output" = ' ' ]
}

@test "agent-bar: --frame changes only the busy glyph — needs-you and finished are unaffected" {
    _stage $'alpha\tneeds-you'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' --frame 2 alpha
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=yellow]!#[default]' ]

    _stage $'alpha\tfinished'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' --frame 2 alpha
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=green]v#[default]' ]
}

@test "agent-bar: --frame with a non-numeric value is frame 0, and the value IS consumed" {
    _stage $'my-session\tbusy'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' --frame x my-session
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=cyan]-#[default]' ]
}

@test "agent-bar: --frame as the last argument with no value is frame 0, roll-up mode" {
    _stage $'alpha\tbusy'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' --frame
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=cyan]-#[default]alpha' ]
}

@test "agent-bar: never reads @clux_frame_idx — stays a pure function of its arguments" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _stage $'alpha\tbusy'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$STAGED_DIR/agent-bar.sh' --frame 2
    "
    [ "$status" -eq 0 ]
    run grep -qF '@clux_frame_idx' "$log"
    [ "$status" -ne 0 ]
}

@test "agent-bar: failed renders the fail glyph in the fail colour (defaults x / red), in both modes" {
    _stage $'alpha\tfailed'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' alpha
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=red]x#[default]' ]
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        '$STAGED_DIR/agent-bar.sh' --frame 3
    "
    [ "$status" -eq 0 ]
    [ "$output" = '#[fg=red]x#[default]alpha' ]
}
