---
name: configuring-tmux
description: Use when installing or repairing the clux session surface in a user's tmux configuration — detecting what the machine and the tmux.conf already hold, asking the prerequisite questions, editing the tmux.conf without changing a line clux did not add, migrating a hand-written session surface, and verifying the result on a throwaway server. Backs /clux:setup.
---

# Configuring tmux for clux

You are installing the clux session surface into the user's tmux. You ARE the LLM — never call external APIs.

This skill holds the whole procedure and every rule that governs it. `/clux:setup` is the entry point and restates none of them, so each rule has exactly one copy and no second copy to drift from it — the fault this codebase has already paid for twice: two deploy lists (CHANGELOG 3.0.9) and the CONTRIBUTING file tree.

Two goals, and setup must reach whichever one the machine asks for:

- **Bare machine** — after this run, the user has a complete working environment: sessions and windows visible in the bar, session navigation working, agent state showing.
- **Existing tmux setup** — after this run, every clux key and every clux visualization works, and **nothing else in that setup has changed**.

**Use subagents (Task tool) to parallelize independent work.** Launch multiple agents concurrently wherever steps don't depend on each other.

## CRITICAL RULES

- **Never call external APIs** — you are Claude Code running inside the user's session
- **clux owns exactly one file**: `~/.config/clux/clux.tmux.conf`. It is rewritten whole on every run, so it needs no markers inside it. Never hand-edit it — call `render-clux-conf.sh`
- **The user's tmux.conf gets one line and two token strings, and nothing else**:
  - `source-file -q ~/.config/clux/clux.tmux.conf`
  - `#{@clux_session_bar}#(~/.config/clux/scripts/session-bar-refresh.sh quiet #{client_pid})` — the session-bar token string, **contiguous**, never the `#{...}` part alone. `#{client_pid}` keys the per-client animation-frame counter (see the animated-busy-glyph note under §3.7) — the argument-less form still works on an install from before 3.5.0, falling back to one shared counter
  - `#{@clux_status}` — the notification token
- **Never write a setting clux does not own.** `status-interval`, `status-position`, colors outside clux's own bar, the prefix key, pane keys, copy mode, the clipboard, resurrect — all stay the user's. Where clux wants a particular value, **report it and leave it alone**
- **Never overwrite an existing status display** — read the current value and insert the tokens into it
- **Prerequisites are questions, not defaults.** Detect what the machine has, offer it as the **first** option, and let the user choose something else. Never hard-code a tool
- **Show the change first, back up, then verify.** Verification is `verify-tmux-conf.sh`. When it fails, restore the backup and say so
- **Refuse rather than guess.** If the status line cannot be located with confidence, refuse and explain
- **Deploy from the manifest** — `plugins/clux/config/deploy-manifest.txt`. Never write a script list into this skill or into a shell block
- **Option naming rule**: hyphens for configuration inputs (`@clux-dir-resolver`, `@clux-editor`, every `@clux-bar-*`, every `@clux-agent-*`); underscores for the two runtime-rendered strings only (`@clux_session_bar`, `@clux_status`). Never set the underscored two from a config file
- **Hook index band 90–99 is clux's.** `agent-clear.sh` at `[90]`, `session-bar-refresh.sh` at `[91]`, `92`–`99` reserved. An unindexed user hook writes index 0, so neither side can drop the other
- **Idempotent** — a second run must leave the user's tmux.conf byte-identical
- **Always ask before modifying files** — use AskUserQuestion for confirmation

## Snippet S1: resolve the plugin source root

Every detection agent needs this. Pass it verbatim into each agent prompt — do not re-derive it, and do not let one agent's copy drift from another's.

```bash
# Tier 1: the harness exported CLAUDE_PLUGIN_ROOT (hook processes always;
# command/subagent Bash calls sometimes). Tier 2: the installed cache
# ~/.claude/plugins/cache/<marketplace>/clux/<version>/ or a flat
# ~/.claude/plugins/clux/. Tier 3: a plain checkout at or below the cwd.
PLUGIN_ROOT=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/scripts/show-notification.sh" ]; then
    PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
    # Tier 2a: the loaded cache copy, searched ALONE first. A marketplace
    # source checkout at ~/.claude/plugins/marketplaces/<mp>/plugins/clux/
    # matches the same glob, and `marketplaces` sorts after `cache`, so one
    # combined search returns that git tree instead of the version Claude
    # Code actually loaded.
    HIT=$(find "$HOME/.claude/plugins/cache" -maxdepth 5 -type f \
        -path "*/clux/*/scripts/show-notification.sh" 2>/dev/null \
        | LC_ALL=C sort -V | tail -1)
    # Tier 2b: any other install shape under ~/.claude/plugins.
    [ -n "$HIT" ] || HIT=$(find "$HOME/.claude/plugins" -maxdepth 6 -type f \
        \( -path "*/clux/*/scripts/show-notification.sh" \
        -o -path "*/clux/scripts/show-notification.sh" \) 2>/dev/null \
        | LC_ALL=C sort -V | tail -1)
    [ -n "$HIT" ] || HIT=$(find "$PWD" -maxdepth 4 -type f \
        -path "*/plugins/clux/scripts/show-notification.sh" 2>/dev/null \
        | LC_ALL=C sort -V | tail -1)
    [ -n "$HIT" ] && PLUGIN_ROOT="${HIT%/scripts/show-notification.sh}"
fi
PLUGIN_SCRIPTS_DIR="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts}"
MANIFEST="${PLUGIN_ROOT:+$PLUGIN_ROOT/config/deploy-manifest.txt}"
[ -f "$MANIFEST" ] || MANIFEST=""
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
echo "PLUGIN_SCRIPTS_DIR=$PLUGIN_SCRIPTS_DIR"
echo "MANIFEST=$MANIFEST"
```

When several versions are installed side by side, `sort -V | tail -1` picks the highest version (3.3.0 over 3.0.8) — deterministic, and it matches the version Claude Code actually loads. Report a clear failure when `PLUGIN_ROOT` is empty.

## Snippet S2: read the deploy manifest

```bash
# One script per line. Blank lines and comments are skipped. This is the ONLY
# list of deployed scripts anywhere in clux — /clux:setup, /clux:validate and
# the bats tests all read this file (CHANGELOG 3.0.9 is what a second,
# hand-written list costs).
manifest_scripts() {
    grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$'
}
```

## Phase 1: Detection (use subagents in parallel)

Launch **three subagents concurrently** using the Task tool with `subagent_type: "general-purpose"`. Give each one snippet S1 verbatim.

### Agent A: Environment, plugin source, prerequisite tools

Prompt the agent to:

1. Verify tmux is installed: `command -v tmux`, and get `tmux -V`
2. Run snippet S1, then snippet S2
3. Verify every manifest script exists in `PLUGIN_SCRIPTS_DIR`, plus the two setup-time scripts that are deliberately **not** in the manifest:
   ```bash
   MISSING=""
   for script in $(manifest_scripts) render-clux-conf.sh verify-tmux-conf.sh; do
       [ -f "$PLUGIN_SCRIPTS_DIR/$script" ] || MISSING="$MISSING $script"
   done
   [ -z "$MISSING" ] && echo "OK  all manifest scripts present" || echo "FAIL missing:$MISSING"
   ```
