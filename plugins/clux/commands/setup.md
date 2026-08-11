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
   - `show-notification.sh`, `jump-to-notification.sh`, `dismiss-notification.sh`, `notification-picker.sh`, `helpers.sh`, `path.sh`, `agent-query.sh`, `agent-bar.sh`, `agent-clear.sh`
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

### Agent C: Hooks, System Settings & Keybindings Check

Prompt the agent to:
1. Find and read the plugin hooks file:
   ```bash
   find ~/.claude -path "*/clux/hooks/hooks.json" -type f 2>/dev/null | head -1
   ```
2. Check if hooks.json contains `notify-tmux.sh` entries for `Stop`, `Notification`, and `UserPromptSubmit` events. Note: clux's hooks.json now registers a SECOND command on those same events (plus `SessionEnd`) — `agent-state.sh <state>`, which writes the per-pane agent-state file the tmux status bar reads. Both commands run in parallel from the same event; this is not a new event and needs no settings.json handling
3. Read `~/.claude/settings.json` and check for existing system hooks:
   - Look for `hooks.Stop`, `hooks.Notification`, `hooks.UserPromptSubmit` entries
   - These are **conflicting** — the plugin's `hooks.json` handles all notification events via `notify-tmux.sh` → `notify-sound.sh`. System-level hooks for these events cause double-firing (e.g., double sounds)
   - Note any `hooks.SessionEnd` entries — clux now adds its own `SessionEnd → notify-tmux.sh` entry; any **additional** user `SessionEnd` commands are preserved alongside it
   - Report each conflicting hook found with its current command
4. Check existing tmux keybindings for conflicts:
   ```bash
   tmux list-keys 2>/dev/null | grep -E "bind-key\s+(m|M|\`)"
   ```
5. Return: hooks file path, hooks status (ok/missing/incomplete), conflicting system hooks (list of event names + commands), preserved hooks (additional user SessionEnd commands etc.), conflicting keybindings (if any). Note: clux manages one `SessionEnd → notify-tmux.sh` entry itself; user-supplied `SessionEnd` commands are preserved alongside it (not treated as conflicting).

**Wait for all three agents to complete before proceeding.**

If Agent A reports tmux not found or plugin scripts missing, tell the user and stop.
If Agent B finds both config files, use AskUserQuestion to ask the user which to use.

## Phase 2: Report Findings

Present a clear summary to the user combining results from all three agents:

```
clux setup — analysis results:

  Environment:
    tmux: /usr/local/bin/tmux (v3.6a)
    Plugin scripts: /Users/.../.claude/plugins/cache/ai-advanced-futures/clux/x.y.z/scripts/

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
    hooks.json: OK (Stop, Notification, UserPromptSubmit events configured)
    Keybinding conflicts: none

  System hooks (~/.claude/settings.json):
    Stop: afplay /System/Library/Sounds/Glass.aiff (CONFLICTING — will be removed)
    Notification: afplay /System/Library/Sounds/Submarine.aiff (CONFLICTING — will be removed)
    UserPromptSubmit: afplay /System/Library/Sounds/Pop.aiff (CONFLICTING — will be removed)
    SessionEnd: notify-tmux.sh (clux-managed — SessionEnd clears agent notifications)
    SessionEnd (user): afplay /System/Library/Sounds/Hero.aiff (preserved alongside clux entry)
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

### B3. Per-notification preferences (interactive — one hook at a time)

Walk the user through each Claude Code hook event, asking whether they want **visual** (status bar badge) and **sound** enabled. Present one event at a time using AskUserQuestion.

The three event types and their defaults (from `helpers.sh`):

| Event | When it fires | Visual default | Sound default |
|-------|---------------|----------------|---------------|
| **Notification** | Claude sends a notification (e.g., tool permission request) | `on` | `on` |
| **Stop** | Claude finishes a task | `off` | `off` |
| **Prompt** | User submits a prompt (UserPromptSubmit hook) | `off` | `off` |

**Flow — ask one event at a time:**

**Step 1:** Ask about **Notification** events:
```
Use AskUserQuestion:
  question: "Notification events (Claude needs attention, e.g., tool permission).
             What should happen?"
  header: "Notification"
  multiSelect: true
  options:
    - label: "Visual (status bar badge)"
      description: "Show a notification badge in the tmux status bar (currently: on)"
    - label: "Sound"
      description: "Play a sound alert (currently: on)"
```

**Step 2:** Ask about **Stop** events:
```
Use AskUserQuestion:
  question: "Stop events (Claude finished a task).
             What should happen?"
  header: "Stop"
  multiSelect: true
  options:
    - label: "Visual (status bar badge)"
      description: "Show a notification badge in the tmux status bar (currently: off)"
    - label: "Sound"
      description: "Play a sound alert (currently: off)"
```

**Step 3:** Ask about **Prompt** events:
```
Use AskUserQuestion:
  question: "Prompt events (you submitted a prompt to Claude).
             What should happen?"
  header: "Prompt"
  multiSelect: true
  options:
    - label: "Visual (status bar badge)"
      description: "Show a notification badge in the tmux status bar (currently: off)"
    - label: "Sound"
      description: "Play a sound alert (currently: off)"
