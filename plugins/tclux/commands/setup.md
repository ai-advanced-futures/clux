---
name: setup
description: Interactively configure tmux for tclux notifications
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
---

# tclux Setup: Interactive tmux Configuration

You are configuring the user's tmux.conf to integrate tclux notifications. Follow each step below precisely using your tools (Read, Write, Bash, Glob, Grep, AskUserQuestion). You ARE the LLM — never call external APIs.

## CRITICAL RULES

- **Never call external APIs** — you are Claude Code running inside the user's session
- **Never overwrite existing status-left** — always READ the current value and APPEND the notification snippet after it
- **Deploy scripts to `~/.config/tclux/scripts/`** — copy from plugin source so tmux.conf survives plugin version updates
- **Always use `~/.config/tclux/scripts/` paths** in tmux.conf — never reference the plugin cache directly
- **Always use double quotes** for status-left values (required for `#{E:}` expansion)
- **Always ask before modifying files** — use AskUserQuestion for confirmation
- **Idempotent** — if already configured, report and offer to skip

## Step 1: Detect Environment

### 1a. Verify tmux is installed

```bash
command -v tmux
```

If tmux is not found, tell the user and stop.

### 1b. Find the plugin source scripts

The `$CLAUDE_PLUGIN_ROOT` env var is NOT available in skill context. Discover the plugin scripts by searching the filesystem:

```bash
# Search for the plugin scripts in Claude's plugin cache
find ~/.claude -path "*/tclux/scripts/show-notification.sh" -type f 2>/dev/null | head -1
```

This returns something like: `/Users/user/.claude/plugins/cache/404pilo/tclux/1.0.10/scripts/show-notification.sh`

Derive `PLUGIN_SCRIPTS_DIR` as the directory containing that file (its parent). If not found, tell the user the tclux plugin may not be installed correctly and stop.

### 1c. Verify all required scripts exist

Check that these files exist in `PLUGIN_SCRIPTS_DIR`:
- `show-notification.sh`
- `jump-to-notification.sh`
- `dismiss-notification.sh`
- `notification-picker.sh`
- `helpers.sh`

If any are missing, tell the user and stop.

The deploy target is always: `DEPLOY_DIR=~/.config/tclux/scripts/`

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

Present grouped changes. Use the absolute expanded path for `DEPLOY_DIR` (e.g., `/Users/user/.config/tclux/scripts`):

### A. Status-left (APPEND notification after existing value)

- If no existing status-left: `set -g status-left "#S #{E:#(DEPLOY_DIR/show-notification.sh)} "`
- If existing status-left: Append ` #{E:#(DEPLOY_DIR/show-notification.sh)}` before the closing quote
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
| `N` | Jump to notification window | `bind-key N run-shell "DEPLOY_DIR/jump-to-notification.sh"` |
| `` ` `` | Dismiss notification | `bind-key \` run-shell "DEPLOY_DIR/dismiss-notification.sh"` |
| `DC` (Delete) | Dismiss notification | `bind-key DC run-shell "DEPLOY_DIR/dismiss-notification.sh"` |
| `M` | Open notification picker | `bind-key M display-popup -w 80% -h 60% -E "DEPLOY_DIR/notification-picker.sh"` |

Use AskUserQuestion with options like:
- "Use defaults (N / ` / M)" (Recommended)
- "Customize keybindings"

If user chooses to customize, ask for each key individually.

### D. Hooks

Find and check the plugin hooks file:

```bash
find ~/.claude -path "*/tclux/hooks/hooks.json" -type f 2>/dev/null | head -1
```

Read it and report whether hooks are properly configured (should contain `notify-tmux.sh` entries for `Stop` and `Notification` events).

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

## Step 8: Deploy Scripts

Copy scripts from the plugin source to the stable deploy location so tmux.conf doesn't break on plugin updates:

```bash
DEPLOY_DIR="$HOME/.config/tclux/scripts"
mkdir -p "$DEPLOY_DIR"
for script in helpers.sh show-notification.sh jump-to-notification.sh dismiss-notification.sh notification-picker.sh; do
    cp "$PLUGIN_SCRIPTS_DIR/$script" "$DEPLOY_DIR/$script"
    chmod +x "$DEPLOY_DIR/$script"
done
```

Where `$PLUGIN_SCRIPTS_DIR` is the path discovered in Step 1b. All paths written to tmux.conf reference `$DEPLOY_DIR/`, not the plugin cache.

## Step 9: Apply

Read the current config content, modify it, and write back using the Write tool. All changes go within tclux section markers:

```
# --- tclux: Claude Code notifications (added by /tclux:setup) ---
...tclux settings and keybindings...
# --- end tclux ---
```

**For status-left specifically:**
- If the file has an existing `set -g status-left "..."` line, modify that line in-place by inserting ` #{E:#(DEPLOY_DIR/show-notification.sh)}` before the closing `"`.
- If no status-left exists, add `set -g status-left "#S #{E:#(DEPLOY_DIR/show-notification.sh)} "` within the tclux section.
- Always ensure double quotes around the status-left value.

Preserve ALL existing content outside the tclux markers.

## Step 10: Verify

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

## Step 11: Summary

Show the user:
- What was changed
- Backup location and rollback command: `cp <backup_path> <tmux_conf> && tmux source-file <tmux_conf>`
- Keybinding quick reference (N = jump, ` = dismiss, M = picker)
- Suggest running `/tclux:validate` for full validation
