#!/usr/bin/env bash

# Shared utilities for clux plugin

# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/path.sh"

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


# Map Claude hook event names to notification types
map_event_to_type() {
    case "$1" in
        Stop) echo "stop" ;;
        Notification) echo "notification" ;;
        UserPromptSubmit) echo "prompt" ;;
        SessionEnd) echo "sessionend" ;;
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

# Re-derive LOCKDIR from the current $NOTIFY_FILE value.
# Call this after resolve_notify_file() overrides NOTIFY_FILE in the agent path.
recompute_lock_target() {
    LOCKDIR="${NOTIFY_FILE}.lock"
}

# Remove all queue entries whose id field matches |||agent:<session_id>$ (end-anchored).
# Skips silently when $1 is empty (prevents "|||agent:$" from matching everything)
# or when the queue file does not exist yet.
# NOTE: mv runs UNCONDITIONALLY after a successful filter (no `&& mv`). grep -v exits 1
# when every line matches (queue becomes empty) — gating mv on grep's exit would leave
# the stale file in place, silently failing to remove the last/only matching entries.
_agent_remove_entry() {
    [ -z "$1" ] && return 0
    [ -f "$NOTIFY_FILE" ] || return 0
    acquire_lock
    grep -v "|||agent:${1}$" "$NOTIFY_FILE" > "${NOTIFY_FILE}.tmp"
    mv "${NOTIFY_FILE}.tmp" "$NOTIFY_FILE"
    release_lock
}

# @clux-agent-* option getters (reader/jump side — hardcoded defaults per spec §5).
get_agent_visual_enabled()  { get_tmux_option "@clux-agent-visual"  "on"; }
get_agent_desktop_enabled() { get_tmux_option "@clux-agent-desktop" "on"; }
get_agent_sound_enabled()   { get_tmux_option "@clux-agent-sound"   "on"; }
get_agent_osc_code()        { get_tmux_option "@clux-agent-osc"     "9"; }
get_agent_marker()          { get_tmux_option "@clux-agent-marker"  "⚡"; }

# Navigate to the claude agents dashboard pane, or open a new one if absent.
# Used by both jump-to-notification.sh and notification-picker.sh.
agent_jump() {
    local match
    match=$(tmux list-panes -a -F '#{session_id}\t#{window_id}\t#{pane_title}' 2>/dev/null \
              | grep -F 'claude agents' | head -1)
    if [ -n "$match" ]; then
        local sess_id win_id
        sess_id=$(echo "$match" | cut -f1)
        win_id=$(echo "$match"  | cut -f2)
        tmux switch-client  -t "$sess_id" 2>/dev/null
        tmux select-window  -t "${sess_id}:${win_id}" 2>/dev/null
    else
        tmux new-window -n agents "claude agents" 2>/dev/null
    fi
}

