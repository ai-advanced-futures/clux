#!/usr/bin/env bats
# notification-line.bats — scripts/notification-line.sh: the one parse of one
# queue line, shared by the tmux keys (prefix + m, prefix + M) and the Claude
# Code notifications pane. Before this script, jump-to-notification.sh and
# notification-picker.sh each carried their own copy of the parse.

load test_helper

SCRIPT="$SCRIPTS_DIR/notification-line.sh"

# ---------------------------------------------------------------------------
# path — the three tiers of resolve_notify_file(), through the script
# ---------------------------------------------------------------------------
@test "notification-line path: prints CLUX_NOTIFY_FILE when it is set" {
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        bash '$SCRIPT' path
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$QUEUE_FILE" ]
}

@test "notification-line path: prints the sidecar path when only the sidecar is set" {
    mkdir -p "$HOME/.config/clux"
    printf '%s\n' "/tmp/sidecar-queue" > "$HOME/.config/clux/notify-file-path"

    run bash -c "
        export CLUX_NOTIFY_FILE=
        bash '$SCRIPT' path
    "
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp/sidecar-queue" ]
}

@test "notification-line path: prints the HOME default with no env and no sidecar" {
    run bash -c "
        export CLUX_NOTIFY_FILE=
        bash '$SCRIPT' path
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.config/tmux/claude_notification" ]
}

@test "notification-line: an unknown verb exits 2" {
    run bash "$SCRIPT" wobble
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# remove — an EQUAL line only, under the queue lock
# ---------------------------------------------------------------------------
@test "notification-line remove: removes an equal line and keeps a longer line that holds it" {
    local short='main:editor done|||$sess1:@win3'
    local long="prefix $short"
    printf '%s\n%s\n' "$short" "$long" > "$QUEUE_FILE"

    run bash "$SCRIPT" remove "$short"
    [ "$status" -eq 0 ]
    run grep -qxF "$short" "$QUEUE_FILE"
    [ "$status" -ne 0 ]
    grep -qxF "$long" "$QUEUE_FILE" || false
}

@test "notification-line remove: deletes the queue file when the last line goes" {
    local line='main:editor done|||$sess1:@win3'
    printf '%s\n' "$line" > "$QUEUE_FILE"

    run bash "$SCRIPT" remove "$line"
    [ "$status" -eq 0 ]
    [ ! -e "$QUEUE_FILE" ]
}

@test "notification-line remove: a line that is not there is exit 0 and changes nothing" {
    local line='main:editor done|||$sess1:@win3'
    printf '%s\n' "$line" > "$QUEUE_FILE"

    run bash "$SCRIPT" remove 'main:other gone|||$sess1:@win9'
    [ "$status" -eq 0 ]
    grep -qxF "$line" "$QUEUE_FILE" || false
}

@test "notification-line remove: a line that starts with - is a pattern, and the rest of the queue stays" {
    local dash='-main:editor done|||$sess1:@win3'
    local keep='main:tests green|||$sess1:@win5'
    printf '%s\n%s\n' "$dash" "$keep" > "$QUEUE_FILE"

    run bash "$SCRIPT" remove "$dash"
    [ "$status" -eq 0 ]
    [ "$(cat "$QUEUE_FILE")" = "$keep" ]
}

@test "notification-line remove: a queue grep cannot read stays, and the remove exits 1" {
    local line='main:editor done|||$sess1:@win3'
    printf '%s\n' "$line" > "$QUEUE_FILE"
    chmod 000 "$QUEUE_FILE"
    # root reads a mode 000 file, so the case proves nothing there.
    if cat "$QUEUE_FILE" >/dev/null 2>&1; then
        chmod 644 "$QUEUE_FILE"
        skip "this user can read a mode 000 file"
    fi

    run bash "$SCRIPT" remove "$line"
    chmod 644 "$QUEUE_FILE"
    [ "$status" -eq 1 ]
    grep -qxF "$line" "$QUEUE_FILE" || false
    [ ! -e "${QUEUE_FILE}.tmp" ]
}

@test "notification-line remove: a missing queue file is exit 0 and takes no lock" {
    rm -f "$QUEUE_FILE"

    run bash "$SCRIPT" remove 'main:editor done|||$sess1:@win3'
    [ "$status" -eq 0 ]
    [ ! -d "${QUEUE_FILE}.lock" ]
}

@test "notification-line remove: exits 1 while a fresh lock directory is held" {
    local line='main:editor done|||$sess1:@win3'
    printf '%s\n' "$line" > "$QUEUE_FILE"
    mkdir "${QUEUE_FILE}.lock"

    run bash "$SCRIPT" remove "$line"
    [ "$status" -eq 1 ]
    # The line is still in the queue, and the lock is still the holder's.
    grep -qxF "$line" "$QUEUE_FILE" || false
    [ -d "${QUEUE_FILE}.lock" ]
    rmdir "${QUEUE_FILE}.lock"
}

@test "notification-line remove: exits 1 while a writer holds the flock lock" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local line='main:editor done|||$sess1:@win3'
    printf '%s\n' "$line" > "$QUEUE_FILE"

    # A writer (acquire_lock in helpers.sh) holds "<queue>.flock": flock times
    # out. The committed stub always succeeds, so this test replaces it.
    cat > "$BATS_TEST_TMPDIR/stubs/flock" <<'STUBEOF'
#!/usr/bin/env bash
echo "flock $*" >> "${STUB_LOG:-/dev/null}"
exit 1
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/flock"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' remove '$line'
    "
    [ "$status" -eq 1 ]
    grep -qF 'flock -w' "$stub_log" || false
    grep -qxF "$line" "$QUEUE_FILE" || false
    [ -f "${QUEUE_FILE}.flock" ]
    [ ! -d "${QUEUE_FILE}.lock" ]
}

