#!/usr/bin/env bash

# Jump to tmux session/window from top notification
# Status bar auto-pops notification on arrival

NOTIFY_FILE="${CLUX_NOTIFY_FILE:-$HOME/.config/tmux/claude_notification}"

[ -f "$NOTIFY_FILE" ] || exit 0

FIRST=$(head -1 "$NOTIFY_FILE")
[ -n "$FIRST" ] || exit 0

# Agent-view entry: id field begins with "agent:" — MUST run before the generic
# ||| check below because agent: lines also contain |||, and the generic branch
# would mis-route them as tmux select-window -t "agent:<sid>".
if [[ "$FIRST" == *"|||agent:"* ]]; then
    # shellcheck source=./helpers.sh
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
    # Line shape: "<marker> <label>|||agent:<session_id>"
    _sid="${FIRST##*|||agent:}"  # "<session_id>"
    agent_jump                   # switch to the agents-view window (by name)
    _agent_remove_entry "$_sid"  # clear-on-jump: drop the entry we just handled
    tmux refresh-client -S 2>/dev/null
    exit 0
fi

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
