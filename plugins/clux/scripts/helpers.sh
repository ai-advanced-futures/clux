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
NOTIFY_JUMP_KEY=$(get_tmux_option "@claude-notify-jump" "m")
NOTIFY_DISMISS_KEY=$(get_tmux_option "@claude-notify-dismiss" '`')
NOTIFY_SMART_TITLE=$(get_tmux_option "@claude-notify-smart-title" "on")

# Map Claude hook event names to notification types
map_event_to_type() {
    case "$1" in
        Stop) echo "stop" ;;
        Notification) echo "notification" ;;
        UserPromptSubmit) echo "prompt" ;;
        *) echo "$1" ;;
    esac
}

# Per-notification config defaults
# Falls back to old @claude-notify-sound for backward compatibility
_get_notification_default_sound() {
    case "$1" in
        notification) echo "on" ;;
        *) echo "off" ;;
    esac
}

_get_notification_default_visual() {
    case "$1" in
        notification) echo "on" ;;
        *) echo "off" ;;
    esac
}

_get_notification_default_sound_file() {
    case "$1" in
        prompt) echo "/System/Library/Sounds/Pop.aiff" ;;
        *) echo "/System/Library/Sounds/Blow.aiff" ;;
    esac
}

get_notification_sound_enabled() {
    local type="$1"
    local val
    val=$(get_tmux_option "@claude-notify-${type}-sound" "")
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    # Backward compat: fall back to global @claude-notify-sound
    local global
    global=$(get_tmux_option "@claude-notify-sound" "")
    if [ -n "$global" ]; then
        echo "$global"
        return
    fi
    _get_notification_default_sound "$type"
}

get_notification_sound_file() {
    local type="$1"
    get_tmux_option "@claude-notify-${type}-sound-file" "$(_get_notification_default_sound_file "$type")"
}

get_notification_visual_enabled() {
    local type="$1"
    local val
    val=$(get_tmux_option "@claude-notify-${type}-visual" "")
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    _get_notification_default_visual "$type"
}

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

