#!/usr/bin/env bash
# Pure path resolution — no top-level statements, no tmux IPC.
# Source this file to obtain resolve_notify_file().

_CLUX_SIDECAR="${HOME}/.config/clux/notify-file-path"
_CLUX_AGENT_SIDECAR="${HOME}/.config/clux/agent-state-dir"

resolve_notify_file() {
    # Tier 1: explicit env var (set by tmux setenv -g in claude-notify.tmux)
    if [ -n "${CLUX_NOTIFY_FILE:-}" ]; then
        echo "$CLUX_NOTIFY_FILE"
        return
    fi
    # Tier 2: sidecar written at plugin load time by claude-notify.tmux
    local sidecar_val
    sidecar_val=$(cat "$_CLUX_SIDECAR" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$sidecar_val" ]; then
        echo "$sidecar_val"
        return
    fi
    # Tier 3: HOME default
    echo "${HOME}/.config/tmux/claude_notification"
}

# Resolve the agent-state directory — one file per tmux pane, holding one word
# (busy / needs-you / finished). Mirrors resolve_notify_file() exactly, same
# three tiers, so the writer (hooks/agent-state.sh) and the readers
# (agent-query.sh, agent-bar.sh, agent-clear.sh) can never disagree about where
# the store lives. Never emits a trailing slash — every caller joins with "/".
#
# XDG_STATE_HOME (not the queue's ~/.config/tmux) is correct here: this data is
# per-machine, regenerable, and not configuration.
resolve_agent_state_dir() {
    # Tier 1: explicit env var (set by tmux setenv -g in claude-notify.tmux)
    if [ -n "${CLUX_AGENT_STATE_DIR:-}" ]; then
        echo "$CLUX_AGENT_STATE_DIR"
        return
    fi
    # Tier 2: sidecar written at plugin load time by claude-notify.tmux
    local sidecar_val
    sidecar_val=$(cat "$_CLUX_AGENT_SIDECAR" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$sidecar_val" ]; then
        echo "$sidecar_val"
        return
    fi
    # Tier 3: XDG default
    echo "${XDG_STATE_HOME:-$HOME/.local/state}/clux/agents"
}
