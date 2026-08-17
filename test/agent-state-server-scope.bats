#!/usr/bin/env bats
# agent-state-server-scope.bats — the state store is scoped to ONE tmux server.
#
# A tmux pane id is unique only INSIDE one server. Two servers both hand out
# %0, %1, %2 …, and the agent-state store is one directory per $HOME, so before
# this scoping the two servers shared a namespace and collided in both
# directions: server B drew a glyph for a Claude running on server A, and B's
# reaper deleted A's files. The same aliasing hit one server across a restart,
# because a fresh server starts again at %0.
#
# These tests use REAL tmux on two sockets rather than the stub used elsewhere
# in the suite. A stub would only prove that the stub and the scripts agree
# about pane ids; the bug being fixed is a fact about tmux itself, so the two
# servers have to be real.
#
# Every script under test calls bare `tmux`. A one-line shim per server, first
# on PATH, is what points a script at server A or server B — the same way a
# real user's two servers each answer their own panes.

load test_helper

REAL_TMUX="$(command -v tmux)"
AGENT_HOOK="$HOOKS_DIR/agent-state.sh"
AGENT_QUERY="$SCRIPTS_DIR/agent-query.sh"
AGENT_CLEAR="$SCRIPTS_DIR/agent-clear.sh"

# Sockets are per-test so a stray server from one test cannot reach another.
_sock() { printf 'cluxscope-%s-%s' "$$" "$1"; }

# _start <tag>  — start a server and a shim that points bare `tmux` at it.
# Echoes nothing; sets up "$BATS_TEST_TMPDIR/bin-<tag>/tmux".
_start() {
    local tag="$1" sock; sock="$(_sock "$tag")"
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    "$REAL_TMUX" -L "$sock" new-session -d -s "sess-$tag" -x 80 -y 24
    mkdir -p "$BATS_TEST_TMPDIR/bin-$tag"
    printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$sock" \
        > "$BATS_TEST_TMPDIR/bin-$tag/tmux"
    chmod +x "$BATS_TEST_TMPDIR/bin-$tag/tmux"
}

# _stop <tag> — kill the server AND unlink its socket. tmux never removes a
# socket file when its server exits, so a test that only killed the server
# would leave one behind per run.
_stop() {
    local tag="$1" sock sockpath
    sock="$(_sock "$tag")"
    sockpath="$("$REAL_TMUX" -L "$sock" display-message -p '#{socket_path}' 2>/dev/null || true)"
    "$REAL_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
    [ -n "$sockpath" ] && rm -f "$sockpath" 2>/dev/null
    return 0
}

# _on <tag> <cmd...> — run a clux script against server <tag>.
_on() {
    local tag="$1"; shift
    env PATH="$BATS_TEST_TMPDIR/bin-$tag:/usr/bin:/bin" \
        CLUX_AGENT_STATE_DIR="$STORE" "$@"
}

# _pane <tag> — first pane id on that server.
_pane() { "$REAL_TMUX" -L "$(_sock "$1")" list-panes -a -F '#{pane_id}' | head -1; }

# _key <tag> — the server key the scripts derive for that server.
_key() { "$REAL_TMUX" -L "$(_sock "$1")" display-message -p '#{pid}-#{start_time}'; }

# _mark <tag> <pane> <state> — write state the way the hook does, through the
# hook itself, so the test exercises the real writer and not a fixture.
_mark() {
    local tag="$1" pane="$2" state="$3" sockpath
    sockpath="$("$REAL_TMUX" -L "$(_sock "$tag")" display-message -p '#{socket_path}')"
    printf '' | env PATH="$BATS_TEST_TMPDIR/bin-$tag:/usr/bin:/bin" \
        CLUX_AGENT_STATE_DIR="$STORE" \
        TMUX="$sockpath,0,0" TMUX_PANE="$pane" "$AGENT_HOOK" "$state"
}

setup_file() { :; }

setup() {
    install_stubs
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    STORE="$BATS_TEST_TMPDIR/store"
    mkdir -p "$STORE"
}

