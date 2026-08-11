#!/usr/bin/env bats
# path.bats — unit tests for resolve_notify_file() in scripts/path.sh

load test_helper

# ---------------------------------------------------------------------------
# Test 1: CLUX_NOTIFY_FILE set (tier 1) — env var takes priority
# ---------------------------------------------------------------------------
@test "resolve_notify_file: CLUX_NOTIFY_FILE set returns that path" {
    run bash -c "
        export CLUX_NOTIFY_FILE=/tmp/custom-queue
        source \"$SCRIPTS_DIR/path.sh\"
        resolve_notify_file
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "/tmp/custom-queue" ]] || false
}

# ---------------------------------------------------------------------------
# Test 2: Sidecar file exists (tier 2) — CLUX_NOTIFY_FILE empty, sidecar present
# ---------------------------------------------------------------------------
@test "resolve_notify_file: sidecar file present returns sidecar path" {
    local fake_home="$BATS_TEST_TMPDIR/fake_home2"
    mkdir -p "$fake_home/.config/clux"
    printf '%s\n' "/tmp/sidecar-queue" > "$fake_home/.config/clux/notify-file-path"

    run bash -c "
        export CLUX_NOTIFY_FILE=
        export HOME=\"$fake_home\"
        source \"$SCRIPTS_DIR/path.sh\"
        resolve_notify_file
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "/tmp/sidecar-queue" ]] || false
}

# ---------------------------------------------------------------------------
# Test 3: Sidecar absent, no env var (tier 3) — HOME default
# ---------------------------------------------------------------------------
@test "resolve_notify_file: no env, no sidecar returns HOME default" {
    local fake_home="$BATS_TEST_TMPDIR/fake_home3"
    mkdir -p "$fake_home"
    # No sidecar directory/file created

    run bash -c "
        export CLUX_NOTIFY_FILE=
        export HOME=\"$fake_home\"
        source \"$SCRIPTS_DIR/path.sh\"
        resolve_notify_file
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "$fake_home/.config/tmux/claude_notification" ]] || false
}

# ---------------------------------------------------------------------------
# Test 4: Sidecar exists but contains only whitespace — falls through to HOME default
# ---------------------------------------------------------------------------
@test "resolve_notify_file: sidecar blank/whitespace falls through to HOME default" {
    local fake_home="$BATS_TEST_TMPDIR/fake_home4"
    mkdir -p "$fake_home/.config/clux"
    printf '   \n\t\n' > "$fake_home/.config/clux/notify-file-path"

    run bash -c "
        export CLUX_NOTIFY_FILE=
        export HOME=\"$fake_home\"
        source \"$SCRIPTS_DIR/path.sh\"
        resolve_notify_file
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "$fake_home/.config/tmux/claude_notification" ]] || false
}

# ---------------------------------------------------------------------------
# Test 5: CLUX_VERSION (path.sh) stays in lockstep with plugin.json's
# "version" field — this is what forces the reinstall after an update.
# ---------------------------------------------------------------------------
@test "path: CLUX_VERSION equals the plugin.json version" {
    local path_version plugin_version
    path_version=$(grep '^CLUX_VERSION=' "$SCRIPTS_DIR/path.sh" | head -1 | cut -d'"' -f2)
    plugin_version=$("$REAL_JQ" -r .version "$SCRIPTS_DIR/../.claude-plugin/plugin.json")
    [ -n "$path_version" ]
    [ -n "$plugin_version" ]
    [ "$path_version" = "$plugin_version" ]
}

# ---------------------------------------------------------------------------
# Test 6: sourcing path.sh is still free — no process spawned, no tmux IPC,
# nothing on stdout/stderr. Enforces the header contract now that a constant
# and two impure functions were added.
# ---------------------------------------------------------------------------
@test "path: sourcing path.sh still costs nothing" {
    local log="$BATS_TEST_TMPDIR/source-stub.log"
    run bash -c "
        export STUB_LOG='$log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        source \"$SCRIPTS_DIR/path.sh\"
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    if [ -f "$log" ]; then
        [ ! -s "$log" ]
    fi
}
