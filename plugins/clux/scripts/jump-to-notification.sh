#!/usr/bin/env bash

# Jump to the tmux session/window of the TOP notification (prefix + m).
# The status bar pops a notification for the current window as it arrives, so
# the top line is the one the person wants. The parse of that line lives in
# notification-line.sh, shared with the fzf popup and the Claude Code pane.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"
NOTIFY_FILE=$(resolve_notify_file)

[ -f "$NOTIFY_FILE" ] || exit 0

FIRST=$(head -1 "$NOTIFY_FILE")
[ -n "$FIRST" ] || exit 0

"$CURRENT_DIR/notification-line.sh" jump "$FIRST"

# A key binding that exits non-zero makes tmux draw an error line, so a line
# with no target ends quietly here, exactly as it did before.
exit 0
