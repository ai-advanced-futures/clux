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
        # Line shape: "<marker> <label>|||agent:<session_id>"
        _sid="${line##*|||agent:}"
        agent_jump                   # switch to the agents-view window (by name)
        _agent_remove_entry "$_sid"  # clear-on-jump
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