```

After collecting all preferences, present a summary table:

```
Per-notification preferences:
  Notification:  visual=on   sound=on
  Stop:          visual=off  sound=off
  Prompt:        visual=off  sound=off
```

Map the user's choices to tmux variables that will be written to the clux section in Phase 5:

```tmux
# Per-notification controls
set -g @claude-notify-notification-visual "on"
set -g @claude-notify-notification-sound "on"
set -g @claude-notify-stop-visual "off"
set -g @claude-notify-stop-sound "off"
set -g @claude-notify-prompt-visual "off"
set -g @claude-notify-prompt-sound "off"
```

**Only include variables that differ from the built-in defaults** (to keep tmux.conf clean). The defaults are defined in `helpers.sh` — if the user's choice matches the default, omit that variable.

### B4. Agent state bar (optional — clux 3.2.0+ installs this itself)

clux can show a per-agent state glyph (busy / needs-you / finished) on the tmux status bar. State lives in files under `@clux-agent-state-dir`, written by the `hooks/agent-state.sh` hook, and read by the new `agent-query.sh` / `agent-bar.sh` scripts — the bar never writes.

As of 3.2.0, clux installs the bar itself: on the first Claude Code hook fire inside tmux, it registers the two `[90]` hooks and appends `#{@clux-agent-bar}` to `status-right` on the LIVE tmux server. Nothing is added to `tmux.conf` — the change is lost on a server restart and reinstalled automatically on the next prompt. Most users need do nothing in this section; it only matters for a manual install or a non-plugin (tpm-only) setup.

| Option | Default | Meaning |
|--------|---------|---------|
| `@clux-agent-state-dir` | `${XDG_STATE_HOME:-$HOME/.local/state}/clux/agents` | where per-pane state files live (honoured only when `claude-notify.tmux` is loaded via tpm) |
| `@clux-agent-glyph-busy` | `*` | glyph shown while Claude is working |
| `@clux-agent-glyph-needs` | `!` | glyph shown when Claude needs your input |
| `@clux-agent-glyph-done` | `v` | glyph shown when Claude finished |
| `@clux-agent-busy-color` | `cyan` | foreground color for the busy glyph |
| `@clux-agent-needs-color` | `yellow` | foreground color for the needs-you glyph |
| `@clux-agent-done-color` | `green` | foreground color for the finished glyph |
| `@clux-agent-refresh-command` | `refresh-client -S` | tmux command run after each state write, to redraw the bar |

Glyph defaults are plain ASCII on purpose: the bar reserves exactly ONE column per session, and a two-column glyph (an emoji, a nerd-font icon) would reflow it. A user who sets a wide glyph owns the reflow. There is no `@clux-agent-glyph-idle` option — idle is always a literal space.

Two usage shapes, depending on the user's status line — **only for a manual install, or a non-plugin (tpm-only) setup**; plugin users get this wired automatically and need neither line:
```tmux
# Plain status line: compact roll-up of every non-idle session, appended with
# tmux's own -a (append). Do NOT use `"#{status-right} ..."` — tmux expands an
# option reference only ONE level, so that shape draws the literal text
# `#{status-right}` on the bar instead of its actual value.
set -ag status-right " #{@clux-agent-bar}"

# Session-list bar: one reserved column per session
#(DEPLOY_DIR/agent-bar.sh #{session_name})
```

The default `status-right-length` is 40 and can silently truncate the segment — raise it (e.g. `set -g status-right-length 150`) if the glyphs do not appear.

**Warning on the session-list shape:** `#{session_name}` is expanded directly into a shell command line before `agent-bar.sh` ever runs, so a session name containing shell metacharacters is a command-injection surface. Do not present that shape as safe for untrusted session names.

This section is optional — offer it, but don't block the rest of setup if the user declines.

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

### C2. tmux hooks for finished marks (non-plugin installs)

The agent-state bar (section B4) clears a session's `finished` glyph back to idle when the user looks at that window. This is done by two tmux hooks, `after-select-window` and `client-session-changed`, at index `[90]`.

**As of 3.2.0, these hooks self-install.** Plugin users need nothing here — the first Claude Code hook fire inside tmux registers both. Users who load `claude-notify.tmux` through tpm also get them automatically.

Only a non-plugin, non-tpm setup (scripts deployed by hand, `claude-notify.tmux` never sourced) needs the manual lines below:

```tmux
set-hook -g 'after-select-window[90]' "run-shell \"DEPLOY_DIR/agent-clear.sh '#{window_id}'\""
set-hook -g 'client-session-changed[90]' "run-shell \"DEPLOY_DIR/agent-clear.sh '#{window_id}'\""
```

Substitute the real `DEPLOY_DIR` (e.g. `~/.config/clux/scripts`). The indexed `[90]` slot makes re-sourcing the config idempotent (no duplicate hook on every reload) and leaves any hand-written user hooks at low indices untouched.

