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
    _AGENT_QUEUE="$NOTIFY_FILE"  # the queue we read FIRST from (CLUX_NOTIFY_FILE-aware)
    # shellcheck source=./helpers.sh
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
    # helpers.sh re-derives NOTIFY_FILE from get_tmux_option at source time, which
    # ignores CLUX_NOTIFY_FILE — restore the queue we actually read so
    # _agent_remove_entry clears the right file.
    NOTIFY_FILE="$_AGENT_QUEUE"
    recompute_lock_target
    # Line shape (new):    "<marker> <label>|||agent:<SID>@@<TMUXSID>:<WID>:<PID>@@<CWD>"
    # Line shape (legacy): "<marker> <label>|||agent:<SID>"
    rest="${FIRST##*|||agent:}"

    # Split rest on @@ into three segments. For a legacy line (no @@) seg2/seg3
    # MUST be force-emptied — ${rest#*@@} returns rest UNCHANGED when there is no
    # delimiter, which would otherwise make seg2 wrongly equal the SID.
    seg1="${rest%%@@*}"
    if [[ "$rest" != *@@* ]]; then
        seg2=""
        seg3=""
    else
        after1="${rest#*@@}"
        seg2="${after1%%@@*}"
        seg3="${after1#*@@}"
    fi
    remove_key="$seg1"  # dedup key is the display SID (seg1), NOT the pane coords

    # P6 CORRECTION: the pane id is seg2's LAST colon token (TMUXSID:WID:PID),
    # NOT seg1. A naive rest%%@@* would hand agent_jump the SID and mis-route.
    if [ -n "$seg2" ]; then
        pane_id="${seg2##*:}"   # last colon token
        sid="${seg2%%:*}"       # first colon token
        _mid="${seg2#*:}"
        wid="${_mid%%:*}"       # middle colon token
        target="$sid $wid $pane_id"
    else
        target=""
    fi

    agent_jump "$target" "$seg3"      # fast-path / re-resolve / v3 fallback
    _agent_remove_entry "$remove_key" # clear-on-jump (widened regex clears both formats)
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
