#!/usr/bin/env bats
# render-clux-conf.bats — render-clux-conf.sh: writes ~/.config/clux/clux.tmux.conf
# whole, every time. This is Tier 1 of the config-updater design: a file clux
# fully owns, so every run replaces it outright.
#
# These tests need the REAL tmux binary (to actually parse the rendered
# file on a throwaway server via verify-tmux-conf.sh), so REAL_TMUX is
# captured at file-load time, before test_helper's setup() prepends the
# stub directory to PATH — same pattern test_helper.bash itself uses to
# capture REAL_JQ.

load test_helper

REAL_TMUX="$(command -v tmux)"

RENDER_SCRIPT="$SCRIPTS_DIR/render-clux-conf.sh"
VERIFY_SCRIPT="$SCRIPTS_DIR/verify-tmux-conf.sh"

# A --scripts-dir populated with no-op stand-ins for the two scripts
# clux.tmux.conf's closing section runs synchronously at source time
# (agent-clear.sh --reap, session-bar-refresh.sh) — without these, sourcing
# the rendered file fails with "returned 127" before verification ever
# exercises anything else, exactly as the configuring-tmux skill's Phase 6
# documents.
_make_fake_scripts_dir() {
    local dir="$BATS_TEST_TMPDIR/fakescripts"
    mkdir -p "$dir"
    for s in agent-clear.sh session-bar-refresh.sh; do
        printf '#!/bin/sh\nexit 0\n' > "$dir/$s"
        chmod +x "$dir/$s"
    done
    printf '%s' "$dir"
}

@test "render-clux-conf: missing a required flag fails with usage, writes nothing" {
    run bash -c "'$RENDER_SCRIPT' --dir-resolver path --editor none --picker fzf"
    [ "$status" -eq 1 ]
    [[ "$output" == *"required"* ]]
}

@test "render-clux-conf: a non-numeric --bar-name-length is refused before anything is written" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --bar-name-length notanumber --out '$out'
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"numeric"* ]]
    [ ! -f "$out" ]
}

@test "render-clux-conf: emits the Part 3 answers and omits theming lines detection did not find" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver zoxide --editor nvim \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker choose-tree \
            --scripts-dir '$scripts_dir' --out '$out' --version 9.9.9
    "
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    grep -qF 'set -g @clux-dir-resolver "zoxide"' "$out" || false
    grep -qF 'set -g @clux-editor "nvim"' "$out" || false
    grep -qF "set -g @clux-agents-command 'claude agents --cwd \"\$PWD\"'" "$out" || false
    grep -qF 'set -g @clux-picker "choose-tree"' "$out" || false
    # No --agent-refresh-command was passed -> no line for it.
    run grep -qF '@clux-agent-refresh-command' "$out"
    [ "$status" -ne 0 ]
    # No --bar-* flags were passed -> no theming section at all (the header
    # comment mentions "@clux-bar-*" in prose, so match an actual set line).
    run grep -qF 'set -g "@clux-bar-' "$out"
    [ "$status" -ne 0 ]
    # The deliberately-absent runtime/session-order lines never appear as a
    # "set -g" statement (the header comment names them in prose, on purpose,
    # to document the naming rule — that mention is not a violation).
    run grep -qF 'set -g @clux-session-order' "$out"
    [ "$status" -ne 0 ]
    run grep -qF 'set -g @clux_session_bar' "$out"
    [ "$status" -ne 0 ]
    run grep -qF 'set -g @clux_status' "$out"
    [ "$status" -ne 0 ]
}

@test "render-clux-conf: no binding carries a command-prompt substitution — the injection regression" {
    # tmux substitutes a command-prompt answer into its command template BEFORE
    # parsing the template, and offers no way to escape the substitution. So a
    # `%1` inside a binding is a hole by construction, whatever the script it
    # calls does afterwards: the old
    #
    #   bind-key A command-prompt -p "Session name:" \
    #       "run-shell '.../new-workspace-prompt.sh \"%1\"'"
    #
    # ran arbitrary shell commands typed at the prompt, because a `"` in the
    # answer closed the shell quote. Typing `ws" ; touch FILE ; "` created FILE
    # on tmux 3.7b. The validation the script performed could never fire — the
    # substitution happened before the script started.
    #
    # This asserts the property rather than the one binding: any future binding
    # that reaches for command-prompt has to answer for it here.
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]

    run grep -n '%1' "$out"
    [ "$status" -ne 0 ] || { echo "a binding still substitutes a prompt answer:"; grep -n '%1' "$out"; false; }

    run grep -n 'command-prompt' "$out"
    [ "$status" -ne 0 ] || { echo "command-prompt is back:"; grep -n 'command-prompt' "$out"; false; }

    # And the A key still exists — the point is a safe prompt, not no prompt.
    grep -qF 'bind-key A display-popup' "$out" \
        || { echo "the A binding is gone entirely"; grep -n 'bind-key A' "$out"; false; }
    grep -qF 'new-workspace-prompt.sh' "$out" || false
}

