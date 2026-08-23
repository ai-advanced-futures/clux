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
set -g status-left "#(~/.config/clux/scripts/show-notification.sh) "
```

### Recommended tmux settings

```bash
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
```

`status-interval 1` is a fast redraw, not just a safety net: the busy glyph on clux's session bar advances one animation frame per interval, so `1` gives a roughly 1fps pulse. `/clux:setup` only ever *reports* this setting on an existing config — it never writes it there.

### Validate

Inside Claude Code, run:

```
/clux:validate
```

It is read-only — it reports what it finds and changes nothing. Run `/clux:setup` to repair anything it reports.

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
set -g status-left "#(~/.config/clux/scripts/show-notification.sh)#[fg=colour235,bg=colour252,bold] #S "
```

### Minimal

```bash
set -g @claude-notify-bg "default"
set -g @claude-notify-fg "yellow"
```

## Agent view

Claude Code ≥ v2.1.139 supports background agent sessions. You can inspect them with `claude agents` inside any terminal, which opens the agent dashboard. clux integrates with this workflow.

### How it works

When a background agent session needs attention (permission prompt, idle), Claude Code fires a `Notification` hook. clux:

1. Appends a `⚡ <label>` entry to the notification queue so the status bar lights up.
2. Fires a direct desktop notification (macOS banner via `osascript`; falls back to `terminal-notifier` if available).
3. Removes the entry automatically when the session is attended to (`UserPromptSubmit`) or ends (`Stop` / `SessionEnd`).

### Navigation

Press `prefix m` (the jump key) from any tmux window. clux routes to the correct dashboard among all open sessions using a three-level cascade:

1. **Fast-path:** jumps directly to the pane recorded in the notification entry (stored as `TMUXSID:WID:PID`), targeting the exact session that owns the waiting agent.
2. **cwd re-resolve:** if the recorded pane is gone, re-scans all panes whose window name matches `@clux-agent-window` and picks the one whose working directory is the longest prefix of the agent's cwd.
3. **Fallback:** if no match is found, opens a new window running `claude agents`.

### Configuration

These tmux options apply to the reader/jump side (status bar and key handler). In v1 the writer (agent hook) uses hardcoded defaults; sidecar-config support is a future enhancement.

| Option | Default | Description |
|--------|---------|-------------|
| `@clux-agent-visual` | `on` | Show `⚡` entry in tmux status bar |
| `@clux-agent-sound` | `on` | Play sound when agent needs attention |
| `@clux-agent-desktop` | `on` | Fire macOS desktop notification |
| `@clux-agent-osc` | `9` | OSC code for terminal sequence (9 = iTerm2 growl) |
| `@clux-agent-marker` | `⚡` | Status bar prefix marker for agent entries |
| `@clux-agent-window` | `agents` | tmux window name that hosts the claude agents dashboard — used as the primary routing anchor for multi-session jump |
| `@clux-agent-nav-key` | `Left` | key sent to the agents pane on arrival to return to the main list |

### Requirements

- Claude Code ≥ v2.1.139
- tmux running (agent sessions are headless; clux bridges them to your tmux status bar)

## Animated busy glyph

On clux's own session bar (installed via `/clux:setup`), the glyph for a `busy` Claude cycles through frames instead of sitting still, so "working" reads differently from "hung" at a glance — default `- \ | /`, one frame per `status-interval`. Customize it with `@clux-agent-glyph-busy-frames` (**always single-quoted** — a double-quoted value loses its backslash to tmux's own parser). Set `@clux-agent-glyph-busy` alone and leave `-frames` unset to keep a static glyph. Full option table and an opt-in moon-rotation example: `plugins/clux/skills/configuring-tmux/SKILL.md`, §3.7.

## throttle.sh — memoize a slow status-line job

tmux re-runs every `#()` job on the status line on every redraw, not just the one segment that changed — so a faster `status-interval` (see above) makes your own status-line jobs pay too, not only clux's. `throttle.sh` caches a job's output and re-runs the command only every N seconds:

```bash
#(~/.config/clux/scripts/throttle.sh 10 ~/.config/tmux/scripts/git.sh "#{pane_current_path}")
```

It ships with clux but is entirely opt-in — `/clux:setup` never rewrites your existing `#()` jobs to use it.

## Troubleshooting

### Hooks not triggering

**Symptom:** Prompts submitted but window doesn't rename / notifications don't appear.

**Solution:** Run validation inside Claude Code:
```
/clux:validate
```

Then run `/clux:setup` to repair what it reports.

### Plugin path issues

Claude Code automatically sets `${CLAUDE_PLUGIN_ROOT}` when executing hooks. If you see path-related errors:

1. Verify plugin is installed: `ls ~/.claude/plugins/cache/*/clux/`
2. Check hooks.json: `cat ~/.claude/plugins/cache/*/clux/*/hooks/hooks.json`
3. For TPM installations, ensure hooks point to `~/.tmux/plugins/clux/`

### Window names not updating

clux uses tmux's `automatic-rename` with `#{pane_title}` — Claude Code sets the pane title via OSC escape sequences as it works. If window names stay static:

1. Ensure `automatic-rename` is on: `tmux show-option -g automatic-rename`
2. Ensure format is set: `tmux show-option -g automatic-rename-format` (should show `#{pane_title}`)
3. Check that no other plugin or config overrides `automatic-rename off`

### Notifications disappear immediately

**Cause:** Auto-dismiss triggered when notification appears in current window.

**Solution:** Jump to notification first using `N` (or configured key) before dismissing.

## Development

Tests require bats-core:

```bash
brew install bats-core
bats test/
```

## License

MIT
