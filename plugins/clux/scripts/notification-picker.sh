#!/usr/bin/env bash

# Interactive notification picker using fzf (prefix + M). The parse of the
# selected line lives in notification-line.sh, so this popup, prefix + m and
# the Claude Code notifications pane route a line the same way.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"
NOTIFY_FILE=$(resolve_notify_file)

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
    "$CURRENT_DIR/notification-line.sh" remove "$line"
else
    "$CURRENT_DIR/notification-line.sh" jump "$line"
fi

# The popup always ends well, as prefix + m does: a line with no target or a
# busy queue must not leave an error line inside display-popup.
exit 0
