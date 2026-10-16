#!/usr/bin/env bats
# session-bar-refresh.bats — session-bar-refresh.sh: the single refresh entry
# point for both @clux_session_bar and @clux_status. Neither option is written
# when its renderer FAILS, and the forced redraw is skipped when called with
# "quiet".
#
# The two tokens differ on an exit-0-with-empty result, and the staged tests
# at the bottom pin that difference down:
#   @clux_status  empty IS the answer ("no notification pending"), so it must
#                 be written — otherwise a dismissed notification stays on the
#                 bar until an unrelated one replaces it.
#   @clux_session_bar  empty is never a real answer while tmux runs, so it is
#                 treated as a silent failure and the previous bar is kept.

load test_helper

REAL_TMUX="$(command -v tmux)"
REFRESH_SCRIPT="$SCRIPTS_DIR/session-bar-refresh.sh"

# session-list.sh (called by session-bar-refresh.sh) renders nothing when
# there are no live sessions, and session-bar-refresh.sh only sets the option
# when its renderer prints something — so this stub answers list-sessions
# with one live session, enough for session-list.sh to produce non-empty
# output.
_write_one_session_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    list-sessions)
        case "$3" in
            *session_id*) printf '$0\talpha\n' ;;
            *session_attached*) printf 'alpha\t1\talpha\n' ;;
        esac
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "session-bar-refresh: sets @clux_session_bar from session-list.sh output" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$REFRESH_SCRIPT'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux_session_bar' "$log" || false
}

@test "session-bar-refresh: quiet skips the forced redraw" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$REFRESH_SCRIPT' quiet
    "
    [ "$status" -eq 0 ]
    run grep -qF 'refresh-client -S' "$log"
    [ "$status" -ne 0 ]
}

@test "session-bar-refresh: without quiet, issues refresh-client -S" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$REFRESH_SCRIPT'
    "
    [ "$status" -eq 0 ]
    grep -qF 'refresh-client -S' "$log" || false
}

# ---------------------------------------------------------------------------
# Staged copy with stub siblings, so each renderer's exit status and output
# can be dictated exactly. session-bar-refresh.sh resolves both renderers
# through $CURRENT_DIR, so a copy in a temp dir picks up the stubs beside it.
# _stage <bar-exit> <bar-output> <status-exit> <status-output>
_stage() {
    STAGED_DIR="$BATS_TEST_TMPDIR/staged"
    mkdir -p "$STAGED_DIR"
    cp "$SCRIPTS_DIR/session-bar-refresh.sh" "$STAGED_DIR/"
    chmod +x "$STAGED_DIR/session-bar-refresh.sh"

    printf '#!/usr/bin/env bash\nprintf %%s %s\nexit %s\n' \
        "$(printf '%q' "$2")" "$1" > "$STAGED_DIR/session-list.sh"
    printf '#!/usr/bin/env bash\nprintf %%s %s\nexit %s\n' \
        "$(printf '%q' "$4")" "$3" > "$STAGED_DIR/show-notification.sh"
    chmod +x "$STAGED_DIR/session-list.sh" "$STAGED_DIR/show-notification.sh"
}

@test "session-bar-refresh: an empty notification CLEARS @clux_status — the dismissed-badge regression" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    # show-notification.sh exits 0 printing nothing: its normal "nothing
    # pending" path, reached every time a notification is dismissed.
    _stage 0 'BAR' 0 ''
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    # The option must be written, with an empty value. Guarding on non-empty
    # here is exactly what stranded the badge on the bar.
    grep -qF 'set-option -g @clux_status' "$log" || false
}

@test "session-bar-refresh: a FAILING show-notification.sh leaves @clux_status untouched" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    _stage 0 'BAR' 1 ''
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    run grep -qF 'set-option -g @clux_status' "$log"
    [ "$status" -ne 0 ]
}

@test "session-bar-refresh: an empty session bar leaves @clux_session_bar untouched" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    _stage 0 '' 0 'NOTIF'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    run grep -qF 'set-option -g @clux_session_bar' "$log"
    [ "$status" -ne 0 ]
}

