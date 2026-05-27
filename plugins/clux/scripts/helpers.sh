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
get_agent_window()          { get_tmux_option "@clux-agent-window"  "agents"; }
# Key sent to the agents pane right after landing, to force the `claude agents`
# TUI back to its main list (in case it was showing a single sub-agent). Empty
# string disables the keystroke. Default "Left" — the TUI's back navigation.
get_agent_nav_key()         { get_tmux_option "@clux-agent-nav-key" "Left"; }

# Resolve the agent session's display name — the name shown in the `claude agents`
# view. Source of truth: the latest "custom-title" entry in the session
# transcript, which is keyed by the hook's session_id for BOTH interactive
# (worktree) and background agent sessions (verified v2.1.150). This is more
# reliable than sessions-index.json (often absent) or the cwd basename (the
# folder, which the session name frequently does NOT match, e.g. a session named
# "sdlc-84-review" living in ".../avonrisk-sdlc").
#
#   $1 = session_id   $2 = cwd   $3 = transcript_path (may be empty)
#
# Falls back to the cwd basename when the session is unnamed or the transcript is
# unreadable. Pure stdout — no tmux IPC, no queue side effects.
resolve_agent_name() {
    local sid="$1" cwd="$2" transcript="$3"
    local tfile="" name="" line=""

    if [ -n "$transcript" ] && [ -f "$transcript" ]; then
        tfile="$transcript"
    elif [ -n "$sid" ] && [ -n "$cwd" ]; then
        # Claude encodes the project dir under ~/.claude/projects by replacing
        # every '/' and '.' in the cwd with '-'. Used only when the hook payload
        # omits transcript_path (some Notification shapes do).
        tfile="$HOME/.claude/projects/$(printf '%s' "$cwd" | sed 's#[/.]#-#g')/$sid.jsonl"
    fi

    if [ -n "$tfile" ] && [ -f "$tfile" ]; then
        # grep-filter first (cheap even on multi-MB transcripts), keep the most
        # recent rename, then parse that single line (jq if available, else sed).
        line=$(grep '"type":"custom-title"' "$tfile" 2>/dev/null | tail -1)
        if [ -n "$line" ]; then
            if command -v jq &>/dev/null; then
                name=$(printf '%s' "$line" | jq -r '.customTitle // empty' 2>/dev/null)
            else
                name=$(printf '%s' "$line" | sed -n 's/.*"customTitle":"\([^"]*\)".*/\1/p')
            fi
        fi
    fi

    [ -z "$name" ] && name=$(basename "$cwd" 2>/dev/null)
    printf '%s' "$name"
}

# Navigate to the tmux WINDOW that hosts the `claude agents` view.
# Used by both jump-to-notification.sh and notification-picker.sh.
#
# Strategy (v2 — "window convention"):
#   The agent view is a single TUI living in one tmux window (by convention
#   named "agents"; configurable via @clux-agent-window). The individual agent
#   sessions live INSIDE that TUI — there is no per-session tmux pane to land on,
#   and no Claude Code CLI to deep-link a specific session by id. So the jump
#   target is the window itself; the user picks the session from the dashboard.
#
#   1. Find a window whose #{window_name} EQUALS the configured name, in ANY
#      session (kept in session "claude" by convention, but not required).
#   2. If found, switch the client to its session and select that window.
#   3. If none exists, open the dashboard in a new window of that name.
#
# (Corrects the old pane-title match: empirically the agent pane titles itself
# with the focused sub-agent name, e.g. "⠐ relay", which changes constantly and
# never equals the cwd-derived label — so pane-title matching always missed.)
agent_jump() {
    local wname match="" nav_key
    wname=$(get_agent_window)
    nav_key=$(get_agent_nav_key)
    match=$(tmux list-windows -a -f "#{==:#{window_name},$wname}" \
              -F '#{session_id} #{window_id}' 2>/dev/null | head -1)
    if [ -n "$match" ]; then
        local sess_id win_id
        read -r sess_id win_id <<< "$match"
        tmux switch-client -t "$sess_id" 2>/dev/null
        tmux select-window -t "$win_id" 2>/dev/null
        # Nudge the agents TUI back to its main list. send-keys writes straight
        # to the pane's input, independent of client focus, so this lands even
        # if switch-client hasn't fully settled. Only on an existing window — a
        # freshly launched `claude agents` (else branch) is already on main.
        [ -n "$nav_key" ] && tmux send-keys -t "$win_id" "$nav_key" 2>/dev/null
    else
        tmux new-window -n "$wname" "claude agents" 2>/dev/null
    fi
}

