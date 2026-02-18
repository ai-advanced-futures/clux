#!/usr/bin/env bash

# Jump to tmux session/window from top notification
# Status bar auto-pops notification on arrival

NOTIFY_FILE="${CLUX_NOTIFY_FILE:-$HOME/.config/tmux/claude_notification}"

[ -f "$NOTIFY_FILE" ] || exit 0

FIRST=$(head -1 "$NOTIFY_FILE")
[ -n "$FIRST" ] || exit 0

# Try ||| marker first (format: ...|||session_id:window_id)
if [[ "$FIRST" == *"|||"* ]]; then
  ID_PART="${FIRST##*|||}"
  SESSION_ID="${ID_PART%%:*}"
  WINDOW_ID="${ID_PART#*:}"
  if [ -n "$SESSION_ID" ] && [ -n "$WINDOW_ID" ]; then
    tmux select-window -t "$SESSION_ID:$WINDOW_ID" 2>/dev/null && \
      tmux switch-client -t "$SESSION_ID" 2>/dev/null
    exit 0
  fi
fi

# Fall back to legacy |ID: marker (format: ...|ID:session_id:window_id)
if [[ "$FIRST" == *"|ID:"* ]]; then
  ID_PART="${FIRST##*|ID:}"
  SESSION_ID="${ID_PART%%:*}"
  WINDOW_ID="${ID_PART#*:}"
  if [ -n "$SESSION_ID" ] && [ -n "$WINDOW_ID" ]; then
    tmux select-window -t "$SESSION_ID:$WINDOW_ID" 2>/dev/null && \
      tmux switch-client -t "$SESSION_ID" 2>/dev/null
    exit 0
  fi
fi

# Fall back to name-based navigation (bare format: SESSION:WINDOW_NAME ...)
SESSION="${FIRST%%:*}"
REMAINDER="${FIRST#*:}"
WINDOW="${REMAINDER%% *}"

[ -n "$SESSION" ] && [ -n "$WINDOW" ] || exit 0

tmux select-window -t "$SESSION:$WINDOW" 2>/dev/null && \
  tmux switch-client -t "$SESSION" 2>/dev/null

exit 0
