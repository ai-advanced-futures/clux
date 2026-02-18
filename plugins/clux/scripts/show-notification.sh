#!/usr/bin/env bash

# Display notification in status bar with styling
# Auto-dismisses notifications for current session/window
# Optimized: single tmux IPC call instead of 4 separate ones

# Static config — env vars avoid tmux show-option IPC calls per cycle
NOTIFY_FILE="${CLUX_NOTIFY_FILE:-$HOME/.config/tmux/claude_notification}"
NOTIFY_BG="${CLUX_NOTIFY_BG:-#EBCB8B}"
NOTIFY_FG="${CLUX_NOTIFY_FG:-#2E3440}"

[ -f "$NOTIFY_FILE" ] || exit 0

# Single tmux IPC call for all 4 identifiers (was 4 separate calls @ ~230ms each)
TMUX_INFO="$(tmux display-message -p '#{session_id}|||#{window_id}|||#{session_name}|||#{window_name}')"
CURRENT_SESSION_ID="${TMUX_INFO%%|||*}"; TMUX_INFO="${TMUX_INFO#*|||}"
CURRENT_WINDOW_ID="${TMUX_INFO%%|||*}"; TMUX_INFO="${TMUX_INFO#*|||}"
CURRENT_SESSION="${TMUX_INFO%%|||*}"
CURRENT_WINDOW_NAME="${TMUX_INFO#*|||}"
CURRENT_ID="$CURRENT_SESSION_ID:$CURRENT_WINDOW_ID"
CURRENT_CONTEXT="$CURRENT_SESSION:$CURRENT_WINDOW_NAME "

# Simple lock using mkdir (atomic on all filesystems)
LOCKDIR="${NOTIFY_FILE}.lock"
# Clean up stale lock (guard against kill -9 leaving orphaned lock)
if [ -d "$LOCKDIR" ]; then
    _now=$(date +%s)
    _mtime=$(stat -f %m "$LOCKDIR" 2>/dev/null || stat -c %Y "$LOCKDIR" 2>/dev/null || echo "$_now")
    [ $(( _now - _mtime )) -gt 10 ] && rm -rf "$LOCKDIR"
fi
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    # Lock held — skip this cycle rather than blocking
    exit 0
fi
trap 'rm -rf "$LOCKDIR"' EXIT

# Auto-dismiss notifications for current location
while [ -f "$NOTIFY_FILE" ]; do
    FIRST=$(head -1 "$NOTIFY_FILE")
    [ -n "$FIRST" ] || exit 0

    DISMISS=false
    if echo "$FIRST" | grep -q '|||'; then
        LINE_ID="${FIRST##*|||}"
        [ "$LINE_ID" = "$CURRENT_ID" ] && DISMISS=true
    elif echo "$FIRST" | grep -q '|ID:'; then
        LINE_ID="${FIRST##*|ID:}"
        [ "$LINE_ID" = "$CURRENT_ID" ] && DISMISS=true
    else
        echo "$FIRST" | grep -qF "$CURRENT_CONTEXT" && DISMISS=true
    fi

    if $DISMISS; then
        REMAINING=$(tail -n +2 "$NOTIFY_FILE")
        if [ -n "$REMAINING" ]; then
            echo "$REMAINING" > "$NOTIFY_FILE"
        else
            rm -f "$NOTIFY_FILE"
            exit 0
        fi
    else
        break
    fi
done

FIRST=$(head -1 "$NOTIFY_FILE" 2>/dev/null)
[ -n "$FIRST" ] || exit 0

# Strip ID markers before display
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
