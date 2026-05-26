#!/usr/bin/env bash

# TPM entry point for clux (tmux-claude-notify)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/scripts/helpers.sh"

# Ensure notification directory exists
mkdir -p "$(dirname "$NOTIFY_FILE")"

# Write queue-file path to sidecar so detached agent hooks can resolve it
# without tmux IPC (resolve_notify_file() tier 2)
_CLUX_SIDECAR_DIR="$HOME/.config/clux"
mkdir -p "$_CLUX_SIDECAR_DIR"
printf '%s\n' "$NOTIFY_FILE" > "$_CLUX_SIDECAR_DIR/notify-file-path"

# Cache tmux options in global env so status-bar scripts avoid IPC on every cycle
# (env vars are inherited by run-shell and #(...) status-bar calls)
tmux setenv -g CLUX_NOTIFY_FILE "$NOTIFY_FILE"
tmux setenv -g CLUX_NOTIFY_BG "$NOTIFY_BG"
tmux setenv -g CLUX_NOTIFY_FG "$NOTIFY_FG"

# Register keybindings
tmux bind-key "$NOTIFY_DISMISS_KEY" run-shell "$CURRENT_DIR/scripts/dismiss-notification.sh"
tmux bind-key "$NOTIFY_JUMP_KEY" run-shell "$CURRENT_DIR/scripts/jump-to-notification.sh"
