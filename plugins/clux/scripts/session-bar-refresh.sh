#!/usr/bin/env bash
# The single refresh entry point for both rendered tokens: computes
# @clux_session_bar from session-list.sh and @clux_status from
# show-notification.sh, then issues one redraw.
#
# The status line renders #{@clux_session_bar} and #{@clux_status} (inline
# option lookups, evaluated on every redraw) instead of live #(...) jobs. A
# #() job is cached and only re-runs on status-interval, so session/window
# switches lagged by up to ~2s. Driving the strings through options + hooks
# makes switches reflect instantly.
#
# Called from: tmux hooks (session/window changes, [91] in clux.tmux.conf),
# session-reorder.sh, the periodic safety-net #() literal in the user's
# status-format, and once at config load.
#   arg1 = "quiet" -> skip the forced redraw (periodic path; the next interval
#                     redraw will pick up the new value on its own).
#
# Neither token is written when the script that computes it FAILS —
# deliberately not `set -e`, so one renderer dying does not skip the other,
# and a renderer that dies leaves the previous option value in place rather
# than blanking that half of the bar. Because `tmux set-option` is atomic,
# hooks firing at once need no lock.
#
# The two differ on what an exit-0-with-empty result means, and the
# difference is load-bearing:
#
#   show-notification.sh  empty IS the answer. `[ -f "$NOTIFY_FILE" ] || exit 0`
#                         is its normal "nothing pending" path, reached every
#                         time a notification is dismissed or jumped to. So an
#                         empty result must be WRITTEN, clearing the badge.
#                         Guarding on non-empty here left a dismissed
#                         notification on the bar until an unrelated one
#                         replaced it — a regression against the pre-3.3
#                         wiring, where a live #() job simply rendered nothing.
#
#   session-list.sh       empty is never a real answer: a running tmux server
#                         always has at least one session, so the renderer
#                         always has a row to draw. An empty result there means
#                         it failed without saying so, and keeping the previous
#                         bar is the safer reading.

set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if bar_out=$("$CURRENT_DIR/session-list.sh") && [ -n "$bar_out" ]; then
    tmux set-option -g @clux_session_bar "$bar_out"
fi

if status_out=$("$CURRENT_DIR/show-notification.sh"); then
    tmux set-option -g @clux_status "$status_out"
fi

# A redraw needs a client, and there is very often no client here.
# `tmux refresh-client -S` exits 1 with "no current client" whenever none is
# attached — the state at config-load time after `tmux new-session -d`, and on
# every session-created[91] hook fired by a script that creates a session
# detached. Both are ordinary. Both used to leave tmux reporting
# "'session-bar-refresh.sh' returned 1" to the next client that attached,
# which is the first thing a user saw on a fresh detached start.
#
# Nothing has actually failed in that case: both options were already written
# above, and there is no client to redraw them on. So the redraw is
# best-effort, and its failure is not this script's failure — hence the
# explicit exit 0 rather than falling off the end on refresh-client's status.
# stderr is dropped for the same reason: tmux surfaces a run-shell command's
# output too, so letting "no current client" through would swap one spurious
# message for another.
if [ "${1:-}" != "quiet" ]; then
    tmux refresh-client -S 2>/dev/null
fi

exit 0
