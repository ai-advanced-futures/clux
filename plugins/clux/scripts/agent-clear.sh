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
#   agent-clear.sh --reap          called once at config load. Runs the shared
#                                   reaper (path.sh): dead panes of this
#                                   server, directories of servers that have
#                                   exited, and unscoped files from clux
#                                   <= 3.3.0.
#
# A refresh is triggered only when a mark was actually removed. A redraw alone
# is not always enough: a bar built from a precomputed tmux option keeps showing
# the old value until something rebuilds that option, and the hook that rebuilds
# it may well have already run before this script did. refresh_agent_bar()
# (path.sh) is the one place that knows how to reach the user's bar.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"

if [ "${1:-}" = "--reap" ]; then
    STATE_DIR="$(resolve_agent_state_dir)"
    [ -d "$STATE_DIR" ] || exit 0
    # Shared reaper (path.sh) — dead panes of this server, directories of
    # servers that have exited, unscoped files from an older clux; skips whole
    # on an empty listing.
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

# The server key leads every row, folded into a listing already being fetched.
# Without it this would clear by pane id alone and reach into the state of a
# Claude on another tmux server, which hands out the same pane ids.
PANES=$(tmux list-panes -t "$WIN" -F '#{pid}-#{start_time}|#{pane_id}' 2>/dev/null)
[ -n "$PANES" ] || exit 0

SRV="${PANES%%|*}"
_clux_valid_server_key "$SRV" || exit 0
STORE="$STATE_DIR/$SRV"

CLEARED=0
while IFS= read -r pane; do
    pane="${pane#*|}"          # drop the leading server key
    [ -n "$pane" ] || continue
    f="$STORE/$pane"
    if [ -f "$f" ]; then
        st=""
        IFS= read -r st < "$f" 2>/dev/null || true
        st="${st//[[:space:]]/}"
        if [ "$st" = "finished" ]; then
            rm -f "$f" 2>/dev/null && CLEARED=1
        fi
    fi
    # Detached-agent files owned by this pane (a `claude agents` dashboard):
    # looking at the dashboard's window clears its finished marks, same as for
    # an interactive pane. busy / needs-you survive, exactly as above.
    for af in "$STORE/agents/$pane"~*; do
        [ -f "$af" ] || continue
        st=""
        IFS= read -r st < "$af" 2>/dev/null || true
        st="${st//[[:space:]]/}"
        [ "$st" = "finished" ] || continue
        rm -f "$af" 2>/dev/null && CLEARED=1
    done
done <<EOF
$PANES
EOF

# Nothing changed on the far side of a window switch is the common case, so the
# refresh is paid for only when the bar would actually differ.
[ "$CLEARED" -eq 1 ] && refresh_agent_bar

exit 0