4. **Detect the prerequisites.** Each one becomes a question in Phase 3 with the detected value as the first option — detection never decides anything on its own:
   ```bash
   # --- folder resolver ---
   command -v autojump >/dev/null 2>&1 && echo "have-autojump: yes" || echo "have-autojump: no"
   command -v zoxide   >/dev/null 2>&1 && echo "have-zoxide: yes"   || echo "have-zoxide: no"

   # --- editor ---
   # $EDITOR is read HERE and nowhere else. Reading it at run time would make
   # the same workspace open a different editor per client environment, so the
   # answer is frozen into @clux-editor now.
   EDITOR_DETECTED="none"
   if [ -n "${EDITOR:-}" ] && command -v "${EDITOR%% *}" >/dev/null 2>&1; then
       EDITOR_DETECTED="$EDITOR"
   elif command -v nvim >/dev/null 2>&1; then
       EDITOR_DETECTED="nvim"
   elif command -v vim >/dev/null 2>&1; then
       EDITOR_DETECTED="vim"
   fi
   echo "editor-detected: $EDITOR_DETECTED"
   command -v nvim >/dev/null 2>&1 && echo "have-nvim: yes" || echo "have-nvim: no"
   command -v vim  >/dev/null 2>&1 && echo "have-vim: yes"  || echo "have-vim: no"

   # --- picker ---
   command -v fzf-tmux >/dev/null 2>&1 && echo "have-fzf-tmux: yes" || echo "have-fzf-tmux: no"
   command -v fzf      >/dev/null 2>&1 && echo "have-fzf: yes"      || echo "have-fzf: no"

   # --- agents command ---
   command -v claude >/dev/null 2>&1 && echo "have-claude: yes" || echo "have-claude: no"
   # Already-configured value wins over any guess.
   AGENTS_LIVE=$(tmux show-option -gqv @clux-agents-command 2>/dev/null)
   [ -n "$AGENTS_LIVE" ] && echo "agents-from-option: $AGENTS_LIVE"
   # A hand-written new-session.sh sends the command with send-keys; pull the
   # single-quoted argument out of that line verbatim, flags and all.
   for f in "$HOME/.config/tmux/scripts/new-session.sh" \
            "$HOME/.config/tmux/scripts/new-workspace.sh"; do
       [ -f "$f" ] || continue
       CMD=$(sed -n "s/.*send-keys[^']*'\(claude[^']*\)'.*/\1/p" "$f" | head -1)
       [ -n "$CMD" ] && echo "agents-from-script: $CMD"
   done
   ```
5. **Flag the permission flag.** If any detected agents command contains `--allow-dangerously-skip-permissions`, report it explicitly — Phase 3 must ask about it by name
6. Return: tmux path and version, `PLUGIN_ROOT`, `PLUGIN_SCRIPTS_DIR`, `MANIFEST`, missing scripts, and every detection line above

### Agent B: tmux.conf analysis, render site, palette, legacy wiring

Prompt the agent to:

1. Check which config files exist:
   - `${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf` (preferred — where tmux 3.x looks first, and where clux writes on a bare machine)
   - `$HOME/.tmux.conf`
2. **Find where the status line really renders. Probe; do not parse.**
   ```bash
   TMUX_CONF="<the chosen config file, or empty if none>"

   # The live server is the truth about what is rendering right now.
   if tmux info >/dev/null 2>&1; then
       LIVE_FORMAT0=$(tmux show-option -gqv 'status-format[0]' 2>/dev/null)
       LIVE_LEFT=$(tmux show-option -gqv status-left 2>/dev/null)
       echo "probe-source: live server"
   elif [ -n "$TMUX_CONF" ]; then
       tmux -L clux-probe -f "$TMUX_CONF" new-session -d 2>/dev/null
       LIVE_FORMAT0=$(tmux -L clux-probe show-option -gqv 'status-format[0]' 2>/dev/null)
       LIVE_LEFT=$(tmux -L clux-probe show-option -gqv status-left 2>/dev/null)
       tmux -L clux-probe kill-server 2>/dev/null
       echo "probe-source: throwaway server on $TMUX_CONF"
   fi

   # tmux's OWN built-in default for status-format[0], read from a stock
   # server at run time. Never hardcode this string: it changes between tmux
   # versions, and comparing against a freshly read default is the only way to
   # tell "the user set status-format[0]" from "tmux populated it".
   tmux -L clux-default -f /dev/null new-session -d 2>/dev/null
   DEFAULT_FORMAT0=$(tmux -L clux-default show-option -gqv 'status-format[0]' 2>/dev/null)
   tmux -L clux-default kill-server 2>/dev/null
   ```
   Decide the render site in this order:
   - `status-format[0]` differs from `DEFAULT_FORMAT0` → **`status-format[0]` is the render site**
   - else `status-left` is non-empty → **`status-left` is the render site**
   - else → **`status-left` is the render site by default**
3. **Map the chosen live value back to exactly one line of the config file**, by option name and by value:
   ```bash
   grep -n "status-format\[0\]" "$TMUX_CONF"   # or: grep -n "status-left" "$TMUX_CONF"
   ```
   Report the candidate count. **Zero candidates, or more than one, is a refusal** — see Phase 4
4. Extract from the config file, and report:
   - `status-interval`, `status-left-length` (reported, never written — see CRITICAL RULES)
   - existing `source-file` line pointing at `clux.tmux.conf` (count it)
   - existing `#{@clux_session_bar}`, `#{@clux_status}`, `session-bar-refresh.sh quiet` occurrences (count each)
   - existing clux section markers (`# --- clux: …` / `# --- end clux ---`)
   - a legacy `#(…/show-notification.sh)` call in the status line — the pre-3.3 wiring the notification token replaces
   - a tpm line loading `claude-notify.tmux`
5. **Extract the color palette** from the config. Look for:
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
   - **The bar the user already has is a better source than the config's styles.**
     A hand-written `session-list.sh` states the exact colours the session bar
     renders today, and the live server states what is set right now. Both beat
     inferring a session-bar colour from `status-style`. Read them:
     ```bash
     OLD_LIST="$HOME/.config/tmux/scripts/session-list.sh"
     # The glyph function and the row builders carry the real values, e.g.
     #   if (st == "busy") return "#[fg=#88C0D0]*#[default]"
     #   wins[$1]= ... "#[bg=#81A1C1,fg=#ECEFF4,bold]" ...
     [ -f "$OLD_LIST" ] && grep -n -E '#\[(fg|bg)=' "$OLD_LIST"
     # Live options win over anything inferred: they are what renders NOW, and
     # for the agent colours they are frequently the ONLY copy — nothing wrote
     # them to a file, so they die with the server unless setup carries them.
     for o in @clux-agent-busy-color @clux-agent-needs-color @clux-agent-done-color \
              @clux-agent-glyph-busy @clux-agent-glyph-needs @clux-agent-glyph-done; do
         v=$(tmux show-option -gqv "$o" 2>/dev/null)
         [ -n "$v" ] && echo "live-option: $o = $v"
     done
     ```
     Add to the color map, when found:
     - `agent_busy` / `agent_needs` / `agent_done`: the three glyph colours
     - `glyph_busy` / `glyph_needs` / `glyph_done`: the three glyphs
