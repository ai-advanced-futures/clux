---
description: Validate clux tmux notification setup — comprehensive read-only health check
allowed-tools: Read, Bash, Glob, Grep, Task
---

# clux Validate: Health Check

You are validating the user's clux integration. This is **read-only** — never modify any files.

**Use subagents (Task tool) to parallelize independent checks.** Launch all three agents concurrently.

## Phase 1: Gather Data (use subagents in parallel)

Launch **three subagents concurrently** using the Task tool with `subagent_type: "general-purpose"`:

### Agent A: Environment & Scripts

Prompt the agent to run these checks and return structured results. Do NOT modify any files.

1. **tmux running**: `tmux info &>/dev/null && echo "OK" || echo "FAIL"`
2. **tmux version**: `tmux -V`
3. **Deployed scripts** — check all 5 exist and are executable at `~/.config/clux/scripts/`:
   ```bash
   DEPLOY_DIR="$HOME/.config/clux/scripts"
   for script in helpers.sh show-notification.sh jump-to-notification.sh dismiss-notification.sh notification-picker.sh; do
       if [ -x "$DEPLOY_DIR/$script" ]; then
           echo "OK  $script"
       elif [ -f "$DEPLOY_DIR/$script" ]; then
           echo "WARN $script (not executable)"
       else
           echo "FAIL $script (missing)"
       fi
   done
   ```
4. **Scripts in sync** — find the plugin source scripts and compare checksums with deployed:
   ```bash
   PLUGIN_SRC=$(find ~/.claude -path "*/clux/scripts/helpers.sh" -type f 2>/dev/null | head -1)
   PLUGIN_DIR=$(dirname "$PLUGIN_SRC")
   DEPLOY_DIR="$HOME/.config/clux/scripts"
   for script in helpers.sh show-notification.sh jump-to-notification.sh dismiss-notification.sh notification-picker.sh notify-sound.sh; do
       if [ -f "$PLUGIN_DIR/$script" ] && [ -f "$DEPLOY_DIR/$script" ]; then
           SRC_HASH=$(shasum "$PLUGIN_DIR/$script" | cut -d' ' -f1)
           DST_HASH=$(shasum "$DEPLOY_DIR/$script" | cut -d' ' -f1)
           if [ "$SRC_HASH" = "$DST_HASH" ]; then
               echo "OK   $script (in sync)"
           else
               echo "WARN $script (out of sync — run /clux:setup to redeploy)"
           fi
       fi
   done
   ```
5. **Dependencies**:
   ```bash
   command -v jq &>/dev/null && echo "OK  jq" || echo "WARN jq (missing)"
   command -v fzf &>/dev/null && echo "OK  fzf" || echo "WARN fzf (missing — notification picker unavailable)"
   command -v flock &>/dev/null && echo "OK  flock" || echo "INFO flock (unavailable — using mkdir fallback)"
   ```
6. **Notification directory writable**:
   ```bash
   NOTIFY_DIR="$HOME/.config/tmux"
   [ -d "$NOTIFY_DIR" ] && [ -w "$NOTIFY_DIR" ] && echo "OK  notification dir writable" || echo "FAIL notification dir not writable ($NOTIFY_DIR)"
   ```
7. Return all results with clear OK/FAIL/WARN/INFO prefixes.

### Agent B: tmux Configuration

Prompt the agent to run these checks and return structured results. Do NOT modify any files.

1. **Status display** — check if `show-notification.sh` is present in the active tmux config:
   ```bash
   # Check status-format[0] first (takes priority)
   if tmux show-option -g 'status-format[0]' 2>/dev/null | grep -q "show-notification.sh"; then
       echo "OK  status display (status-format[0])"
       # Check path references stable deploy dir
       if tmux show-option -g 'status-format[0]' 2>/dev/null | grep -q "$HOME/.config/clux/scripts/"; then
           echo "OK  uses stable deploy path"
       elif tmux show-option -g 'status-format[0]' 2>/dev/null | grep -q "\.config/clux/scripts/"; then
           echo "OK  uses stable deploy path"
       else
           echo "WARN references plugin cache path (should use ~/.config/clux/scripts/)"
       fi
   elif tmux show-option -gv status-left 2>/dev/null | grep -q "show-notification.sh"; then
       echo "OK  status display (status-left)"
       if tmux show-option -gv status-left 2>/dev/null | grep -q ".config/clux/scripts/"; then
           echo "OK  uses stable deploy path"
       else
           echo "WARN references plugin cache path (should use ~/.config/clux/scripts/)"
       fi
   else
       echo "FAIL show-notification.sh not in status display"
   fi
   ```
