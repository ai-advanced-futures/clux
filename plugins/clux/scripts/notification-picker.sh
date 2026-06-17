#!/usr/bin/env bash

# Interactive notification picker using fzf

NOTIFY_FILE="${CLUX_NOTIFY_FILE:-$HOME/.config/tmux/claude_notification}"
LOCKDIR="${NOTIFY_FILE}.lock"

# Check fzf is installed
if ! command -v fzf &>/dev/null; then
    echo "fzf is required but not installed."
    echo ""
    echo "Install via:"
    echo "  brew install fzf        # macOS"
    echo "  apt install fzf         # Debian/Ubuntu"
    echo "  pacman -S fzf           # Arch"
    echo ""
    echo "See https://github.com/junegunn/fzf#installation"
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

# Check notifications exist
if [ ! -f "$NOTIFY_FILE" ] || [ ! -s "$NOTIFY_FILE" ]; then
    echo "No notifications."
    read -n 1 -s -r -p "Press any key to close..."
    exit 0
fi

selected=$(fzf --reverse \
    --header="Enter=jump  Ctrl-D=dismiss  Esc=close" \
    --expect=ctrl-d \
    < "$NOTIFY_FILE")

# fzf exits 130 on Esc/ctrl-c
[ -z "$selected" ] && exit 0

key=$(head -1 <<< "$selected")
line=$(tail -1 <<< "$selected")

[ -z "$line" ] && exit 0

if [ "$key" = "ctrl-d" ]; then
    # Dismiss: remove the selected line from the queue
    # Retry briefly (user-triggered: 500ms max)
    _i=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        _i=$((_i + 1)); [ "$_i" -ge 5 ] && exit 0
        sleep 0.1
    done
    trap 'rm -rf "$LOCKDIR"' EXIT
    grep -vF "$line" "$NOTIFY_FILE" > "${NOTIFY_FILE}.tmp" 2>/dev/null
    mv "${NOTIFY_FILE}.tmp" "$NOTIFY_FILE"
else
    # ENTER: jump to the window
    # Check for agent-view entry first — these have |||agent: in the line.
    # NOTE: sourcing helpers.sh here re-runs its module-level code (sets NOTIFY_FILE
    # and LOCKDIR globals). This is SAFE because the agent: branch calls agent_jump
    # and the handler returns immediately — no code after this block reads NOTIFY_FILE.
    # The Ctrl-D dismiss path (above) runs before this else branch and is unaffected.
    if [[ "$line" == *"|||agent:"* ]]; then
        # shellcheck source=./helpers.sh
        # shellcheck disable=SC1091
        source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
        # helpers.sh re-derives NOTIFY_FILE from get_tmux_option at source time,
        # which ignores CLUX_NOTIFY_FILE — restore the queue we actually read so
        # _agent_remove_entry clears the right file (mirrors jump-to-notification.sh).
        NOTIFY_FILE="${CLUX_NOTIFY_FILE:-$NOTIFY_FILE}"
        recompute_lock_target
        # Line shape (new):    "<marker> <label>|||agent:<SID>@@<TMUXSID>:<WID>:<PID>@@<CWD>"
        # Line shape (legacy): "<marker> <label>|||agent:<SID>"
        # Parse identically to jump-to-notification.sh (P6: the pane id is seg2's
        # LAST colon token, NOT seg1 — the dedup/remove key is seg1, the display SID).
        rest="${line##*|||agent:}"
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
    else
        # Parse SESSION:WINDOW_NAME from bare format (interactive)
        session="${line%%:*}"
        remainder="${line#*:}"
        window="${remainder%% *}"
        if [ -n "$session" ] && [ -n "$window" ]; then
            tmux select-window -t "${session}:${window}" 2>/dev/null && \
              tmux switch-client -t "${session}" 2>/dev/null
        fi
    fi
fi