teardown() {
    _stop A; _stop B
    rm -rf "$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# 1. The false positive. Two servers, both numbering panes from %0.
# ---------------------------------------------------------------------------
@test "scope: a busy agent on one server draws no glyph on another server" {
    _start A; _start B
    local pa pb
    pa="$(_pane A)"; pb="$(_pane B)"
    # The premise of the whole bug — assert it rather than assume it.
    [ "$pa" = "$pb" ] || skip "the two servers did not collide on a pane id"

    _mark A "$pa" busy

    local on_a on_b
    on_a="$(_on A "$AGENT_QUERY")"
    on_b="$(_on B "$AGENT_QUERY")"

    [ -n "$on_a" ] || { echo "server A lost its own agent: [$on_a]"; false; }
    [ -z "$on_b" ] || { echo "server B reported another server's agent: [$on_b]"; false; }
}

# ---------------------------------------------------------------------------
# 2. The destructive half. Any hook fire on B runs the reaper, which used to
#    judge A's files against B's pane listing.
# ---------------------------------------------------------------------------
@test "scope: a reap on one server never deletes another server's state" {
    _start A; _start B
    local pa
    # Give A more panes than B, so A's highest pane id cannot exist on B.
    "$REAL_TMUX" -L "$(_sock A)" new-window -t sess-A
    "$REAL_TMUX" -L "$(_sock A)" new-window -t sess-A
    pa="$("$REAL_TMUX" -L "$(_sock A)" list-panes -a -F '#{pane_id}' | tail -1)"

    _mark A "$pa" needs-you
    [ -n "$(_on A "$AGENT_QUERY")" ] || { echo "precondition failed: A shows nothing"; false; }

    # A hook fires on B — the reaper runs there.
    _on B bash -c "source '$SCRIPTS_DIR/path.sh'; reap_agent_state_dir '$STORE'"

    local still
    still="$(_on A "$AGENT_QUERY")"
    [ -n "$still" ] || { echo "server B's reap deleted server A's state"; false; }
}

# ---------------------------------------------------------------------------
# 3. Same socket, restarted server: pane ids start over at %0, so the old
#    server's files must not be adopted by the new one.
# ---------------------------------------------------------------------------
@test "scope: state does not survive a server restart onto the reused pane id" {
    _start A
    local pane old_key
    pane="$(_pane A)"
    old_key="$(_key A)"
    _mark A "$pane" needs-you
    [ -n "$(_on A "$AGENT_QUERY")" ] || { echo "precondition failed"; false; }

    _stop A
    _start A
    [ "$(_pane A)" = "$pane" ] || skip "the restarted server did not reuse the pane id"
    [ "$(_key A)" != "$old_key" ] || { echo "server key did not change across a restart"; false; }

    local after
    after="$(_on A "$AGENT_QUERY")"
    [ -z "$after" ] || { echo "a restarted server inherited the old server's state: [$after]"; false; }
}

# ---------------------------------------------------------------------------
# 4. Files written by an older clux carry no server, so they cannot be
#    attributed to anyone. Adopting them would manufacture the very false
#    positive this change removes, so the reaper deletes them.
# ---------------------------------------------------------------------------
@test "scope: unscoped files from an older version are swept, never adopted" {
    _start A
    local pane
    pane="$(_pane A)"
    # Exactly what clux <= 3.3.0 wrote: keyed by pane id alone.
    printf 'needs-you\n' > "$STORE/$pane"
    mkdir -p "$STORE/agents"
    printf 'busy\n' > "$STORE/agents/$pane~legacy-session-id"

    local shown
    shown="$(_on A "$AGENT_QUERY")"
    [ -z "$shown" ] || { echo "an unattributable legacy file was adopted: [$shown]"; false; }

    _on A bash -c "source '$SCRIPTS_DIR/path.sh'; reap_agent_state_dir '$STORE'"
    [ ! -e "$STORE/$pane" ] || { echo "legacy pane file survived the reap"; false; }
    [ ! -e "$STORE/agents/$pane~legacy-session-id" ] || { echo "legacy agent file survived the reap"; false; }
}

# ---------------------------------------------------------------------------
# 5. Regression guard: scoping must not stop the reaper doing its actual job
#    inside its own server.
# ---------------------------------------------------------------------------
@test "scope: the reaper still deletes dead-pane files within its own server" {
    _start A
    local pane key
    pane="$(_pane A)"; key="$(_key A)"
    _mark A "$pane" busy
    [ -f "$STORE/$key/$pane" ] || { echo "writer did not scope by server: $(ls -R "$STORE")"; false; }

    # A pane id that server A has never handed out.
    printf 'busy\n' > "$STORE/$key/%999"
    _on A bash -c "source '$SCRIPTS_DIR/path.sh'; reap_agent_state_dir '$STORE'"

    [ ! -e "$STORE/$key/%999" ] || { echo "dead-pane file survived its own server's reap"; false; }
    [ -f "$STORE/$key/$pane" ] || { echo "the reaper ate a live pane's file"; false; }
}

# ---------------------------------------------------------------------------
# 6. A dead server's directory is collected. Its pid is gone, so nothing can
#    claim those files, and leaving them would grow the store without bound.
# ---------------------------------------------------------------------------
@test "scope: a dead server's directory is collected by a live server's reap" {
    _start A; _start B
    local key_b
    key_b="$(_key B)"
    _mark B "$(_pane B)" busy
    [ -d "$STORE/$key_b" ] || { echo "server B wrote nothing"; false; }

    _stop B
    _on A bash -c "source '$SCRIPTS_DIR/path.sh'; reap_agent_state_dir '$STORE'"

    [ ! -e "$STORE/$key_b" ] || { echo "the dead server's directory survived: $(ls -R "$STORE")"; false; }
}

# ---------------------------------------------------------------------------
# 7. A LIVE foreign server's directory is left alone — the collector must not
#    become the cross-server deletion it replaces.
# ---------------------------------------------------------------------------
@test "scope: a live server's directory survives another server's reap" {
    _start A; _start B
    local key_b
    key_b="$(_key B)"
    _mark B "$(_pane B)" busy

    _on A bash -c "source '$SCRIPTS_DIR/path.sh'; reap_agent_state_dir '$STORE'"

    [ -f "$STORE/$key_b/$(_pane B)" ] || { echo "a live server's state was collected"; false; }
    [ -n "$(_on B "$AGENT_QUERY")" ] || { echo "server B lost its own agent"; false; }
}

# ---------------------------------------------------------------------------
# 8. agent-clear.sh reads the store too, so it must be scoped the same way:
#    looking at a window on B must not clear a finished mark on A.
# ---------------------------------------------------------------------------
@test "scope: clearing a window on one server leaves another server's marks" {
    _start A; _start B
    local pa pb key_a
    pa="$(_pane A)"; pb="$(_pane B)"; key_a="$(_key A)"
    [ "$pa" = "$pb" ] || skip "the two servers did not collide on a pane id"

    _mark A "$pa" finished
    [ -f "$STORE/$key_a/$pa" ] || { echo "precondition failed: no file at $STORE/$key_a/$pa"; false; }

    local win_b
    win_b="$("$REAL_TMUX" -L "$(_sock B)" list-windows -F '#{window_id}' | head -1)"
    _on B "$AGENT_CLEAR" "$win_b"

    [ -f "$STORE/$key_a/$pa" ] || { echo "a clear on server B removed server A's mark"; false; }
}
