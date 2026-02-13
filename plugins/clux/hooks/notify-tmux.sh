#!/usr/bin/env bash

# Claude hook bridge — writes notifications to queue file
# Called by Claude Code hooks on Stop and Notification events

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/../scripts/helpers.sh"

# Extract message from JSON stdin or argument
if [ -t 0 ]; then
    MESSAGE="$1"
    EVENT=""
else
    INPUT=$(cat)
    if command -v jq &>/dev/null; then
        MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)
        EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
    else
        MESSAGE=$(echo "$INPUT" | grep -o '"message":"[^"]*"' | sed 's/"message":"\(.*\)"/\1/' 2>/dev/null)
        EVENT=$(echo "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | sed 's/"hook_event_name":"\(.*\)"/\1/' 2>/dev/null)
    fi
fi

# Default message based on event
if [ -z "$MESSAGE" ]; then
    case "$EVENT" in
        Stop) MESSAGE="Task complete" ;;
        Notification) MESSAGE="Waiting for input" ;;
        *) MESSAGE="Notification" ;;
    esac
fi

# Must be in tmux
[ -n "$TMUX" ] || exit 0

SESSION=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}')
WINDOW_NAME=$(tmux display-message -t "$TMUX_PANE" -p '#{window_name}')
SESSION_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{session_id}')
WINDOW_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}')

[ -n "$SESSION" ] && [ -n "$WINDOW_NAME" ] || exit 0

CONTEXT="$SESSION:$WINDOW_NAME"

acquire_lock

# Skip duplicate for same session/window
if [ -f "$NOTIFY_FILE" ] && grep -qF "$CONTEXT" "$NOTIFY_FILE"; then
    release_lock
    exit 0
fi

echo "$CONTEXT $MESSAGE|||$SESSION_ID:$WINDOW_ID" >> "$NOTIFY_FILE"
release_lock

# Bell alert + sound + refresh
printf '\a'
play_sound
tmux refresh-client -S 2>/dev/null

exit 0
