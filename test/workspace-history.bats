#!/usr/bin/env bats
# workspace-history.bats — workspace-history.sh: the saved workspaces that
# prefix + A lists. One "<name><TAB><folder>" line each, newest first, 9 at
# most, under XDG_STATE_HOME.

load test_helper

HIST="$SCRIPTS_DIR/workspace-history.sh"

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
}

@test "workspace-history: the file is under XDG_STATE_HOME" {
    run "$HIST" path
    [ "$status" -eq 0 ]
    [ "$output" = "$XDG_STATE_HOME/clux/workspaces" ]
}

@test "workspace-history: list of a missing file is empty, not an error" {
    run "$HIST" list
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workspace-history: add puts the newest workspace on top" {
    "$HIST" add one /a
    "$HIST" add two /b
    run "$HIST" list
    [ "${lines[0]}" = $'two\t/b' ]
    [ "${lines[1]}" = $'one\t/a' ]
}

@test "workspace-history: add of a saved name moves it to the top, one line only" {
    "$HIST" add one /a
    "$HIST" add two /b
    "$HIST" add one /a2
    run "$HIST" list
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = $'one\t/a2' ]
    [ "${lines[1]}" = $'two\t/b' ]
}

@test "workspace-history: the list keeps 9 workspaces, so 1-9 reach each row" {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11; do "$HIST" add "w$i" "/d$i"; done
    run "$HIST" list
    [ "${#lines[@]}" -eq 9 ]
    [ "${lines[0]}" = $'w11\t/d11' ]
    [ "${lines[8]}" = $'w3\t/d3' ]
}

@test "workspace-history: remove deletes one line and keeps the order" {
    "$HIST" add one /a
    "$HIST" add two /b
    "$HIST" add three /c
    "$HIST" remove two
    run "$HIST" list
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = $'three\t/c' ]
    [ "${lines[1]}" = $'one\t/a' ]
    "$HIST" remove three
    "$HIST" remove one
    run "$HIST" list
    [ -z "$output" ]
}

@test "workspace-history: set-dir changes the folder and keeps the place" {
    "$HIST" add one /a
    "$HIST" add two /b
    "$HIST" set-dir one /new
    run "$HIST" list
    [ "${lines[0]}" = $'two\t/b' ]
    [ "${lines[1]}" = $'one\t/new' ]
}

@test "workspace-history: a name is matched exactly, not as a pattern" {
    # awk -v would read the backslash as an escape; ENVIRON does not.
    "$HIST" add 'a.b' '/x\new'
    "$HIST" add 'axb' /y
    "$HIST" remove 'a.b'
    run "$HIST" list
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = $'axb\t/y' ]
    "$HIST" add 'p' '/x\new'
    run "$HIST" list
    [ "${lines[0]}" = $'p\t/x\\new' ]
}

@test "workspace-history: a TAB or a newline in a value is refused" {
    run "$HIST" add $'a\tb' /a
    [ "$status" -eq 1 ]
    run "$HIST" add a $'/x\ny'
    [ "$status" -eq 1 ]
    run "$HIST" list
    [ -z "$output" ]
}

@test "workspace-history: only the user can read the file" {
    "$HIST" add one /a
    local mode
    mode=$(stat -c '%a' "$XDG_STATE_HOME/clux/workspaces" 2>/dev/null \
        || stat -f '%Lp' "$XDG_STATE_HOME/clux/workspaces")
    [ "$mode" = "600" ]
}

@test "workspace-history: a bad command prints the usage" {
    run "$HIST" nope
    [ "$status" -eq 2 ]
    [[ "$output" == *usage* ]]
}
