# clux Setup Guide

This document describes how to configure your tmux.conf for clux notifications.

## Recommended: Interactive Setup

For intelligent, interactive configuration that preserves your existing tmux settings, run:

```
/clux:setup
```

This uses Claude Code's built-in tools to:

1. **Analyze** your current tmux.conf
2. **Report** findings and potential conflicts
3. **Recommend** changes (status-left, keybindings, supporting settings)
4. **Confirm** with you before making any modifications
5. **Backup** your existing config automatically
6. **Deploy** scripts to `~/.config/clux/scripts/` for version independence
7. **Apply** changes preserving all existing configuration
8. **Verify** the configuration works correctly

No external API keys required — Claude Code drives the entire interactive flow.

## Alternative: Script-Based Setup

For a simpler, non-interactive script-based approach, the `configure-tmux.sh` script can be found in the plugin's `scripts/` directory.

## What Gets Configured

Both methods add or update your tmux.conf to include:

```tmux
# Status-left with notification appended after existing content
set -g status-left "<your existing value> #(~/.config/clux/scripts/show-notification.sh) "
set -g status-interval 1
set -g status-left-length 200
set -g monitor-bell on
set -g bell-action any

# Keybindings
bind-key N run-shell "~/.config/clux/scripts/jump-to-notification.sh"
bind-key ` run-shell "~/.config/clux/scripts/dismiss-notification.sh"
bind-key DC run-shell "~/.config/clux/scripts/dismiss-notification.sh"
bind-key M display-popup -w 80% -h 60% -E "~/.config/clux/scripts/notification-picker.sh"
```

Scripts are deployed to `~/.config/clux/scripts/` so your tmux.conf doesn't break when the plugin version updates.

## After Setup

Reload your tmux configuration and refresh the status bar:

```bash
tmux source-file ~/.tmux.conf && tmux refresh-client -S
```

Or restart tmux:

```bash
tmux kill-server && tmux
```

## Manual Setup

If you prefer manual configuration, add this to your `~/.tmux.conf`:

```tmux
set -g status-left "<your existing value> #(~/.config/clux/scripts/show-notification.sh) "
```

You'll need to manually copy the plugin scripts to `~/.config/clux/scripts/` first.
