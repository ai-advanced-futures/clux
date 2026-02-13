# Reference: tmux Configuration Strategy

This document describes the logical approach for autonomously configuring tmux.conf for clux integration. This is reference documentation for LLM-driven configuration merging (not an executable script).

## Overview

Transform user's tmux.conf to display Claude Code notifications in the status bar by intelligently appending a notification display to the status-left setting while preserving all existing configuration.

## State Detection Logic

### Step 1: Locate tmux.conf

Check for existing configuration in order of precedence:

1. `~/.tmux.conf` (most common)
2. `${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf` (XDG-compliant)
3. Default to `~/.tmux.conf` if neither exists

### Step 2: Determine Configuration State

Examine the file to determine one of four states:

**State A: Already Configured**
- Detection: `grep -q "show-notification.sh" ~/.tmux.conf`
- Action: Skip modification (idempotent)
- Output: "Already configured"

**State B: Has status-left**
- Detection: `grep -q '^[[:space:]]*set.*status-left' ~/.tmux.conf`
- Action: Append notification to existing value
- Output: Show current status-left, then show modified version

**State C: No status-left**
- Detection: File exists but no status-left found
- Action: Append new status-left configuration section
- Output: Show what will be added

**State D: No tmux.conf**
- Detection: File doesn't exist
- Action: Create new file with clux configuration
- Output: Show new file content

### Step 3: Permission Check

Before modification:
- If file exists and is not writable, return error
- Suggest using `chmod u+w` or file owner change

## Modification Cases

### Case A: Create New tmux.conf

When no `~/.tmux.conf` exists, create with:

```
# clux — Claude Code tmux notification plugin
set -g status-left "#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh) "
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
```

Key points:
- `${CLAUDE_PLUGIN_ROOT}` must be **expanded** to absolute path at setup time
- Example: `/Users/user/.claude/plugins/cache/404pilo/clux/1.0.0/scripts/show-notification.sh`
- This is not a shell variable; tmux.conf doesn't expand `${}` syntax
- `#(command)` is tmux's command substitution syntax — runs the command and inserts its stdout

### Case B: Append to Existing Config

When file exists but has no `status-left`, append:

```
# --- clux: Claude Code notifications (added by /clux:auto-setup) ---
set -g status-left "#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh) "
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
# --- end clux ---
```

Benefits of section markers:
- Enable clean detection of added vs. existing config
- Support re-running setup (detect and skip clux section)
- Enable clean removal if user uninstalls

### Case C: Append to Existing status-left

When file has existing `status-left` setting, this is the complex case.

**Goal:** Insert the notification display at the end of the status-left value (before the closing quote) while preserving all existing content and syntax.

**Example transformations:**

Before:
```
set -g status-left " #S "
```

After:
```
set -g status-left " #S #(/absolute/path/to/show-notification.sh) "
```

---

Before (with conditionals):
```
set -g status-left "#{?client_prefix,[PREFIX] ,}#S "
```

After (conditionals preserved):
```
set -g status-left "#{?client_prefix,[PREFIX] ,}#S #(/absolute/path/to/show-notification.sh) "
```

---

Before (complex formatting):
```
set -g status-left "#[fg=green]#S #[fg=yellow]#I"
```

After (all formatting preserved):
```
set -g status-left "#[fg=green]#S #[fg=yellow]#I #(/absolute/path/to/show-notification.sh) "
```

**Algorithm:**

1. Find the line containing `set.*status-left`
2. Extract the quoted value
3. Inject the notification command right before the closing quote
4. Preserve everything else exactly

**Pattern matching approach (reference):**

Regex pattern to match:
```
^(\s*set\s+(?:-option\s+)?\-g\s+status\-left\s+["'])(.*)(["'])$
```

Components:
- `\1`: The full prefix up to and including the opening quote
- `\2`: The existing value
- `\3`: The closing quote

Replacement:
```
\1\2 #(/absolute/path/to/show-notification.sh) \3
```

## Backup Strategy

### Before Any Modification

1. Create backup directory: `mkdir -p ~/.config/clux/backups`
2. Copy existing config: `cp ~/.tmux.conf ~/.config/clux/backups/tmux.conf.YYYYMMDD_HHMMSS`
3. Preserve timestamp for reference

### Backup Retention

Keep only 5 most recent backups:

```
ls -1t ~/.config/clux/backups/tmux.conf.* | tail -n +6 | xargs rm -f
```

### Rollback Instructions

After modification, provide user with:

```
To undo: cp ~/.config/clux/backups/tmux.conf.YYYYMMDD_HHMMSS ~/.tmux.conf && tmux source-file ~/.tmux.conf
```

## Variable Expansion: Critical

### The Challenge

The tmux.conf file is parsed by tmux at runtime. Environment variables like `$CLAUDE_PLUGIN_ROOT` are **not** expanded by tmux.

In tmux.conf, only these syntaxes have meaning:
- `#{variable}` — tmux session/pane variables
- `#(command)` — command substitution (runs command, inserts stdout)
- `$` is just a literal character

### The Solution

At setup time, **expand** `${CLAUDE_PLUGIN_ROOT}` to the **absolute path**.

Example:

