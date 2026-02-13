---
description: Interactively configure tmux for clux notifications
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion, Task
---

# clux Setup: Interactive tmux Configuration

You are configuring the user's tmux.conf to integrate clux notifications. You ARE the LLM — never call external APIs.

**Use subagents (Task tool) to parallelize independent work.** Launch multiple agents concurrently wherever steps don't depend on each other. This speeds up the setup significantly.

## CRITICAL RULES

- **Never call external APIs** — you are Claude Code running inside the user's session
- **Never overwrite existing status display** — always READ the current value and APPEND the notification snippet
- **Prefer `status-format[0]`** — if the config uses `status-format[0]`, inject the notification there (it overrides `status-left`). Fall back to `status-left` only if no `status-format[0]` exists.
- **Deploy scripts to `~/.config/clux/scripts/`** — copy from plugin source so tmux.conf survives plugin version updates
- **Always use `~/.config/clux/scripts/` paths** in tmux.conf — never reference the plugin cache directly
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
   find ~/.claude -path "*/clux/scripts/show-notification.sh" -type f 2>/dev/null | head -1
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
   - Whether it uses `status-format[0]` (custom status bar layout) or traditional `status-left`
   - Current `status-format[0]` value (if any)
   - Current `set -g status-left` value (if any, and no `status-format[0]`)
   - Current `status-interval` value
   - Current `status-left-length` value
   - Any existing clux section markers
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
   find ~/.claude -path "*/clux/hooks/hooks.json" -type f 2>/dev/null | head -1
   ```
2. Check if hooks.json contains `notify-tmux.sh` entries for `Stop` and `Notification` events
3. Check existing tmux keybindings for conflicts:
   ```bash
   tmux list-keys 2>/dev/null | grep -E "bind-key\s+(m|M|\`)"
   ```
4. Return: hooks file path, hooks status (ok/missing/incomplete), conflicting keybindings (if any)

**Wait for all three agents to complete before proceeding.**

If Agent A reports tmux not found or plugin scripts missing, tell the user and stop.
If Agent B finds both config files, use AskUserQuestion to ask the user which to use.

## Phase 2: Report Findings

Present a clear summary to the user combining results from all three agents:

```
clux setup — analysis results:

  Environment:
    tmux: /usr/local/bin/tmux (v3.6a)
    Plugin scripts: /Users/.../.claude/plugins/cache/404pilo/clux/x.y.z/scripts/

  tmux.conf:
    Config file: ~/.config/tmux/tmux.conf
    Status display: status-format[0] (or status-left if no format override)
    status-interval: 15 (recommend: 1)
    status-left-length: 10 (recommend: 150)
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

Present grouped changes. Use the absolute expanded path for `DEPLOY_DIR` (e.g., `/Users/user/.config/clux/scripts`):

### A. Status display (APPEND notification — never overwrite)

Determine where to inject the notification snippet `#(DEPLOY_DIR/show-notification.sh)`:

1. **If `status-format[0]` exists** (preferred): Insert a centre-aligned notification section into the existing `status-format[0]` value. Place `#[align=centre]#(DEPLOY_DIR/show-notification.sh)` between the left-aligned content and the `#[align=right]` section. This keeps the notification centered in the status bar. Preserve all existing conditionals and formatting.
2. **If only `status-left` exists** (fallback): Append ` #(DEPLOY_DIR/show-notification.sh)` before the closing quote of the existing value.
3. **If neither exists**: Add `set -g status-left "#S #(DEPLOY_DIR/show-notification.sh) "` within clux section markers.

- **Never prepend. Never overwrite.** The user's existing content stays intact.

### B. Supporting settings

```tmux
set -g status-interval 1
set -g status-left-length 150
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
| `m` | Jump to notification window | `bind-key m run-shell "DEPLOY_DIR/jump-to-notification.sh"` |
| `` ` `` | Dismiss notification | `bind-key \` run-shell "DEPLOY_DIR/dismiss-notification.sh"` |
| `DC` (Delete) | Dismiss notification | `bind-key DC run-shell "DEPLOY_DIR/dismiss-notification.sh"` |
| `M` | Open notification picker | `bind-key M display-popup -w 80% -h 60% -E "DEPLOY_DIR/notification-picker.sh"` |

Use AskUserQuestion with options like:
- "Use defaults (m / ` / M)" (Recommended)
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
   mkdir -p ~/.config/clux/backups
   cp "$TMUX_CONF" ~/.config/clux/backups/tmux.conf.$(date +%Y%m%d_%H%M%S)
   ls -1t ~/.config/clux/backups/tmux.conf.* | tail -n +6 | xargs rm -f 2>/dev/null
   ```
2. Deploy scripts from plugin source to stable location:
   ```bash
   DEPLOY_DIR="$HOME/.config/clux/scripts"
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

- **If `status-format[0]` exists**: Modify it in-place — insert `#[align=centre]#(DEPLOY_DIR/show-notification.sh)` immediately before the `#[align=right]` section. This centres the notification in the status bar. Preserve all existing conditionals and single-quote wrapping.
- **If only `status-left` exists**: Modify it in-place — insert ` #(DEPLOY_DIR/show-notification.sh)` before the closing `"`.
- **If neither exists**: Add `set -g status-left "#S #(DEPLOY_DIR/show-notification.sh) "` within clux section markers.
- Add supporting settings, **notification color options**, and keybindings within clux section markers:
  ```
  # --- clux: Claude Code notifications (added by /clux:setup) ---
  ...clux settings...
  set -g @claude-notify-bg "<bg_attention>"
  set -g @claude-notify-fg "<fg_on_attention>"
  ...keybindings...
  # --- end clux ---
  ```
  Only include the `@claude-notify-bg`/`@claude-notify-fg` lines if a color palette was detected.
- Preserve ALL existing content outside the clux markers
- If clux markers already exist, replace the content between them
- Return: the complete new file content

**Write the new tmux.conf** using the Write tool with Agent E's output.

## Phase 6: Verify

Run verification commands:

```bash
# Reload config and refresh status bar
tmux source-file "$TMUX_CONF"
tmux refresh-client -S

# Check notification is present (check both status-format and status-left)
tmux show-option -g 'status-format[0]' 2>/dev/null | grep -q "show-notification.sh" || \
  tmux show-option -gv status-left 2>/dev/null | grep -q "show-notification.sh"

# Check keybindings registered
tmux list-keys | grep -E "jump-to-notification|dismiss-notification|notification-picker"
```

Report success or failure for each check.

## Phase 7: Summary

Show the user:
- What was changed
- Backup location and rollback command: `cp <backup_path> <tmux_conf> && tmux source-file <tmux_conf>`
- Keybinding quick reference (m = jump, ` = dismiss, M = picker)
- Suggest running `/clux:validate` for full validation
