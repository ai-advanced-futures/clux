#!/bin/sh
# Resolve the session display order, one name per line.
#
# Order is stored in the @clux-session-order option (comma-separated names).
# Stored names that are still live come first (in stored order); any live
# session not yet in the list (e.g. freshly created) is appended in creation
# (session id) order. Dead sessions are dropped. This is the single source of
# truth shared by session-list.sh (render), session-reorder.sh (mutate) and
# switch-session.sh (next/previous), so the three can never disagree about
# order.
#
# Dependency-free and fast on purpose: this runs on every bar render (via
# session-list.sh) and every N/P/{/} keypress, so it does not source
# path.sh or helpers.sh for a single option read. @clux-session-order's
# documented default is the empty string, which is exactly what
# `tmux show-option -gqv` already returns for an unset option, so no
# fallback logic is needed to reproduce get_tmux_option's behaviour here.
#
# A stored name containing a comma splits into fragments that match no live
# session, so this script silently skips them and the real session
# reappears through the creation-order fallback below — benign and
# self-correcting. The delimiter stays comma because the migrated
# @session_order value already uses it and because the option must stay
# hand-editable.

ORDER_OPT="@clux-session-order"

stored=$(tmux show-option -gqv "$ORDER_OPT" 2>/dev/null)

# Live session names, ordered by numeric session id (creation order).
live=$(tmux list-sessions -F '#{session_id}	#{session_name}' \
  | sed 's/^\$//' | sort -n | cut -f2-)

printf '%s\n' "$live" | awk -v stored="$stored" '
  $0 != "" { live[++n]=$0; islive[$0]=1 }
  END {
    m=split(stored, pref, ",")
    for (i=1; i<=m; i++) {
      name=pref[i]
      if (name != "" && islive[name] && !seen[name]) { print name; seen[name]=1 }
    }
    for (i=1; i<=n; i++) {
      if (!seen[live[i]]) { print live[i]; seen[live[i]]=1 }
    }
  }'
