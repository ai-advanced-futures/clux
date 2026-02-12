#!/usr/bin/env bash

# Display notification in status bar with styling
# Auto-dismisses notifications for current session/window

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

[ -f "$NOTIFY_FILE" ] || exit 0

CURRENT_SESSION=$(tmux display-message -p '#{session_name}')
CURRENT_WINDOW_NAME=$(tmux display-message -p '#{window_name}')
CURRENT_CONTEXT="$CURRENT_SESSION:$CURRENT_WINDOW_NAME "

acquire_lock

# Auto-dismiss notifications for current location
while [ -f "$NOTIFY_FILE" ]; do
    FIRST=$(head -1 "$NOTIFY_FILE")
    [ -n "$FIRST" ] || { release_lock; exit 0; }

    if echo "$FIRST" | grep -qF "$CURRENT_CONTEXT"; then
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

TOTAL=$(wc -l < "$NOTIFY_FILE" | tr -d ' ')

if [ "$TOTAL" -gt 1 ]; then
    printf '#[bg=%s,fg=%s,bold] [%d/%d] %-60s #[default]' "$NOTIFY_BG" "$NOTIFY_FG" 1 "$TOTAL" "$FIRST"
else
    printf '#[bg=%s,fg=%s,bold] %-70s #[default]' "$NOTIFY_BG" "$NOTIFY_FG" "$FIRST"
fi
