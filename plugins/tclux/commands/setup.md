---
description: Interactively configure tmux for tclux notifications
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion, Task
---

# tclux Setup: Interactive tmux Configuration

You are configuring the user's tmux.conf to integrate tclux notifications. You ARE the LLM — never call external APIs.

**Use subagents (Task tool) to parallelize independent work.** Launch multiple agents concurrently wherever steps don't depend on each other. This speeds up the setup significantly.

## CRITICAL RULES

- **Never call external APIs** — you are Claude Code running inside the user's session
- **Never overwrite existing status-left** — always READ the current value and APPEND the notification snippet after it
- **Deploy scripts to `~/.config/tclux/scripts/`** — copy from plugin source so tmux.conf survives plugin version updates
- **Always use `~/.config/tclux/scripts/` paths** in tmux.conf — never reference the plugin cache directly
- **Always use double quotes** for status-left values
- **Always ask before modifying files** — use AskUserQuestion for confirmation
- **Idempotent** — if already configured, report and offer to skip
- **Use subagents** — delegate independent detection, analysis, and verification tasks to subagents running in parallel

## Phase 1: Detection (use subagents in parallel)

Launch **three subagents concurrently** using the Task tool with `subagent_type: "general-purpose"`:

### Agent A: Environment Detection

Prompt the agent to:
1. Verify tmux is installed: `command -v tmux`
2. Get tmux version: `tmux -V`
3. Find the plugin source scripts:
   ```bash
   find ~/.claude -path "*/tclux/scripts/show-notification.sh" -type f 2>/dev/null | head -1
   ```
4. Derive `PLUGIN_SCRIPTS_DIR` from the result (parent directory of that file)
5. Verify all required scripts exist in `PLUGIN_SCRIPTS_DIR`:
   - `show-notification.sh`, `jump-to-notification.sh`, `dismiss-notification.sh`, `notification-picker.sh`, `helpers.sh`
6. Return: tmux path, tmux version, `PLUGIN_SCRIPTS_DIR` path, list of missing scripts (if any)

### Agent B: tmux.conf Analysis

Prompt the agent to:
1. Check which config files exist:
   - `$HOME/.tmux.conf`
   - `${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf`
2. If a config file exists, read it and extract:
   - Whether `show-notification.sh` is already present (already configured?)
   - Current `set -g status-left` value (if any)
   - Current `status-interval` value
   - Current `status-left-length` value
   - Any existing tclux section markers
3. **Extract the color palette** from the config. Look for:
   - `status-style` bg/fg values (e.g., `bg='#2E3440',fg='#88C0D0'`)
   - `message-style` bg/fg values (e.g., `bg=#EBCB8B,fg=#2E3440`)
   - `window-status-current-format` colors
   - `pane-active-border-style` fg
   - `mode-style` colors
   - Any `@prefix_highlight_*` color options
   - Build a color map with semantic names:
     - `bg_dark`: main background (from status-style bg)
     - `fg_primary`: main foreground (from status-style fg)
     - `fg_snow`: bright white foreground (from prefix_highlight_fg or status-left fg)
     - `bg_accent`: accent/session background (from status-left bg, e.g., `#81A1C1`)
     - `bg_attention`: attention color (from message-style bg, e.g., `#EBCB8B`)
     - `fg_on_attention`: text on attention bg (from message-style fg, e.g., `#2E3440`)
     - `bg_alert`: alert/red color (from prefix_highlight_bg, e.g., `#BF616A`)
4. Return: config file path(s) found, analysis results, **color map**

### Agent C: Hooks & Keybindings Check

Prompt the agent to:
1. Find and read the plugin hooks file:
   ```bash
   find ~/.claude -path "*/tclux/hooks/hooks.json" -type f 2>/dev/null | head -1
   ```
2. Check if hooks.json contains `notify-tmux.sh` entries for `Stop` and `Notification` events
3. Check existing tmux keybindings for conflicts:
   ```bash
   tmux list-keys 2>/dev/null | grep -E "bind-key\s+(N|M|\`)"
   ```
4. Return: hooks file path, hooks status (ok/missing/incomplete), conflicting keybindings (if any)

**Wait for all three agents to complete before proceeding.**

If Agent A reports tmux not found or plugin scripts missing, tell the user and stop.
If Agent B finds both config files, use AskUserQuestion to ask the user which to use.

## Phase 2: Report Findings

Present a clear summary to the user combining results from all three agents:

```
tclux setup — analysis results:

  Environment:
    tmux: /usr/local/bin/tmux (v3.6a)
    Plugin scripts: /Users/.../.claude/plugins/cache/404pilo/tclux/x.y.z/scripts/

  tmux.conf:
    Config file: ~/.config/tmux/tmux.conf
    Current status-left: "#[fg=green]#S #[fg=yellow]#I"
    status-interval: 15 (recommend: 1)
    status-left-length: 10 (recommend: 200)
    Already configured: no

  Color palette detected:
    bg_dark:         #2E3440   (status bar background)
    fg_primary:      #88C0D0   (status bar text)
    fg_snow:         #ECEFF4   (bright white)
    bg_accent:       #81A1C1   (session highlight)
    bg_attention:    #EBCB8B   (message/notification)
    fg_on_attention: #2E3440   (text on attention bg)
    bg_alert:        #BF616A   (prefix/alert)

  Hooks & keybindings:
    hooks.json: OK (Stop, Notification events configured)
    Keybinding conflicts: none
```

