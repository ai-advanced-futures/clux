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

[ "${1:-}" = "quiet" ] || tmux refresh-client -S