@test "notification-line remove: removes from the sidecar queue when only the sidecar is set" {
    local sidecar_queue="$BATS_TEST_TMPDIR/sidecar-queue"
    local line='main:editor done|||$sess1:@win3'
    mkdir -p "$HOME/.config/clux"
    printf '%s\n' "$sidecar_queue" > "$HOME/.config/clux/notify-file-path"
    printf '%s\n' "$line" > "$sidecar_queue"

    run bash -c "
        export CLUX_NOTIFY_FILE=
        bash '$SCRIPT' remove '$line'
    "
    [ "$status" -eq 0 ]
    [ ! -e "$sidecar_queue" ]
}

# ---------------------------------------------------------------------------
# jump — a window line, by id, by the legacy marker, and by name
# ---------------------------------------------------------------------------
@test "notification-line jump: a ||| id line selects the window and switches the client" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump 'main:editor Task done|||\$sess1:@win3'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t $sess1:@win3' "$stub_log" || false
    grep -qF 'switch-client -t $sess1' "$stub_log" || false
}

@test "notification-line jump: a legacy |ID: line selects the window by id too" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump 'main:editor Task done|ID:\$sess1:@win3'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t $sess1:@win3' "$stub_log" || false
}

@test "notification-line jump: a line with no marker falls back to the name parse" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump 'main:editor Task done'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t main:editor' "$stub_log" || false
    grep -qF 'switch-client -t main' "$stub_log" || false
}

@test "notification-line jump: a line with no target exits 1 and calls no tmux" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump 'a notification with no target at all'
    "
    [ "$status" -eq 1 ]
    [ ! -f "$stub_log" ] || [ ! -s "$stub_log" ]
}

@test "notification-line jump: an empty line exits 1" {
    run bash "$SCRIPT" jump ''
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# jump — an agent line. The agent check MUST run before the generic |||
# check: an agent line also holds |||, and the generic branch would try
# `tmux select-window -t "agent:<sid>"`.
# ---------------------------------------------------------------------------
@test "notification-line jump: a new-format agent line fast-paths to the embedded pane and clears it" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # The fast-path probe must find %pane3 alive (bare pane_id listing); the
    # cwd resolver's listing (it asks for pane_current_path) stays empty, so
    # the fast path is the one taken.
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    case "$*" in
        *pane_current_path*) : ;;
        *) printf '%%pane3\n' ;;
    esac
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    printf '⚡ agents / x|||agent:abc-123@@$s9:@w9:%%pane3@@/c\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump '⚡ agents / x|||agent:abc-123@@\$s9:@w9:%pane3@@/c'
    "
    [ "$status" -eq 0 ]
    # Routed by the embedded pane id (the last colon token of segment 2).
    grep -qF 'send-keys -t %pane3' "$stub_log" || false
    # Only this branch asks for the redraw.
    grep -qF 'refresh-client -S' "$stub_log" || false
    # Clear-on-jump took the entry out.
    run grep -qF '|||agent:abc-123@@' "$QUEUE_FILE"
    [ "$status" -ne 0 ]
}