**Consequence of skipping this:** everything else still works — the bar still shows busy and needs-you correctly — but `finished` marks never clear on their own once written; they only go away when the pane's `SessionEnd` fires.

### D. System hooks cleanup (`~/.claude/settings.json`)

The plugin's `hooks.json` registers `notify-tmux.sh` for Stop, Notification, and UserPromptSubmit events. The script handles both visual notifications (via tmux status bar) and sound (via `notify-sound.sh`), respecting the per-notification preferences configured in Phase B3.

**Any system-level hooks in `~/.claude/settings.json` for these same events are redundant and cause conflicts** (e.g., double sounds, sounds playing when the user disabled them).

Based on Agent C's findings:
1. **Remove** any `hooks.Stop`, `hooks.Notification`, and `hooks.UserPromptSubmit` entries from settings.json
2. **Preserve** user `SessionEnd` commands — clux's own `SessionEnd → notify-tmux.sh` is managed by hooks.json and should NOT appear in settings.json; if found there, treat as duplicate and remove it, but keep any other user-supplied `SessionEnd` commands
3. **Preserve** all other non-clux hook entries and all non-hook settings
4. If the hooks object becomes empty after removal, keep it as `"hooks": {}`

Present the changes clearly to the user:
```
System hooks (settings.json):
  Remove: Stop (afplay Glass.aiff) — handled by plugin notify-sound.sh
  Remove: Notification (afplay Submarine.aiff) — handled by plugin notify-sound.sh
  Remove: UserPromptSubmit (afplay Pop.aiff) — handled by plugin notify-sound.sh
  Keep:   SessionEnd (user) (afplay Hero.aiff) — preserved alongside clux's own SessionEnd entry
```

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
   for script in helpers.sh path.sh show-notification.sh jump-to-notification.sh dismiss-notification.sh notification-picker.sh agent-query.sh agent-bar.sh agent-clear.sh; do
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
  # Per-notification controls (only vars that differ from defaults)
  set -g @claude-notify-stop-sound "on"
  set -g @claude-notify-stop-visual "on"
  ...keybindings...
  # --- end clux ---
  ```
  Only include the `@claude-notify-bg`/`@claude-notify-fg` lines if a color palette was detected.
  Only include per-notification `@claude-notify-{type}-{sound|visual}` lines for values that differ from the built-in defaults in `helpers.sh`. The defaults are: notification sound=on, notification visual=on, stop sound=off, stop visual=off, prompt sound=off, prompt visual=off.
- Preserve ALL existing content outside the clux markers
- If clux markers already exist, replace the content between them
- Return: the complete new file content

**Write the new tmux.conf** using the Write tool with Agent E's output.

### Agent F: Update system hooks in settings.json (run after Agent E)

Read the current `~/.claude/settings.json` and update it:

1. Remove `hooks.Stop`, `hooks.Notification`, and `hooks.UserPromptSubmit` entries if they exist
2. Preserve user `SessionEnd` commands that are NOT clux's own `notify-tmux.sh` — if a `hooks.SessionEnd` entry points to `notify-tmux.sh`, remove it (duplicate of hooks.json); keep all other `SessionEnd` commands alongside clux's managed entry. Preserve all other non-clux hook entries and all non-hook settings.
3. Preserve the exact JSON formatting (2-space indent)
4. Write the updated file using the Edit tool (not Write — to avoid overwriting concurrent changes)

**Important**: Only remove hooks that Agent C identified as conflicting. If a hook entry doesn't exist, skip it. If the `hooks` key has no remaining entries after removal, keep it as an empty object `{}`.

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

# Check system hooks — no conflicting entries should remain
# SessionEnd is checked too, but clux's own notify-tmux.sh entry is excluded
python3 -c "
import json
with open('$HOME/.claude/settings.json') as f:
    s = json.load(f)
hooks = s.get('hooks', {})
conflicts = []
for e in ('Stop', 'Notification', 'UserPromptSubmit', 'SessionEnd'):
    if e in hooks:
        for entry in hooks[e]:
            for h in entry.get('hooks', []):
                cmd = h.get('command', '')
                if 'notify-tmux' not in cmd:
                    conflicts.append(e)
                    break
if conflicts:
    print(f'FAIL: conflicting system hooks still present: {conflicts}')
    exit(1)
print('OK: no conflicting system hooks')
"
```

Report success or failure for each check.

## Phase 7: Summary

Show the user:
- What was changed (tmux.conf + settings.json)
- System hooks removed and why (plugin handles them via notify-tmux.sh → notify-sound.sh)
- Scripts deployed, including the three agent-state scripts (`agent-query.sh`, `agent-bar.sh`, `agent-clear.sh`)
- Whether the agent-state bar was configured (section B4) and, if so, whether the non-tpm tmux hooks (section C2) were added
- Backup location and rollback command: `cp <backup_path> <tmux_conf> && tmux source-file <tmux_conf>`
- Keybinding quick reference (m = jump, ` = dismiss, M = picker)
- Suggest running `/clux:validate` for full validation
