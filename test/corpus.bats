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
# skills/configuring-tmux/SKILL.md (Phase 4, "Use the Edit tool on the single
# line ...").
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

BEFORE_FIXTURES="empty plain-status-left status-format-n generated-by-tool author-real"
AFTER_FIXTURES="already-installed installed-then-hand-edited status-format-n-installed"

# Two eras of the "quiet" job, both represented on purpose (animated
# busy-glyph design, 2026-08-23): already-installed.conf and
# installed-then-hand-edited.conf stay on the argument-less legacy form
# (session-bar-refresh.sh falls back to one shared frame counter on it, so a
# 3.3/3.4-era install keeps working unchanged). status-format-n-installed.conf
# carries the new "#{client_pid}" argument instead — no comment is added to
# that fixture's own body for it, because ASSERTION 4 below diffs it, byte for
# byte, against status-format-n.conf once clux's additions are stripped; a
# stray comment there would fail that diff even though the install itself is
# correct. It is also the one fixture that proves real tmux parses
# "#{client_pid}" inside a #() job's argument, embedded in a single-quoted
# status-format[0] value.

# Every verify call redirects to a file (never `run`/$( )) so its output can
# be shown on failure. It no longer needs to reap anything: verify-tmux-conf.sh
# used to background a `< <(tail -f /dev/null)` helper whose pid bash 3.2 does
# not report in $!, so it leaked one process per call and the tests papered
# over it with `pkill -f 'tail -f /dev/null'` — which would also have killed
# an unrelated process of the user's carrying that same command line. The
# script now holds its own fifo open instead and leaves nothing behind.
_run_verify() {
    local conf="$1" log="$2"
    if bash -c "PATH='$(dirname "$REAL_TMUX"):/usr/bin:/bin' '$VERIFY_SCRIPT' '$conf'" >"$log" 2>&1 </dev/null; then
        VERIFY_STATUS=0
    else
        VERIFY_STATUS=$?
    fi
}

teardown() {
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
    # No closing ")" in the needle: since the animated-busy-glyph design
    # (2026-08-23), the "quiet" job optionally carries a trailing
    # "#{client_pid}" argument (status-format-n-installed.conf is on the new
    # form; already-installed.conf and installed-then-hand-edited.conf stay on
    # the argument-less legacy form on purpose — both must match here).
    for name in $AFTER_FIXTURES; do
        local f="$FIXTURES_DIR/$name.conf"
        grep -qF '#{@clux_session_bar}#(~/.config/clux/scripts/session-bar-refresh.sh quiet' "$f" \
            || { echo "$name: contiguous session-bar token string not found"; false; }
    done
}

@test "corpus: every before-fixture parses cleanly on a real, throwaway tmux server" {
    for name in empty plain-status-left status-format-n generated-by-tool; do
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
    # `local status=$?` after a bare command cannot work here: bats runs each
    # test under errexit, so a genuine failure aborts the test on the command
    # itself and the diagnostic below never runs — the test would report a
    # bare failure with the parse error still sitting unread in $log. The
    # if/else keeps the non-zero exit inside a tested condition.
    local vstatus=0
    if ! HOME="$fake_home" bash -c "PATH='$(dirname "$REAL_TMUX"):/usr/bin:/bin' HOME='$fake_home' '$VERIFY_SCRIPT' '$f'" >"$log" 2>&1 </dev/null; then
        vstatus=1
    fi
    [ "$vstatus" -eq 0 ] || { echo "author-real failed:"; cat "$log"; false; }
}

@test "corpus: ASSERTION 4 — an installed config differs from its source by clux's additions ALONE" {
    # The design's own words: "Every other line byte-identical to the input.
    # Assertion 4 is the whole requirement, expressed as a test."
    #
    # status-format-n-installed.conf is status-format-n.conf after a correct
    # install. Strip exactly what clux is allowed to add — the one source-file
    # line and the two token strings — and what remains must be the original,
    # byte for byte, comments and all. Any other edit the installer made shows
    # up here as a diff.
    local before="$FIXTURES_DIR/status-format-n.conf"
    local after="$FIXTURES_DIR/status-format-n-installed.conf"
    local stripped="$BATS_TEST_TMPDIR/stripped.conf"

    sed -e '/^source-file -q .*clux\.tmux\.conf$/d' \
        -e 's|#{@clux_session_bar}#(~/\.config/clux/scripts/session-bar-refresh\.sh quiet #{client_pid})||' \
        -e 's|#\[align=centre\]#{@clux_status}||' \
        "$after" > "$stripped"

    diff -u "$before" "$stripped" || {
        echo "installed fixture differs from its source by more than clux's additions"
        false
    }
}

@test "corpus: ASSERTION 5 — a second install adds nothing (each token still appears exactly once)" {
    # Idempotence, stated as the property that actually matters: an installer
    # run against an ALREADY-installed file must not add a second source-file
    # line or a second token. Every after-fixture is by definition the input
    # to a hypothetical second run, so asserting single-occurrence across all
    # of them is that check.
    for name in $AFTER_FIXTURES; do
        local f="$FIXTURES_DIR/$name.conf"
        local n
        n=$(grep -c 'source-file -q .*clux\.tmux\.conf' "$f")
        [ "$n" -eq 1 ] || { echo "$name: source-file appears $n times"; false; }
        n=$(grep -F -o '#{@clux_session_bar}' "$f" | wc -l | tr -d ' ')
        [ "$n" -eq 1 ] || { echo "$name: session-bar token appears $n times"; false; }
        n=$(grep -F -o '#{@clux_status}' "$f" | wc -l | tr -d ' ')
        [ "$n" -eq 1 ] || { echo "$name: status token appears $n times"; false; }
    done
}

@test "corpus: the generated-by-tool fixture is detectable as generated, so setup can refuse it" {
    # The sixth shape from the design's list. Nothing can safely edit it, so
    # the corpus carries it to keep the refusal path honest: it must look like
    # a before-fixture in every other way, and it must carry a generator
    # marker a reader can act on.
    local f="$FIXTURES_DIR/generated-by-tool.conf"
    [ -f "$f" ]
    grep -qiE 'do not edit|generated by' "$f" || {
        echo "generated-by-tool.conf carries no marker setup could detect"
        false
    }
}

@test "corpus: every after-fixture parses cleanly on a real, throwaway tmux server (source-file -q tolerates the missing clux.tmux.conf)" {
    for name in $AFTER_FIXTURES; do
        local f="$FIXTURES_DIR/$name.conf"
        local log="$BATS_TEST_TMPDIR/$name.log"
        _run_verify "$f" "$log"
        [ "$VERIFY_STATUS" -eq 0 ] || { echo "$name failed:"; cat "$log"; false; }
    done
}
