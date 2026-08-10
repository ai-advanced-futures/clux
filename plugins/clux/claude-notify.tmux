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

# --- Agent state bar (see scripts/path.sh, hooks/agent-state.sh) ---

# Resolve the agent-state directory the same way NOTIFY_FILE is resolved above,
# then cache it the same two ways: a sidecar file (tier 2, read by detached
# Claude Code hooks that have no tmux IPC) and a tmux global env var (tier 1,
# read by anything spawned through tmux itself, e.g. the hooks below).
AGENT_STATE_DIR=$(get_tmux_option "@clux-agent-state-dir" "${XDG_STATE_HOME:-$HOME/.local/state}/clux/agents")
mkdir -p "$AGENT_STATE_DIR"

# Sidecar first: agent-clear.sh --reap below runs as a plain child of this
# script, not through tmux, so it cannot see the setenv -g that follows — it
# resolves via the sidecar (tier 2), exactly like a detached hook would.
printf '%s\n' "$AGENT_STATE_DIR" > "$_CLUX_SIDECAR_DIR/agent-state-dir"

tmux setenv -g CLUX_AGENT_STATE_DIR "$AGENT_STATE_DIR"

# Register the two hooks that clear a window's `finished` marks when the user
# looks at it. Indexed [90] so re-sourcing tmux.conf (tpm reload) never
# duplicates the hook, and any hand-written hooks at low indices are left
# alone. Non-tpm installs must add the equivalent lines by hand — see
# /clux:setup section C2.
tmux set-hook -g 'after-select-window[90]' "run-shell \"$CURRENT_DIR/scripts/agent-clear.sh '#{window_id}'\""
tmux set-hook -g 'client-session-changed[90]' "run-shell \"$CURRENT_DIR/scripts/agent-clear.sh '#{window_id}'\""

# Reap state files whose pane id is no longer live anywhere on the server —
# closes the pane-id-reuse hole after a tmux server restart. Writer's job,
# done once at config load.
"$CURRENT_DIR/scripts/agent-clear.sh" --reap
