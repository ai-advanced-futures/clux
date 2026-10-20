#!/usr/bin/env bats
# new-workspace-prompt.bats — new-workspace-prompt.sh: prefix + A.
#
# The script runs inside `tmux display-popup -E`: an fzf text box for the name
# (or a plain name prompt without fzf), then a plain folder question for a new
# name. It reads every answer itself, so no answer ever reaches a tmux command
# string. Three layers of tests:
#
#   1. the --fzf helper mode, alone: fzf's state in, fzf actions out. This is
#      where the box's state lives (new / open / switch to, picked or not), so
#      each event is checked here with no tmux and no fzf;
#   2. the box through a real pty (a pane on a throwaway tmux server) with real
#      keys, because a `read` or an fzf from a pipe would not take the path
#      the popup takes;
#   3. the plain prompts, on a PATH that holds no fzf.
#
# REAL_TMUX is captured at file-load time, before test_helper's setup()
# prepends the stub directory to PATH — the same pattern REAL_JQ uses.
#
# The test this file exists for is the injection one. Before the popup,
# `bind-key A` handed the typed name to tmux's command-prompt, which
# substitutes into its command template BEFORE parsing it; typing
# `ws" ; touch FILE ; "` created FILE. It is testable from two sides: this file
# proves the script rejects the name, and render-clux-conf.bats proves no
# emitted binding carries a `%1` substitution for anything to break out of.

load test_helper

REAL_TMUX="$(command -v tmux)"
PROMPT_SCRIPT="$SCRIPTS_DIR/new-workspace-prompt.sh"
HIST="$SCRIPTS_DIR/workspace-history.sh"

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
    cp "$SCRIPTS_DIR/helpers.sh" "$SCRIPTS_DIR/path.sh" "$SCRIPTS_DIR/workspace-history.sh" "$STAGE/"
    cat > "$STAGE/new-workspace.sh" <<'STUB'
#!/usr/bin/env bash
# --resolve is what Ctrl-E asks for a new folder: an existing folder only.
if [ "$1" = --resolve ]; then (cd "$2" 2>/dev/null && pwd); exit; fi
# Records what the prompt handed over, then exits so the popup would close.
printf 'FOLDER=%s\n' "$1" >> "$RECORD"
printf 'NAME=%s\n' "$(tmux show-option -gqv @clux-new-workspace-name)" >> "$RECORD"
STUB
    chmod +x "$STAGE/new-workspace-prompt.sh" "$STAGE/new-workspace.sh"
    RECORD="$BATS_TEST_TMPDIR/record"
    : > "$RECORD"
    # Written by the pane AFTER the script returns, so a cancel can be proved
    # by the script stopping rather than guessed at from what is on screen.
    DONE="$BATS_TEST_TMPDIR/done"
    rm -f "$DONE"
    # The saved list of this test only. The throwaway tmux server starts from
    # this environment, so its panes read this list and never the user's.
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
    rm -rf "$XDG_STATE_HOME"
}

# The PATH the pane runs with: the real tmux (and fzf, which sits beside it on
# a Homebrew machine) and the system tools.
_pane_path() { printf '%s:/usr/bin:/bin' "$(dirname "$REAL_TMUX")"; }

