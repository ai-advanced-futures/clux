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
# Each token is set only when the script that computes it exits 0 AND prints
# something — deliberately not `set -e`, so one renderer dying does not skip
# the other, and a renderer that dies leaves the previous option value in
# place rather than blanking that half of the bar. Because `tmux set-option`
# is atomic, hooks firing at once need no lock.

set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if bar_out=$("$CURRENT_DIR/session-list.sh") && [ -n "$bar_out" ]; then
    tmux set-option -g @clux_session_bar "$bar_out"
fi

if status_out=$("$CURRENT_DIR/show-notification.sh") && [ -n "$status_out" ]; then
    tmux set-option -g @clux_status "$status_out"
fi

[ "${1:-}" = "quiet" ] || tmux refresh-client -S
