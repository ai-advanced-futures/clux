# clux

tmux status bar notifications for Claude Code — know when tasks finish or need input.

## Prerequisites

- **tmux** — installed and running
- **bash** ≥ 4.0 — for proper string operations
- **jq** (recommended) — for JSON parsing; grep fallback available
- **flock** (recommended) — for file locking; mkdir fallback available
- **~/.config/tmux/** — writable directory for notification queue

## Install (Claude Code Plugin)

```bash
claude plugin install ai-advanced-futures/clux --scope user
```

Hooks auto-register via `${CLAUDE_PLUGIN_ROOT}` (automatically set by Claude Code). No manual JSON editing needed.

### Add to your tmux status bar

Add the notification display to `status-left` or `status-right` in `tmux.conf`:

```bash
set -g status-left "#(~/.claude/plugins/clux/scripts/show-notification.sh) "
```

### Recommended tmux settings

```bash
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
```

### Validate

Run `/clux:setup` inside Claude Code, or:

```bash
~/.claude/plugins/clux/scripts/validate-setup.sh
```

## Alternative: TPM Install

Add to `~/.tmux.conf`:

```bash
set -g @plugin 'ai-advanced-futures/clux'
```

Then `prefix + I` to install.

Add the following to `~/.claude/settings.json` under `"hooks"`:

```json
{
  "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/clux/hooks/notify-tmux.sh", "timeout": 5 }] }],
  "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/clux/hooks/notify-tmux.sh", "timeout": 5 }] }]
}
```

Add to your status bar:

```bash
set -g status-left "#(~/.tmux/plugins/clux/scripts/show-notification.sh) "
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
set -g status-left "#(~/.claude/plugins/clux/scripts/show-notification.sh)#[fg=colour235,bg=colour252,bold] #S "
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
~/.claude/plugins/cache/ai-advanced-futures/clux/*/scripts/validate-setup.sh
```

Or inside Claude Code:
```
/clux:setup
```

### Plugin path issues

Claude Code automatically sets `${CLAUDE_PLUGIN_ROOT}` when executing hooks. If you see path-related errors:

1. Verify plugin is installed: `ls ~/.claude/plugins/cache/ai-advanced-futures/clux/`
2. Check hooks.json: `cat ~/.claude/plugins/cache/ai-advanced-futures/clux/*/hooks/hooks.json`
3. For TPM installations, ensure hooks point to `~/.tmux/plugins/clux/`

### Window names not updating

clux uses tmux's `automatic-rename` with `#{pane_title}` — Claude Code sets the pane title via OSC escape sequences as it works. If window names stay static:

1. Ensure `automatic-rename` is on: `tmux show-option -g automatic-rename`
2. Ensure format is set: `tmux show-option -g automatic-rename-format` (should show `#{pane_title}`)
3. Check that no other plugin or config overrides `automatic-rename off`

### Notifications disappear immediately

**Cause:** Auto-dismiss triggered when notification appears in current window.

**Solution:** Jump to notification first using `N` (or configured key) before dismissing.

## License

MIT
