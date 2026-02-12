# tclux

tmux status bar notifications for Claude Code — know when tasks finish or need input.

## Prerequisites

- **tmux** — installed and running
- **bash** ≥ 4.0 — for proper string operations
- **jq** (recommended) — for JSON parsing; grep fallback available
- **flock** (recommended) — for file locking; mkdir fallback available
- **OPENAI_API_KEY** — required only for smart window renaming feature
- **~/.config/tmux/** — writable directory for notification queue

## Install (Claude Code Plugin)

```bash
claude plugin install 404pilo/tclux --scope user
```

Hooks auto-register via `${CLAUDE_PLUGIN_ROOT}` (automatically set by Claude Code). No manual JSON editing needed.

### Add to your tmux status bar

Add the notification display to `status-left` or `status-right` in `tmux.conf`:

```bash
set -g status-left "#(~/.claude/plugins/tclux/scripts/show-notification.sh) "
```

### Recommended tmux settings

```bash
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
```

### Validate

Run `/tclux:setup` inside Claude Code, or:

```bash
~/.claude/plugins/tclux/scripts/validate-setup.sh
```

## Alternative: TPM Install

Add to `~/.tmux.conf`:

```bash
set -g @plugin '404pilo/tclux'
```

Then `prefix + I` to install.

Add the following to `~/.claude/settings.json` under `"hooks"`:

```json
{
  "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tclux/hooks/notify-tmux.sh", "timeout": 5 }] }],
  "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/tclux/hooks/notify-tmux.sh", "timeout": 5 }] }]
}
```

Add to your status bar:

```bash
set -g status-left "#(~/.tmux/plugins/tclux/scripts/show-notification.sh) "
```

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `@claude-notify-file` | `~/.config/tmux/claude_notification` | Queue file path |
| `@claude-notify-jump` | `N` | Jump to notification source |
| `@claude-notify-dismiss` | `` ` `` | Dismiss top notification |
| `@claude-notify-bg` | `yellow` | Background color |
| `@claude-notify-fg` | `black` | Foreground color |
| `@claude-notify-sound` | `on` | `on`, `off`, or custom command |
| `@claude-notify-smart-title` | `on` | Auto-rename tmux window via Haiku (`on`/`off`) |

Example overrides:

```bash
set -g @claude-notify-bg "colour214"
set -g @claude-notify-fg "colour0"
set -g @claude-notify-sound "off"
```

## Theme Examples

### Catppuccin

```bash
set -g @claude-notify-bg "#f9e2af"
set -g @claude-notify-fg "#1e1e2e"
```

### Powerline

```bash
set -g status-left "#(~/.claude/plugins/tclux/scripts/show-notification.sh)#[fg=colour235,bg=colour252,bold] #S "
```

### Minimal

```bash
set -g @claude-notify-bg "default"
set -g @claude-notify-fg "yellow"
```

## Troubleshooting

### Hooks not triggering

**Symptom:** Prompts submitted but window doesn't rename / notifications don't appear.

**Solution:** Run validation:
```bash
~/.claude/plugins/cache/404pilo/tclux/1.0.0/scripts/validate-setup.sh
```

Or inside Claude Code:
```
/tclux:setup
```

### Plugin path issues

Claude Code automatically sets `${CLAUDE_PLUGIN_ROOT}` when executing hooks. If you see path-related errors:

1. Verify plugin is installed: `ls ~/.claude/plugins/cache/404pilo/tclux/`
2. Check hooks.json references: `cat ~/.claude/plugins/cache/404pilo/tclux/*/hooks/hooks.json`
3. For TPM installations, ensure hooks point to `~/.tmux/plugins/tclux/`

### Smart window renaming fails

If window names aren't auto-updating:

1. Check API key: `echo $OPENAI_API_KEY` (should not be empty)
2. Enable debug mode: `TCLUX_DEBUG=1` (logs to `/tmp/tclux.log`)
3. Verify jq installed: `jq --version`

### Notifications disappear immediately

**Cause:** Auto-dismiss triggered when notification appears in current window.

**Solution:** Jump to notification first using `N` (or configured key) before dismissing.

## License

MIT