@test "render-clux-conf: a passed theming flag is written, an omitted one is not" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --bar-name-attached-style 'bg=red,fg=white' \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set -g "@clux-bar-name-attached-style" "bg=red,fg=white"' "$out" || false
    run grep -qF '@clux-bar-name-detached-style' "$out"
    [ "$status" -ne 0 ]
}

@test "render-clux-conf: --agent-refresh-command is written only when passed" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --agent-refresh-command 'run-shell -b /x/session-bar-refresh.sh' \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set -g @clux-agent-refresh-command "run-shell -b /x/session-bar-refresh.sh"' "$out" || false
}

@test "render-clux-conf: output parses cleanly on a throwaway real tmux server" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    # verify-tmux-conf.sh backgrounds a control client fed by
    # `< <(tail -f /dev/null)`, which outlives the script by design (see its
    # own header comment). A `run`/$( ) capture waits for every writer on the
    # pipe to close and hangs forever on that leftover process, so — exactly
    # like the configuring-tmux skill's own Phase 6 step 8 — redirect to a FILE and
    # read the exit status back out-of-band instead.
    local log="$BATS_TEST_TMPDIR/verify.log"
    bash -c "PATH='$(dirname "$REAL_TMUX"):/usr/bin:/bin' '$VERIFY_SCRIPT' '$out'" >"$log" 2>&1 </dev/null
    local verify_status=$?
    # The leaked `tail -f /dev/null` (there is no clean way for
    # verify-tmux-conf.sh to reap a process-substitution grandchild) still
    # holds fds inherited from further up this test-harness's own process
    # tree, which hangs any OUTER capture of this whole test run even though
    # the redirect-to-file above already isolated verify-tmux-conf.sh's own
    # output. Reap it explicitly so the suite itself never hangs on it.
    pkill -f 'tail -f /dev/null' >/dev/null 2>&1 || true
    [ "$verify_status" -eq 0 ] || { cat "$log"; false; }
}

@test "render-clux-conf: running it twice produces content-identical files, ignoring only the Generated timestamp" {
    local out1="$BATS_TEST_TMPDIR/first.tmux.conf"
    local out2="$BATS_TEST_TMPDIR/second.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver autojump --editor vim \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --bar-separator '~' \
            --scripts-dir '$scripts_dir' --out '$out1' --version 3.3.0
    "
    [ "$status" -eq 0 ]
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver autojump --editor vim \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --bar-separator '~' \
            --scripts-dir '$scripts_dir' --out '$out2' --version 3.3.0
    "
    [ "$status" -eq 0 ]
    diff <(grep -v '^# Generated:' "$out1") <(grep -v '^# Generated:' "$out2")
}

@test "render-clux-conf: drops @clux_bar_tpl above the closing seed render (animated busy glyph, 3.5.0)" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set -gu @clux_bar_tpl' "$out" || { echo "no set -gu @clux_bar_tpl line"; false; }
    local drop_line seed_line
    drop_line=$(grep -n 'set -gu @clux_bar_tpl' "$out" | head -1 | cut -d: -f1)
    seed_line=$(grep -n 'run-shell ".*session-bar-refresh\.sh"$' "$out" | tail -1 | cut -d: -f1)
    [ -n "$drop_line" ] || false
    [ -n "$seed_line" ] || false
    [ "$drop_line" -lt "$seed_line" ] || {
        echo "@clux_bar_tpl drop (line $drop_line) is not above the seed render (line $seed_line)"
        false
    }
}

@test "render-clux-conf: sweeps every @clux_frame_idx* option, including the per-client form" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    grep -qF '@clux_frame_idx' "$out" || { echo "no @clux_frame_idx sweep line"; false; }
    # The sweep line carries the regex, not a literal set -gu per counter —
    # it must name the option prefix so both the shared and per-client forms
    # are covered by one line.
}

@test "render-clux-conf: never emits @clux-agent-glyph-busy-frames — no matching flag exists" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --bar-name-attached-style 'bg=red,fg=white' \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    run grep -c '@clux-agent-glyph-busy-frames' "$out"
    [ "$output" = "0" ]
}