## Phase 3: Recommend Changes

Present grouped changes. Use the absolute expanded path for `DEPLOY_DIR` (e.g., `/Users/user/.config/tclux/scripts`):

### A. Status-left (APPEND notification after existing value)

- If no existing status-left: `set -g status-left "#S #(DEPLOY_DIR/show-notification.sh) "`
- If existing status-left: Append ` #(DEPLOY_DIR/show-notification.sh)` before the closing quote
- **Never prepend. Never overwrite.** The user's session name and existing content stay first.

### B. Supporting settings

```tmux
set -g status-interval 1
set -g status-left-length 200
set -g monitor-bell on
set -g bell-action any
```

### B2. Notification colors (from detected palette)

If a color palette was detected, set `@claude-notify-bg` and `@claude-notify-fg` to match the user's theme instead of using generic defaults. Use the **attention** colors from the detected palette (these are the message-style colors, designed for high-visibility transient notifications):

```tmux
set -g @claude-notify-bg "<bg_attention>"    # e.g., #EBCB8B (Nord yellow)
set -g @claude-notify-fg "<fg_on_attention>"  # e.g., #2E3440 (Nord dark)
```

If no color palette was detected, skip this section and let the defaults (`yellow`/`black`) apply.

Present the chosen colors to the user in the summary, showing a visual preview like:
```
Notification style: bg=#EBCB8B fg=#2E3440 (matches your message-style)
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

### D. Hooks status

Report what Agent C found. Plugin hooks auto-merge with user settings — no manual settings.json editing needed.

## Phase 4: Confirm

Use AskUserQuestion to confirm before making any changes. Show the exact changes that will be made. Options:
- "Apply all changes" (Recommended)
- "Apply without keybindings"
- "Cancel"

## Phase 5: Apply (use subagents in parallel)

Run **two subagents sequentially** (backup must complete before config is written):

### Agent D: Backup & Deploy Scripts (run first)

Prompt the agent to:
1. Backup existing tmux.conf:
   ```bash
   mkdir -p ~/.config/tclux/backups
   cp "$TMUX_CONF" ~/.config/tclux/backups/tmux.conf.$(date +%Y%m%d_%H%M%S)
   ls -1t ~/.config/tclux/backups/tmux.conf.* | tail -n +6 | xargs rm -f 2>/dev/null
   ```
2. Deploy scripts from plugin source to stable location:
   ```bash
   DEPLOY_DIR="$HOME/.config/tclux/scripts"
   mkdir -p "$DEPLOY_DIR"
   for script in helpers.sh show-notification.sh jump-to-notification.sh dismiss-notification.sh notification-picker.sh; do
       cp "$PLUGIN_SCRIPTS_DIR/$script" "$DEPLOY_DIR/$script"
       chmod +x "$DEPLOY_DIR/$script"
   done
   ```
3. Return: backup file path, list of deployed scripts

Pass the actual resolved paths for `$TMUX_CONF` and `$PLUGIN_SCRIPTS_DIR` to this agent.

**Wait for Agent D to complete before launching Agent E.**

### Agent E: Prepare & Write tmux.conf (run second)

Prompt the agent to read the current tmux.conf content (pass it in the prompt) and generate the new content following these rules:

- Modify `status-left` in-place if it exists: insert ` #(DEPLOY_DIR/show-notification.sh)` before the closing `"`
- If no `status-left`, add `set -g status-left "#S #(DEPLOY_DIR/show-notification.sh) "` within tclux section markers
- Add supporting settings, **notification color options**, and keybindings within tclux section markers:
  ```
  # --- tclux: Claude Code notifications (added by /tclux:setup) ---
  ...tclux settings...
  set -g @claude-notify-bg "<bg_attention>"
  set -g @claude-notify-fg "<fg_on_attention>"
  ...keybindings...
  # --- end tclux ---
  ```
  Only include the `@claude-notify-bg`/`@claude-notify-fg` lines if a color palette was detected.
- Preserve ALL existing content outside the tclux markers
- If tclux markers already exist, replace the content between them
- Always use double quotes for status-left
- Return: the complete new file content

**Write the new tmux.conf** using the Write tool with Agent E's output.

## Phase 6: Verify

Run verification commands:

```bash
# Reload config and refresh status bar
tmux source-file "$TMUX_CONF"
tmux refresh-client -S

# Check status-left contains notification
tmux show-option -gv status-left

# Check keybindings registered
tmux list-keys | grep -E "jump-to-notification|dismiss-notification|notification-picker"
```

Report success or failure for each check.

## Phase 7: Summary

Show the user:
- What was changed
- Backup location and rollback command: `cp <backup_path> <tmux_conf> && tmux source-file <tmux_conf>`
- Keybinding quick reference (N = jump, ` = dismiss, M = picker)
- Suggest running `/tclux:validate` for full validation