# _nofzf_path — a PATH with the real tmux, the tools that the prompt runs,
# and NO fzf, wherever fzf lives. "/usr/bin:/bin" is not enough: Debian and
# Ubuntu put fzf in /usr/bin (see _make_nofzf_bin in session-picker.bats).
_nofzf_path() {
    local dir="$BATS_TEST_TMPDIR/nofzf-bin" t src
    mkdir -p "$dir"
    ln -sf "$REAL_TMUX" "$dir/tmux"
    for t in env bash sh dirname basename cat sed grep awk cut tr head tail \
        mktemp rm rmdir mkdir mv chmod stty ps sleep touch wc sort id date uname; do
        src="$(PATH=/usr/bin:/bin command -v "$t" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$dir/$t"
    done
    printf '%s' "$dir"
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
    # TMPDIR: the script's temporary files stay in the test's own folder.
    mkdir -p "$BATS_TEST_TMPDIR/tmp"
    "$REAL_TMUX" -L "$SOCKET" -f /dev/null new-session -d -x 80 -y 24 \
        "TMPDIR='$BATS_TEST_TMPDIR/tmp' RECORD='$RECORD' PATH='${RUN_PATH:-$(_pane_path)}' '$STAGE/new-workspace-prompt.sh'; sleep 30" 3>&-
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

# A cancelled prompt has to STOP. Which way it stops depends on the signal:
# SIGINT reaches the whole foreground process group and takes the pane with it,
# while SIGQUIT leaves the pane's trailing command to run, so the script's own
# exit is what shows. Either is a cancel; a prompt still waiting is not. The
# screen cannot answer this — the last frame stays drawn after the script ends.
_assert_cancelled() {
    local sock="$1" tries=40
    while [ "$tries" -gt 0 ]; do
        [ -e "$DONE" ] && return 0
        "$REAL_TMUX" -L "$sock" has-session >/dev/null 2>&1 || return 0
        sleep 0.1
        tries=$((tries - 1))
    done
    echo "the prompt was still waiting:"
    "$REAL_TMUX" -L "$sock" capture-pane -p 2>/dev/null
    return 1
}

# _start_box [COLS ROWS [PATH]] — start the staged popup in a session named
# "live1" (so a row named live1 is a live session) and wait for the box. The
# default size is the popup's INNER size: -w 72 -h 10 less the border.
_start_box() {
    local cols="${1:-70}" rows="${2:-8}" path="${3:-$(_pane_path)}"
    BSOCK="clux-box-$$-${BATS_TEST_NUMBER}"
    "$REAL_TMUX" -L "$BSOCK" kill-server >/dev/null 2>&1 || true
    # BOX_LIVE="NAME:FOLDER" — one more live session, there before the box.
    [ -z "${BOX_LIVE:-}" ] || "$REAL_TMUX" -L "$BSOCK" -f /dev/null \
        new-session -d -s "${BOX_LIVE%%:*}" -c "${BOX_LIVE#*:}" 3>&-
    # TMPDIR: the rows file stays in the test's own folder.
    mkdir -p "$BATS_TEST_TMPDIR/tmp"
    "$REAL_TMUX" -L "$BSOCK" -f /dev/null new-session -d -s live1 -x "$cols" -y "$rows" \
        -c "$BATS_TEST_TMPDIR" \
        "TMPDIR='$BATS_TEST_TMPDIR/tmp' RECORD='$RECORD' PATH='$path' '$STAGE/new-workspace-prompt.sh'; touch '$DONE'; sleep 20" 3>&-
    _wait_for_screen "$BSOCK" "${BOX_READY:-recents}" >/dev/null \
        || { echo "the box never drew:"; "$REAL_TMUX" -L "$BSOCK" capture-pane -p; return 1; }
}

# _k KEY... — send each tmux key name, one at a time, with time to redraw.
_k() {
    local k
    for k in "$@"; do
        "$REAL_TMUX" -L "$BSOCK" send-keys -t '=live1:' "$k"
        sleep 0.3
    done
}

# _t TEXT — type TEXT and wait for it to show in the box.
_t() {
    "$REAL_TMUX" -L "$BSOCK" send-keys -t '=live1:' -l "$1"
    _wait_for_screen "$BSOCK" "$1" >/dev/null || true
    sleep 0.3
}

# _prompt — the text box line (row 2: the header is row 1).
_prompt() {
    "$REAL_TMUX" -L "$BSOCK" capture-pane -p -t '=live1:' 2>/dev/null | sed -n 2p
}

# _end — wait for the popup script to end (or 2 s), keep the last screen in
# SCREEN, and stop the server.
_end() {
    local tries=20
    while [ "$tries" -gt 0 ] && [ ! -e "$DONE" ]; do sleep 0.1; tries=$((tries - 1)); done
    # Esc or Ctrl-C can take the pane, and the server, with it.
    SCREEN="$("$REAL_TMUX" -L "$BSOCK" capture-pane -p 2>/dev/null)" || true
    "$REAL_TMUX" -L "$BSOCK" kill-server >/dev/null 2>&1 || true
}

# The box needs fzf 0.66 or later (--gutter). An older fzf gets the plain
# prompt (see "old fzf" below), so a box test cannot run with it.
_need_fzf() {
    local v major minor
    v="$(PATH="$(_pane_path)" fzf --version 2>/dev/null)" || skip "fzf is not installed beside tmux"
    v="${v%% *}"
    major="${v%%.*}"
    minor="${v#*.}"
    minor="${minor%%.*}"
    { [ "$major" -gt 0 ] || [ "$minor" -ge 66 ]; } 2>/dev/null || skip "fzf $v is older than 0.66"
}

# A test that fails before _end leaves its server, and the box in it,
# running. This stops both servers on each exit path. The servers start with
# fd 3 closed (3>&-, as in terminal-e2e.bats): bats waits for each holder of
# fd 3, so a server that kept it made the whole run wait.
teardown() {
    local s
    for s in "${BSOCK:-}" "${SOCKET:-}"; do
        [ -n "$s" ] || continue
        "$REAL_TMUX" -L "$s" kill-server >/dev/null 2>&1 || true
        # kill-server does not remove the socket file.
        rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$s"
    done
    stop_fake_clef
    stop_holders
    rm -rf "$BATS_TEST_TMPDIR"
}

# ===========================================================================
# 1. The --fzf helper mode
# ===========================================================================

# _rows — a rows file: one saved workspace, one live session.
_rows() {
    ROWS="$BATS_TEST_TMPDIR/rows"
    printf 'one\t/a\tone\t/a\tsaved\tkept\nlive1\t/b\tlive1\t/b\tlive\tunkept\n' > "$ROWS"
}

# _fzf EVENT [FIELD] — run the helper mode with the FZF_* values set by the
# caller in Q (query), PTR (pointer), POS and N (match count).
_fzf() {
    run env FZF_QUERY="${Q:-}" FZF_POINTER="${PTR:- }" FZF_POS="${POS:-1}" \
        FZF_MATCH_COUNT="${N:-2}" CLUX_WS_ROWS="${ROWS:-/dev/null}" CLUX_WS_GHOST='<g>' \
        "$PROMPT_SCRIPT" --fzf "$@"
}

@test "helper: typing un-picks, goes to the first row and says new for an unknown name" {
    _rows
    Q=zz _fzf change
    [ "$status" -eq 0 ]
    [ "$output" = 'first+change-pointer( )+change-prompt(new       ▸ )+change-list-label( matches )' ] \
        || { echo "got: $output"; false; }
}

@test "helper: an empty box shows the recents label" {
    _rows
    Q='' _fzf change
    [[ "$output" == *'change-list-label( recents )'* ]] || { echo "got: $output"; false; }
    [[ "$output" == *'change-prompt(new       ▸ )'* ]] || { echo "got: $output"; false; }
}

@test "helper: the exact name of a saved workspace says open, of a live one says switch to" {
    _rows
    Q=one _fzf change
    [[ "$output" == *'change-prompt(open      ▸ )'* ]] || { echo "saved: $output"; false; }
    Q=live1 _fzf change
    [[ "$output" == *'change-prompt(switch to ▸ )'* ]] || { echo "live: $output"; false; }
    # A prefix of a name is not the name.
    Q=on _fzf change
    [[ "$output" == *'change-prompt(new       ▸ )'* ]] || { echo "prefix: $output"; false; }
}

@test "helper: a name that looks like a number is compared as text" {
    # awk compares two values that look like numbers as numbers: "1" was the
    # exact name of a saved "01", so the prompt said open for a new name.
    ROWS="$BATS_TEST_TMPDIR/rows"
    printf '01\t/a\t01\t/a\tsaved\n' > "$ROWS"
    Q=1 _fzf change
    [[ "$output" == *'change-prompt(new       ▸ )'* ]] || { echo "1: $output"; false; }
    Q=1.0 _fzf change
    [[ "$output" == *'change-prompt(new       ▸ )'* ]] || { echo "1.0: $output"; false; }
    Q=01 _fzf change
    [[ "$output" == *'change-prompt(open      ▸ )'* ]] || { echo "01: $output"; false; }
}

@test "helper: the first Down picks the top row and does not move" {
    PTR=' ' _fzf down live
    [ "$output" = 'change-pointer(▸)+change-prompt(switch to ▸ )' ] || { echo "got: $output"; false; }
    PTR=' ' _fzf down saved
    [ "$output" = 'change-pointer(▸)+change-prompt(open      ▸ )' ] || { echo "got: $output"; false; }
}

@test "helper: Down with no match picks nothing, Down when picked moves down" {
    PTR=' ' N=0 _fzf down saved
    [ -z "$output" ] || { echo "got: $output"; false; }
    PTR='▸' _fzf down saved
    [ "$output" = 'down' ] || { echo "got: $output"; false; }
}

@test "helper: Up from the top row un-picks; Up lower moves up; Up un-picked does nothing" {
    _rows
    PTR='▸' POS=1 Q=one _fzf up
    [ "$output" = 'change-pointer( )+change-prompt(open      ▸ )' ] || { echo "top: $output"; false; }
    PTR='▸' POS=2 _fzf up
    [ "$output" = 'up' ] || { echo "lower: $output"; false; }
    PTR=' ' _fzf up
    [ -z "$output" ] || { echo "un-picked: $output"; false; }
}

@test "helper: Page Up moves a page from a lower row and un-picks from the top row" {
    _rows
    PTR='▸' POS=3 _fzf up page-up
    [ "$output" = 'page-up' ] || { echo "lower: $output"; false; }
    PTR='▸' POS=1 Q=zz _fzf up page-up
    [ "$output" = 'change-pointer( )+change-prompt(new       ▸ )' ] || { echo "top: $output"; false; }
}

@test "helper: focus follows the picked row, and leaves an un-picked prompt alone" {
    PTR='▸' _fzf focus live
    [ "$output" = 'change-prompt(switch to ▸ )' ] || { echo "got: $output"; false; }
    PTR=' ' _fzf focus live
    [ -z "$output" ] || { echo "got: $output"; false; }
}

@test "helper: a cursor that moved with no Down picks its row" {
    # fzf's own keys (Ctrl-N, PgDn) move the cursor with no Down. The row
    # under the cursor then gets the pointer, so Enter opens the row it is on.
    PTR=' ' POS=2 _fzf focus saved
    [ "$output" = 'change-pointer(▸)+change-prompt(open      ▸ )' ] || { echo "got: $output"; false; }
}

@test "helper: Enter is OPEN when a row is picked, NEW when not" {
    PTR='▸' _fzf enter
    [ "$output" = 'print(OPEN)+accept' ] || { echo "got: $output"; false; }
    PTR=' ' _fzf enter
    [ "$output" = 'print(NEW)+accept' ] || { echo "got: $output"; false; }
}

@test "helper: Ctrl-X removes a picked saved row, and does nothing un-picked or on an unsaved row" {
    PTR='▸' _fzf remove kept
    [ "$output" = 'print(REMOVE)+accept' ]
    PTR=' ' _fzf remove kept
    [ -z "$output" ]
    PTR='▸' _fzf remove unkept
    [ -z "$output" ]
}

@test "helper: Ctrl-E edits a picked saved row, and does nothing un-picked or on a live row" {
    PTR='▸' _fzf edit saved
    [ "$output" = 'print(EDIT)+accept' ]
    PTR=' ' _fzf edit saved
    [ -z "$output" ]
    PTR='▸' _fzf edit live
    [ -z "$output" ]
}

@test "helper: the gray completion is the rest of the name, or → name for a fuzzy match" {
    Q=cl _fzf ghost clux
    [ "$output" = $'<g>ux\033[0m' ] || { echo "got: $output"; false; }
    Q=ht _fzf ghost hotel
    [ "$output" = $'<g>  → hotel\033[0m' ] || { echo "got: $output"; false; }
}

# The bug this pins: the exact name left nothing to show, and the colour
# sequence printed for it was drawn by fzf as the text "[38;2;...m[0m".
@test "helper: the gray completion prints NOTHING when the name is typed in full or the box is empty" {
    Q=clux _fzf ghost clux
    [ -z "$output" ] || { echo "exact name printed: $(printf '%s' "$output" | cat -v)"; false; }
    Q='' _fzf ghost clux
    [ -z "$output" ] || { echo "empty box printed: $(printf '%s' "$output" | cat -v)"; false; }
    Q=cl _fzf ghost ''
    [ -z "$output" ] || { echo "no row printed: $(printf '%s' "$output" | cat -v)"; false; }
}

@test "helper: the gray completion shows no other row when the typed text is an exact name" {
    # "api" typed, the newer "api-v2" on top: the prompt said open for api,
    # and a gray "-v2" named a workspace that Enter does not open.
    ROWS="$BATS_TEST_TMPDIR/rows"
    printf 'api-v2\t/b\tapi-v2\t/b\tsaved\napi\t/a\tapi\t/a\tsaved\n' > "$ROWS"
    Q=api _fzf ghost api-v2
    [ -z "$output" ] || { echo "un-picked: $(printf '%s' "$output" | cat -v)"; false; }
    # When api-v2 is picked, Enter opens it, so the rest of its name shows.
    Q=api PTR='▸' _fzf ghost api-v2
    [ "$output" = $'<g>-v2\033[0m' ] || { echo "picked: $(printf '%s' "$output" | cat -v)"; false; }
}

@test "helper: runs no tmux command (it runs on every key)" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    : > "$log"
    _rows
    local ev
    for ev in change focus down up enter remove edit ghost; do
        STUB_LOG="$log" Q=on PTR='▸' _fzf "$ev" saved
    done
    [ ! -s "$log" ] || { echo "the helper called:"; cat "$log"; false; }
}

