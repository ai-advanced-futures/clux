#!/usr/bin/env bash
# Move the current session left or right in the status-bar order.
# Usage: session-reorder.sh left|right   (bound to prefix + { / })
#
# Reads the resolved order (session-order.sh), swaps the current session with
# its neighbour, and writes the new order back to @clux-session-order. No-op
# at the edges.
#
# Then redraws immediately: none of session-bar-refresh.sh's six hook events
# (client-session-changed, after-select-window, session-created,
# session-closed, window-linked, window-unlinked) fires on a plain option
# set, so without this call a reorder would sit invisible until the next
# status-interval tick.

set -eu

dir="${1:-right}"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDER_OPT="@clux-session-order"

cur=$(tmux display-message -p '#S')
order=$("$CURRENT_DIR/session-order.sh")

new=$(printf '%s\n' "$order" | awk -v cur="$cur" -v dir="$dir" '
  $0 != "" { a[++n]=$0 }
  END {
    idx=0
    for (i=1; i<=n; i++) if (a[i] == cur) idx=i
    if (idx > 0) {
      j = (dir == "left") ? idx-1 : idx+1
      if (j >= 1 && j <= n) { t=a[idx]; a[idx]=a[j]; a[j]=t }
    }
    for (i=1; i<=n; i++) printf "%s%s", (i>1 ? "," : ""), a[i]
  }')

tmux set-option -g "$ORDER_OPT" "$new"
"$CURRENT_DIR/session-bar-refresh.sh"
