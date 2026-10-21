#!/usr/bin/env bash

# Interactive notification picker using fzf (prefix + M). The parse of the
# selected line lives in notification-line.sh, so this popup, prefix + m and
# the Claude Code notifications pane route a line the same way.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"
NOTIFY_FILE=$(resolve_notify_file "$(clux_server_name)")

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

# fzf runs in a loop, so the popup stays open after a delete: ctrl-x (and
# ctrl-d, the key of 4.x) takes the line out, then fzf starts again on the new
# queue, with the cursor on the first line. A shell loop, not a fzf reload
# bind: it works with every fzf version, and the test stub can drive it.
# Enter jumps and ends the popup; Esc ends it; an empty queue ends it.
#
# fzf gets "<line><TAB><text>" and shows field 2 only: the text before the id
# marker, as the notifications pane and the status bar show it. The text is the
# LAST field, because some fzf versions show the delimiter after a field that
# is not last. The writers remove control bytes, so a line holds no TAB.
while [ -s "$NOTIFY_FILE" ]; do
    selected=$(awk '{
            text = $0
            i = index(text, "|||")
            if (i > 0) text = substr(text, 1, i - 1)
            print $0 "\t" text
        }' "$NOTIFY_FILE" | fzf --reverse \
        --delimiter='\t' --with-nth=2 \
        --header="Enter=jump  Ctrl-X=delete  Esc=close" \
        --expect=ctrl-x,ctrl-d)

    # fzf exits 130 on Esc/ctrl-c
    [ -z "$selected" ] && exit 0

    key=$(head -1 <<< "$selected")
    line=$(tail -1 <<< "$selected")
    line="${line%%$'\t'*}"

    [ -z "$line" ] && exit 0

    case "$key" in
        ctrl-x|ctrl-d)
            # A busy queue keeps the line: fzf shows it again, and the person
            # can press ctrl-x once more.
            "$CURRENT_DIR/notification-line.sh" remove "$line"
            ;;
        *)
            "$CURRENT_DIR/notification-line.sh" jump "$line"
            break
            ;;
    esac
done

# The popup always ends well, as prefix + m does: a line with no target or a
# busy queue must not leave an error line inside display-popup.
exit 0
