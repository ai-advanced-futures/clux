#!/usr/bin/env bats
# session-picker.bats — session-picker.sh: prefix + g. @clux-picker names the
# preferred picker, but the fzf/fzf-tmux binary is re-checked at run time
# regardless of the option, and a missing binary always still leaves a
# working key (choose-tree, plus one display-message).

load test_helper

PICKER_SCRIPT="$SCRIPTS_DIR/session-picker.sh"

_write_picker_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    show-option)
        case "$*" in
            *@clux-session-order*) printf '%s\n' "${FAKE_ORDER:-}" ;;
            *@clux-picker*) printf '%s\n' "${FAKE_PICKER:-}" ;;
        esac
        ;;
    list-sessions)
        case "$3" in
            *session_id*) [ -n "${FAKE_SESSIONS:-}" ] && printf '%s\n' "${FAKE_SESSIONS}" ;;
            *session_windows*) [ -n "${FAKE_META:-}" ] && printf '%s\n' "${FAKE_META}" ;;
        esac
        ;;
    display-message)
        [ -n "${FAKE_CURRENT:-}" ] && printf '%s\n' "${FAKE_CURRENT}"
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "session-picker: falls back to choose-tree when neither fzf nor fzf-tmux is on PATH" {
    _write_picker_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    # Remove the committed fzf/fzf-tmux stubs and use a PATH that excludes
    # wherever the real binaries live on this machine (Homebrew et al.), so
    # "have_fzf_tmux"/"have_fzf" both genuinely fail.
    rm -f "$BATS_TEST_TMPDIR/stubs/fzf" "$BATS_TEST_TMPDIR/stubs/fzf-tmux"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin'
        export STUB_LOG='$log'
        export FAKE_CURRENT='current'
        export FAKE_PICKER='fzf'
        '$PICKER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    grep -qF 'choose-tree -Zs' "$log" || false
    grep -qF "clux: fzf not found, using choose-tree" "$log" || false
}

@test "session-picker: @clux-picker=choose-tree always runs choose-tree, without checking for fzf" {
    _write_picker_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_CURRENT='current'
        export FAKE_PICKER='choose-tree'
        '$PICKER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    grep -qF 'choose-tree -Zs' "$log" || false
    run grep -qF 'fzf' "$log"
    [ "$status" -ne 0 ]
}

@test "session-picker: no other sessions prints the message and never invokes a picker" {
    _write_picker_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_CURRENT='solo'
        export FAKE_PICKER='fzf'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\tsolo'
        '$PICKER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    grep -qF 'No other sessions' "$log" || false
    run grep -qF 'switch-client' "$log"
    [ "$status" -ne 0 ]
}

@test "session-picker: selecting a session via fzf-tmux switches to it, excluding the current session" {
    _write_picker_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    local fzf_input="$BATS_TEST_TMPDIR/fzf-tmux.input"
    cat > "$BATS_TEST_TMPDIR/stubs/fzf-tmux" <<STUBEOF
#!/usr/bin/env bash
echo "fzf-tmux \$*" >> "\${STUB_LOG:-/dev/null}"
cat > "$fzf_input"
printf 'other\tother: 2 windows\n'
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/fzf-tmux"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        export FAKE_CURRENT='current'
        export FAKE_PICKER='fzf'
        export FAKE_ORDER=''
        export FAKE_SESSIONS=\$'\$0\tcurrent\n\$1\tother'
        export FAKE_META=\$'current\t1\t1\nother\t2\t0'
        '$PICKER_SCRIPT'
    "
    [ "$status" -eq 0 ]
    grep -qF 'switch-client -t other' "$log" || false
    # The current session must never be offered to fzf-tmux at all.
    run grep -F 'current' "$fzf_input"
    [ "$status" -ne 0 ]
}
