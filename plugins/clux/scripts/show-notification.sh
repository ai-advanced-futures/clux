#!/usr/bin/env bash

# Display notification in status bar with styling
# Auto-dismisses notifications for current session/window
# Optimized: single tmux IPC call instead of 4 separate ones

# Static config — env vars avoid tmux show-option IPC calls per cycle
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"
NOTIFY_BG="${CLUX_NOTIFY_BG:-#EBCB8B}"
NOTIFY_FG="${CLUX_NOTIFY_FG:-#2E3440}"

# The fast path of the status bar: with no queue file of any server there is
# nothing to show, so make no tmux call. The glob costs no process.
_BASE=$(_clux_notify_base)
_QUEUED=""
for _f in "$_BASE" "$_BASE"-*; do
    case "$_f" in *.lock|*.flock|*.tmp) continue ;; esac
    [ -f "$_f" ] && { _QUEUED=1; break; }
done
[ -n "$_QUEUED" ] || exit 0

# Single tmux IPC call for the server name and all 4 identifiers (was 4
# separate calls @ ~230ms each). The name picks the queue of this server, so
# the call comes before the file check.
TMUX_INFO="$(tmux display-message -p "${CLUX_SERVER_NAME_FMT}|||#{session_id}|||#{window_id}|||#{session_name}|||#{window_name}")"
NOTIFY_FILE=$(notify_file_for_server "$_BASE" "${TMUX_INFO%%|||*}"); TMUX_INFO="${TMUX_INFO#*|||}"

[ -f "$NOTIFY_FILE" ] || exit 0

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
    # GNU stat (-c %Y) first: on Linux `stat -f` means --file-system and "succeeds"
    # with garbage instead of failing, so it must not be tried first. BSD/macOS stat
    # rejects -c and falls through to -f %m.
    _mtime=$(stat -c %Y "$LOCKDIR" 2>/dev/null || stat -f %m "$LOCKDIR" 2>/dev/null || echo "$_now")
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

# Strip the id marker before display. A line with no marker stays as it is.
DISPLAY="${FIRST%%|||*}"

# tmux reads this output as a format: "#[...]" sets a style and "#{...}" or
# "#S" expands. The text holds window and session names, which a program can
# set, so double each "#" to show it as plain text. Escape here, where the
# text is drawn, and not in the queue: the picker shows the queue text as is.
DISPLAY="${DISPLAY//#/##}"

TOTAL=$(wc -l < "$NOTIFY_FILE" | tr -d ' ')

if [ "$TOTAL" -gt 1 ]; then
    printf '#[bg=%s,fg=%s,bold] [%d/%d] %s #[default]' "$NOTIFY_BG" "$NOTIFY_FG" 1 "$TOTAL" "$DISPLAY"
else
    printf '#[bg=%s,fg=%s,bold] %s #[default]' "$NOTIFY_BG" "$NOTIFY_FG" "$DISPLAY"
fi