2. **status-interval**:
   ```bash
   INTERVAL=$(tmux show-option -gv status-interval 2>/dev/null)
   if [ "${INTERVAL:-15}" -le 1 ]; then
       echo "OK  status-interval ($INTERVAL)"
   elif [ "${INTERVAL:-15}" -le 5 ]; then
       echo "WARN status-interval ($INTERVAL — recommend 1)"
   else
       echo "FAIL status-interval ($INTERVAL — too slow, set to 1)"
   fi
   ```
3. **status-left-length**:
   ```bash
   LENGTH=$(tmux show-option -gv status-left-length 2>/dev/null)
   if [ "${LENGTH:-10}" -ge 100 ]; then
       echo "OK  status-left-length ($LENGTH)"
   else
       echo "WARN status-left-length ($LENGTH — recommend 150, notification may be truncated)"
   fi
   ```
4. **Bell settings**:
   ```bash
   MONITOR=$(tmux show-option -gv monitor-bell 2>/dev/null)
   BELL_ACTION=$(tmux show-option -gv bell-action 2>/dev/null)
   [ "$MONITOR" != "off" ] && echo "OK  monitor-bell ($MONITOR)" || echo "WARN monitor-bell off (bell alerts disabled)"
   [ "$BELL_ACTION" != "none" ] && echo "OK  bell-action ($BELL_ACTION)" || echo "WARN bell-action none (bell alerts muted)"
   ```
5. **Notification colors**:
   ```bash
   BG=$(tmux show-option -gqv @claude-notify-bg)
   FG=$(tmux show-option -gqv @claude-notify-fg)
   [ -n "$BG" ] && echo "OK  @claude-notify-bg ($BG)" || echo "INFO @claude-notify-bg (using default: yellow)"
   [ -n "$FG" ] && echo "OK  @claude-notify-fg ($FG)" || echo "INFO @claude-notify-fg (using default: black)"
   ```
6. **Per-notification preferences** — show current effective values:
   ```bash
   for TYPE in notification stop prompt; do
       VIS=$(tmux show-option -gqv "@claude-notify-${TYPE}-visual")
       SND=$(tmux show-option -gqv "@claude-notify-${TYPE}-sound")
       echo "INFO ${TYPE}: visual=${VIS:-default} sound=${SND:-default}"
   done
   ```
7. **Keybindings** — check all 4 expected bindings:
   ```bash
   KEYS=$(tmux list-keys 2>/dev/null)
   echo "$KEYS" | grep -q "jump-to-notification" && echo "OK  prefix m (jump)" || echo "FAIL prefix m not bound to jump-to-notification"
   echo "$KEYS" | grep -q "dismiss-notification" && echo "OK  prefix \` / DC (dismiss)" || echo "FAIL dismiss-notification not bound"
   echo "$KEYS" | grep -q "notification-picker" && echo "OK  prefix M (picker)" || echo "FAIL prefix M not bound to notification-picker"
   ```
8. Return all results with clear OK/FAIL/WARN/INFO prefixes.

### Agent C: Hooks Validation

Prompt the agent to run these checks and return structured results. Do NOT modify any files.

1. **Plugin hooks.json** — find and validate:
   ```bash
   HOOKS_FILE=$(find ~/.claude -path "*/clux/hooks/hooks.json" -type f 2>/dev/null | head -1)
   if [ -z "$HOOKS_FILE" ]; then
       echo "FAIL plugin hooks.json not found"
   else
       echo "OK  hooks.json found ($HOOKS_FILE)"
       for EVENT in Stop Notification UserPromptSubmit; do
           if grep -q "\"$EVENT\"" "$HOOKS_FILE" && grep -q "notify-tmux" "$HOOKS_FILE"; then
               echo "OK  hook: $EVENT → notify-tmux.sh"
           else
               echo "FAIL hook: $EVENT not configured in hooks.json"
           fi
       done
   fi
   ```
