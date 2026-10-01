# clux reference

Detail that the [README](../README.md) leaves out.

## Manual setup

Use this section only if you do not want `/clux:setup` to edit your tmux config.

Add the notification display to `status-left` or `status-right` in `tmux.conf`:

```bash
set -g status-left "#(~/.config/clux/scripts/show-notification.sh) "
```

Recommended settings:

```bash
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
```

`status-interval 1` gives a fast redraw. The busy glyph on the clux session bar advances one frame each interval, so `1` gives approximately one frame each second. `/clux:setup` reports this setting on an existing config. It does not write it there.

### TPM

Add to `~/.tmux.conf`, then press `prefix + I`:

```bash
set -g @plugin 'ai-advanced-futures/clux'
```

Then add the hooks to `~/.claude/settings.json` under `"hooks"`:

```json
{
  "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/clux/hooks/notify-tmux.sh", "timeout": 5 }] }],
  "StopFailure": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/clux/hooks/notify-tmux.sh", "timeout": 5 }] }],
  "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/clux/hooks/notify-tmux.sh", "timeout": 5 }] }],
  "TeammateIdle": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.tmux/plugins/clux/hooks/notify-tmux.sh", "timeout": 5 }] }]
}
```

The plugin's own `hooks/hooks.json` is the complete list. It also registers `agent-state.sh` on the same events, plus `SessionStart` and `SessionEnd`, for the agent-state column. Copy that file if you want the bar's state glyphs too.

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
| `@claude-notify-sound` | `on` | `on`, `off`, or custom command (the global fallback for every type below) |
| `@claude-notify-<type>-visual` | see below | Status-bar badge (and, for an agents workspace, the desktop banner and jump entry) for one type |
| `@claude-notify-<type>-sound` | see below | `on`, `off`, or a custom command, for one type |
| `@claude-notify-<type>-sound-file` | OS default | Sound file for one type |

`<type>` names what Claude Code told clux, and each one is a question in `/clux:setup`:

| Type | Claude Code event | Visual / sound default |
|------|-------------------|------------------------|
| `notification` | `Notification` — Claude needs you (permission, idle, `agent_needs_input`, an MCP elicitation dialog) | on / on |
| `stop` | `Stop`, and `Notification: agent_completed` — Claude finished | off / off |
| `failure` | `StopFailure` — the turn ended on an API error (rate limit, overloaded, billing, auth) | on / on |
| `quota` | `Notification: quota_auto_resume_*` — Claude paused on a usage quota | on / on |
| `prompt` | `UserPromptSubmit` | off / off |
| `teammate` | `TeammateIdle` — an agent-team teammate went idle | off / off |

Sound defaults to `off` on a machine with no audio player.

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

When a background agent session needs attention (permission prompt, idle, an MCP dialog), Claude Code fires a `Notification` hook; when it finishes, `Stop`; when its turn dies on an API error, `StopFailure`. For each one whose `@claude-notify-<type>-visual` is on, clux:

1. Appends a `<marker> agents / <label>` entry to the notification queue so the status bar lights up — `⚡` needs you, `✓` finished, `✗` failed (with the error type), `⏳` paused on quota.
2. Fires a direct desktop notification (macOS banner via `osascript`; falls back to `terminal-notifier` if available).
3. Keeps the entry until you jump to it (`prefix m`) or dismiss it. A newer event for the same session replaces the older entry, so a session that finishes after asking shows `✓`, not both.

The agent-state column in the bar (`*` busy, `!` needs you, `v` finished, `x` failed) is written by the same hooks and needs no option — see `/clux:setup`.

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

The clux session bar shows the glyph for a `busy` Claude in frames. The glyph
moves. You can thus see the difference between "working" and "hung". The
default is `- \ | /`, with one frame each `status-interval`.

To change the frames, set `@clux-agent-glyph-busy-frames`. **Use single
quotes.** tmux removes the backslash from a value in double quotes.