@test "session-bar-refresh: a server with no attached client is not a failure — the 'returned 1' regression" {
    # Uses the REAL tmux, because the fault was in what real tmux does:
    # `refresh-client -S` exits 1 with "no current client" when nothing is
    # attached. That is the ordinary state at config-load time after
    # `tmux new-session -d`, and on every session-created[91] hook fired by a
    # script. The bar is computed fine; there is simply no client to redraw on.
    # The non-zero exit made tmux report "'session-bar-refresh.sh' returned 1"
    # to the next client that attached — the first thing a user saw on a fresh
    # detached start.
    local sock="clux-noclient-$$-${BATS_TEST_NUMBER}"
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    "$REAL_TMUX" -L "$sock" new-session -d -x 80 -y 24
    local sockpath
    sockpath="$("$REAL_TMUX" -L "$sock" display-message -p '#{socket_path}')"

    local out="$BATS_TEST_TMPDIR/refresh.out"
    local rc=0
    # The `if` is load-bearing: bats runs test bodies under errexit, so a bare
    # failing command would abort here instead of reaching the assertions.
    if ! env TMUX="$sockpath,0,0" PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin" \
        "$REFRESH_SCRIPT" > "$out" 2>&1; then
        rc=$?
    fi

    local bar
    bar="$("$REAL_TMUX" -L "$sock" show-option -gqv @clux_session_bar)"
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    rm -f "$sockpath" >/dev/null 2>&1 || true

    [ "$rc" -eq 0 ] || { echo "exited $rc — tmux shows this as \"returned $rc\""; cat "$out"; false; }
    # Output counts too: tmux surfaces a run-shell command's output, so letting
    # "no current client" through on stderr would swap one message for another.
    [ ! -s "$out" ] || { echo "output would reach the client: $(cat "$out")"; false; }
    # And the work still happened — this must not become a script that exits 0
    # by doing nothing.
    [ -n "$bar" ] || { echo "@clux_session_bar was never seeded"; false; }
}

@test "session-bar-refresh: one renderer failing does not skip the other" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_one_session_tmux_stub
    _stage 1 '' 0 'NOTIF'
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux_status NOTIF' "$log" || false
    grep -qF 'refresh-client -S' "$log" || false
}

# ---------------------------------------------------------------------------
# Animated busy glyph (2026-08-23 design): the per-client frame counter, the
# cached "<epoch><TAB><template>" option, and the bash-string-replace
# substitution.
#
# The committed test/stubs/tmux (used above) logs and exits 0 with no output
# — it cannot answer a display-message -p or a show-option -gqv, both of
# which this half of the script depends on. The cases below build a TINY
# OPTION STORE instead: one file per option under $OPT_DIR, so this script's
# own batched display-message read and helpers.sh's get_agent_frame() (via
# show-option -gqv, exercised by the cross-check below) resolve against the
# exact same backing store.
# ---------------------------------------------------------------------------

SENTINEL=$'\356\200\200'   # U+E000 octal UTF-8. NOT the \u escape form (bash 3.2 mis-parses it) — see session-bar-refresh.sh's own header comment.
TAB=$'\t'

# _write_opt_store_tmux_stub — display-message -p answers every #{@name}
# token in its format from a file per option under $CLUX_OPT_DIR; set-option
# -g writes that file, set-option -gu removes it; show-option -gqv prints it.
# Every call is logged, same as every other stub in this suite.
_write_opt_store_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
OPT_DIR="${CLUX_OPT_DIR:?CLUX_OPT_DIR must be set}"
mkdir -p "$OPT_DIR"
case "$1" in
    display-message)
        fmt="$3"
        result=""
        rest="$fmt"
        while [[ "$rest" == *'#{'* ]]; do
            before="${rest%%'#{'*}"
            after_open="${rest#*'#{'}"
            name="${after_open%%'}'*}"
            after="${after_open#*'}'}"
            val=""
            [ -f "$OPT_DIR/$name" ] && val="$(cat "$OPT_DIR/$name")"
            result="${result}${before}${val}"
            rest="$after"
        done
        result="${result}${rest}"
        printf '%s\n' "$result"
        ;;
    set-option)
        if [ "$2" = "-gu" ]; then
            rm -f "$OPT_DIR/$3"
        elif [ "$2" = "-g" ]; then
            printf '%s' "$4" > "$OPT_DIR/$3"
        fi
        ;;
    show-option)
        [ -f "$OPT_DIR/$3" ] && cat "$OPT_DIR/$3"
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