2. **Hook scripts executable**:
   ```bash
   HOOKS_DIR=$(dirname "$HOOKS_FILE")
   for script in notify-tmux.sh; do
       if [ -x "$HOOKS_DIR/$script" ]; then
           echo "OK  $script executable"
       elif [ -f "$HOOKS_DIR/$script" ]; then
           echo "WARN $script not executable"
       else
           echo "FAIL $script missing"
       fi
   done
   # Also check notify-sound.sh in scripts dir
   SCRIPTS_DIR="$HOOKS_DIR/../scripts"
   if [ -x "$SCRIPTS_DIR/notify-sound.sh" ]; then
       echo "OK  notify-sound.sh executable"
   elif [ -f "$SCRIPTS_DIR/notify-sound.sh" ]; then
       echo "WARN notify-sound.sh not executable"
   else
       echo "FAIL notify-sound.sh missing"
   fi
   ```
3. **No conflicting system hooks** — check `~/.claude/settings.json`:
   ```bash
   SETTINGS="$HOME/.claude/settings.json"
   if [ -f "$SETTINGS" ]; then
       CONFLICTS=""
       for EVENT in Stop Notification UserPromptSubmit; do
           if python3 -c "
   import json, sys
   with open('$SETTINGS') as f:
       s = json.load(f)
   hooks = s.get('hooks', {})
   if '$EVENT' in hooks:
       entries = hooks['$EVENT']
       for e in entries:
           for h in e.get('hooks', []):
               cmd = h.get('command', '')
               if 'notify-tmux' not in cmd:
                   print(cmd)
                   sys.exit(0)
   sys.exit(1)
   " 2>/dev/null; then
               CONFLICTS="$CONFLICTS $EVENT"
           fi
       done
       if [ -z "$CONFLICTS" ]; then
           echo "OK  no conflicting system hooks"
       else
           echo "FAIL conflicting system hooks:$CONFLICTS (run /clux:setup to fix)"
       fi
   else
       echo "WARN ~/.claude/settings.json not found"
   fi
   ```
4. Return all results with clear OK/FAIL/WARN/INFO prefixes.

**Wait for all three agents to complete before proceeding.**

## Phase 2: Present Report

Combine all results into a single, clean report. Categorize each check result:

- **PASS** (OK): Check passed
- **FAIL**: Check failed — needs fixing
- **WARN**: Non-critical issue — works but suboptimal
- **INFO**: Informational — no action needed

Format the output as:

```
clux validate — health check results
=====================================

  Environment:
    ✓ tmux running (v3.6a)
    ✓ jq installed
    ✓ fzf installed
    ~ flock unavailable (mkdir fallback)

  Deployed scripts (~/.config/clux/scripts/):
    ✓ helpers.sh
    ✓ show-notification.sh
    ✓ jump-to-notification.sh
    ✓ dismiss-notification.sh
    ✓ notification-picker.sh
    ✓ all scripts in sync with plugin source

  tmux configuration:
    ✓ notification in status-format[0]
    ✓ stable deploy path (~/.config/clux/scripts/)
    ✓ status-interval: 1
    ✓ status-left-length: 150
    ✓ monitor-bell: on
    ✓ bell-action: any
    ✓ notification dir writable

  Notification style:
    ✓ bg: #EBCB8B  fg: #2E3440

  Per-notification preferences:
    notification:  visual=on   sound=on
    stop:          visual=off  sound=off
    prompt:        visual=off  sound=off

  Keybindings:
    ✓ prefix m  → jump to notification
    ✓ prefix `  → dismiss notification
    ✓ prefix DC → dismiss notification
    ✓ prefix M  → notification picker

  Hooks:
    ✓ hooks.json: Stop, Notification, UserPromptSubmit
    ✓ notify-tmux.sh executable
    ✓ notify-sound.sh executable
    ✓ no conflicting system hooks

  ──────────────────────────────
  N passed, 0 failed, 0 warnings
```

Use these symbols:
- `✓` for PASS
- `✗` for FAIL
- `!` for WARN
- `~` for INFO

## Phase 3: Recommendations

If any checks failed or warned:

1. **For FAIL results**: Suggest running `/clux:setup` to fix, or provide the specific fix command.
2. **For WARN results**: Explain the impact and suggest the fix (e.g., "set status-interval to 1 for faster notification updates").
3. **If everything passes**: Report "All checks passed. clux is fully operational."

**Do NOT offer to make changes.** This command is read-only. Direct the user to run `/clux:setup` for fixes.
