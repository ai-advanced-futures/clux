---
name: setup
description: Autonomously configure tmux.conf for tclux notifications
---

Run the tclux autonomous setup script to configure your tmux.conf:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/setup-tmux-conf.sh
```

This command will:

1. **Detect** your current tmux.conf state (missing, existing, or already configured)
2. **Show** you exactly what will change before making modifications
3. **Ask** for confirmation before proceeding
4. **Backup** your existing ~/.tmux.conf with timestamp
5. **Modify** your config to add the tclux notification display
6. **Verify** the changes are correct
7. **Provide** rollback instructions if needed

## What it configures

The script will add or update your tmux.conf to include:

```tmux
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
```

## Edge cases handled

- **No ~/.tmux.conf** → Creates new file with tclux config
- **Existing status-left** → Prepends notification display
- **Already configured** → Detects and skips (no changes)
- **Complex status-left** → Preserves existing formatting and variables

## After setup

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

## Manual setup

If you prefer manual configuration, add this to your ~/.tmux.conf:

```tmux
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
```

Note: The `${CLAUDE_PLUGIN_ROOT}` variable is automatically set by Claude Code and should remain as-is (do not expand to an absolute path).
