#!/usr/bin/env bats
# corpus.bats — the corpus invariant test the config-updater design asks for
# (docs/superpowers/specs/2026-08-10-clux-config-updater-skill-design.md,
# "Testing"). Corpus files live in test/fixtures/: empty, plain status-left,
# status-format[N], already installed, installed then hand-edited, and the
# author's real tmux.conf as the seventh case — the only one that exercises
# status-format[0] with nested #[...] escapes, if-shell, and indexed hooks
# together.
#
# SCOPE NOTE, stated plainly rather than faked: the actual byte-preserving
# EDIT — inserting the source-file line and the two token strings into a
# user's live tmux.conf — is judgement performed by the LLM itself inside
# commands/setup.md (Phase 4, "Use the Edit tool on the single line ...").
# There is no deterministic script in this repo that performs that edit, so
# there is nothing here a bats process can invoke to drive it — the
# config-updater design's own "Testing" section says exactly this about a
# skill ("test the invariant instead"). What this file DOES cover, with real
# assertions against real files:
#   1. The corpus itself exists and is well-formed — every "before" fixture
#      genuinely has no clux wiring yet, and every "after" fixture genuinely
#      satisfies the invariant (source-file once, each token once,
#      contiguous session-bar token) — a concrete, runnable specification of
#      what "satisfies the invariant" means, so a regression in a fixture
#      itself cannot go unnoticed.
#   2. Every fixture — before AND after — parses cleanly on a real,
#      throwaway tmux server via verify-tmux-conf.sh, the actual deterministic
#      mechanical piece that exists today and that the future installer must
#      also pass.
# When the deterministic installer script this corpus is "the deliverable
# that makes testable" lands, its own test should drive it against every
# fixture here and assert assertion 4 from the design: every line the
# installer did not add is byte-identical to the input.

load test_helper

REAL_TMUX="$(command -v tmux)"
VERIFY_SCRIPT="$SCRIPTS_DIR/verify-tmux-conf.sh"
FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures"

BEFORE_FIXTURES="empty plain-status-left status-format-n author-real"
AFTER_FIXTURES="already-installed installed-then-hand-edited"

# See verify-tmux-conf.bats for why: verify-tmux-conf.sh backgrounds a
# `< <(tail -f /dev/null)` helper process no trap can reap, so every call
# here redirects to a file (never `run`/$( )) and reaps the leak afterward.
_run_verify() {
    local conf="$1" log="$2"
    if bash -c "PATH='$(dirname "$REAL_TMUX"):/usr/bin:/bin' '$VERIFY_SCRIPT' '$conf'" >"$log" 2>&1 </dev/null; then
        VERIFY_STATUS=0
    else
        VERIFY_STATUS=$?
    fi
    pkill -f 'tail -f /dev/null' >/dev/null 2>&1 || true
}

teardown() {
    pkill -f 'tail -f /dev/null' >/dev/null 2>&1 || true
    rm -rf "$BATS_TEST_TMPDIR"
}

# author-real.conf runs three SYNCHRONOUS (non "-b") run-shell commands and
# loads a plugin .tmux file at source time — real config-file commands that
# execute immediately, unlike the #() jobs embedded inside a status-format
# VALUE (those are only evaluated later, by the status-line renderer, and
# never fail source-file itself). Stub exactly those paths under a fake HOME
# so the parse can complete the way it would on a machine where clux and the
# author's own scripts are actually deployed.
_stub_author_real_home() {
    local home="$1"
    mkdir -p "$home/.config/tmux/scripts" "$home/.config/clux/scripts" \
        "$home/.config/tmux/plugins/tmux-resurrect"
    printf '#!/bin/sh\nexit 0\n' > "$home/.config/tmux/scripts/session-bar-refresh.sh"
    printf '#!/bin/sh\nexit 0\n' > "$home/.config/clux/scripts/agent-clear.sh"
    printf '#!/bin/sh\nexit 0\n' > "$home/.config/tmux/plugins/tmux-resurrect/resurrect.tmux"
    chmod +x "$home/.config/tmux/scripts/session-bar-refresh.sh" \
        "$home/.config/clux/scripts/agent-clear.sh" \
        "$home/.config/tmux/plugins/tmux-resurrect/resurrect.tmux"
}