# _seed_opt <name> <value> — writes an option's backing file directly, no
# tmux round trip: how these tests set up "what the store already holds"
# before the script under test ever runs.
_seed_opt() {
    mkdir -p "$OPT_DIR"
    printf '%s' "$2" > "$OPT_DIR/$1"
}

# _get_opt <name> — reads an option's backing file back; prints nothing if it
# was never written (unset).
_get_opt() {
    [ -f "$OPT_DIR/$1" ] && cat "$OPT_DIR/$1"
}

# _stage_anim <bar-output> [bar-exit] — a staged copy of
# session-bar-refresh.sh with a stub session-list.sh (prints <bar-output>,
# exits [bar-exit] (default 0), touches $MARKER_FILE if set — so a test can
# assert it was, or was not, invoked) and a stub show-notification.sh
# (prints nothing, exits 0) beside it. session-bar-refresh.sh resolves both
# through $CURRENT_DIR, so a copy in a temp dir picks up the stubs beside it
# — same trick the existing _stage() above uses.
_stage_anim() {
    STAGED_DIR="$BATS_TEST_TMPDIR/staged-anim"
    mkdir -p "$STAGED_DIR"
    cp "$SCRIPTS_DIR/session-bar-refresh.sh" "$STAGED_DIR/"
    chmod +x "$STAGED_DIR/session-bar-refresh.sh"
    printf '#!/usr/bin/env bash\n[ -n "${MARKER_FILE:-}" ] && touch "$MARKER_FILE"\nprintf %%s %s\nexit %s\n' \
        "$(printf '%q' "$1")" "${2:-0}" > "$STAGED_DIR/session-list.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STAGED_DIR/show-notification.sh"
    chmod +x "$STAGED_DIR/session-list.sh" "$STAGED_DIR/show-notification.sh"
}

# ---------------------------------------------------------------------------
# Case 1/2: frame sequence on the quiet path. No frame is skipped and the
# order is list order — the property a wall-clock-derived frame fails.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: frame sequence on the quiet path — three ticks, three distinct frames in list order" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet 1234
    "
    [ "$status" -eq 0 ]
    local f1 c1; f1="$(_get_opt @clux_session_bar)"; c1="$(_get_opt @clux_frame_idx_1234)"

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet 1234
    "
    [ "$status" -eq 0 ]
    local f2 c2; f2="$(_get_opt @clux_session_bar)"; c2="$(_get_opt @clux_frame_idx_1234)"

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet 1234
    "
    [ "$status" -eq 0 ]
    local f3 c3; f3="$(_get_opt @clux_session_bar)"; c3="$(_get_opt @clux_frame_idx_1234)"

    [ "$f1" = "PRE-POST" ] || { echo "tick1: $f1"; false; }
    [ "$f2" = 'PRE\POST' ] || { echo "tick2: $f2"; false; }
    [ "$f3" = 'PRE|POST' ] || { echo "tick3: $f3"; false; }
    [ "$c1" = "1" ]; [ "$c2" = "2" ]; [ "$c3" = "3" ]
}

# ---------------------------------------------------------------------------
# Case 3: the hook path does not advance.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: the hook path does not advance the shared counter" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_opt_store_tmux_stub
    _seed_opt @clux_frame_idx "2"
    _stage_anim "HOOKBAR"

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        export STUB_LOG='$log'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]

    [ "$(_get_opt @clux_frame_idx)" = "2" ] || { echo "counter moved: $(_get_opt @clux_frame_idx)"; false; }
    run grep -qF 'set-option -g @clux_frame_idx ' "$log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Case 4: template reuse under FULL_EVERY — a fresh template does not invoke
# session-list.sh (the ~110ms render this whole design exists to avoid).
# ---------------------------------------------------------------------------
@test "session-bar-refresh: template reuse under FULL_EVERY — a fresh template does not invoke session-list.sh" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    local marker="$BATS_TEST_TMPDIR/list-invoked"
    _write_opt_store_tmux_stub
    _stage_anim "SHOULD-NOT-BE-USED"
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        export MARKER_FILE='$marker'
        '$STAGED_DIR/session-bar-refresh.sh' quiet
    "
    [ "$status" -eq 0 ]
    [ ! -e "$marker" ] || { echo "session-list.sh was invoked on a fresh template"; false; }
}