@test "notification-line jump: an agent line with no tmux server exits 1 and keeps the line" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
[ "$1" = "list-sessions" ] && exit 1
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    local line='⚡ agents / x|||agent:abc-123@@$s9:@w9:%pane3@@/c'
    printf '%s\n' "$line" > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump '⚡ agents / x|||agent:abc-123@@\$s9:@w9:%pane3@@/c'
    "
    [ "$status" -eq 1 ]
    grep -qxF "$line" "$QUEUE_FILE" || false
    run grep -E 'switch-client|select-window|new-window|send-keys' "$stub_log"
    [ "$status" -ne 0 ]
}

@test "notification-line jump: an agent line never reaches the generic ||| parse" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    printf '⚡ needs input|||agent:s-abc-123\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump '⚡ needs input|||agent:s-abc-123'
    "
    [ "$status" -eq 0 ]
    # The legacy line has no coordinates, so agent_jump opens the agents view.
    grep -qF "new-window" "$stub_log" || false
    run grep -F "select-window -t agent:" "$stub_log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The callers. Both tmux keys now run this script, and both resolve the queue
# with the three tiers of resolve_notify_file(), as the status bar does. They
# used to read two tiers and ignore the sidecar file.
# ---------------------------------------------------------------------------
@test "jump-to-notification: jumps to the top line of the sidecar queue" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local sidecar_queue="$BATS_TEST_TMPDIR/sidecar-queue"
    mkdir -p "$HOME/.config/clux"
    printf '%s\n' "$sidecar_queue" > "$HOME/.config/clux/notify-file-path"
    printf 'main:editor Task done|||$sess1:@win3\n' > "$sidecar_queue"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE=
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t $sess1:@win3' "$stub_log" || false
}

@test "notification-picker: Ctrl-D removes an equal line and keeps a longer line that holds it" {
    local short='main:editor done|||$sess1:@win3'
    local long="prefix $short"
    printf '%s\n%s\n' "$short" "$long" > "$QUEUE_FILE"

    run bash -c "
        export FZF_STUB_KEY='ctrl-d'
        export FZF_STUB_LINE='main:editor done|||\$sess1:@win3'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    run grep -qxF "$short" "$QUEUE_FILE"
    [ "$status" -ne 0 ]
    grep -qxF "$long" "$QUEUE_FILE" || false
}

@test "notification-picker: Enter on an interactive line jumps by id, never by name" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    printf 'main:editor Task done|||$sess1:@win3\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export FZF_STUB_KEY=''
        export FZF_STUB_LINE='main:editor Task done|||\$sess1:@win3'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t $sess1:@win3' "$stub_log" || false
    run grep -F 'select-window -t main:editor' "$stub_log"
    [ "$status" -ne 0 ]
}

@test "notification-picker: Ctrl-D removes from the sidecar queue" {
    local sidecar_queue="$BATS_TEST_TMPDIR/sidecar-queue"
    local line='main:editor done|||$sess1:@win3'
    mkdir -p "$HOME/.config/clux"
    printf '%s\n' "$sidecar_queue" > "$HOME/.config/clux/notify-file-path"
    printf '%s\n' "$line" > "$sidecar_queue"

    run bash -c "
        export CLUX_NOTIFY_FILE=
        export FZF_STUB_KEY='ctrl-d'
        export FZF_STUB_LINE='main:editor done|||\$sess1:@win3'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    [ ! -e "$sidecar_queue" ]
}