6. **Detect a hand-written session surface** — the migration case (Part 5 of the design):
   ```bash
   OLD_DIR="$HOME/.config/tmux/scripts"
   for s in session-order.sh session-list.sh session-reorder.sh switch-session.sh \
            session-bar-refresh.sh fzf-session-switch.sh new-session.sh new-session-prompt.sh; do
       [ -f "$OLD_DIR/$s" ] && echo "legacy-script: $s"
   done
   # Lines in tmux.conf whose COMMAND TEXT references one of those paths. This
   # path match — never a key name — is the only rule that cannot delete
   # something clux did not write.
   #
   # The directory is part of the pattern, not decoration: clux deploys its own
   # session-bar-refresh.sh, so a bare "scripts/session-bar-refresh.sh" match
   # would also hit the line clux itself just added. Match the OLD directory.
   grep -n -E "tmux/scripts/(session-order|session-list|session-reorder|switch-session|session-bar-refresh|fzf-session-switch|new-session|new-session-prompt)\.sh" "$TMUX_CONF"
   # Bindings on a clux key that point somewhere ELSE: reported as conflicts,
   # never touched.
   grep -n -E "^[[:space:]]*bind(-key)?[[:space:]]+(-[^[:space:]]+[[:space:]]+)*('?\{'?|'?\}'?|N|P|g|A)[[:space:]]" "$TMUX_CONF"
   # The live custom order, read from server memory. Only session-reorder.sh
   # ever wrote it, so there is no file to migrate.
   tmux show-option -gqv @session_order 2>/dev/null
   tmux show-option -gqv @clux-session-order 2>/dev/null
   ```
7. Return: config file path(s) found, render site + the single config line that produces it (or the refusal), all counts from step 4, the **color map**, the legacy inventory, the conflicting bindings, and both order option values

### Agent C: Hooks, system settings, keybinding conflicts

Prompt the agent to:

1. Run snippet S1, then locate the hooks file:
   ```bash
   HOOKS_FILE="${PLUGIN_ROOT:+$PLUGIN_ROOT/hooks/hooks.json}"
   # PLUGIN_ROOT is resolved from scripts/show-notification.sh, so a tree that
   # carries the scripts but not the hooks (a partially synced cache, a deployed
   # copy) yields a non-empty HOOKS_FILE that does not exist. Empty it here so the
   # not-found branch below still fires.
   [ -f "$HOOKS_FILE" ] || HOOKS_FILE=""
   echo "HOOKS_FILE=$HOOKS_FILE"
   ```
2. Check if hooks.json contains `notify-tmux.sh` entries for `Stop`, `Notification`, and `UserPromptSubmit` events. Note: clux's hooks.json registers a SECOND command on those same events (plus `SessionEnd`) — `agent-state.sh <state>`, which writes the per-pane agent-state file the tmux status bar reads. Both commands run in parallel from the same event; this is not a new event and needs no settings.json handling
3. Read `~/.claude/settings.json` and check for existing system hooks:
   - Look for `hooks.Stop`, `hooks.Notification`, `hooks.UserPromptSubmit` entries
   - These are **conflicting** — the plugin's `hooks.json` handles all notification events via `notify-tmux.sh` → `notify-sound.sh`. System-level hooks for these events cause double-firing (e.g., double sounds)
   - Note any `hooks.SessionEnd` entries — clux adds its own `SessionEnd → notify-tmux.sh` entry; any **additional** user `SessionEnd` commands are preserved alongside it
   - Report each conflicting hook found with its current command