# ---------------------------------------------------------------------------
# Case 5: full render after FULL_EVERY.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: full render after FULL_EVERY — a stale template invokes session-list.sh and rewrites both options" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    local marker="$BATS_TEST_TMPDIR/list-invoked"
    _write_opt_store_tmux_stub
    _stage_anim "FRESH${SENTINEL}BAR"
    local now stale; now=$(date +%s); stale=$(( now - 6 ))
    _seed_opt @clux_bar_tpl "${stale}${TAB}OLD${SENTINEL}BAR"

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        export MARKER_FILE='$marker'
        '$STAGED_DIR/session-bar-refresh.sh' quiet
    "
    [ "$status" -eq 0 ]
    [ -e "$marker" ] || { echo "session-list.sh was NOT invoked on a stale template"; false; }
    local tpl bar
    tpl="$(_get_opt @clux_bar_tpl)"
    bar="$(_get_opt @clux_session_bar)"
    [[ "$tpl" == *"FRESH${SENTINEL}BAR" ]] || { echo "template not rewritten: $tpl"; false; }
    [[ "$tpl" != "${stale}"* ]] || { echo "template epoch not refreshed: $tpl"; false; }
    [ -n "$bar" ]
    [[ "$bar" != *"$SENTINEL"* ]]
}

# ---------------------------------------------------------------------------
# Case 6: full render on a missing template.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: full render on a missing template" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    local marker="$BATS_TEST_TMPDIR/list-invoked"
    _write_opt_store_tmux_stub
    _stage_anim "ROWBAR"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        export MARKER_FILE='$marker'
        '$STAGED_DIR/session-bar-refresh.sh' quiet
    "
    [ "$status" -eq 0 ]
    [ -e "$marker" ] || { echo "session-list.sh was not invoked when no template existed"; false; }
    [ -n "$(_get_opt @clux_bar_tpl)" ]
    [ -n "$(_get_opt @clux_session_bar)" ]
}

# ---------------------------------------------------------------------------
# Case 7: idle writes nothing — a fresh template with no sentinel leaves
# @clux_session_bar untouched, but the counter still advances and
# @clux_status is still written.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: idle — a fresh template with no sentinel writes no @clux_session_bar" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_opt_store_tmux_stub
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PLAIN BAR NO BUSY"

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        export STUB_LOG='$log'
        '$REFRESH_SCRIPT' quiet
    "
    [ "$status" -eq 0 ]
    run grep -qF 'set-option -g @clux_session_bar' "$log"
    [ "$status" -ne 0 ]
    [ "$(_get_opt @clux_frame_idx)" = "1" ]
    grep -qF 'set-option -g @clux_status' "$log" || false
}

# ---------------------------------------------------------------------------
# Case 8: the sentinel must never reach the screen — cheap tick, full render.
# (The empty-frames-list sub-case is case 9 below, which asserts the same
# thing plus the "never empty" half.)
# ---------------------------------------------------------------------------
@test "session-bar-refresh: the sentinel never reaches @clux_session_bar — cheap tick" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet
    "
    [ "$status" -eq 0 ]
    local bar; bar="$(_get_opt @clux_session_bar)"
    [ -n "$bar" ]
    [[ "$bar" != *"$SENTINEL"* ]]
}

@test "session-bar-refresh: the sentinel never reaches @clux_session_bar — full render" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub
    _stage_anim "BAR${SENTINEL}ALPHA"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$STAGED_DIR/session-bar-refresh.sh' quiet
    "
    [ "$status" -eq 0 ]
    local bar; bar="$(_get_opt @clux_session_bar)"
    [ -n "$bar" ]
    [[ "$bar" != *"$SENTINEL"* ]]
}

# ---------------------------------------------------------------------------
# Case 9: an empty frames list still substitutes one column, never empty.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: an empty frames list still substitutes one column, never empty" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub
    _seed_opt @clux-agent-glyph-busy-frames "   "
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet
    "
    [ "$status" -eq 0 ]
    [ "$(_get_opt @clux_session_bar)" = "PRE*POST" ]
}

# ---------------------------------------------------------------------------
# Case 10: two client ids do not collide.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: two distinct client ids do not collide" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet 111
    "
    [ "$status" -eq 0 ]

    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet 222
    "
    [ "$status" -eq 0 ]

    [ "$(_get_opt @clux_frame_idx_111)" = "1" ]
    [ "$(_get_opt @clux_frame_idx_222)" = "1" ]
    [ -z "$(_get_opt @clux_frame_idx)" ]
}

