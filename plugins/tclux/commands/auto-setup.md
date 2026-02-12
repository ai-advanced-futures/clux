---
name: auto-setup
description: Interactively configure tmux for tclux notifications
allowed-tools: Read, Write, Bash, AskUserQuestion
---

# tclux Auto-Setup: Interactive tmux Configuration

You are configuring the user's tmux.conf to integrate tclux notifications. Follow each step below precisely using your tools (Read, Write, Bash, AskUserQuestion). You ARE the LLM — never call external APIs.

## CRITICAL RULES

- **Never call external APIs** — you are Claude Code running inside the user's session
- **Never overwrite existing status-left** — always READ the current value and APPEND the notification snippet after it
- **Always use absolute paths** — expand `$CLAUDE_PLUGIN_ROOT` to the real path on disk
- **Always use double quotes** for status-left values (required for `#{E:}` expansion)
- **Always ask before modifying files** — use AskUserQuestion for confirmation
- **Idempotent** — if already configured, report and offer to skip

## Step 1: Detect Environment

Run these checks using Bash:

```bash
# Verify tmux is installed
command -v tmux

# Resolve plugin root (CLAUDE_PLUGIN_ROOT should be set)
echo "$CLAUDE_PLUGIN_ROOT"

# Verify show-notification.sh exists
ls -la "$CLAUDE_PLUGIN_ROOT/scripts/show-notification.sh"
```

Store `PLUGIN_ROOT` as the resolved absolute path of `$CLAUDE_PLUGIN_ROOT`. Verify these scripts exist:
- `$PLUGIN_ROOT/scripts/show-notification.sh`
- `$PLUGIN_ROOT/scripts/jump-to-notification.sh`
- `$PLUGIN_ROOT/scripts/dismiss-notification.sh`
- `$PLUGIN_ROOT/scripts/notification-picker.sh`

If any are missing, tell the user and stop.

## Step 2: Locate tmux.conf

Check for existing config files in order:
1. `$HOME/.tmux.conf`
2. `${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf`

**If neither exists:** Note that you'll create `$HOME/.tmux.conf`.
**If only one exists:** Use that one.
**If both exist:** Use AskUserQuestion to ask the user which to use.

## Step 3: Analyze Current Configuration

Read the tmux.conf file (if it exists) using the Read tool. Check for:

1. **Already configured?** — Search for `show-notification.sh` in the file. If found, report "tclux is already configured" and use AskUserQuestion to ask if user wants to reconfigure or skip.
2. **Existing status-left** — Extract the current `set -g status-left` value (if any). This is what you will APPEND to — never replace.
3. **status-interval** — Check current value. Recommend `1` if higher than `5`.
4. **status-left-length** — Check current value. Recommend `100` if lower than `80`.
5. **Existing keybindings on N, backtick, M** — Run `tmux list-keys 2>/dev/null | grep -E "bind-key\s+(N|M|\`)"` to detect conflicts.

## Step 4: Report Findings

Present a clear summary to the user. Example:

```
tmux.conf analysis:
  - Config file: ~/.tmux.conf
  - Current status-left: "#[fg=green]#S #[fg=yellow]#I"
  - status-interval: 15 (recommend: 1)
  - status-left-length: 10 (recommend: 100)
  - Keybinding conflicts: none
  - tclux already configured: no
```

## Step 5: Recommend Changes

Present grouped changes using the resolved absolute paths:

### A. Status-left (APPEND notification after existing value)

- If no existing status-left: `set -g status-left "#S #{E:#($PLUGIN_ROOT/scripts/show-notification.sh)} "`
- If existing status-left: Append ` #{E:#($PLUGIN_ROOT/scripts/show-notification.sh)}` before the closing quote
- **Never prepend. Never overwrite.** The user's session name and existing content stay first.

### B. Supporting settings

```tmux
set -g status-interval 1
set -g status-left-length 100
set -g monitor-bell on
set -g bell-action any
```

### C. Keybindings

Offer these defaults, and use AskUserQuestion to let the user customize the keys:

| Key | Action | Command |
|-----|--------|---------|
| `N` | Jump to notification window | `bind-key N run-shell "$PLUGIN_ROOT/scripts/jump-to-notification.sh"` |
| `` ` `` | Dismiss notification | `bind-key \` run-shell "$PLUGIN_ROOT/scripts/dismiss-notification.sh"` |
| `DC` (Delete) | Dismiss notification | `bind-key DC run-shell "$PLUGIN_ROOT/scripts/dismiss-notification.sh"` |
| `M` | Open notification picker | `bind-key M display-popup -w 80% -h 60% -E "$PLUGIN_ROOT/scripts/notification-picker.sh"` |

Use AskUserQuestion with options like:
- "Use defaults (N / ` / M)" (Recommended)
- "Customize keybindings"

If user chooses to customize, ask for each key individually.

### D. Hooks

Check that the plugin hooks file exists and is correct:
```bash
cat "$PLUGIN_ROOT/hooks/hooks.json"
```

Report whether hooks are properly configured (should contain `notify-tmux.sh` entries for `Stop` and `Notification` events).

## Step 6: Confirm

Use AskUserQuestion to confirm before making any changes. Show the exact changes that will be made. Options:
- "Apply all changes" (Recommended)
- "Apply without keybindings"
- "Cancel"

## Step 7: Backup

Before writing, backup the existing config:

```bash
mkdir -p ~/.config/tclux/backups
cp "$TMUX_CONF" ~/.config/tclux/backups/tmux.conf.$(date +%Y%m%d_%H%M%S)
# Keep only 5 most recent
ls -1t ~/.config/tclux/backups/tmux.conf.* | tail -n +6 | xargs rm -f 2>/dev/null
```

Tell the user the backup path.

## Step 8: Apply

Read the current config content, modify it, and write back using the Write tool. All changes go within tclux section markers:

```
# --- tclux: Claude Code notifications (added by /tclux:auto-setup) ---
...tclux settings and keybindings...
# --- end tclux ---
```

**For status-left specifically:**
- If the file has an existing `set -g status-left "..."` line, modify that line in-place by inserting ` #{E:#($PLUGIN_ROOT/scripts/show-notification.sh)}` before the closing `"`.
- If no status-left exists, add `set -g status-left "#S #{E:#($PLUGIN_ROOT/scripts/show-notification.sh)} "` within the tclux section.
- Always ensure double quotes around the status-left value.

Preserve ALL existing content outside the tclux markers.

## Step 9: Verify

Run verification commands:

```bash
# Reload config
tmux source-file "$TMUX_CONF"

# Check status-left contains notification
tmux show-option -gv status-left

# Check keybindings registered
tmux list-keys | grep -E "jump-to-notification|dismiss-notification|notification-picker"
```

Report success or failure for each check.

## Step 10: Summary

Show the user:
- What was changed
- Backup location and rollback command: `cp <backup_path> <tmux_conf> && tmux source-file <tmux_conf>`
- Keybinding quick reference (N = jump, ` = dismiss, M = picker)
- Suggest running `/tclux:validate` for full validation