# ===========================================================================
# 2. The box, through a real pty
# ===========================================================================

@test "new-workspace-prompt: with no tty it refuses to run and says to re-run setup" {
    # The shape a stale clux.tmux.conf produces: the old binding called this
    # through run-shell, which has no tty.
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

@test "new-workspace-prompt: a new name, then the folder, are both handed on" {
    _need_fzf
    _stage
    _run_in_pty "work" "projects/work"
    grep -qF 'FOLDER=projects/work' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "pane: $PANE_TEXT"; false; }
    grep -qF 'NAME=work' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "new-workspace-prompt: an empty folder falls back to the session name" {
    _need_fzf
    _stage
    _run_in_pty "solo" ""
    grep -qF 'FOLDER=solo' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "pane: $PANE_TEXT"; false; }
}

@test "new-workspace-prompt: Enter in an empty box creates nothing" {
    _need_fzf
    _stage
    _run_in_pty ""
    [ ! -s "$RECORD" ] || { echo "record should be empty: $(cat "$RECORD")"; false; }
    [ -z "$OPT_AFTER" ] || { echo "option was written: $OPT_AFTER"; false; }
}

@test "new-workspace-prompt: a name carrying a shell command runs nothing — the injection regression" {
    _need_fzf
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
    _need_fzf
    _stage
    _run_in_pty "bad'name"
    [ ! -s "$RECORD" ] || { echo "a workspace was created: $(cat "$RECORD")"; false; }
    [ -z "$OPT_AFTER" ] || { echo "the rejected name was stored: $OPT_AFTER"; false; }
}