4. Check existing tmux keybindings and hooks for conflicts:
   ```bash
   # clux's ten keys: N P { } g A m ` DC M
   tmux list-keys 2>/dev/null | grep -E "bind-key[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(N|P|\{|\}|g|A|m|M|\`|DC)[[:space:]]"
   # Anything already living in clux's reserved 90-99 hook band, and any
   # unindexed (index 0) hook on the six session-bar events.
   tmux show-hooks -g 2>/dev/null | grep -E "\[9[0-9]\]|client-session-changed|after-select-window|session-created|session-closed|window-linked|window-unlinked"
   ```
5. Return: hooks file path, hooks status (ok/missing/incomplete), conflicting system hooks (list of event names + commands), preserved hooks (additional user SessionEnd commands etc.), conflicting keybindings, and the current hook band contents. Note: clux manages one `SessionEnd → notify-tmux.sh` entry itself; user-supplied `SessionEnd` commands are preserved alongside it (not treated as conflicting)

**Wait for all three agents to complete before proceeding.**

If Agent A reports tmux not found, plugin scripts missing, or no manifest, tell the user and stop.
If Agent B finds both config files, use AskUserQuestion to ask the user which to use.

## Phase 2: Report Findings

Present a clear summary combining all three agents:

```
clux setup — analysis results:

  Environment:
    tmux: /usr/local/bin/tmux (v3.6a)
    Plugin scripts: /Users/.../.claude/plugins/cache/ai-advanced-futures/clux/3.3.0/scripts/
    Deploy manifest: 19 scripts, all present in the plugin source

  tmux.conf:
    Config file: ~/.config/tmux/tmux.conf
    Install mode: existing config (adds 1 line + 2 tokens, changes nothing else)
    Status line renders from: status-format[0]  (differs from tmux's own default)
    Config line that sets it: line 239 (exactly one candidate — good)
    source-file line for clux.tmux.conf: not present (will be added)
    #{@clux_session_bar}: 0   #{@clux_status}: 0   session-bar-refresh.sh quiet: 0
    Legacy wiring: #(…/show-notification.sh) at line 239 (replaced by #{@clux_status})
    status-interval: 2  (the busy glyph advances one frame per status-interval —
                         1 gives a ~1fps pulse, 2 gives one every two seconds;
                         no change needed, and clux will not write it either way)
    status-left-length: 150 (fine)
    tpm loads claude-notify.tmux: no

  Prerequisites detected (each is a question in the next phase):
    Folder resolver: autojump on PATH (zoxide: no)
    Editor:          nvim ($EDITOR unset)
    Agents command:  claude agents --cwd $(pwd) --allow-dangerously-skip-permissions
                     ⚠ carries --allow-dangerously-skip-permissions
    Picker:          fzf-tmux and fzf both on PATH

  Color palette detected:
    bg_dark:         #2E3440   (status bar background)
    fg_primary:      #88C0D0   (status bar text)
    fg_snow:         #ECEFF4   (bright white)
    bg_accent:       #81A1C1   (session highlight)
    bg_attention:    #EBCB8B   (message/notification)
    fg_on_attention: #2E3440   (text on attention bg)
    bg_alert:        #BF616A   (prefix/alert)

  Hand-written session surface found (migration case):
    ~/.config/tmux/scripts/: session-order.sh session-list.sh session-reorder.sh
      switch-session.sh session-bar-refresh.sh fzf-session-switch.sh
      new-session.sh new-session-prompt.sh
    tmux.conf lines referencing them: 26,27,31,32,155,158,248-251,267,268,270
    @session_order (live): work,notes,scratch  → copies to @clux-session-order
    Bindings on a clux key pointing elsewhere: none

  Hooks & keybindings:
    hooks.json: OK (Stop, Notification, UserPromptSubmit, SessionEnd)
    Hook band 90-99: [90] agent-clear.sh (already installed) — [91] free
    Keybinding conflicts: none outside the migration above

  System hooks (~/.claude/settings.json):
    Stop: afplay /System/Library/Sounds/Glass.aiff (CONFLICTING — will be removed)
    Notification: afplay /System/Library/Sounds/Submarine.aiff (CONFLICTING — will be removed)
    UserPromptSubmit: afplay /System/Library/Sounds/Pop.aiff (CONFLICTING — will be removed)
    SessionEnd: notify-tmux.sh (clux-managed — SessionEnd clears agent notifications)
    SessionEnd (user): afplay /System/Library/Sounds/Hero.aiff (preserved alongside clux entry)
```

## Phase 3: Ask

Prerequisites are **questions with alternatives**, and the detected value is always the first option. Never hard-code a tool choice, and never skip a question because detection was confident.

### 3.1 — How should folder names resolve to directories?

Sets `@clux-dir-resolver` (`autojump` | `zoxide` | `path`, default `path`).

```
Use AskUserQuestion:
  question: "prefix + A asks for a folder name. How should that name become a directory?"
  header: "Resolver"
  options (build in THIS order — detected first):
    - label: "autojump"        (only when detected)
      description: "Use autojump's database. Detected on this machine."
    - label: "zoxide"          (only when detected)
      description: "Use zoxide's database. Detected on this machine."
    - label: "Plain path"
      description: "No database. The name must be a real path (absolute, ~-prefixed, or relative to the current pane)."
```

In **every** mode, an input that already names an existing directory wins before the resolver runs, and a missing resolver binary degrades to `path` mode with one `display-message`. An unresolvable folder prints `clux: no directory for '<folder>'`, creates nothing and exits 1 — a session with a window in the wrong directory is worse than no session.

### 3.2 — Which editor opens in the workspace's first window?

Sets `@clux-editor`. The sentinel is the string `none`, never the empty string: `get_tmux_option()` collapses an empty value to its default, so an empty string cannot express "off".

```
Use AskUserQuestion:
  question: "A clux workspace opens two windows: '---' (editor) and 'claude' (agents).
             What should run in the '---' window?"
  header: "Editor"
  options:
    - label: "<EDITOR_DETECTED>"   (first — e.g. "nvim")
      description: "Detected on this machine. Sent into the window with send-keys."
    - label: "<the other of nvim/vim, when present>"
      description: "Also on this machine."
    - label: "No editor"
      description: "The '---' window is still created and pinned, but nothing is sent — you land in a shell."
```

"No editor" writes `none`. The window is still created either way: the workspace shape is the one default layout regardless of the editor choice.

### 3.3 — What command runs in the workspace's `claude` window?

Sets `@clux-agents-command`. Default `claude agents --cwd "$PWD"` when `claude` is on PATH, else `none`.

```
Use AskUserQuestion:
  question: "What should run in the workspace's 'claude' window?"
  header: "Agents cmd"
  options:
    - label: "Keep detected"      (first, only when detection found one)
      description: "<the detected command, verbatim, flags and all>"
    - label: "clux default"
      description: "claude agents --cwd \"$PWD\""
    - label: "Custom"
      description: "Type your own command."
    - label: "None"
      description: "Create the window, send nothing."
```

**The permission-flag question.** If the chosen command contains `--allow-dangerously-skip-permissions`, ask about it separately, by name. Detection makes it the default; confirmation makes it a choice:

```
Use AskUserQuestion:
  question: "Your detected agents command carries --allow-dangerously-skip-permissions.
             Every workspace clux creates will start Claude with tool permission
             prompts turned off. Keep that flag?"
  header: "Skip perms"
  options:
    - label: "Keep it"
      description: "<full command, verbatim>"
    - label: "Drop the flag"
      description: "<same command with --allow-dangerously-skip-permissions removed>"
```

Ask this **once**, and only when the flag is actually present. Record the answer and use the resulting command as `@clux-agents-command`.

The command is sent with `send-keys … Enter` into a shell, never run as `new-window "<cmd>"`: launched as the window's command, the window would close and take its scrollback with it when the dashboard exits, and `send-keys` is also what lets `$PWD` expand in the target shell. `render-clux-conf.sh` writes the value **single-quoted** so a literal `$PWD` survives into the option.

### 3.4 — How should the session picker work?

Sets `@clux-picker` (`fzf` | `choose-tree`, default `fzf` when a binary was found, else `choose-tree`).

```
Use AskUserQuestion:
  question: "prefix + g opens the session picker. Which one?"
  header: "Picker"
  options:
    - label: "fzf with pane preview"   (first when fzf or fzf-tmux was detected)
      description: "Fuzzy search with a live preview of each session's pane."
    - label: "choose-tree"
      description: "tmux's own picker. No extra binary."
```

`session-picker.sh` degrades independently of this option at run time, because the binary is a per-machine fact that can change after setup: `fzf-tmux -p` first, then `fzf` inside `tmux display-popup -E`, then `choose-tree -Zs` plus one `display-message`. The `g` key always works.

### 3.5 — Let clux render the session list?

This is an **install branch**, not an option. It decides which token strings enter the user's status line and whether `@clux-agent-refresh-command` is written at all.

```
Use AskUserQuestion:
  question: "Should clux render the session list in your status bar (sessions,
             their windows, and one agent-state column per session)?"
  header: "Session bar"
  options:
    - label: "Yes"
      description: "Adds #{@clux_session_bar} and #{@clux_status} to your status line. Recommended."
    - label: "No, keep my bar"
      description: "Adds only #{@clux_status}. Your own session rendering stays untouched."
```

- **Yes** → insert **both** token strings, and write
  `set -g @clux-agent-refresh-command "run-shell -b $HOME/.config/clux/scripts/session-bar-refresh.sh"`.
  Write `$HOME` **expanded to the real absolute path, with no `~`**: tmux expands this option's value unquoted and splits it on spaces to build the command, so no argument may contain a space and nothing downstream expands a tilde.
- **No** → insert only `#{@clux_status}`, and write **no** `@clux-agent-refresh-command` line, leaving whatever the user already has. Then offer section 3.7 (the standalone agent glyph) instead.

### 3.6 — Per-notification preferences (interactive — one hook at a time)

