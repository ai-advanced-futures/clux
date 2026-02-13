#!/usr/bin/env bash

# Display notification in status bar with styling
# Auto-dismisses notifications for current session/window

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

[ -f "$NOTIFY_FILE" ] || exit 0

# Current identifiers for matching
CURRENT_SESSION_ID=$(tmux display-message -p '#{session_id}')
CURRENT_WINDOW_ID=$(tmux display-message -p '#{window_id}')
CURRENT_ID="$CURRENT_SESSION_ID:$CURRENT_WINDOW_ID"
# Fallback: name-based matching for old format
CURRENT_SESSION=$(tmux display-message -p '#{session_name}')
CURRENT_WINDOW_NAME=$(tmux display-message -p '#{window_name}')
CURRENT_CONTEXT="$CURRENT_SESSION:$CURRENT_WINDOW_NAME "

acquire_lock

# Auto-dismiss notifications for current location
while [ -f "$NOTIFY_FILE" ]; do
    FIRST=$(head -1 "$NOTIFY_FILE")
    [ -n "$FIRST" ] || { release_lock; exit 0; }

    DISMISS=false
    if echo "$FIRST" | grep -q '|||'; then
        # New format: match by ID after |||
        LINE_ID="${FIRST##*|||}"
        if [ "$LINE_ID" = "$CURRENT_ID" ]; then
            DISMISS=true
        fi
    elif echo "$FIRST" | grep -q '|ID:'; then
        # Backward compat: old |ID: format
        LINE_ID="${FIRST##*|ID:}"
        if [ "$LINE_ID" = "$CURRENT_ID" ]; then
            DISMISS=true
        fi
    else
        # Fallback: name-based matching
        if echo "$FIRST" | grep -qF "$CURRENT_CONTEXT"; then
            DISMISS=true
        fi
    fi

    if $DISMISS; then
        REMAINING=$(tail -n +2 "$NOTIFY_FILE")
        if [ -n "$REMAINING" ]; then
            echo "$REMAINING" > "$NOTIFY_FILE"
        else
            rm -f "$NOTIFY_FILE"
            release_lock
            exit 0
        fi
    else
        break
    fi
done

FIRST=$(head -1 "$NOTIFY_FILE" 2>/dev/null)
release_lock

[ -n "$FIRST" ] || exit 0

# Strip |||... marker before display (and fallback for old |ID: format)
if echo "$FIRST" | grep -q '|||'; then
    DISPLAY="${FIRST%%|||*}"
elif echo "$FIRST" | grep -q '|ID:'; then
    DISPLAY="${FIRST%%|ID:*}"
else
    DISPLAY="$FIRST"
fi

TOTAL=$(wc -l < "$NOTIFY_FILE" | tr -d ' ')

if [ "$TOTAL" -gt 1 ]; then
    printf '#[bg=%s,fg=%s,bold] [%d/%d] %s #[default]' "$NOTIFY_BG" "$NOTIFY_FG" 1 "$TOTAL" "$DISPLAY"
else
    printf '#[bg=%s,fg=%s,bold] %s #[default]' "$NOTIFY_BG" "$NOTIFY_FG" "$DISPLAY"
fi