@test "render-clux-conf: the generated conf clears animation runtime state on a throwaway real server" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]

    # Real tmux, not the logging stub install_stubs put on PATH — same
    # PATH-narrowing trick the "output parses cleanly" test above uses.
    local real_path; real_path="$(dirname "$REAL_TMUX"):/usr/bin:/bin"
    local sock="clux-render-test-$$"
    local log="$BATS_TEST_TMPDIR/probe.log"

    bash -c "
        PATH='$real_path'
        tmux -L '$sock' -f /dev/null new-session -d -x 80 -y 24
        tmux -L '$sock' set-option -g @clux_frame_idx 3
        tmux -L '$sock' set-option -g @clux_frame_idx_9999 2
        tmux -L '$sock' set-option -g @clux_bar_tpl 'leftover'
        tmux -L '$sock' set-option -g @clux-agent-glyph-busy '@'
        tmux -L '$sock' source-file '$out'
        {
            printf 'frame_idx=%s\n' \"\$(tmux -L '$sock' show-option -gqv @clux_frame_idx)\"
            printf 'frame_idx_pid=%s\n' \"\$(tmux -L '$sock' show-option -gqv @clux_frame_idx_9999)\"
            printf 'bar_tpl=%s\n' \"\$(tmux -L '$sock' show-option -gqv @clux_bar_tpl)\"
            printf 'busy=%s\n' \"\$(tmux -L '$sock' show-option -gqv @clux-agent-glyph-busy)\"
        } > '$log'
        tmux -L '$sock' kill-server
    " >/dev/null 2>&1

    local frame_idx frame_idx_pid bar_tpl busy
    frame_idx=$(grep '^frame_idx=' "$log" | cut -d= -f2-)
    frame_idx_pid=$(grep '^frame_idx_pid=' "$log" | cut -d= -f2-)
    bar_tpl=$(grep '^bar_tpl=' "$log" | cut -d= -f2-)
    busy=$(grep '^busy=' "$log" | cut -d= -f2-)

    [ -z "$frame_idx" ] || { echo "@clux_frame_idx survived: $frame_idx"; false; }
    [ -z "$frame_idx_pid" ] || { echo "@clux_frame_idx_9999 survived: $frame_idx_pid"; false; }
    [ -z "$bar_tpl" ] || { echo "@clux_bar_tpl survived: $bar_tpl"; false; }
    [ "$busy" = "@" ] || { echo "unrelated @clux-agent-glyph-busy did not survive: $busy"; false; }
}

@test "render-clux-conf: prints the output path on stdout" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$out" ]
}

@test "render-clux-conf: the A popup is fixed-height and pinned to the top-left" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$SCRIPTS_DIR/render-clux-conf.sh' --dir-resolver autojump --editor nvim \
            --agents-command 'claude agents' --picker fzf \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]

    local line; line="$(grep -F 'bind-key A display-popup' "$out")"

    # A percentage height grew this popup to fifteen rows on a tall terminal;
    # it holds four lines whatever the terminal is.
    [[ "$line" != *"-h 30%"* ]] || { echo "still a percentage height: $line"; false; }
    [[ "$line" == *"-h 7"* ]]   || { echo "no fixed height: $line"; false; }

    # -x 0 -y S pins it to the top-left, clear of the status line, and S
    # follows status-position rather than needing a second setting.
    [[ "$line" == *"-x 0"* ]] || { echo "not pinned to the left: $line"; false; }
    [[ "$line" == *"-y S"* ]] || { echo "not pinned to the status line: $line"; false; }
}

# ---------------------------------------------------------------------------
# Agent colour/glyph flags (added for the "honour the bar the user already
# had" case). Before these existed, a migrated hand-written bar could keep its
# @clux-bar-* palette but NOT its agent-glyph colours: those had no flag, so
# they survived only as live server state and reverted to the cyan/yellow/green
# defaults on the next tmux server restart.
# ---------------------------------------------------------------------------
@test "render-clux-conf: agent colour flags are written, and omitted ones are not" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --agent-busy-color '#88C0D0' \
            --agent-needs-color '#EBCB8B,bold' \
            --agent-done-color '#A3BE8C' \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set -g "@clux-agent-busy-color" "#88C0D0"' "$out" || false
    grep -qF 'set -g "@clux-agent-needs-color" "#EBCB8B,bold"' "$out" || false
    grep -qF 'set -g "@clux-agent-done-color" "#A3BE8C"' "$out" || false
    # A glyph flag that was not passed stays out, same rule as @clux-bar-*.
    run grep -c '@clux-agent-glyph-' "$out"
    [ "$output" = "0" ]
}