Walk the user through each Claude Code hook event, asking whether they want **visual** (status bar badge) and **sound** enabled. Present one event at a time using AskUserQuestion.

The three event types and their defaults (from `helpers.sh`):

| Event | When it fires | Visual default | Sound default |
|-------|---------------|----------------|---------------|
| **Notification** | Claude sends a notification (e.g., tool permission request) | `on` | `on` |
| **Stop** | Claude finishes a task | `off` | `off` |
| **Prompt** | User submits a prompt (UserPromptSubmit hook) | `off` | `off` |

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

**Step 2:** Ask about **Stop** events (same shape, currently: off / off).

**Step 3:** Ask about **Prompt** events (same shape, currently: off / off).

After collecting all preferences, present a summary table:

```
Per-notification preferences:
  Notification:  visual=on   sound=on
  Stop:          visual=off  sound=off
  Prompt:        visual=off  sound=off
```

These map to `@claude-notify-{type}-{visual|sound}` options. **Only write variables that differ from the built-in defaults** — the defaults live in `helpers.sh`, and a line that restates one only makes the file longer.

These options belong to the notification feature, which predates clux's own file and lives inside the user's clux markers. Keep writing them there, next to `@claude-notify-bg` / `@claude-notify-fg`.

### 3.7 — Agent state glyph without clux's bar (only when 3.5 was "No")

When clux renders the session list, the per-session agent column is already part of it and there is nothing to ask. When the user keeps their own bar, offer the standalone glyph:

| Option | Default | Meaning |
|--------|---------|---------|
| `@clux-agent-state-dir` | `${XDG_STATE_HOME:-$HOME/.local/state}/clux/agents` | root of the state store; files live one level down, under a directory per tmux server |
| `@clux-agent-glyph-busy` | `*` | glyph shown while Claude is working |
| `@clux-agent-glyph-busy-frames` | `- \ \| /` | frames the busy glyph cycles through in clux's own session bar, one per `status-interval`. Set `@clux-agent-glyph-busy` alone and leave this unset to keep a static glyph — see the note below the table |
| `@clux-agent-glyph-needs` | `!` | glyph shown when Claude needs your input |
| `@clux-agent-glyph-done` | `v` | glyph shown when Claude finished |
| `@clux-agent-busy-color` | `cyan` | foreground color for the busy glyph |
| `@clux-agent-needs-color` | `yellow` | foreground color for the needs-you glyph |
| `@clux-agent-done-color` | `green` | foreground color for the finished glyph |
| `@clux-agent-refresh-command` | `refresh-client -S` | tmux command run after each state write |

Glyph defaults are plain ASCII on purpose: the bar reserves exactly ONE column per session, and a two-column glyph (an emoji, a nerd-font icon) would reflow it. A user who sets a wide glyph owns the reflow. There is no `@clux-agent-glyph-idle` — `get_tmux_option` collapses a single-space value to its default, so idle is a literal space the renderer emits. `@clux-agent-glyph-busy-frames` does not change this: the shipped default (`- \ | /`) stays one plain-ASCII column, same as every other glyph default here.

**`@clux-agent-glyph-busy-frames` must always be written single-quoted.** Verified on tmux 3.7b: a double-quoted value —

```tmux
set -g @clux-agent-glyph-busy-frames "- \ | /"    # WRONG — do not do this
```

— loses the backslash to tmux's own double-quote parser and comes back as three frames (`- | /`), not four. Single-quoted, it survives intact:

```tmux
set -g @clux-agent-glyph-busy-frames '- \ | /'
```

Opt-in moon rotation — not the shipped default, because these glyphs are Unicode "ambiguous width": one cell in a common terminal, two cells under a CJK locale, and the bar reserves exactly one:

```tmux
set -g @clux-agent-glyph-busy-frames '◐ ◓ ◑ ◒'
```

```tmux
# Plain status line: compact roll-up of every non-idle session
set -g status-right "#(DEPLOY_DIR/agent-bar.sh) #{status-right}"

# The user's own session-list bar: one reserved column per session
#(DEPLOY_DIR/agent-bar.sh #{session_name})
```

Neither snippet above moves: `@clux-agent-glyph-busy-frames` is read by clux's own session bar (`session-list.sh` via `session-bar-refresh.sh`), not by `agent-bar.sh`. A standalone `agent-bar.sh` install keeps a static glyph unless it is invoked with an explicit `--frame N` — nothing in this skill ever calls it that way, so the two snippets above render exactly as they always have.

**`throttle.sh` — memoize a slow status-line job.** tmux re-runs **every** `#()` job on the status line on every redraw, not just the one segment whose content changed (measured with `refresh-client -S`). So a faster `status-interval` — see the note above about the animated busy glyph — makes the user's *own* `#()` jobs pay too, not just clux's. `throttle.sh` is a small opt-in tool for that: cache a job's output and only re-run the command every N seconds.

```tmux
#(~/.config/clux/scripts/throttle.sh 10 ~/.config/tmux/scripts/git.sh "#{pane_current_path}")
```

`throttle.sh <seconds> <command> [args…]` — a cache miss runs the command and caches stdout; a cache hit is a single bash start (~5ms), no fork of the wrapped command. Deployed via the manifest like every other script, at `~/.config/clux/scripts/throttle.sh`. Setup does **not** rewrite the user's existing `#()` jobs to use it — it is a tool to reach for, opted into by editing the user's own status line, same as every other line in this section.

Ask explicitly — this is opt-in, default off:
```
question: "Show a per-agent state glyph (busy/needs-you/finished) on your own status bar?"
header: "Agent bar"
options:
  - label: "Skip (default)"
    description: "Don't add an agent-state indicator."
  - label: "Per-session glyph"
    description: "One reserved column per session, next to each session name."
  - label: "Compact roll-up"
    description: "A single indicator in status-right summarizing all non-idle sessions."
```

Before asking, check whether an equivalent glyph is already wired — the literal `agent-bar.sh` snippets above, or a user-authored script that itself calls `agent-query.sh` or reads `@clux-agent-state-dir`. If found, report it as already configured and skip rather than adding a second glyph.

### 3.8 — Theming (fill the bar options from the detected palette)

Only when 3.5 was "Yes". Map the palette Agent B extracted onto the `@clux-bar-*` options, and **emit a line only for a value detection actually found** — everything else falls through to the reader's own default, so clux's file stays honest about what it inferred.

