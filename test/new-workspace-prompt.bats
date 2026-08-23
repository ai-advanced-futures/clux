#!/usr/bin/env bats
# new-workspace-prompt.bats — new-workspace-prompt.sh: both steps of prefix + A.
#
# The script now runs inside `tmux display-popup -E` and reads BOTH answers
# itself, so neither one ever reaches a tmux command string. The tests match:
# the happy path is driven through a real pty (a pane on a throwaway tmux
# server) with real keystrokes, because a `read` from a pipe would not exercise
# the code path the popup actually takes.
#
# REAL_TMUX is captured at file-load time, before test_helper's setup()
# prepends the stub directory to PATH — the same pattern REAL_JQ uses.
#
# The test this file exists for is the injection one at the bottom. Before the
# change, `bind-key A` handed the typed name to tmux's command-prompt, which
# substitutes into its command template BEFORE parsing it; typing
# `ws" ; touch FILE ; "` created FILE. That could not be tested here at all,
# because the fault lived in the binding and fired before this script started.
# It is now testable from two sides: this file proves the script rejects the
# name, and render-clux-conf.bats proves no emitted binding carries a `%1`
# substitution for anything to break out of.

load test_helper

REAL_TMUX="$(command -v tmux)"
PROMPT_SCRIPT="$SCRIPTS_DIR/new-workspace-prompt.sh"

# Stage the script with a recording stand-in for new-workspace.sh beside it:
# the prompt resolves its sibling through $CURRENT_DIR and `exec`s it, so a
# stand-in in the same directory is what makes the hand-off observable.
_stage() {
    STAGE="$BATS_TEST_TMPDIR/staged"
    mkdir -p "$STAGE"
    cp "$PROMPT_SCRIPT" "$STAGE/new-workspace-prompt.sh"
    # The prompt sources helpers.sh for its colours, and helpers.sh sources
    # path.sh. Both resolve through $CURRENT_DIR, so both belong beside the
    # staged copy — without them the styles come out empty and every run
    # prints "get_tmux_option: command not found" into the popup.
    cp "$SCRIPTS_DIR/helpers.sh" "$SCRIPTS_DIR/path.sh" "$STAGE/"
    cat > "$STAGE/new-workspace.sh" <<'STUB'
#!/usr/bin/env bash
# Records what the prompt handed over, then exits so the popup would close.
printf 'FOLDER=%s\n' "$1" >> "$RECORD"
printf 'NAME=%s\n' "$(tmux show-option -gqv @clux-new-workspace-name)" >> "$RECORD"
STUB
    chmod +x "$STAGE/new-workspace-prompt.sh" "$STAGE/new-workspace.sh"
    RECORD="$BATS_TEST_TMPDIR/record"
    : > "$RECORD"
}

# Run the staged prompt in a real pane on a throwaway server, type $@ as
# separate lines, and wait for the pane to finish. Uses the REAL tmux: the
# point is a genuine tty and a genuine option round-trip.
_run_in_pty() {
    SOCKET="clux-prompt-$$-${BATS_TEST_NUMBER}"
    "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    # The trailing sleep keeps the session — and therefore the server, and
    # therefore the option — alive after the script finishes, so the
    # assertions below have something to read. It is reached even though the
    # script ends in `exec`: tmux runs this string through `sh -c`, the script
    # is a forked child of that shell, and `exec` replaces only the child.
    "$REAL_TMUX" -L "$SOCKET" new-session -d -x 80 -y 24 \
        "RECORD='$RECORD' PATH='$(dirname "$REAL_TMUX"):/usr/bin:/bin' '$STAGE/new-workspace-prompt.sh'; sleep 30"
    sleep 1
    local line
    for line in "$@"; do
        "$REAL_TMUX" -L "$SOCKET" send-keys -l "$line"
        "$REAL_TMUX" -L "$SOCKET" send-keys Enter
        sleep 0.5
    done
    sleep 1
    PANE_TEXT="$("$REAL_TMUX" -L "$SOCKET" capture-pane -p 2>/dev/null)"
    OPT_AFTER="$("$REAL_TMUX" -L "$SOCKET" show-option -gqv @clux-new-workspace-name 2>/dev/null)"
    "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET" >/dev/null 2>&1 || true
}