@test "render-clux-conf: agent glyph flags are written independently of the colours" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --agent-glyph-busy '+' --agent-glyph-needs '?' --agent-glyph-done 'x' \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set -g "@clux-agent-glyph-busy" "+"' "$out" || false
    grep -qF 'set -g "@clux-agent-glyph-needs" "?"' "$out" || false
    grep -qF 'set -g "@clux-agent-glyph-done" "x"' "$out" || false
    run grep -c '@clux-agent-busy-color\|@clux-agent-needs-color\|@clux-agent-done-color' "$out"
    [ "$output" = "0" ]
}

@test "render-clux-conf: a conf carrying agent colours parses on a throwaway real tmux server" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    "$RENDER_SCRIPT" --dir-resolver path --editor none \
        --agents-command 'claude agents --cwd "$PWD"' --picker fzf \
        --agent-busy-color '#88C0D0' --agent-needs-color '#EBCB8B,bold' \
        --agent-done-color '#A3BE8C' --agent-glyph-done 'v' \
        --scripts-dir "$scripts_dir" --out "$out" >/dev/null
    PATH="$(dirname "$REAL_TMUX"):$PATH" run "$VERIFY_SCRIPT" "$out"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 3.8.0: the §3.6 notification preferences, the notification colours, and
# the fourth agent state's colour/glyph all reach clux.tmux.conf through
# flags. Before this the skill was told to write @claude-notify-* "inside the
# user's clux markers" — a second file clux does not own, contradicting the
# one-file rule.
# ---------------------------------------------------------------------------
@test "render-clux-conf: --notify-visual / --notify-sound write one @claude-notify line each, in order" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --notify-visual stop on --notify-sound stop on \
            --notify-visual failure off --notify-sound teammate on \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set -g "@claude-notify-stop-visual" "on"' "$out" || false
    grep -qF 'set -g "@claude-notify-stop-sound" "on"' "$out" || false
    grep -qF 'set -g "@claude-notify-failure-visual" "off"' "$out" || false
    grep -qF 'set -g "@claude-notify-teammate-sound" "on"' "$out" || false
    # Nothing was said about notification / quota / prompt: no line for them.
    run grep -c '@claude-notify-notification-\|@claude-notify-quota-\|@claude-notify-prompt-' "$out"
    [ "$output" = "0" ]
    # Exactly four preference lines — no duplicates, none invented.
    [ "$(grep -c '^set -g "@claude-notify-.*-\(visual\|sound\)"' "$out")" -eq 4 ]
}

@test "render-clux-conf: no --notify flag at all means no notification section" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    "$RENDER_SCRIPT" --dir-resolver path --editor none \
        --agents-command 'claude agents --cwd "$PWD"' --picker fzf \
        --scripts-dir "$scripts_dir" --out "$out" >/dev/null
    run grep -c '@claude-notify' "$out"
    [ "$output" = "0" ]
}

@test "render-clux-conf: an unknown notification type or a value other than on/off is refused, nothing written" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --notify-visual bogus on --out '$out'
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown notification type"* ]]
    [ ! -f "$out" ]
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --notify-sound stop maybe --out '$out'
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"on or off"* ]]
    [ ! -f "$out" ]
}

@test "render-clux-conf: --notify-bg/-fg and the fail colour/glyph are theming lines like the others" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    run bash -c "
        '$RENDER_SCRIPT' --dir-resolver path --editor none \
            --agents-command 'claude agents --cwd \"\$PWD\"' --picker fzf \
            --notify-bg '#EBCB8B' --notify-fg '#2E3440' \
            --agent-fail-color '#BF616A' --agent-glyph-fail '!' \
            --scripts-dir '$scripts_dir' --out '$out'
    "
    [ "$status" -eq 0 ]
    grep -qF 'set -g "@claude-notify-bg" "#EBCB8B"' "$out" || false
    grep -qF 'set -g "@claude-notify-fg" "#2E3440"' "$out" || false
    grep -qF 'set -g "@clux-agent-fail-color" "#BF616A"' "$out" || false
    grep -qF 'set -g "@clux-agent-glyph-fail" "!"' "$out" || false
}

@test "render-clux-conf: a conf carrying notification preferences parses on a throwaway real tmux server" {
    local out="$BATS_TEST_TMPDIR/clux.tmux.conf"
    local scripts_dir; scripts_dir="$(_make_fake_scripts_dir)"
    "$RENDER_SCRIPT" --dir-resolver path --editor none \
        --agents-command 'claude agents --cwd "$PWD"' --picker fzf \
        --notify-visual stop on --notify-sound failure off \
        --notify-bg '#EBCB8B' --agent-fail-color red \
        --scripts-dir "$scripts_dir" --out "$out" >/dev/null
    PATH="$(dirname "$REAL_TMUX"):$PATH" run "$VERIFY_SCRIPT" "$out"
    [ "$status" -eq 0 ]
}