@test "new-workspace-prompt: a name containing a semicolon or a # is rejected" {
    _need_fzf
    _stage
    _run_in_pty "bad;name"
    [ ! -s "$RECORD" ] || { echo "semicolon accepted: $(cat "$RECORD")"; false; }

    _stage
    _run_in_pty "bad#name"
    [ ! -s "$RECORD" ] || { echo "# accepted: $(cat "$RECORD")"; false; }
}

# tmux ACCEPTS a colon in a session name but reads it as the session/window
# separator in every target, so "a:b" builds a workspace nothing can address.
@test "new-workspace-prompt: a name containing a colon is rejected" {
    _need_fzf
    _stage
    _run_in_pty "bad:name"
    [ ! -s "$RECORD" ] || { echo "colon accepted: $(cat "$RECORD")"; false; }
}

@test "new-workspace-prompt: no printf carries a \u escape bash 3.2 cannot expand" {
    # bash 3.2 is what macOS ships, and its printf has no \u — it prints the
    # six characters verbatim. Literal UTF-8 is the only form every supported
    # bash renders.
    run grep -n '\\u[0-9a-fA-F]\{4\}' "$PROMPT_SCRIPT"
    [ "$status" -ne 0 ] \
        || { echo "a \\u escape survives, and bash 3.2 will print it literally:"; echo "$output"; false; }
}

@test "box: draws the header, an un-picked new prompt, and the recents, newest first" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    "$HIST" add two "$BATS_TEST_TMPDIR/b"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    # Wait for the last row: the label draws before the rows do.
    BOX_READY="two" _start_box || false
    local screen; screen="$("$REAL_TMUX" -L "$BSOCK" capture-pane -p)"
    _k Escape
    _end
    [[ "$screen" == *"Workspace"* ]] || { echo "$screen"; false; }
    [[ "$(printf '%s\n' "$screen" | sed -n 2p)" == "new       ▸"* ]] || { echo "$screen"; false; }
    # one is newer than two, so it is the first row.
    [[ "$(printf '%s\n' "$screen" | sed -n 4p)" == *"one"* ]] || { echo "$screen"; false; }
    [[ "$(printf '%s\n' "$screen" | sed -n 5p)" == *"two"* ]] || { echo "$screen"; false; }
    [[ "$screen" != *"▸ one"* ]] || { echo "a row is picked before any key:"; echo "$screen"; false; }
    [[ "$screen" != *'\u'* ]] || { echo "an unexpanded escape reached the screen:"; echo "$screen"; false; }
}

@test "box: typing narrows the list, and the label says matches" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    "$HIST" add beta "$BATS_TEST_TMPDIR/b"
    "$HIST" add alpha "$BATS_TEST_TMPDIR/a"
    _start_box || false
    _t bet
    local screen; screen="$(_wait_for_screen "$BSOCK" "matches")" || true
    _k Escape
    _end
    [[ "$screen" == *"matches"* ]] || { echo "$screen"; false; }
    [[ "$screen" == *"beta"* ]] || { echo "$screen"; false; }
    [[ "$screen" != *"alpha"* ]] || { echo "a row that does not match stays:"; echo "$screen"; false; }
}