@test "corpus: every 'before' fixture genuinely has no clux wiring yet" {
    for name in $BEFORE_FIXTURES; do
        local f="$FIXTURES_DIR/$name.conf"
        [ -f "$f" ] || { echo "missing fixture: $f"; false; }
        run grep -c 'source-file -q .*clux\.tmux\.conf' "$f"
        [ "$output" = "0" ]
        run grep -F -o '#{@clux_session_bar}' "$f"
        [ -z "$output" ]
        run grep -F -o '#{@clux_status}' "$f"
        [ -z "$output" ]
    done
}

@test "corpus: every 'after' fixture satisfies the invariant — one source-file line, one of each token" {
    for name in $AFTER_FIXTURES; do
        local f="$FIXTURES_DIR/$name.conf"
        [ -f "$f" ] || { echo "missing fixture: $f"; false; }

        local source_count
        source_count=$(grep -c 'source-file -q .*clux\.tmux\.conf' "$f")
        [ "$source_count" -eq 1 ] || { echo "$name: source-file count=$source_count"; false; }

        local bar_count
        bar_count=$(grep -F -o '#{@clux_session_bar}' "$f" | wc -l | tr -d ' ')
        [ "$bar_count" -eq 1 ] || { echo "$name: @clux_session_bar count=$bar_count"; false; }

        local status_count
        status_count=$(grep -F -o '#{@clux_status}' "$f" | wc -l | tr -d ' ')
        [ "$status_count" -eq 1 ] || { echo "$name: @clux_status count=$status_count"; false; }

        local quiet_count
        quiet_count=$(grep -F -o 'session-bar-refresh.sh quiet' "$f" | wc -l | tr -d ' ')
        [ "$quiet_count" -eq 1 ] || { echo "$name: 'session-bar-refresh.sh quiet' count=$quiet_count"; false; }
    done
}

@test "corpus: the session-bar token string is the CONTIGUOUS pair, never #{@clux_session_bar} alone" {
    for name in $AFTER_FIXTURES; do
        local f="$FIXTURES_DIR/$name.conf"
        grep -qF '#{@clux_session_bar}#(~/.config/clux/scripts/session-bar-refresh.sh quiet)' "$f" \
            || { echo "$name: contiguous session-bar token string not found"; false; }
    done
}

@test "corpus: every before-fixture parses cleanly on a real, throwaway tmux server" {
    for name in empty plain-status-left status-format-n; do
        local f="$FIXTURES_DIR/$name.conf"
        local log="$BATS_TEST_TMPDIR/$name.log"
        _run_verify "$f" "$log"
        [ "$VERIFY_STATUS" -eq 0 ] || { echo "$name failed:"; cat "$log"; false; }
    done
}

@test "corpus: the author's real tmux.conf (the seventh case) parses cleanly given its own scripts are present" {
    local fake_home="$BATS_TEST_TMPDIR/home-authorreal"
    _stub_author_real_home "$fake_home"
    local f="$FIXTURES_DIR/author-real.conf"
    local log="$BATS_TEST_TMPDIR/author-real.log"
    HOME="$fake_home" bash -c "PATH='$(dirname "$REAL_TMUX"):/usr/bin:/bin' HOME='$fake_home' '$VERIFY_SCRIPT' '$f'" >"$log" 2>&1 </dev/null
    local status=$?
    pkill -f 'tail -f /dev/null' >/dev/null 2>&1 || true
    [ "$status" -eq 0 ] || { cat "$log"; false; }
}

@test "corpus: every after-fixture parses cleanly on a real, throwaway tmux server (source-file -q tolerates the missing clux.tmux.conf)" {
    for name in $AFTER_FIXTURES; do
        local f="$FIXTURES_DIR/$name.conf"
        local log="$BATS_TEST_TMPDIR/$name.log"
        _run_verify "$f" "$log"
        [ "$VERIFY_STATUS" -eq 0 ] || { echo "$name failed:"; cat "$log"; false; }
    done
}
