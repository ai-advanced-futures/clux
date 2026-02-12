---
name: setup
description: Intelligently configure tmux for tclux notifications
---

# tclux Setup

This command intelligently configures your tmux.conf to display Claude Code notifications in the status bar.

## Recommended: Interactive Setup

For intelligent, interactive configuration that preserves your existing tmux settings, run:

```bash
/tclux:auto-setup
```

This uses Claude Code's built-in tools to:

1. **Analyze** your current tmux.conf
2. **Report** findings and potential conflicts
3. **Recommend** changes (status-left, keybindings, supporting settings)
4. **Confirm** with you before making any modifications
5. **Backup** your existing config automatically
6. **Apply** changes preserving all existing configuration
7. **Verify** the configuration works correctly

No external API keys required — Claude Code drives the entire interactive flow.

## Alternative: Script-Based Setup

For a simpler, non-interactive script-based approach, run:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/configure-tmux.sh
```

## What Gets Configured

Both methods add or update your tmux.conf to include:

```tmux
# Status-left with notification appended after existing content
set -g status-left "<your existing value> #{E:#(/absolute/path/to/show-notification.sh)} "
set -g status-interval 1
set -g status-left-length 100
set -g monitor-bell on
set -g bell-action any

# Keybindings
bind-key N run-shell "/absolute/path/to/jump-to-notification.sh"
bind-key ` run-shell "/absolute/path/to/dismiss-notification.sh"
bind-key M display-popup -w 80% -h 60% -E "/absolute/path/to/notification-picker.sh"
```

## After Setup

Reload your tmux configuration:

```bash
tmux source-file ~/.tmux.conf
```

Or restart tmux:

```bash
tmux kill-server && tmux
```

Then validate the integration:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/validate-setup.sh
```

## Manual Setup

If you prefer manual configuration, add this to your `~/.tmux.conf`:

```tmux
set -g status-left "<your existing value> #{E:#(/absolute/path/to/show-notification.sh)} "
```

Replace `/absolute/path/to` with the actual path to the tclux plugin installation.

## Documentation

For detailed strategy and edge case handling, see:

```bash
$CLAUDE_PLUGIN_ROOT/docs/REFERENCE-tmux-setup-strategy.md
```

For configuration definition:

```bash
$CLAUDE_PLUGIN_ROOT/config/tmux-config.yaml
```