@test "box: Enter on a typed name that matches a row is still a NEW workspace" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/clux"
    "$HIST" add clux "$BATS_TEST_TMPDIR/clux"
    _start_box || false
    _t cl
    _k Enter
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question"; false; }
    _k Enter
    _end
    grep -qxF 'NAME=cl' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "$SCREEN"; false; }
    grep -qxF 'FOLDER=cl' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: Down picks the top match and Enter opens it in its saved folder" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    "$HIST" add two "$BATS_TEST_TMPDIR/b"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    _start_box || false
    _k Down
    local p; p="$(_prompt)"
    _k Enter
    _end
    [[ "$p" == "open      ▸"* ]] || { echo "prompt after Down: $p"; false; }
    grep -qxF "FOLDER=$BATS_TEST_TMPDIR/a" "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "$SCREEN"; false; }
    grep -qxF 'NAME=one' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: Ctrl-X removes the picked row, and the box opens again with the typed text" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    "$HIST" add two "$BATS_TEST_TMPDIR/b"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    _start_box || false
    _t o
    _k Down C-x
    local screen; screen="$(_wait_for_screen "$BSOCK" "matches")" || true
    local p; p="$(_prompt)"
    _k Escape
    _end
    run "$HIST" list
    [ "$output" = "two"$'\t'"$BATS_TEST_TMPDIR/b" ] || { echo "list: $output"; echo "$screen"; false; }
    [[ "$p" == *"▸ o"* ]] || { echo "the typed text is lost: $p"; false; }
    [[ "$screen" == *"two"* ]] || { echo "$screen"; false; }
    [[ "$screen" != *"one "* ]] || { echo "the removed row stays:"; echo "$screen"; false; }
    [ ! -s "$RECORD" ] || { echo "a workspace was opened: $(cat "$RECORD")"; false; }
}

@test "box: Ctrl-X on a saved session that runs removes the line, and the session stays a row" {
    _need_fzf
    _stage
    "$HIST" add live1 "$BATS_TEST_TMPDIR"
    BOX_READY="live1" _start_box || false
    _k Down C-x
    sleep 0.5
    local screen; screen="$(_wait_for_screen "$BSOCK" "live1")" || true
    _k Escape
    _end
    run "$HIST" list
    [ -z "$output" ] || { echo "list: $output"; false; }
    [[ "$screen" == *"live1"* ]] || { echo "the live session is gone from the box:"; echo "$screen"; false; }
}

@test "box: Ctrl-X with no picked row removes nothing" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    BOX_READY="one" _start_box || false
    _k C-x
    _k Escape
    _end
    run "$HIST" list
    [ "${#lines[@]}" -eq 1 ] || { echo "list: $output"; false; }
}

@test "box: Ctrl-E changes the name and the folder, and keeps the place" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b" "$BATS_TEST_TMPDIR/c"
    "$HIST" add two "$BATS_TEST_TMPDIR/b"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    BOX_READY="two" _start_box || false
    _k Down C-e
    _wait_for_screen "$BSOCK" "Edit workspace" >/dev/null || { echo "no edit prompt"; false; }
    _t uno
    _k Enter
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question"; false; }
    _t "$BATS_TEST_TMPDIR/c"
    _k Enter
    _wait_for_screen "$BSOCK" "recents" >/dev/null || { echo "the box did not open again"; false; }
    _k Escape
    _end
    run "$HIST" list
    [ "${lines[0]}" = "uno"$'\t'"$BATS_TEST_TMPDIR/c" ] || { echo "list: $output"; false; }
    [ "${lines[1]}" = "two"$'\t'"$BATS_TEST_TMPDIR/b" ] || { echo "list: $output"; false; }
    [ ! -s "$RECORD" ] || { echo "a workspace was opened: $(cat "$RECORD")"; false; }
}

@test "box: Ctrl-E with Enter alone keeps both, and refuses a name that is taken" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    "$HIST" add two "$BATS_TEST_TMPDIR/b"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    BOX_READY="two" _start_box || false
    _k Down C-e
    _wait_for_screen "$BSOCK" "Edit workspace" >/dev/null || { echo "no edit prompt"; false; }
    _k Enter
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question"; false; }
    _k Enter
    _wait_for_screen "$BSOCK" "recents" >/dev/null || { echo "the box did not open again"; false; }
    _k Down C-e
    _wait_for_screen "$BSOCK" "Edit workspace" >/dev/null || { echo "no edit prompt"; false; }
    _t two
    _k Enter
    local screen; screen="$(_wait_for_screen "$BSOCK" "is taken")" || { echo "no refusal:"; echo "$screen"; false; }
    _k Escape
    _end
    run "$HIST" list
    [ "$output" = "one"$'\t'"$BATS_TEST_TMPDIR/a"$'\n'"two"$'\t'"$BATS_TEST_TMPDIR/b" ] || { echo "list: $output"; false; }
}

@test "box: Ctrl-E does nothing on a live session" {
    _need_fzf
    _stage
    BOX_READY="live1" _start_box || false
    _k Down C-e
    sleep 0.5
    local screen; screen="$("$REAL_TMUX" -L "$BSOCK" capture-pane -p)"
    _k Escape
    _end
    [[ "$screen" != *"Edit workspace"* ]] || { echo "$screen"; false; }
}

@test "box: Down Down opens the second row" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
    "$HIST" add two "$BATS_TEST_TMPDIR/b"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    _start_box || false
    _k Down Down Enter
    _end
    grep -qxF 'NAME=two' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "$SCREEN"; false; }
}

@test "box: Up from the top row un-picks, so Enter is a new name again" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/one"
    "$HIST" add one "$BATS_TEST_TMPDIR/one"
    _start_box || false
    _t on
    _k Down Up
    local p; p="$(_prompt)"
    _k Enter
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question"; false; }
    _k Enter
    _end
    [[ "$p" == "new       ▸"* ]] || { echo "prompt after Up: $p"; false; }
    grep -qxF 'NAME=on' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: each fzf key that moves up un-picks from the top row, as Up does" {
    # On the top row, fzf's own up keys do not move the cursor, so no focus
    # event came and the row stayed picked: Enter opened it.
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/one"
    "$HIST" add one "$BATS_TEST_TMPDIR/one"
    _start_box || false
    _t on
    local key p bad=""
    for key in C-k C-p M-Up BTab PPage; do
        _k Down
        p="$(_prompt)"
        [[ "$p" == "open      ▸"* ]] || bad="$bad $key:no-pick($p)"
        _k "$key"
        p="$(_prompt)"
        [[ "$p" == "new       ▸"* ]] || bad="$bad $key($p)"
    done
    _k Escape
    _end
    [ -z "$bad" ] || { echo "still picked after:$bad"; false; }
}