# Polls the pane instead of sleeping a flat worst case. How long tmux needs to
# start a pane, and the script to draw into it, is the machine's business — a
# fixed sleep is either slower than it has to be or shorter than it can afford.
# Prints the last screen it read either way, so a failing caller can show it.
_wait_for_screen() {
    local sock="$1" needle="$2" tries="${3:-40}" screen=""
    while [ "$tries" -gt 0 ]; do
        screen="$("$REAL_TMUX" -L "$sock" capture-pane -p 2>/dev/null)"
        case "$screen" in *"$needle"*) printf '%s' "$screen"; return 0 ;; esac
        sleep 0.1
        tries=$((tries - 1))
    done
    printf '%s' "$screen"
    return 1
}

# The mirror of the above: waits for the pane to stop showing something, and
# treats a server that has exited as success — a cancelled prompt takes the
# whole pane with it, so "gone" is the expected end state either way.
_wait_for_gone() {
    local sock="$1" needle="$2" tries="${3:-40}"
    while [ "$tries" -gt 0 ]; do
        "$REAL_TMUX" -L "$sock" has-session >/dev/null 2>&1 || return 0
        case "$("$REAL_TMUX" -L "$sock" capture-pane -p 2>/dev/null)" in
            *"$needle"*) ;;
            *) return 0 ;;
        esac
        sleep 0.1
        tries=$((tries - 1))
    done
    return 1
}

@test "new-workspace-prompt: with no tty it refuses to run and says to re-run setup" {
    # The shape a stale clux.tmux.conf produces: the old binding called this
    # through run-shell, which has no tty. `read` would hit EOF at once and the
    # key would look silently broken.
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export STUB_LOG='$log'
        '$PROMPT_SCRIPT' < /dev/null
    "
    [ "$status" -eq 0 ]
    grep -qF 'display-message' "$log" || { echo "no message shown"; false; }
    grep -qF 're-run /clux:setup' "$log" || { echo "message does not say what to do"; false; }
    run grep -qF 'set-option' "$log"
    [ "$status" -ne 0 ]
}

@test "new-workspace-prompt: name then folder are both read from the popup and handed on" {
    _stage
    _run_in_pty "work" "projects/work"
    grep -qF 'FOLDER=projects/work' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "pane: $PANE_TEXT"; false; }
    grep -qF 'NAME=work' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "new-workspace-prompt: an empty folder falls back to the session name" {
    _stage
    _run_in_pty "solo" ""
    grep -qF 'FOLDER=solo' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "pane: $PANE_TEXT"; false; }
}

@test "new-workspace-prompt: an empty name cancels without storing anything" {
    _stage
    _run_in_pty ""
    [ ! -s "$RECORD" ] || { echo "record should be empty: $(cat "$RECORD")"; false; }
    [ -z "$OPT_AFTER" ] || { echo "option was written: $OPT_AFTER"; false; }
}

@test "new-workspace-prompt: a name carrying a shell command runs nothing — the injection regression" {
    _stage
    local marker="$BATS_TEST_TMPDIR/PWNED"
    rm -f "$marker"
    # Byte-for-byte the payload that created a file through the old
    # command-prompt binding.
    _run_in_pty "ws\" ; touch $marker ; \""
    [ ! -e "$marker" ] || { echo "the typed command EXECUTED"; false; }
    [ ! -s "$RECORD" ] || { echo "a workspace was created anyway: $(cat "$RECORD")"; false; }
    [ -z "$OPT_AFTER" ] || { echo "the rejected name was stored: $OPT_AFTER"; false; }
}

@test "new-workspace-prompt: a name containing a single quote is rejected, not truncated" {
    _stage
    # The old binding created a workspace called "bad" for this input, silently
    # dropping everything from the quote on.
    _run_in_pty "bad'name"
    [ ! -s "$RECORD" ] || { echo "a workspace was created: $(cat "$RECORD")"; false; }
    [ -z "$OPT_AFTER" ] || { echo "the rejected name was stored: $OPT_AFTER"; false; }
}

@test "new-workspace-prompt: a name containing a semicolon or a # is rejected" {
    _stage
    _run_in_pty "bad;name"
    [ ! -s "$RECORD" ] || { echo "semicolon accepted: $(cat "$RECORD")"; false; }

    _stage
    _run_in_pty "bad#name"
    [ ! -s "$RECORD" ] || { echo "# accepted: $(cat "$RECORD")"; false; }
}