```bash
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIPPET_PATH="$PLUGIN_ROOT/scripts/show-notification.sh"
# Now $SNIPPET_PATH is: /Users/user/.claude/plugins/cache/404pilo/clux/1.0.0/scripts/show-notification.sh

# Inject into tmux.conf as literal string:
echo "set -g status-left \"#($SNIPPET_PATH) \"" >> ~/.tmux.conf
```

The resulting line in tmux.conf:
```
set -g status-left "#(/Users/user/.claude/plugins/cache/404pilo/clux/1.0.0/scripts/show-notification.sh) "
```

### Why Not Use Environment Variables?

Tempting but wrong:
```bash
# DO NOT DO THIS
echo "set -g status-left \"#($CLAUDE_PLUGIN_ROOT/scripts/show-notification.sh)\"" >> ~/.tmux.conf
```

Result (wrong):
```
set -g status-left "#($CLAUDE_PLUGIN_ROOT/scripts/show-notification.sh) "
```

When tmux parses this, it sees literally: `$CLAUDE_PLUGIN_ROOT/scripts/...`. Since tmux doesn't expand shell variables, the command substitution fails.

## Edge Cases

### Multi-line Continuation

Some configs use backslash continuation:

```
set -g status-left \
    " #S "
```

**Handling:** Detect this pattern and either:
1. Collapse to single line before modification
2. Document as limitation (rare edge case)

### Single-Quoted vs Double-Quoted

tmux accepts both:
```
set -g status-left ' #S '      # single quotes
set -g status-left " #S "      # double quotes
```

**Handling:**
- Either quote style works with `#(...)` syntax
- For consistency, prefer double quotes
- Append notification

Example:
```
Before: set -g status-left ' #S '
After:  set -g status-left "#S #(...)"
```

### Conditional Syntax

tmux supports complex conditionals:

```
set -g status-left "#{?client_prefix,[PREFIX] ,}#S #{window_index}:#I"
```

**Handling:**
- Do not try to parse conditionals
- Simply append notification before closing quote of value
- Result:

```
set -g status-left "#{?client_prefix,[PREFIX] ,}#S #{window_index}:#I #(...)"
```

### status-left Set in Sourced File

If user's ~/.tmux.conf has:

```
source ~/.tmux/custom.conf
```

And custom.conf defines status-left, the main grep won't find it.

**Handling:**
- Check runtime value via: `tmux show-option -gv status-left`
- If runtime value includes `show-notification.sh`, already configured
- If not, inform user that setting may be in sourced file
- Suggest adding to main file or sourced file manually

### status-left-length Too Short

If user hasn't set `status-left-length`, default is 10 characters.

**Handling:**
- Show warning: "Consider increasing status-left-length for full notification display"
- Suggest: `set -g status-left-length 150`

## Verification Steps

After modification:

### 1. File Content Check

Verify the file contains what we added:
```bash
grep -q "show-notification.sh" ~/.tmux.conf
```

### 2. Syntax Validation

Verify tmux can parse it:
```bash
tmux -f ~/.tmux.conf source-file ~/.tmux.conf 2>&1 | grep -q "no server running" && echo "OK"
```

Note: "no server running" is expected and OK; it means syntax is valid.

### 3. Idempotency Check

Run setup twice:
1. First run modifies config
2. Second run should detect "already configured" and skip

Result after second run: File unchanged

## Summary of Key Points

| Aspect | Decision | Reason |
|--------|----------|--------|
| **Variable expansion** | Hardcode absolute path | tmux doesn't expand `${}` syntax |
| **Injection position** | Append to status-left | Session name stays first |
| **Quoting** | Double quotes | Consistent convention for `#(...)` syntax |
| **Backup location** | `~/.config/clux/backups/` | Persistent, namespaced, not in tmux dir |
| **Section markers** | Comment-based | Enable clean detection and removal |
| **Idempotency** | grep for script name | Simple, reliable, catches all cases |
| **Permissions** | Check before modification | Fail early with clear error message |

## Keybinding Integration

clux registers three keybindings for notification management:

| Key | Action | Script |
|-----|--------|--------|
| `N` | Jump to notification window | `jump-to-notification.sh` |
| `` ` `` | Dismiss current notification | `dismiss-notification.sh` |
| `M` | Open notification picker (fzf) | `notification-picker.sh` |

These keybindings are added within the clux section markers and use absolute paths to the plugin scripts. Users can customize the key assignments during interactive setup.

### Keybinding Format

```tmux
bind-key m run-shell "/absolute/path/to/jump-to-notification.sh"
bind-key ` run-shell "/absolute/path/to/dismiss-notification.sh"
bind-key M display-popup -w 80% -h 60% -E "/absolute/path/to/notification-picker.sh"
```

## Implementation for LLM

When implementing via LLM-based configuration:

1. **Provide** this document as context
2. **Define** desired state in tmux-config.yaml
3. **Read** user's current ~/.tmux.conf (if exists)
4. **Determine** which of 4 cases applies
5. **Generate** modified configuration preserving all existing settings
6. **Show** user a diff before applying
7. **Backup** existing config with timestamp
8. **Apply** changes
9. **Verify** syntax with tmux source-file
10. **Report** success with rollback instructions

The auto-setup command follows a Socratic/interactive design principle: it analyzes the user's configuration, presents findings, recommends changes, and asks for confirmation before modifying any files. Claude Code itself drives the interactive flow using its built-in tools (Read, Write, Bash, AskUserQuestion) — no external API calls are needed.
