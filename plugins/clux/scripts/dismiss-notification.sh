#!/usr/bin/env bash

# Dismiss the top notification without jumping to it

NOTIFY_FILE="${CLUX_NOTIFY_FILE:-$HOME/.config/tmux/claude_notification}"
LOCKDIR="${NOTIFY_FILE}.lock"

[ -f "$NOTIFY_FILE" ] || exit 0

# Clean up stale lock (guard against kill -9 leaving orphaned lock)
if [ -d "$LOCKDIR" ]; then
    _now=$(date +%s)
    _mtime=$(stat -f %m "$LOCKDIR" 2>/dev/null || stat -c %Y "$LOCKDIR" 2>/dev/null || echo "$_now")
    [ $(( _now - _mtime )) -gt 10 ] && rm -rf "$LOCKDIR"
fi

# Retry briefly (user-triggered keybind: 500ms max)
_i=0
while ! mkdir "$LOCKDIR" 2>/dev/null; do
    _i=$((_i + 1)); [ "$_i" -ge 5 ] && exit 0
    sleep 0.1
done
trap 'rm -rf "$LOCKDIR"' EXIT

FIRST=$(head -1 "$NOTIFY_FILE")
[ -z "$FIRST" ] && exit 0

REMAINING=$(tail -n +2 "$NOTIFY_FILE")
if [ -n "$REMAINING" ]; then
    echo "$REMAINING" > "$NOTIFY_FILE"
else
    rm -f "$NOTIFY_FILE"
fi

exit 0
