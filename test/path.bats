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