@test "box: the prompt says switch to for a live session, open for a saved one, new otherwise" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/s"
    "$HIST" add saved1 "$BATS_TEST_TMPDIR/s"
    _start_box || false
    _t live1
    local p_live; p_live="$(_prompt)"
    _k C-u
    _t saved1
    local p_saved; p_saved="$(_prompt)"
    _k C-u
    _t zz
    local p_new; p_new="$(_prompt)"
    _k Escape
    _end
    [[ "$p_live" == "switch to ▸ live1"* ]] || { echo "live: $p_live"; false; }
    [[ "$p_saved" == "open      ▸ saved1"* ]] || { echo "saved: $p_saved"; false; }
    [[ "$p_new" == "new       ▸ zz"* ]] || { echo "new: $p_new"; false; }
}

@test "box: the exact name of a live session switches to it, with no folder question" {
    _need_fzf
    _stage
    _start_box || false
    _t live1
    _k Enter
    _end
    grep -qxF 'NAME=live1' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "$SCREEN"; false; }
    [[ "$SCREEN" != *"folder"* ]] || { echo "asked for a folder:"; echo "$SCREEN"; false; }
}

@test "box: the exact name of a saved workspace opens it in its folder" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/b"
    "$HIST" add two "$BATS_TEST_TMPDIR/b"
    _start_box || false
    _t two
    _k Enter
    _end
    grep -qxF "FOLDER=$BATS_TEST_TMPDIR/b" "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "$SCREEN"; false; }
    grep -qxF 'NAME=two' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: a typed name that looks like a number is a new name, not a saved one" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/z"
    "$HIST" add 01 "$BATS_TEST_TMPDIR/z"
    _start_box || false
    _t 1
    local p; p="$(_prompt)"
    _k Enter
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question"; false; }
    _k Enter
    _end
    [[ "$p" == "new       ▸ 1"* ]] || { echo "prompt: $p"; false; }
    grep -qxF 'NAME=1' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
    grep -qxF 'FOLDER=1' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: a long name matches by its end too" {
    # The list showed the name cut to 18 characters, and fzf finds a row by
    # the shown text only: "terraform" did not find infrastructure-terraform.
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/t"
    "$HIST" add infrastructure-terraform "$BATS_TEST_TMPDIR/t"
    _start_box || false
    _t terraform
    local screen; screen="$("$REAL_TMUX" -L "$BSOCK" capture-pane -p)"
    _k Down Enter
    _end
    [[ "$screen" == *"infrastructure-terraform"* ]] || { echo "no match:"; echo "$screen"; false; }
    grep -qxF 'NAME=infrastructure-terraform' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "$SCREEN"; false; }
    grep -qxF "FOLDER=$BATS_TEST_TMPDIR/t" "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: Ctrl-J is Enter, so an Enter typed before the box is up still counts" {
    # The terminal turns an Enter that comes before fzf starts into Ctrl-J,
    # and fzf's own Ctrl-J moves down: the typed name went nowhere.
    _need_fzf
    _stage
    _start_box || false
    _t zebra
    _k C-j
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question:"; "$REAL_TMUX" -L "$BSOCK" capture-pane -p; false; }
    _k Enter
    _end
    grep -qxF 'NAME=zebra' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: Tab puts the current row's name in the box, and Enter then opens it" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    _start_box || false
    _t on
    _k Tab
    local p; p="$(_prompt)"
    _k Enter
    _end
    [[ "$p" == "open      ▸ one"* ]] || { echo "prompt after Tab: $p"; false; }
    grep -qxF 'NAME=one' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: Tab, then more typing, is a new name" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    _start_box || false
    _t on
    _k Tab
    _t x
    _k Enter
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question"; false; }
    _k Enter
    _end
    grep -qxF 'NAME=onex' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: the gray completion shows the rest of the name, and no colour code as text" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    _start_box || false
    _t on
    local part; part="$(_prompt)"
    _t e
    local full; full="$(_prompt)"
    _k Escape
    _end
    [[ "$part" == *"on e"* ]] || { echo "after 'on': $part"; false; }
    [[ "$full" != *"[38;"* && "$full" != *"[0m"* ]] || { echo "a colour code drawn as text: $full"; false; }
}