# tmux ACCEPTS a colon in a session name but reads it as the session/window
# separator in every target, so "a:b" builds a workspace nothing can address:
# has-session says "can't find session: a", new-window says "can't find
# window: b". The name has to be refused here, before new-workspace.sh runs.
@test "new-workspace-prompt: a name containing a colon is rejected" {
    _stage
    _run_in_pty "bad:name"
    [ ! -s "$RECORD" ] || { echo "colon accepted: $(cat "$RECORD")"; false; }
}

@test "new-workspace-prompt: no printf carries a \u escape bash 3.2 cannot expand" {
    # bash 3.2 is what macOS ships, and its printf has no \u — it prints the
    # six characters verbatim, so the popup showed "\u25b8 name". Literal UTF-8
    # is the only form every supported bash renders.
    run grep -n '\\u[0-9a-fA-F]\{4\}' "$PROMPT_SCRIPT"
    [ "$status" -ne 0 ] \
        || { echo "a \\u escape survives, and bash 3.2 will print it literally:"; echo "$output"; false; }
}

@test "new-workspace-prompt: the popup draws its markers, not escape text" {
    # Drives the real script through a pty the way the popup does, and reads
    # back what landed on screen. This is the check that would have caught the
    # \u regression from the user's side rather than from the source's.
    _stage
    local sock="clux-test-$$-draw"
    "$REAL_TMUX" -L "$sock" -f /dev/null new-session -d -x 62 -y 7 \
        "$STAGE/new-workspace-prompt.sh" 2>/dev/null
    local screen
    screen="$(_wait_for_screen "$sock" "New workspace")" || true
    "$REAL_TMUX" -L "$sock" kill-server 2>/dev/null || true

    [[ "$screen" != *'\u'* ]] \
        || { echo "an unexpanded escape reached the screen:"; echo "$screen"; false; }
    [[ "$screen" == *"New workspace"* ]] \
        || { echo "the header never drew:"; echo "$screen"; false; }
    [[ "$screen" == *"name"* ]] \
        || { echo "the name prompt never drew:"; echo "$screen"; false; }
}

@test "new-workspace-prompt: Esc cancels the prompt instead of typing ^[" {
    # Esc used to be an ordinary character in the line: it echoed "^[" and the
    # prompt kept waiting, so the only way out of the popup was Ctrl-C. The
    # terminal now carries Esc as its interrupt character, so Esc takes the
    # same path Ctrl-C did.
    _stage
    local sock="clux-test-$$-esc-${BATS_TEST_NUMBER}"
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    "$REAL_TMUX" -L "$sock" new-session -d -x 62 -y 10 \
        "RECORD='$RECORD' PATH='$(dirname "$REAL_TMUX"):/usr/bin:/bin' '$STAGE/new-workspace-prompt.sh'; sleep 20"
    _wait_for_screen "$sock" "New workspace" >/dev/null \
        || { echo "the prompt never drew, so Esc was never the thing under test"; false; }
    "$REAL_TMUX" -L "$sock" send-keys -l "partial"
    _wait_for_screen "$sock" "partial" >/dev/null \
        || { echo "the typed text never echoed, so nothing was waiting for Esc"; false; }
    "$REAL_TMUX" -L "$sock" send-keys Escape
    _wait_for_gone "$sock" "partial" || true

    # The interrupt reaches the whole foreground process group, so the pane
    # ends with the script. Either the server is gone or no prompt is left.
    local alive=0
    "$REAL_TMUX" -L "$sock" has-session >/dev/null 2>&1 && alive=1
    local screen=""
    [ "$alive" -eq 1 ] && screen="$("$REAL_TMUX" -L "$sock" capture-pane -p 2>/dev/null)"
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true

    if [ "$alive" -eq 1 ]; then
        [[ "$screen" != *"partial"* ]] \
            || { echo "Esc left the prompt waiting with the text still typed:"; echo "$screen"; false; }
    fi

    # And nothing was created or stored on the way out.
    [ ! -s "$RECORD" ] || { echo "a cancelled prompt still handed over:"; cat "$RECORD"; false; }
}
