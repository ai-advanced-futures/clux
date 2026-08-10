#!/usr/bin/env bash

# agent-clear.sh — looks like a reader but is a WRITER, driven by tmux hooks
# (after-select-window, client-session-changed) and by claude-notify.tmux at
# load time. Clears `finished` marks for a window when the user looks at it;
# never touches `busy` or `needs-you`.
#
# Two modes:
#   agent-clear.sh '<window_id>'   default. Deletes only state files whose
#                                   content is exactly `finished`, for panes in
#                                   that window.
#   agent-clear.sh --reap          called once at config load. Deletes state
#                                   files whose pane id is not live anywhere on
#                                   the server — closes the pane-id-reuse hole
#                                   after a tmux server restart.
#
# No refresh is triggered here: selecting a window or a session already
# triggers a status redraw, and the #(...) job's cached output refreshes
# within status-interval on its own (bounded lag).

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"

if [ "${1:-}" = "--reap" ]; then
    STATE_DIR="$(resolve_agent_state_dir)"
    [ -d "$STATE_DIR" ] || exit 0
    # Shared reaper (path.sh) — deletes state files whose pane id is not live
    # anywhere on the server; skips whole on an empty listing.
    reap_agent_state_dir "$STATE_DIR"
    exit 0
fi

WIN="${1:-}"
if [ -z "$WIN" ]; then
    # Load-bearing fallback: client-session-changed could not be exercised
    # without an attached client, so its #{window_id} argument may not arrive.
    WIN=$(tmux display-message -p '#{window_id}' 2>/dev/null)
fi
[ -n "$WIN" ] || exit 0

STATE_DIR="$(resolve_agent_state_dir)"
[ -d "$STATE_DIR" ] || exit 0

PANES=$(tmux list-panes -t "$WIN" -F '#{pane_id}' 2>/dev/null)
[ -n "$PANES" ] || exit 0

while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    f="$STATE_DIR/$pane"
    [ -f "$f" ] || continue
    st=""
    IFS= read -r st < "$f" 2>/dev/null || true
    st="${st//[[:space:]]/}"
    [ "$st" = "finished" ] && rm -f "$f" 2>/dev/null
done <<EOF
$PANES
EOF

exit 0
