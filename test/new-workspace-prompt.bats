#!/usr/bin/env bats
# new-workspace-prompt.bats — new-workspace-prompt.sh: step 1 of prefix + A.
# Validates the typed session name, stores it in the transient
# @clux-new-workspace-name option (never in a tmux command string), then
# issues the second command-prompt for the folder.

load test_helper

PROMPT_SCRIPT="$SCRIPTS_DIR/new-workspace-prompt.sh"

@test "new-workspace-prompt: an empty name (cancelled prompt) is a silent no-op" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        '$PROMPT_SCRIPT' ''
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -qF 'set-option' "$log"
    [ "$status" -ne 0 ]
}

@test "new-workspace-prompt: a valid name is stored in @clux-new-workspace-name and a folder prompt is issued" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        '$PROMPT_SCRIPT' 'work'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux-new-workspace-name work' "$log" || false
    grep -qF 'command-prompt -I work/ -p Folder name:' "$log" || false
    # The higher-risk name never itself reaches a run-shell command string.
    run grep -qF "new-workspace.sh \"work\"" "$log"
    [ "$status" -ne 0 ]
}

@test "new-workspace-prompt: a name containing a quote is rejected and never stored" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        '$PROMPT_SCRIPT' \"bad'name\"
    "
    [ "$status" -eq 0 ]
    grep -qF 'display-message' "$log" || false
    run grep -qF 'set-option -g @clux-new-workspace-name' "$log"
    [ "$status" -ne 0 ]
}

@test "new-workspace-prompt: a name containing a # is rejected" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        '$PROMPT_SCRIPT' 'bad#name'
    "
    [ "$status" -eq 0 ]
    grep -qF 'display-message' "$log" || false
    run grep -qF 'set-option -g @clux-new-workspace-name'  "$log"
    [ "$status" -ne 0 ]
}

@test "new-workspace-prompt: a name containing a semicolon is rejected" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        '$PROMPT_SCRIPT' 'bad;name'
    "
    [ "$status" -eq 0 ]
    grep -qF 'display-message' "$log" || false
    run grep -qF 'set-option -g @clux-new-workspace-name'  "$log"
    [ "$status" -ne 0 ]
}
