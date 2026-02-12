---
name: setup
description: Intelligently configure tmux for tclux notifications using Claude
---

# tclux Setup

This command intelligently configures your tmux.conf to display Claude Code notifications in the status bar.

## Default: LLM-Driven Setup (Recommended)

For intelligent configuration that preserves your existing tmux settings, run:

```bash
/tclux:auto-setup
```

This uses Claude API to:

1. **Analyze** your current tmux.conf
2. **Intelligently merge** tclux notification integration
3. **Preview** changes before applying
4. **Backup** your existing config automatically
5. **Verify** the configuration is syntactically correct
6. **Reload** tmux with the new settings

**Requires:** `OPENAI_API_KEY` environment variable set

## Alternative: Script-Based Setup

For a simpler, no-API script-based approach, run:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/setup-tmux-conf.sh
```

Or with the newer implementation:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/configure-tmux.sh
```

## What Gets Configured

Both methods add or update your tmux.conf to include:

```tmux
set -g status-left "#{E:#(/absolute/path/to/show-notification.sh)} "
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
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
set -g status-left "#{E:#(/absolute/path/to/show-notification.sh)} "
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