@test "box: a picked row whose folder is gone asks for a folder" {
    _need_fzf
    _stage
    "$HIST" add old "$BATS_TEST_TMPDIR/no-such-folder"
    mkdir -p "$BATS_TEST_TMPDIR/new-home"
    _start_box || false
    _k Down Enter
    local screen; screen="$(_wait_for_screen "$BSOCK" "folder is gone")" || true
    "$REAL_TMUX" -L "$BSOCK" send-keys -t '=live1:' -l "$BATS_TEST_TMPDIR/new-home"
    _k Enter
    _end
    [[ "$screen" == *"folder is gone"* ]] || { echo "$screen"; false; }
    grep -qxF "FOLDER=$BATS_TEST_TMPDIR/new-home" "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
    grep -qxF 'NAME=old' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: a session that ends while the box is open is not switched to" {
    # The box read the live sessions once, at the start. When the session of
    # a picked row ended in the meantime, and its folder was gone too, the
    # row opened in the gone folder with no folder question.
    _need_fzf
    _stage
    local gone="$BATS_TEST_TMPDIR/gone"
    mkdir -p "$gone" "$BATS_TEST_TMPDIR/new-home"
    "$HIST" add w "$gone"
    BOX_LIVE="w:$gone" _start_box || false
    _k Down
    local p; p="$(_prompt)"
    local picked; picked="$("$REAL_TMUX" -L "$BSOCK" capture-pane -p -t '=live1:')"
    "$REAL_TMUX" -L "$BSOCK" kill-session -t '=w'
    rm -rf "$gone"
    _k Enter
    local screen; screen="$(_wait_for_screen "$BSOCK" "folder is gone")" || true
    "$REAL_TMUX" -L "$BSOCK" send-keys -t '=live1:' -l "$BATS_TEST_TMPDIR/new-home"
    _k Enter
    _end
    [[ "$p" == "switch to ▸"* ]] || { echo "not live at the start: $p"; false; }
    [[ "$picked" == *"▸ w "* ]] || { echo "w is not picked:"; echo "$picked"; false; }
    [[ "$screen" == *"folder is gone"* ]] || { echo "$screen"; false; }
    grep -qxF "FOLDER=$BATS_TEST_TMPDIR/new-home" "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
    grep -qxF 'NAME=w' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "box: on a narrow terminal the folder is cut from the left and the ✗ still shows" {
    # On a client of less than 72 columns the popup takes the full width
    # (render-clux-conf.sh), so a row must fit a narrower box. The end of a
    # folder tells the most, so the cut takes the start.
    _need_fzf
    _stage
    "$HIST" add old "$BATS_TEST_TMPDIR/a/very/long/path/to/the/project/folder/old"
    _start_box 58 8 || false
    local screen; screen="$("$REAL_TMUX" -L "$BSOCK" capture-pane -p)"
    _k Escape
    _end
    local row; row="$(printf '%s\n' "$screen" | grep -F '✗')" || { echo "no ✗:"; echo "$screen"; false; }
    [[ "$row" == *"/folder/old ✗"* ]] || { echo "the end of the folder is cut: $row"; false; }
}

@test "box: a renamed workspace switches to the live session and the row takes its name" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/r"
    "$HIST" add old "$BATS_TEST_TMPDIR/r"
    BOX_READY="old" _start_box || false
    "$REAL_TMUX" -L "$BSOCK" new-session -d -s renamed -c "$BATS_TEST_TMPDIR/r"
    _t old
    _k Down Enter
    _end
    [ ! -s "$RECORD" ] || { echo "it built a new workspace: $(cat "$RECORD")"; false; }
    run "$HIST" list
    [ "$output" = "renamed"$'\t'"$BATS_TEST_TMPDIR/r" ] || { echo "list: $output"; echo "$SCREEN"; false; }
}

@test "box: shows 5 rows at the popup size, and Down scrolls past them" {
    _need_fzf
    _stage
    local i
    for i in 6 5 4 3 2 1; do mkdir -p "$BATS_TEST_TMPDIR/d$i"; "$HIST" add "w$i" "$BATS_TEST_TMPDIR/d$i"; done
    BOX_READY="w5" _start_box || false
    local first; first="$("$REAL_TMUX" -L "$BSOCK" capture-pane -p)"
    _k Down Down Down Down Down Down
    local after; after="$("$REAL_TMUX" -L "$BSOCK" capture-pane -p)"
    _k Escape
    _end
    [[ "$first" == *"w5"* && "$first" != *"w6"* ]] || { echo "not 5 rows:"; echo "$first"; false; }
    [[ "$after" == *"▸ w6"* ]] || { echo "Down did not scroll to the 6th row:"; echo "$after"; false; }
    [[ "$after" == *"Workspace"* ]] || { echo "the header scrolled away:"; echo "$after"; false; }
}

@test "box: the user's FZF_DEFAULT_OPTS do not change it" {
    _need_fzf
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/a"
    "$HIST" add one "$BATS_TEST_TMPDIR/a"
    FZF_DEFAULT_OPTS='--layout=default --border --prompt=XX' BOX_READY="one" _start_box || false
    local screen; screen="$("$REAL_TMUX" -L "$BSOCK" capture-pane -p)"
    _k Escape
    _end
    [[ "$(printf '%s\n' "$screen" | sed -n 2p)" == "new       ▸"* ]] || { echo "$screen"; false; }
    [[ "$screen" != *"XX"* ]] || { echo "the user's prompt leaked in:"; echo "$screen"; false; }
}

@test "box: Esc cancels" {
    _need_fzf
    _stage
    _start_box || false
    _t partial
    _k Escape
    local cancelled=0
    _assert_cancelled "$BSOCK" && cancelled=1
    "$REAL_TMUX" -L "$BSOCK" kill-server >/dev/null 2>&1 || true
    [ "$cancelled" -eq 1 ] || false
    [ ! -s "$RECORD" ] || { echo "a cancelled box still handed over:"; cat "$RECORD"; false; }
}

@test "box: Ctrl-C cancels" {
    _need_fzf
    _stage
    _start_box || false
    _t partial
    _k C-c
    local cancelled=0
    _assert_cancelled "$BSOCK" && cancelled=1
    "$REAL_TMUX" -L "$BSOCK" kill-server >/dev/null 2>&1 || true
    [ "$cancelled" -eq 1 ] || false
    [ ! -s "$RECORD" ] || { echo "a cancelled box still handed over:"; cat "$RECORD"; false; }
}

@test "box: Esc at the folder question cancels" {
    _need_fzf
    _stage
    _start_box || false
    _t brandnew
    _k Enter
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question"; false; }
    _k Escape
    local cancelled=0
    _assert_cancelled "$BSOCK" && cancelled=1
    "$REAL_TMUX" -L "$BSOCK" kill-server >/dev/null 2>&1 || true
    [ "$cancelled" -eq 1 ] || false
    [ ! -s "$RECORD" ] || { echo "a cancelled folder question still handed over:"; cat "$RECORD"; false; }
}

