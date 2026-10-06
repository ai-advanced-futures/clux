#!/usr/bin/env bats
# upgrade-clux.bats — upgrade-clux.sh reads the answers of the last setup back
# out of clux.tmux.conf, deploys, renders again, verifies, and restores the
# backup on a failure. The verify step needs the REAL tmux, so it is read
# before test_helper's setup() puts the stubs first on PATH.

load test_helper

REAL_TMUX="$(command -v tmux)"
RENDER="$SCRIPTS_DIR/render-clux-conf.sh"
UPGRADE="$SCRIPTS_DIR/upgrade-clux.sh"

# Every flag kind the parser must give back: the four required answers, the
# single-quoted agents command with a $(...) in it, a bar style, a glyph, the
# notification colours and two notification preferences.
_render_old() {
    "$RENDER" --dir-resolver autojump --editor nvim \
        --agents-command 'claude agents --cwd $(pwd) --permission-mode default' \
        --picker fzf \
        --agent-refresh-command "run-shell -b $HOME/.config/clux/scripts/session-bar-refresh.sh" \
        --bar-name-attached-style 'bg=#B48EAD,fg=#2E3440,bold' \
        --bar-name-length 24 --agent-glyph-busy '*' \
        --notify-bg '#EBCB8B' --notify-fg '#2E3440' \
        --notify-visual stop on --notify-sound quota off \
        --scripts-dir "$HOME/.config/clux/scripts" \
        --out "$HOME/.config/clux/clux.tmux.conf" --version 0.0.1 "$@" >/dev/null
}

_upgrade() {
    PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin" run "$UPGRADE" --no-reload \
        --tmux-conf "$HOME/tmux.conf" "$@"
}

@test "upgrade-clux: with no clux.tmux.conf it asks for /clux:setup" {
    run "$UPGRADE" --no-reload
    [ "$status" -eq 3 ]
    [[ "$output" == *"needs-setup"* ]]
}

@test "upgrade-clux: a clux.tmux.conf that setup did not make is refused" {
    mkdir -p "$HOME/.config/clux"
    echo 'set -g @clux-editor "vim"' > "$HOME/.config/clux/clux.tmux.conf"
    run "$UPGRADE" --no-reload
    [ "$status" -eq 3 ]
}

@test "render-clux-conf --from: the answers it reads render the same file again" {
    _render_old
    local conf="$HOME/.config/clux/clux.tmux.conf"
    run "$RENDER" --from "$conf" --scripts-dir "$HOME/.config/clux/scripts" \
        --out "$BATS_TEST_TMPDIR/again.conf" --version 0.0.1
    [ "$status" -eq 0 ]
    diff <(grep -v '^# Generated:' "$conf") <(grep -v '^# Generated:' "$BATS_TEST_TMPDIR/again.conf")
    grep -qF "set -g @clux-agents-command 'claude agents --cwd \$(pwd) --permission-mode default'" \
        "$BATS_TEST_TMPDIR/again.conf"
}

@test "render-clux-conf --from: a flag after it overrides the value it read" {
    _render_old
    run "$RENDER" --from "$HOME/.config/clux/clux.tmux.conf" --editor vim \
        --out "$BATS_TEST_TMPDIR/again.conf"
    [ "$status" -eq 0 ]
    grep -qF 'set -g @clux-editor "vim"' "$BATS_TEST_TMPDIR/again.conf"
}

@test "render-clux-conf --from: a setting this version does not write is dropped and reported" {
    _render_old
    echo 'set -g "@clux-bar-gone-away" "x"' >> "$HOME/.config/clux/clux.tmux.conf"
    run "$RENDER" --from "$HOME/.config/clux/clux.tmux.conf" --out "$BATS_TEST_TMPDIR/again.conf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dropped: @clux-bar-gone-away"* ]]
    ! grep -q 'gone-away' "$BATS_TEST_TMPDIR/again.conf"
}

@test "upgrade-clux: a missing required answer stops it before any change" {
    _render_old
    local conf="$HOME/.config/clux/clux.tmux.conf"
    sed -i '/@clux-editor/d' "$conf"
    local before; before=$(cat "$conf")
    run "$UPGRADE" --no-reload
    [ "$status" -eq 4 ]
    [ "$output" = "missing: --editor" ]
    [ "$(cat "$conf")" = "$before" ]
    [ ! -d "$HOME/.config/clux/backups" ]
    [ ! -d "$HOME/.config/clux/scripts" ]
}

@test "upgrade-clux: a flag after -- gives a missing answer" {
    [ -n "$REAL_TMUX" ] || skip "no tmux"
    _render_old
    sed -i '/@clux-editor/d' "$HOME/.config/clux/clux.tmux.conf"
    printf '%s\n' 'source-file -q ~/.config/clux/clux.tmux.conf' > "$HOME/tmux.conf"
    _upgrade -- --editor vim
    [ "$status" -eq 0 ]
    grep -qF 'set -g @clux-editor "vim"' "$HOME/.config/clux/clux.tmux.conf"
}

@test "upgrade-clux: a real upgrade deploys, renders this version, verifies, and backs up" {
    [ -n "$REAL_TMUX" ] || skip "no tmux"
    _render_old
    printf '%s\n' 'source-file -q ~/.config/clux/clux.tmux.conf' \
        'set -g status-left "#{@clux_session_bar}#{@clux_status}"' > "$HOME/tmux.conf"
    _upgrade
    echo "$output"
    [ "$status" -eq 0 ]
    local conf="$HOME/.config/clux/clux.tmux.conf"
    local want; want=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$REPO_ROOT/plugins/clux/.claude-plugin/plugin.json" | head -1)
    head -1 "$conf" | grep -qF "(clux $want)"
    grep -qF "set -g @clux-agents-command 'claude agents --cwd \$(pwd) --permission-mode default'" "$conf"
    grep -qF 'set -g "@claude-notify-quota-sound" "off"' "$conf"
    [ -x "$HOME/.config/clux/scripts/workspace-history.sh" ]
    ls "$HOME/.config/clux/backups/" | grep -q '^clux.tmux.conf\.'
    [[ "$output" == *"from: 0.0.1"* ]]
    [[ "$output" == *"to: $want"* ]]
    [[ "$output" != *"warn:"* ]]
}

@test "upgrade-clux: it reports a tmux.conf without the clux line and tokens, and does not change it" {
    [ -n "$REAL_TMUX" ] || skip "no tmux"
    _render_old
    echo 'set -g status-left "x"' > "$HOME/tmux.conf"
    local before; before=$(cat "$HOME/tmux.conf")
    _upgrade
    [ "$status" -eq 0 ]
    [[ "$output" == *"no source-file line"* ]]
    [[ "$output" == *"no #{@clux_session_bar} token"* ]]
    [ "$(cat "$HOME/tmux.conf")" = "$before" ]
}

@test "upgrade-clux: when the new file does not verify, the backup is back in place" {
    [ -n "$REAL_TMUX" ] || skip "no tmux"
    _render_old
    local conf="$HOME/.config/clux/clux.tmux.conf"
    local before; before=$(cat "$conf")
    # A verify step that always fails, in a copy of the plugin tree.
    local tree="$BATS_TEST_TMPDIR/plugin"
    cp -R "$REPO_ROOT/plugins/clux" "$tree"
    printf '#!/bin/sh\necho "bad file" >&2\nexit 1\n' > "$tree/scripts/verify-tmux-conf.sh"
    PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin" run "$tree/scripts/upgrade-clux.sh" --no-reload
    [ "$status" -eq 5 ]
    [[ "$output" == *"backup is back in place"* ]]
    [ "$(cat "$conf")" = "$before" ]
}