To keep a glyph that does not move, set `@clux-agent-glyph-busy` and do not set
`-frames`.

For the full option table and a moon-rotation example, read
`plugins/clux/skills/configuring-tmux/SKILL.md`, §3.7.

## throttle.sh — memoize a slow status-line job

tmux runs every `#()` job on the status line again at each redraw. It does not
run only the segment that changed. Thus a smaller `status-interval` (read
above) also costs more for your own jobs, not only for the clux job.

`throttle.sh` keeps the output of a job. It runs the command again only after N
seconds:

```bash
#(~/.config/clux/scripts/throttle.sh 10 ~/.config/tmux/scripts/git.sh "#{pane_current_path}")
```

clux supplies this tool. Use it if you want it. `/clux:setup` does not change your `#()` jobs.

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


## Companion terminal (clux:terminal)

The `clux:terminal` skill gives Claude one tmux pane that you can see. Claude runs commands in it, and the pane shell keeps its directory and its exported variables from one command to the next.

The companion needs `perl` for its locks and for the start time of a process (macOS and most Linux systems have it). Without perl, `terminal.sh` gives exit code 2 and `clux terminal needs perl`. `/clux:validate` gives a `WARN` when perl is missing.

From 4.0.0, the companion needs Laya, a local model. Laya examines each command before it runs, each line that Claude sends with Enter, the prompt in the pane, and all pane text that goes back to Claude:

- A dangerous command runs only after you type `y` in the pane.
- A line with a secret goes back to Claude as `[held by laya: secret]`. The raw text stays in the pane.
- Text that Laya cannot examine in its time limit goes back as `[held by laya: not_examined, <k> lines]`. On a machine with no GPU (no MPS or CUDA), a large output takes more time, so more lines can be held this way.
- When Laya does not answer, the companion stops with exit code 6 and sends no pane text to Claude.
- Each command and each line that Claude ends at the companion prompt runs in a subshell. Only the directory and the exported variables persist. A command that Laya passed can still write any file of your user; Laya is the only check before it runs.
- When the Laya server that the companion started stops, `open` again starts a new one.

Install Laya one time. Claude asks you before it runs the install:

```bash
<plugin>/scripts/terminal.sh laya install
<plugin>/scripts/terminal.sh laya status
```

The install makes a Python venv in `~/.local/share/clux/laya` with `laya` 0.3.21 and PyTorch, and downloads the English checkpoint to the Hugging Face cache. Each Claude session starts its own Laya server, which uses about 1–2 GB of memory. To use a server that you start, set `CLUX_LAYA_URL` (a loopback host only) and `CLUX_LAYA_KEY`.

The policies are in `plugins/clux/config/laya/`. There is no user copy: a command in the companion can write the files of the user, so a user copy could turn off the checks.

### Background sessions

From 4.1.0, the companion also operates in a Claude Code session with no tmux pane, for example a `claude --bg` session or a session that a `claude agents` dashboard starts:

- `open` opens a new window, `clux-terminal <id>`, in the tmux session of the dashboard, on your default tmux server. `<id>` is the first 8 characters of the session ID. The output has a `window=<session>:<index>` line.
- With no dashboard, or with `--socket`, `open` opens the companion on a private tmux server. The output has an `attach=` line, and an `attach_in_tmux=` line to use inside tmux.
- The `SessionStart` hook writes `CLUX_SESSION_ID` to the environment of the session. The companion uses it, else `CLAUDE_CODE_SESSION_ID`, and the session process `CLAUDE_PID`.
- A watchdog process closes the companion and stops its Laya server when the session process ends, also after a crash. The `SessionEnd` hook closes it at the end of the session and at `/clear`.
- The companion pane holds a mark. After a restart of the tmux server, a verb that does not find the mark gives exit code 4 and types nothing.
- clux finds only a dashboard on the default tmux server. A dashboard on another server (`tmux -L name`) gives a private server.

