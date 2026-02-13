#!/usr/bin/env bash

# Shared utilities for clux plugin

get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local value
    value=$(tmux show-option -gqv "$option")
    echo "${value:-$default_value}"
}

# Configuration defaults
NOTIFY_FILE=$(get_tmux_option "@claude-notify-file" "$HOME/.config/tmux/claude_notification")
NOTIFY_BG=$(get_tmux_option "@claude-notify-bg" "yellow")
NOTIFY_FG=$(get_tmux_option "@claude-notify-fg" "black")
NOTIFY_SOUND=$(get_tmux_option "@claude-notify-sound" "on")
NOTIFY_JUMP_KEY=$(get_tmux_option "@claude-notify-jump" "N")
NOTIFY_DISMISS_KEY=$(get_tmux_option "@claude-notify-dismiss" '`')
NOTIFY_SMART_TITLE=$(get_tmux_option "@claude-notify-smart-title" "on")

LOCKDIR="${NOTIFY_FILE}.lock"

acquire_lock() {
    local lockfile="${NOTIFY_FILE}.flock"
    if command -v flock &>/dev/null; then
        exec 9>"$lockfile"
        flock -w 5 9
    else
        local attempts=0
        while ! mkdir "$LOCKDIR" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 50 ]; then
                # Stale lock — force remove
                rm -rf "$LOCKDIR"
                mkdir "$LOCKDIR" 2>/dev/null
                return
            fi
            sleep 0.1
        done
    fi
}

release_lock() {
    if command -v flock &>/dev/null; then
        exec 9>&-
    else
        rm -rf "$LOCKDIR"
    fi
}

play_sound() {
    [ "$NOTIFY_SOUND" = "off" ] && return
    if [ "$NOTIFY_SOUND" != "on" ]; then
        # Custom command
        eval "$NOTIFY_SOUND" &>/dev/null &
        return
    fi
    if [[ "$OSTYPE" == darwin* ]]; then
        afplay /System/Library/Sounds/Blow.aiff &>/dev/null &
    elif command -v paplay &>/dev/null; then
        paplay /usr/share/sounds/freedesktop/stereo/complete.oga &>/dev/null &
    elif command -v aplay &>/dev/null; then
        aplay /usr/share/sounds/freedesktop/stereo/complete.oga &>/dev/null &
    fi
}
