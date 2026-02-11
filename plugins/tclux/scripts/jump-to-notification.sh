#!/usr/bin/env bash

# Jump to tmux session/window from top notification
# Status bar auto-pops notification on arrival

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

[ -f "$NOTIFY_FILE" ] || exit 0

FIRST=$(head -1 "$NOTIFY_FILE")
[ -n "$FIRST" ] || exit 0

# Parse [SESSION:WINDOW_INDEX:...]
SESSION=$(echo "$FIRST" | sed -n 's/.*\[\([^:]*\):.*/\1/p')
WINDOW=$(echo "$FIRST" | sed -n 's/.*\[[^:]*:\([^:]*\):.*/\1/p')

[ -n "$SESSION" ] && [ -n "$WINDOW" ] || exit 0

tmux select-window -t "$SESSION:$WINDOW" 2>/dev/null && \
  tmux switch-client -t "$SESSION" 2>/dev/null

exit 0