@test "box: the rows file is removed when the terminal closes at the folder question" {
    # kill-server closes the pane: the script gets a hangup, and one more
    # hangup when the pane's shell ends. The second one stopped the clean-up
    # before it removed the rows file.
    _need_fzf
    _stage
    _start_box || false
    local tmpd="$BATS_TEST_TMPDIR/tmp" tries=30
    [ -n "$(ls "$tmpd")" ] || { echo "no rows file while the box is open"; false; }
    _t brandnew
    _k Enter
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question"; false; }
    "$REAL_TMUX" -L "$BSOCK" kill-server >/dev/null 2>&1 || true
    while [ "$tries" -gt 0 ] && [ -n "$(ls "$tmpd")" ]; do sleep 0.1; tries=$((tries - 1)); done
    [ -z "$(ls "$tmpd")" ] || { echo "left behind:"; ls -l "$tmpd"; false; }
}

@test "box: the folder question states the default it falls back to" {
    # Enter alone reuses the session name. bash 3.2 has no `read -i`, so the
    # default cannot be prefilled — stating it is the only way a user can know
    # the empty answer does anything.
    _need_fzf
    _stage
    _start_box || false
    _t myws
    _k Enter
    local screen; screen="$(_wait_for_screen "$BSOCK" "folder")" || true
    _k Escape
    _end
    [[ "$screen" == *"[myws]"* ]] || { echo "the folder question never states its default:"; echo "$screen"; false; }
    [[ "$screen" == *"name    myws"* ]] || { echo "the name is not shown above it:"; echo "$screen"; false; }
}

@test "box: the rejection fits the popup without scrolling the header away" {
    # The pane is the popup's INNER size: -w 72 -h 10 less the border.
    _need_fzf
    _stage
    _start_box || false
    _t "bad:name"
    _k Enter
    local screen; screen="$(_wait_for_screen "$BSOCK" "press any key")" || true
    _k Enter
    _end
    [[ "$screen" == *"press any key"* ]] || { echo "the reject path never finished drawing:"; echo "$screen"; false; }
    [[ "$screen" == *"New workspace"* ]] || { echo "the reason scrolled the header off the popup:"; echo "$screen"; false; }
    [ ! -s "$RECORD" ] || { echo "record: $(cat "$RECORD")"; false; }
}

# ===========================================================================
# 3. Without fzf: the plain prompts
# ===========================================================================

@test "no fzf: the name prompt, then the folder, are both handed on" {
    _stage
    RUN_PATH="$(_nofzf_path)" _run_in_pty "work" "projects/work"
    grep -qF 'FOLDER=projects/work' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "pane: $PANE_TEXT"; false; }
    grep -qF 'NAME=work' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "no fzf: a rejected name creates nothing" {
    _stage
    RUN_PATH="$(_nofzf_path)" _run_in_pty "bad:name"
    [ ! -s "$RECORD" ] || { echo "record: $(cat "$RECORD")"; false; }
}

@test "no fzf: the exact name of a saved workspace opens it in its folder" {
    # Without fzf there is no list, so this is the one way to reopen a saved
    # workspace. It asked for a folder and made the workspace again there.
    _stage
    mkdir -p "$BATS_TEST_TMPDIR/b"
    "$HIST" add two "$BATS_TEST_TMPDIR/b"
    BOX_READY="New workspace" _start_box 70 8 "$(_nofzf_path)" || false
    _t two
    _k Enter
    _end
    grep -qxF "FOLDER=$BATS_TEST_TMPDIR/b" "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "$SCREEN"; false; }
    grep -qxF 'NAME=two' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "old fzf: the plain prompt asks instead, says why, and hands on" {
    # An fzf older than 0.66 does not know --gutter and stops with status 2
    # before it draws. The popup closed with no word: prefix + A did nothing.
    _stage
    local dir="$BATS_TEST_TMPDIR/oldfzf-bin"
    mkdir -p "$dir"
    printf '#!/bin/sh\necho "unknown option: --gutter" >&2\nexit 2\n' > "$dir/fzf"
    chmod +x "$dir/fzf"
    BOX_READY="fzf 0.66" _start_box 70 8 "$dir:$(_nofzf_path)" || false
    _t work
    _k Enter
    _wait_for_screen "$BSOCK" "folder" >/dev/null || { echo "no folder question"; false; }
    "$REAL_TMUX" -L "$BSOCK" send-keys -t '=live1:' -l "projects/work"
    _k Enter
    _end
    grep -qxF 'NAME=work' "$RECORD" || { echo "record: $(cat "$RECORD")"; echo "$SCREEN"; false; }
    grep -qxF 'FOLDER=projects/work' "$RECORD" || { echo "record: $(cat "$RECORD")"; false; }
}

@test "no fzf: Esc cancels the name prompt instead of typing ^[" {
    # Esc used to be an ordinary character in the line: it echoed "^[" and the
    # prompt kept waiting. The terminal now carries Esc as its interrupt
    # character, so Esc takes the same path Ctrl-C did.
    _stage
    BOX_READY="New workspace" _start_box 70 8 "$(_nofzf_path)" || false
    _t partial
    _k Escape
    local cancelled=0
    _assert_cancelled "$BSOCK" && cancelled=1
    "$REAL_TMUX" -L "$BSOCK" kill-server >/dev/null 2>&1 || true
    [ "$cancelled" -eq 1 ] || false
    [ ! -s "$RECORD" ] || { echo "a cancelled prompt still handed over:"; cat "$RECORD"; false; }
}

@test "no fzf: Ctrl-C still cancels after Esc took the interrupt key" {
    # `stty intr` names ONE character. Handing it to Esc TAKES it from Ctrl-C,
    # which would then land in the line as a literal \003. Ctrl-C is moved onto
    # `quit` so both keys still cancel.
    _stage
    BOX_READY="New workspace" _start_box 70 8 "$(_nofzf_path)" || false
    _t partial
    _k C-c
    local cancelled=0
    _assert_cancelled "$BSOCK" && cancelled=1
    "$REAL_TMUX" -L "$BSOCK" kill-server >/dev/null 2>&1 || true
    [ "$cancelled" -eq 1 ] || false
    [ ! -s "$RECORD" ] || { echo "a cancelled prompt still handed over:"; cat "$RECORD"; false; }
}