# ---------------------------------------------------------------------------
# Case 11: no client id falls back to the shared counter — the legacy token
# form from a 3.3/3.4 install keeps working.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: no client id falls back to the shared counter — legacy token still works" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet
    "
    [ "$status" -eq 0 ]
    [ "$(_get_opt @clux_frame_idx)" = "1" ]
}

# ---------------------------------------------------------------------------
# Case 12: a hostile client id is refused — read the shared counter, and the
# logged display-message format string carries no injected text.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: a hostile client id is refused — falls back to the shared counter, no injection" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_opt_store_tmux_stub
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        export STUB_LOG='$log'
        '$REFRESH_SCRIPT' quiet '}#{q:#H}'
    "
    [ "$status" -eq 0 ]
    [ "$(_get_opt @clux_frame_idx)" = "1" ]
    run grep -qF '#{q:#H}' "$log"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Case 13: quiet with a fresh template still writes @clux_status — the one
# assertion that keeps the notification half out of the animation throttle.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: quiet with a fresh template still writes @clux_status" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    local log="$BATS_TEST_TMPDIR/stub.log"
    _write_opt_store_tmux_stub
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        export STUB_LOG='$log'
        '$REFRESH_SCRIPT' quiet
    "
    [ "$status" -eq 0 ]
    grep -qF 'set-option -g @clux_status' "$log" || false
}

# ---------------------------------------------------------------------------
# Case 14: a failing session-list.sh leaves BOTH the bar and the template
# untouched — extends the existing "empty session bar" test to the template.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: a failing session-list.sh leaves BOTH @clux_session_bar and @clux_bar_tpl untouched" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub
    _stage_anim "" 1
    _seed_opt @clux_session_bar "PRIOR-BAR"
    _seed_opt @clux_bar_tpl "1${TAB}PRIOR-TPL"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$STAGED_DIR/session-bar-refresh.sh'
    "
    [ "$status" -eq 0 ]
    [ "$(_get_opt @clux_session_bar)" = "PRIOR-BAR" ]
    [ "$(_get_opt @clux_bar_tpl)" = "1${TAB}PRIOR-TPL" ]
}

# ---------------------------------------------------------------------------
# Case 15: a frame containing a backslash survives substitution intact.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: a frame containing a backslash survives substitution intact" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub
    _seed_opt @clux_frame_idx "1"
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet
    "
    [ "$status" -eq 0 ]
    [ "$(_get_opt @clux_session_bar)" = 'PRE\POST' ]
}

# ---------------------------------------------------------------------------
# Case 16: a frame containing # is doubled before it is substituted — the
# substitution happens downstream of session-list.sh's own esc(), so a
# user-supplied frame containing "#" would otherwise inject a style.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: a frame containing # is doubled before substitution" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub
    _seed_opt @clux-agent-glyph-busy-frames 'a#b c'
    local now; now=$(date +%s)
    _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export CLUX_OPT_DIR='$OPT_DIR'
        '$REFRESH_SCRIPT' quiet
    "
    [ "$status" -eq 0 ]
    [ "$(_get_opt @clux_session_bar)" = "PREa##bPOST" ]
}

# ---------------------------------------------------------------------------
# Case 17: cross-check — helpers.sh's get_agent_frame() and this script's
# inline parser must never drift apart (D5: the logic is a deliberate second
# copy, pinned together by this test). Covers the shipped default, the
# single-glyph fallback, and a list containing "#", across six indices each.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: cross-check — helpers.sh get_agent_frame agrees with the inline parser" {
    local OPT_DIR="$BATS_TEST_TMPDIR/opt"
    _write_opt_store_tmux_stub

    local cfg frames_val busy_val idx now inline_bar inline_val helper_val
    for cfg in "__unset__:__unset__" "__unset__:@" "a#b c:__unset__"; do
        frames_val="${cfg%%:*}"
        busy_val="${cfg#*:}"
        rm -f "$OPT_DIR/@clux-agent-glyph-busy-frames" "$OPT_DIR/@clux-agent-glyph-busy"
        [ "$frames_val" = "__unset__" ] || _seed_opt @clux-agent-glyph-busy-frames "$frames_val"
        [ "$busy_val" = "__unset__" ] || _seed_opt @clux-agent-glyph-busy "$busy_val"

        for idx in 0 1 2 3 4 5; do
            _seed_opt @clux_frame_idx "$idx"
            now=$(date +%s)
            _seed_opt @clux_bar_tpl "${now}${TAB}PRE${SENTINEL}POST"

            run bash -c "
                export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
                export HOME='$BATS_TEST_TMPDIR/home'
                export CLUX_OPT_DIR='$OPT_DIR'
                '$REFRESH_SCRIPT' quiet
            "
            [ "$status" -eq 0 ]
            inline_bar="$(_get_opt @clux_session_bar)"
            inline_val="${inline_bar#PRE}"
            inline_val="${inline_val%POST}"

            run bash -c "
                export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
                export HOME='$BATS_TEST_TMPDIR/home'
                export CLUX_OPT_DIR='$OPT_DIR'
                source '$SCRIPTS_DIR/helpers.sh'
                get_agent_frame $idx
            "
            [ "$status" -eq 0 ]
            helper_val="$output"

            [ "$inline_val" = "$helper_val" ] || {
                echo "cfg=[$cfg] idx=$idx inline=[$inline_val] helper=[$helper_val]"
                false
            }
        done
    done
}