| Option | Default | Fill from |
|---|---|---|
| `@clux-bar-name-attached-style` | `bg=magenta,fg=black,bold` | `bg=<bg_accent>,fg=<bg_dark>,bold` |
| `@clux-bar-name-detached-style` | `fg=magenta` | `fg=<bg_accent>` |
| `@clux-bar-window-active-style` | `bg=blue,fg=white,bold` | `bg=<fg_primary>,fg=<bg_dark>,bold` |
| `@clux-bar-window-inactive-style` | `bg=brightblack,fg=white` | `fg=<fg_primary>` |
| `@clux-bar-bracket-style` | `fg=magenta` | `fg=<bg_accent>` |
| `@clux-bar-separator-style` | `fg=brightblack` | (leave default unless the palette has a muted color) |
| `@clux-bar-window-open` | `❰` | (glyph — never inferred from a palette) |
| `@clux-bar-window-close` | `❱` | (glyph) |
| `@clux-bar-separator` | `│` | (glyph) |
| `@clux-bar-name-length` | `24` | the existing `#{=N:window_name}` truncation width, when the config has one |
| `@clux-agent-busy-color` | `cyan` | `<agent_busy>` |
| `@clux-agent-needs-color` | `yellow` | `<agent_needs>` |
| `@clux-agent-done-color` | `green` | `<agent_done>` |
| `@clux-agent-glyph-busy` | `*` | `<glyph_busy>` |
| `@clux-agent-glyph-needs` | `!` | `<glyph_needs>` |
| `@clux-agent-glyph-done` | `v` | `<glyph_done>` |

The six agent rows matter most on a **migration**. The `@clux-bar-*` palette can
be inferred from the user's styles, but the agent glyph colours usually exist
only as live server state — a hand-written bar hardcoded them in its own
`session-list.sh`, and nothing wrote them to a file. Carry them or the bar
silently reverts to `cyan`/`yellow`/`green` on the next tmux server restart,
long after setup ran and with nothing to point at.

`@clux-agent-glyph-busy-frames` has no flag on purpose: its default holds a
backslash that needs single-quoting, and an animation cadence is not something
detection reads off an old bar. A user who wants it sets it in their own file.

The defaults are tmux **named** colours on purpose, so an 8-colour terminal and an unthemed machine both render readably. `@clux-bar-name-length` must be numeric — `render-clux-conf.sh` refuses a non-numeric value, because a bad `N` corrupts the whole tmux format string `session-list.sh` builds from it.

Also carry the notification colors forward, when a palette was found — these use the **attention** colors, which are designed for high-visibility transient messages:

```tmux
set -g @claude-notify-bg "<bg_attention>"     # e.g. #EBCB8B
set -g @claude-notify-fg "<fg_on_attention>"  # e.g. #2E3440
```

Show the user what was chosen: `Notification style: bg=#EBCB8B fg=#2E3440 (matches your message-style)`.

## Phase 4: Plan the change and show it

Build the plan **and show the exact diff** before anything is written. There are two install modes and one optional migration.

### Mode 1 — bare machine (no tmux.conf anywhere)

Write `${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf` — the XDG path, not `~/.tmux.conf`: it is where tmux 3.x looks first and where clux already looks first. It contains exactly this and nothing else:

```tmux
# tmux.conf — created by /clux:setup.
# clux owns only the source-file line at the bottom of this file. Everything
# else here is a plain starting point: edit it freely, clux will not rewrite it.
set -g status-interval 1
set -g status-left-length 150
set -g monitor-bell on
set -g bell-action any
set -g 'status-format[0]' '#[align=left] #{@clux_session_bar}#[align=centre]#{@clux_status}#[align=right]#(~/.config/clux/scripts/session-bar-refresh.sh quiet #{client_pid}) '
source-file -q ~/.config/clux/clux.tmux.conf
```

- `status-interval 1`: the busy glyph advances one frame per `status-interval`, so `1` gives a ~1fps pulse. The bar is otherwise event-driven — this interval is only the periodic safety net — and a bare-machine install has exactly one `#()` job on the line, so a quiet tick is cheap (about 30ms/s; see the `throttle.sh` note under §3.7 for a job that is not this one).
- The `source-file` line is **last**, so clux's hooks register after the status settings they redraw.
- The result is stock tmux plus a working clux bar and working session keys. Prefix stays `C-b`. Pane keys stay stock.

### Mode 2 — existing config

Exactly one line added, and the two token strings inserted **into the value that already renders**:

1. `source-file -q ~/.config/clux/clux.tmux.conf`, appended near the end of the file (after the status settings it redraws)
2. The session-bar token string, immediately after the first `#[align=left…]` segment's leading field, or at the start of the value when there is none
3. The notification token, immediately before the first `#[align=right]` and prefixed with `#[align=centre]`, or appended to the end of the value when there is none

That is exactly where the currently shipped setup puts `#(show-notification.sh)`, so migrating an existing install is a substitution in place and the live result is visually unchanged.

**The session-bar token string is contiguous text**:

```
#{@clux_session_bar}#(~/.config/clux/scripts/session-bar-refresh.sh quiet #{client_pid})
```

Never insert `#{@clux_session_bar}` alone. tmux does not re-expand a `#()` found inside an option value, so the periodic safety net that keeps the bar fresh between hook-covered events cannot live in clux's own file — it has to be literal text in the rendered status line. It renders zero characters (the `quiet` argument skips the redraw) and goes in as part of the same single edit. `#{client_pid}` lets `session-bar-refresh.sh` key its per-client animation-frame counter — see the animated-busy-glyph note under §3.7.

For a shared setting clux wants but does not own, **report and move on**:

```
clux works best with status-interval at 1: the busy glyph advances one frame
per interval, so 1 gives a ~1fps pulse. Yours is 2 (one frame every two
seconds — still smooth, just slower). No change needed.
```

### Optional migration (only when Agent B found a hand-written session surface)

Show the diff, then offer this as **one confirmed step**:

1. Set the Part 3 options so behaviour stays identical (the detected resolver, editor, agents command, picker).
2. Write `~/.config/clux/clux.tmux.conf` with bindings, hooks and options.
3. Edit tmux.conf: add the source line, replace the session-bar hook block and the clux marker block with the two token strings, and remove the superseded bindings. **Only a line whose command text references one of the superseded script paths is removed** — `switch-session.sh`, `session-reorder.sh`, `fzf-session-switch.sh`, `new-session-prompt.sh`, `new-session.sh`, `session-list.sh`, `session-order.sh`, `session-bar-refresh.sh`, and the six session-bar hooks, each matched **with its old directory** (`tmux/scripts/…`). The directory is load-bearing: clux deploys its own `session-bar-refresh.sh`, and the token string this same run inserts names it, so a bare-filename match would delete the line clux just added. **Never remove a binding by key name alone.** A user binding on `N`, `P`, `{`, `}`, `g` or `A` that points somewhere else is left alone and reported as a conflict, together with where the `source-file` line sits, so the user can see which one wins. `bind-key s` / `C-x choose-tree` and `bind-key W` are untouched — both are outside clux's ownership.
4. Copy the order across, from **live server memory**, before any file is rewritten:
   ```bash
   OLD=$(tmux show-option -gqv @session_order 2>/dev/null)
   NEW=$(tmux show-option -gqv @clux-session-order 2>/dev/null)
   if [ -n "$OLD" ] && [ -z "$NEW" ]; then
       tmux set-option -g @clux-session-order "$OLD"
       echo "migrated order: $OLD"
   elif [ -z "$OLD" ]; then
       echo "no order to migrate"
   else
       echo "@clux-session-order already set ($NEW) — left alone"
   fi
   ```
   Nothing is written to any file. `@session_order` is **left set** and reported as a leftover, never unset: it exists only in server memory (only `session-reorder.sh` ever wrote it) and unsetting it would be clux writing an option it does not own. Gating on an empty destination means a second `/clux:setup` run can never clobber an order the user has since changed. With no server running, report "no order to migrate" and continue. At run time `session-order.sh` reads only `@clux-session-order` — there is no legacy fallback.
