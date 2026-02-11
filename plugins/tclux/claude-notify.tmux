#!/usr/bin/env bash

# TPM entry point for tclux (tmux-claude-notify)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/scripts/helpers.sh"

# Ensure notification directory exists
mkdir -p "$(dirname "$NOTIFY_FILE")"

# Register keybindings
tmux bind-key "$NOTIFY_DISMISS_KEY" run-shell "$CURRENT_DIR/scripts/dismiss-notification.sh"
tmux bind-key "$NOTIFY_JUMP_KEY" run-shell "$CURRENT_DIR/scripts/jump-to-notification.sh"