# ---------------------------------------------------------------------------
# Case 18: real-server three-tick test (spec Testing section). Uses REAL
# tmux, a real agent-state file marking one pane busy, exactly the harness
# shape test/agent-state-server-scope.bats uses. Proves the display-message
# -p template round-trip against real tmux, not just the stub.
# ---------------------------------------------------------------------------
@test "session-bar-refresh: real-server three-tick — three distinct frames, no sentinel ever shown" {
    local sock="clux-anim-$$-${BATS_TEST_NUMBER}"
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    "$REAL_TMUX" -L "$sock" new-session -d -x 80 -y 24
    local sockpath pane
    sockpath="$("$REAL_TMUX" -L "$sock" display-message -p '#{socket_path}')"
    pane="$("$REAL_TMUX" -L "$sock" list-panes -a -F '#{pane_id}' | head -1)"

    local store="$BATS_TEST_TMPDIR/store"
    mkdir -p "$store"

    # Mark the pane busy through the real hook, exactly as the hook itself
    # would — not a fixture, the real writer.
    printf '' | env TMUX="$sockpath,0,0" TMUX_PANE="$pane" \
        PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin" \
        CLUX_AGENT_STATE_DIR="$store" \
        "$HOOKS_DIR/agent-state.sh" busy

    local f1 f2 f3
    env TMUX="$sockpath,0,0" PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin" \
        CLUX_AGENT_STATE_DIR="$store" \
        "$REFRESH_SCRIPT" quiet 4242 >/dev/null 2>&1
    f1="$("$REAL_TMUX" -L "$sock" show-option -gqv @clux_session_bar)"

    env TMUX="$sockpath,0,0" PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin" \
        CLUX_AGENT_STATE_DIR="$store" \
        "$REFRESH_SCRIPT" quiet 4242 >/dev/null 2>&1
    f2="$("$REAL_TMUX" -L "$sock" show-option -gqv @clux_session_bar)"

    env TMUX="$sockpath,0,0" PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin" \
        CLUX_AGENT_STATE_DIR="$store" \
        "$REFRESH_SCRIPT" quiet 4242 >/dev/null 2>&1
    f3="$("$REAL_TMUX" -L "$sock" show-option -gqv @clux_session_bar)"

    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    rm -f "$sockpath" >/dev/null 2>&1 || true

    [ -n "$f1" ] && [ -n "$f2" ] && [ -n "$f3" ] || { echo "a tick produced no bar: [$f1] [$f2] [$f3]"; false; }
    [ "$f1" != "$f2" ] || { echo "frame 1 and 2 did not differ: $f1"; false; }
    [ "$f2" != "$f3" ] || { echo "frame 2 and 3 did not differ: $f2"; false; }
    [ "$f1" != "$f3" ] || { echo "frame 1 and 3 did not differ: $f1"; false; }
    [[ "$f1" != *"$SENTINEL"* ]] || { echo "sentinel reached the screen (tick 1)"; false; }
    [[ "$f2" != *"$SENTINEL"* ]] || { echo "sentinel reached the screen (tick 2)"; false; }
    [[ "$f3" != *"$SENTINEL"* ]] || { echo "sentinel reached the screen (tick 3)"; false; }
}