5. Delete the eight superseded scripts from `~/.config/tmux/scripts/` — **after** backing them up and **after** re-scanning the rewritten file (Phase 6, step 7).

Also report, never act on:

- **tpm loading `claude-notify.tmux`.** It sets the same `[90]` hooks pointing at the tpm plugin cache rather than `~/.config/clux/scripts/`, possibly a different version. clux.tmux.conf always writes the `[90]` hooks pointing at `~/.config/clux/scripts/`. Recommend removing the tpm line, but **never remove it** — it lives in the user's file, not clux's. The commands are functionally identical, so whichever loads last is correct either way; the hazard is version skew, not breakage.

### When setup must refuse

Refusing and explaining is a correct outcome. Guessing is not. Refuse when:

- **The status line cannot be located with confidence** — the live render site maps back to zero config lines, or to more than one. Report which lines matched and stop.
- **The configuration is generated by another tool** (a header saying so, a `# DO NOT EDIT` banner, a dotfile manager's marker). Report it and stop.
- Verification fails after writing — restore the backup and say so (Phase 6, step 8).

## Phase 5: Confirm

Use AskUserQuestion to confirm before making **any** change. Show the exact diff — the one added line, the two token insertions in context, and (when migrating) every line that will be removed with the script path that justifies removing it.

Options:
- "Apply all changes" (Recommended)
- "Apply without the migration" (only when a migration was offered — installs clux beside the hand-written scripts, changes no existing line)
- "Cancel"

## Phase 6: Apply

Run these **in order**. Steps 1–2 must finish before step 3, and step 8 gates everything.

### 1. Back up

```bash
mkdir -p ~/.config/clux/backups
[ -f "$TMUX_CONF" ] && cp "$TMUX_CONF" ~/.config/clux/backups/tmux.conf.$(date +%Y%m%d_%H%M%S)
ls -1t ~/.config/clux/backups/tmux.conf.* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
```

Keep the exact backup path — steps 8 and the summary both need it.

### 2. Deploy the scripts (from the manifest, never from a list written here)

Every Bash call is a fresh shell, so re-run snippets S1 and S2 in the same call that uses them — `PLUGIN_SCRIPTS_DIR`, `MANIFEST` and `manifest_scripts` do not survive from Phase 1's subagents.

```bash
DEPLOY_DIR="$HOME/.config/clux/scripts"
mkdir -p "$DEPLOY_DIR"
for script in $(manifest_scripts); do
    cp "$PLUGIN_SCRIPTS_DIR/$script" "$DEPLOY_DIR/$script"
    chmod +x "$DEPLOY_DIR/$script"
done
echo "deployed: $(manifest_scripts | wc -l | tr -d ' ') scripts"
```

### 3. Write clux's own file

Call the renderer — never write `clux.tmux.conf` by hand. It emits the six sections in order: header, the Part 3 answers, the theming lines it was actually given, the ten bind-key lines, the 90–99 hooks, and a closing `agent-clear.sh --reap` plus one `session-bar-refresh.sh` so the bar it seeds carries no marks left over from a previous server.

```bash
"$PLUGIN_SCRIPTS_DIR/render-clux-conf.sh" \
    --dir-resolver "<3.1 answer>" \
    --editor "<3.2 answer>" \
    --agents-command "<3.3 answer, verbatim>" \
    --picker "<3.4 answer>" \
    --agent-refresh-command "run-shell -b $HOME/.config/clux/scripts/session-bar-refresh.sh" \
    --bar-name-attached-style "<only when detection found it>" \
    --bar-name-length "<only when detection found it>" \
    --agent-needs-color "<only when detection found it>" \
    --agent-busy-color "<only when detection found it>"
```

- Pass `--agent-refresh-command` **only** when 3.5 was "Yes".
- Pass a `--bar-*` or `--agent-*` flag **only** for a value detection actually found.
- `$PWD` inside the agents command must reach the option **unexpanded**; the renderer single-quotes the value for exactly that reason, so pass it through verbatim and do not pre-expand it.
- The renderer writes no `@clux-session-order`, `@clux_session_bar` or `@clux_status` line. Those three are live server state, and a `set -g` for any of them would reset it on every reload — which for `@clux-session-order` is exactly the failure the reorder keys exist to prevent.

### 4. Edit the user's tmux.conf

Use the Edit tool on the single line Agent B identified, and on that line only:

- Insert the two token strings at the positions Phase 4 fixed.
- When migrating, replace the legacy `#(…/show-notification.sh)` call with `#{@clux_status}` **in place** — same position, so the bar looks the same.
- Append the `source-file -q ~/.config/clux/clux.tmux.conf` line.
- When migrating, remove only lines matched by script path.

**Every other line in the file must stay byte-identical.** That is the whole requirement, and it is what the corpus test asserts.

If clux markers already exist, replace the content between them rather than adding a second block. If the source line, both tokens and the `quiet` job are already present exactly once each, **make no edit at all** and report the file as already configured — a second run must change nothing.

### 5. Migrate the session order

Run the live-server read-and-set from Phase 4, step 4. Report what happened.

### 6. Update system hooks in `~/.claude/settings.json`

The plugin's `hooks.json` registers `notify-tmux.sh` for Stop, Notification, UserPromptSubmit and SessionEnd. Any system-level hook in `settings.json` for those same events is redundant and causes double-firing (double sounds, sounds when the user disabled them).

1. Remove `hooks.Stop`, `hooks.Notification` and `hooks.UserPromptSubmit` entries.
2. Remove a `hooks.SessionEnd` entry that points at `notify-tmux.sh` (a duplicate of hooks.json); **keep** every other user `SessionEnd` command.
3. Preserve all other hook entries and all non-hook settings, and the file's existing 2-space indent.
4. If the hooks object ends up empty, keep it as `"hooks": {}`.
5. Use the **Edit** tool, not Write — this file changes concurrently.

Report it plainly:
```
System hooks (settings.json):
  Remove: Stop (afplay Glass.aiff) — handled by plugin notify-sound.sh
  Remove: Notification (afplay Submarine.aiff) — handled by plugin notify-sound.sh
  Remove: UserPromptSubmit (afplay Pop.aiff) — handled by plugin notify-sound.sh
  Keep:   SessionEnd (user) (afplay Hero.aiff) — preserved alongside clux's own SessionEnd entry
```

### 7. Migration: back up, re-scan, then delete the superseded scripts

Only when the user confirmed the migration. **Back up first, re-scan second, delete last.**

```bash
STAMP=$(date +%Y%m%d_%H%M%S)
BAK="$HOME/.config/clux/backups/tmux-scripts-$STAMP"
mkdir -p "$BAK"
OLD_DIR="$HOME/.config/tmux/scripts"
SUPERSEDED="session-order.sh session-list.sh session-reorder.sh switch-session.sh
            session-bar-refresh.sh fzf-session-switch.sh new-session.sh new-session-prompt.sh"

for s in $SUPERSEDED; do
    [ -f "$OLD_DIR/$s" ] && cp "$OLD_DIR/$s" "$BAK/$s"
done

# Re-scan the REWRITTEN tmux.conf. The worst outcome of this step is a
# half-applied edit that leaves a live reference to a file the same run just
# deleted, so refuse per script rather than trusting step 4 succeeded.
#
# Match "$OLD_DIR/$s", never the bare filename: clux deploys its own
# session-bar-refresh.sh to ~/.config/clux/scripts/, and the token string this
# run just inserted names it. A bare-filename match would see that line, refuse
# every time, and the migration could never finish.
for s in $SUPERSEDED; do
    [ -f "$OLD_DIR/$s" ] || continue
    if grep -q "tmux/scripts/$s" "$TMUX_CONF"; then
        echo "REFUSED $s — still referenced by $TMUX_CONF"
    else
        rm -f "$OLD_DIR/$s"
        echo "deleted  $s (backed up in $BAK)"
    fi
done

# Same 5-generation prune as the tmux.conf backups.
ls -1dt "$HOME"/.config/clux/backups/tmux-scripts-* 2>/dev/null | tail -n +6 | xargs rm -rf 2>/dev/null
```

The config repo copy (`404pilo/config`) is **not** touched. Committing the slimmed tmux.conf there stays the user's own step — say so.

### 8. Verify, and restore on failure

```bash
# Redirect to a FILE. Never capture this with $( ) — verify-tmux-conf.sh
# attaches a throwaway control client in the BACKGROUND, and a command
# substitution waits for every writer on the pipe, so it can block on that
# client rather than on the verify, which finishes in a fraction of a second.
# A file redirect gives the background client a file to hold instead.
LOG=$(mktemp -t clux-verify)
"$PLUGIN_SCRIPTS_DIR/verify-tmux-conf.sh" "$HOME/.config/clux/clux.tmux.conf" >"$LOG" 2>&1 </dev/null
CLUX_STATUS=$?
[ "$CLUX_STATUS" -eq 0 ] && echo "OK  clux.tmux.conf parses" || { echo "FAIL clux.tmux.conf:"; cat "$LOG"; }

"$PLUGIN_SCRIPTS_DIR/verify-tmux-conf.sh" "$TMUX_CONF" >"$LOG" 2>&1 </dev/null
CONF_STATUS=$?
[ "$CONF_STATUS" -eq 0 ] && echo "OK  tmux.conf parses" || { echo "FAIL tmux.conf:"; cat "$LOG"; }
rm -f "$LOG"
```

`verify-tmux-conf.sh` parses the candidate for real on a throwaway `-L` socket, so it cannot disturb a live session, and it returns tmux's own error message on failure.

Verification must run **after** step 2. `clux.tmux.conf` ends with a synchronous `run-shell …/session-bar-refresh.sh`, so a config that is perfectly correct still fails to parse while the scripts are not yet deployed — the reported error is `'…/session-bar-refresh.sh' returned 127`. Deploy first, render second, verify last, which is the order above.

**If either verification fails**: restore the backup from step 1, re-source it, and say so plainly — which file failed, tmux's exact error, and that the backup is back in place. Do not attempt a second edit.

```bash
cp "<backup_path>" "$TMUX_CONF" && tmux source-file "$TMUX_CONF" 2>/dev/null
```

## Phase 7: Confirm it actually works

```bash
DEPLOY_DIR="$HOME/.config/clux/scripts"

# Reload and redraw
tmux source-file "$TMUX_CONF" 2>/dev/null
tmux refresh-client -S 2>/dev/null

# The one line, exactly once
grep -c "source-file -q .*clux.tmux.conf" "$TMUX_CONF"

# Each token exactly once. -F because the tokens contain { } and #.
grep -F -o '#{@clux_session_bar}' "$TMUX_CONF" | wc -l
grep -F -o '#{@clux_status}' "$TMUX_CONF" | wc -l
grep -F -o 'session-bar-refresh.sh quiet' "$TMUX_CONF" | wc -l

# The options resolve on the live server
for opt in @clux-dir-resolver @clux-editor @clux-agents-command @clux-picker; do
    printf '%s = %s\n' "$opt" "$(tmux show-option -gqv "$opt")"
done

# The runtime strings are being rendered into (non-empty means the bar is live)
[ -n "$(tmux show-option -gqv @clux_session_bar)" ] && echo "OK  @clux_session_bar rendered" || echo "WARN @clux_session_bar empty"
[ -n "$(tmux show-option -gqv @clux_status)" ] || echo "INFO @clux_status empty (no notification pending — expected)"

# All ten keys
tmux list-keys 2>/dev/null | grep -E "switch-session|session-reorder|session-picker|new-workspace-prompt|jump-to-notification|dismiss-notification|notification-picker"

# The hook band
tmux show-hooks -g 2>/dev/null | grep -E "\[90\]|\[91\]"

# No conflicting system hooks left
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

Report pass or fail for each check. A count other than `1` for the source line or for any token is a **failure**, not a warning — it means the edit landed twice or not at all.

## Phase 8: Summary

Show the user:

- **What changed**: the one added line and the two token insertions (quote them), plus `settings.json` if it was touched
- **What clux deliberately did not change**: `status-interval` and every other shared setting, the prefix key, pane keys, copy mode, the clipboard, resurrect, and any binding on a clux key that points elsewhere
- **The answers now in force**, and where to change each one:
  ```
  @clux-dir-resolver    autojump
  @clux-editor          nvim
  @clux-agents-command  claude agents --cwd "$PWD"
  @clux-picker          fzf
  ```
  Changing a choice later means re-running `/clux:setup` or setting the option — never editing a script.
- **Scripts deployed**: the count from the manifest, at `~/.config/clux/scripts/`
- **Migration results**, when it ran: which lines were removed and which script path justified each one; which scripts were deleted and which were refused; where the script backup is; that `@session_order` was copied and is **left set** as a reported leftover; that the `404pilo/config` repo copy is untouched and committing it is the user's own step
- **Anything reported but not acted on**: a tpm `claude-notify.tmux` load, a conflicting binding, a shared setting clux recommends
- **Backup location and rollback**: `cp <backup_path> <tmux_conf> && tmux source-file <tmux_conf>`
- **Key quick reference**:
  ```
  prefix + N / P   next / previous session, in bar order
  prefix + { / }   move this session left / right in the bar
  prefix + g       session picker with pane preview
  prefix + A       new Claude workspace (name, then folder)
  prefix + m       jump to the notifying agent
  prefix + M       notification picker
  prefix + ` /DC   dismiss notification
  ```
- Suggest running `/clux:validate` for the full health check
