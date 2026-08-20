---
description: Validate clux tmux setup — comprehensive read-only health check
allowed-tools: Read, Bash, Glob, Grep, Task
---

# clux Validate: Health Check

You are validating the user's clux integration — the notification surface **and** the session surface. This is **read-only** — never modify any files.

**Use subagents (Task tool) to parallelize independent checks.** Launch all four agents concurrently.

## Snippet S1: resolve the plugin source root

Several agents need this. Pass it verbatim into each agent prompt — one copy, so no two agents can drift apart.

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
PLUGIN_DIR="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts}"
MANIFEST="${PLUGIN_ROOT:+$PLUGIN_ROOT/config/deploy-manifest.txt}"
[ -f "$MANIFEST" ] || MANIFEST=""
```

## Snippet S2: read the deploy manifest

```bash
# One script per line, comments and blank lines skipped. This is the ONLY list
# of deployed scripts. Never write a literal list into this file — that is the
# bug CHANGELOG 3.0.9 recorded (path.sh in one hand-written list, not the other).
manifest_scripts() {
    grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$'
}
```

## Snippet S3: find the user's tmux.conf

```bash
TMUX_CONF=""
for f in "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" "$HOME/.tmux.conf"; do
    [ -f "$f" ] && { TMUX_CONF="$f"; break; }
done
```

## Phase 1: Gather Data (use subagents in parallel)

Launch **four subagents concurrently** using the Task tool with `subagent_type: "general-purpose"`.

Every Bash call is a fresh shell. Each agent must re-run the snippets it needs **in the same call** as the check that uses them — `PLUGIN_DIR`, `MANIFEST`, `TMUX_CONF` and `manifest_scripts` do not carry over between calls.

### Agent A: Environment & Scripts

Prompt the agent to run these checks and return structured results. Do NOT modify any files. Give it snippets S1 and S2.

1. **tmux running**: `tmux info &>/dev/null && echo "OK" || echo "FAIL"`
2. **tmux version**: `tmux -V`
3. **Deploy manifest present**:
   ```bash
   [ -n "$MANIFEST" ] && echo "OK  deploy manifest ($MANIFEST, $(manifest_scripts | wc -l | tr -d ' ') scripts)" \
                      || echo "FAIL deploy manifest not found — cannot check the deployed set"
   ```
4. **Deployed scripts** — every script the manifest names must exist and be executable at `~/.config/clux/scripts/`:
   ```bash
   DEPLOY_DIR="$HOME/.config/clux/scripts"
   for script in $(manifest_scripts); do
       if [ -x "$DEPLOY_DIR/$script" ]; then
           echo "OK  $script"
       elif [ -f "$DEPLOY_DIR/$script" ]; then
           echo "WARN $script (not executable)"
       else
           echo "FAIL $script (missing — run /clux:setup)"
       fi
   done
   ```
5. **Scripts in sync** — compare each manifest script's checksum with the plugin source:
   ```bash
   [ -n "$PLUGIN_DIR" ] || echo "WARN plugin source not found — skipping sync check"
   DEPLOY_DIR="$HOME/.config/clux/scripts"
   for script in $(manifest_scripts); do
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
6. **Setup-time scripts** — these are deliberately NOT in the manifest and are never deployed; they must exist in the plugin source:
   ```bash
   for script in render-clux-conf.sh verify-tmux-conf.sh; do
       [ -f "$PLUGIN_DIR/$script" ] && echo "OK  $script (plugin source)" \
                                    || echo "FAIL $script missing from plugin source"
   done
   ```
7. **Dependencies**:
   ```bash
   command -v jq &>/dev/null && echo "OK  jq" || echo "WARN jq (missing)"
   command -v fzf &>/dev/null && echo "OK  fzf" || echo "INFO fzf (missing — pickers fall back to choose-tree)"
   command -v flock &>/dev/null && echo "OK  flock" || echo "INFO flock (unavailable — using mkdir fallback)"
   ```
8. **Notification directory writable**:
   ```bash
   NOTIFY_DIR="$HOME/.config/tmux"
   [ -d "$NOTIFY_DIR" ] && [ -w "$NOTIFY_DIR" ] && echo "OK  notification dir writable" || echo "FAIL notification dir not writable ($NOTIFY_DIR)"
   ```
9. Return all results with clear OK/FAIL/WARN/INFO prefixes.

### Agent B: tmux Configuration

Prompt the agent to run these checks and return structured results. Do NOT modify any files.

1. **Notification render site** — the token is the current wiring; a `#(…/show-notification.sh)` call is the pre-3.3 wiring and still works:
   ```bash
   FMT=$(tmux show-option -g 'status-format[0]' 2>/dev/null)
   LEFT=$(tmux show-option -gv status-left 2>/dev/null)
   RIGHT=$(tmux show-option -gv status-right 2>/dev/null)
   ALL="$FMT
   $LEFT
   $RIGHT"
   if printf '%s' "$ALL" | grep -Fq '#{@clux_status}'; then
       echo "OK  notification token #{@clux_status} in the status line"
   elif printf '%s' "$ALL" | grep -q "show-notification.sh"; then
       echo "INFO notification wired the pre-3.3 way (#(…/show-notification.sh)) — works; /clux:setup migrates it to #{@clux_status}"
       if printf '%s' "$ALL" | grep -q "\.config/clux/scripts/"; then
           echo "OK  uses stable deploy path"
       else
           echo "WARN references plugin cache path (should use ~/.config/clux/scripts/)"
       fi
   else
       echo "FAIL no notification in the status display (neither #{@clux_status} nor show-notification.sh)"
   fi
   ```
2. **status-interval** — clux never writes this; the bar is event-driven, so the interval is only a safety net:
   ```bash
   INTERVAL=$(tmux show-option -gv status-interval 2>/dev/null)
   if [ "${INTERVAL:-15}" -ge 1 ] && [ "${INTERVAL:-15}" -le 2 ]; then
       echo "OK  status-interval ($INTERVAL)"
   elif [ "${INTERVAL:-15}" -le 5 ]; then
       echo "WARN status-interval ($INTERVAL — clux works best at 1 or 2)"
   else
       echo "WARN status-interval ($INTERVAL — the safety-net redraw is slow; clux works best at 1 or 2. clux will not change this for you)"
   fi
   ```
3. **status-left-length**:
   ```bash
   LENGTH=$(tmux show-option -gv status-left-length 2>/dev/null)
   if [ "${LENGTH:-10}" -ge 100 ]; then
       echo "OK  status-left-length ($LENGTH)"
   else
       echo "WARN status-left-length ($LENGTH — recommend 150, the session list may be truncated)"
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
7. **Audio playback readiness** — confirm a player is installed and configured sound files exist. Prefer the plugin source for helpers (it always has the latest API) so older deployed copies don't break this step. Use snippet S1, then:
   ```bash
   HELPERS="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/helpers.sh}"
   [ -f "$HELPERS" ] || HELPERS="$HOME/.config/clux/scripts/helpers.sh"
   if [ -f "$HELPERS" ] && grep -q '^detect_sound_player' "$HELPERS"; then
       # shellcheck disable=SC1090
       source "$HELPERS"
       PLAYER=$(detect_sound_player)
       ANY_SOUND_ON=0
       for TYPE in notification stop prompt; do
           [ "$(get_notification_sound_enabled "$TYPE")" = "on" ] && ANY_SOUND_ON=1
       done
       if [ -n "$PLAYER" ]; then
           echo "OK  audio player ($PLAYER)"
       elif [ "$ANY_SOUND_ON" = "1" ]; then
           echo "WARN sound enabled but no audio player found (install paplay/aplay/play/ffplay on Linux, or afplay on macOS)"
       else
           echo "INFO no audio player detected (sound defaults to off on this system)"
       fi
       for TYPE in notification stop prompt; do
           if [ "$(get_notification_sound_enabled "$TYPE")" = "on" ]; then
               FILE=$(get_notification_sound_file "$TYPE")
               if [ -z "$FILE" ]; then
                   echo "WARN ${TYPE}: sound enabled but no sound file resolved"
               elif [ -f "$FILE" ]; then
                   echo "OK  ${TYPE} sound file ($FILE)"
               else
                   echo "WARN ${TYPE} sound file missing ($FILE) — set @claude-notify-${TYPE}-sound-file or install the default"
               fi
           fi
       done
   else
       echo "INFO helpers.sh missing or outdated — skipping audio playback check (run /clux:setup to redeploy)"
   fi
   ```
8. **Keybindings** — all ten clux keys. Match on the **script path**, never on the key name: a key name alone cannot tell clux's binding from a user binding that happens to share the key.
   ```bash
   KEYS=$(tmux list-keys 2>/dev/null)
   check_key() {  # check_key <label> <script fragment>
       echo "$KEYS" | grep -q "$2" && echo "OK  $1" || echo "FAIL $1 (no binding runs $2)"
   }
   check_key "prefix N / P  (next / previous session)" "switch-session.sh"
   check_key "prefix { / }  (move session in the bar)" "session-reorder.sh"
   check_key "prefix g      (session picker)"          "session-picker.sh"
   check_key "prefix A      (new Claude workspace)"    "new-workspace-prompt.sh"
   check_key "prefix m      (jump to notification)"    "jump-to-notification.sh"
   check_key "prefix \` / DC (dismiss notification)"    "dismiss-notification.sh"
   check_key "prefix M      (notification picker)"     "notification-picker.sh"
   ```
9. Return all results with clear OK/FAIL/WARN/INFO prefixes.

### Agent C: Hooks Validation

Prompt the agent to run these checks and return structured results. Do NOT modify any files. Give it snippet S1.

1. **Plugin hooks.json** — locate and validate:
   ```bash
   HOOKS_FILE="${PLUGIN_ROOT:+$PLUGIN_ROOT/hooks/hooks.json}"
   # PLUGIN_ROOT is resolved from scripts/show-notification.sh, so a tree that
   # carries the scripts but not the hooks (a partially synced cache, a deployed
   # copy) yields a non-empty HOOKS_FILE that does not exist. Empty it here so the
   # not-found branch below still fires.
   [ -f "$HOOKS_FILE" ] || HOOKS_FILE=""
   if [ -z "$HOOKS_FILE" ]; then
       echo "FAIL plugin hooks.json not found"
   else
       echo "OK  hooks.json found ($HOOKS_FILE)"
       for EVENT in Stop Notification UserPromptSubmit SessionEnd; do
           if grep -q "\"$EVENT\"" "$HOOKS_FILE" && grep -q "notify-tmux" "$HOOKS_FILE"; then
               echo "OK  hook: $EVENT → notify-tmux.sh"
           else
               echo "FAIL hook: $EVENT not configured in hooks.json"
           fi
       done
       # Agent-state second command, registered beside notify-tmux.sh on the SAME
       # four events — no new event name (see CHANGELOG 3.1.0). Each pair below
       # must appear verbatim in hooks.json.
       for PAIR in "UserPromptSubmit:busy" "Notification:needs-you" "Stop:finished" "SessionEnd:remove"; do
           EVENT="${PAIR%%:*}"
           ARG="${PAIR#*:}"
           if grep -q "\"$EVENT\"" "$HOOKS_FILE" && grep -q "agent-state.sh $ARG" "$HOOKS_FILE"; then
               echo "OK  hook: $EVENT → agent-state.sh $ARG"
           else
               echo "FAIL hook: $EVENT not wired to agent-state.sh $ARG in hooks.json"
           fi
       done
   fi
   ```
2. **Hook scripts executable**:
   ```bash
   HOOKS_DIR=$(dirname "$HOOKS_FILE")
   for script in notify-tmux.sh agent-state.sh; do
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
3. **tmux hooks, band 90–99** — clux reserves this band. `[90]` clears a finished mark before `[91]` renders the bar, so the cleared state reaches the bar in the same pass:
   ```bash
   HOOKS_OUT=$(tmux show-hooks -g 2>/dev/null)
   for EVENT in after-select-window client-session-changed; do
       if printf '%s' "$HOOKS_OUT" | grep -q "$EVENT\[90\]" && printf '%s' "$HOOKS_OUT" | grep -q "agent-clear.sh"; then
           echo "OK  $EVENT[90] → agent-clear.sh"
       else
           echo "WARN $EVENT[90] missing — finished marks will not clear on their own (run /clux:setup)"
       fi
   done
   for EVENT in client-session-changed after-select-window session-created session-closed window-linked window-unlinked; do
       if printf '%s' "$HOOKS_OUT" | grep -q "$EVENT\[91\]"; then
           echo "OK  $EVENT[91] → session-bar-refresh.sh"
       else
           echo "WARN $EVENT[91] missing — the bar lags this event until the next status-interval tick"
       fi
   done
   # An unindexed user hook writes index 0, so the two sides cannot drop each
   # other. Report anything else already sitting in clux's band.
   printf '%s' "$HOOKS_OUT" | grep -E "\[9[2-9]\]" && echo "WARN something occupies clux's reserved 92-99 band"
   ```
4. **No conflicting system hooks** — check `~/.claude/settings.json`:
   ```bash
   SETTINGS="$HOME/.claude/settings.json"
   if [ -f "$SETTINGS" ]; then
       CONFLICTS=""
       for EVENT in Stop Notification UserPromptSubmit SessionEnd; do
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
5. Return all results with clear OK/FAIL/WARN/INFO prefixes.

### Agent D: clux Session Surface

Prompt the agent to run these checks and return structured results. Do NOT modify any files. Give it snippets S1 and S3.

1. **clux owns one file — it must exist and parse**:
   ```bash
   CLUX_CONF="$HOME/.config/clux/clux.tmux.conf"
   if [ ! -f "$CLUX_CONF" ]; then
       echo "FAIL $CLUX_CONF missing — run /clux:setup"
   else
       echo "OK  clux.tmux.conf present ($CLUX_CONF)"
       # verify-tmux-conf.sh parses the file for real on a throwaway -L socket,
       # so it cannot disturb a live session. Read-only by construction.
       #
       # Redirect to a FILE. Never capture it with $( ): the script attaches a
       # throwaway control client whose stdin is held open by a background
       # `tail -f /dev/null`, and that process outlives the script. A command
       # substitution waits for every writer on the pipe, so it blocks forever
       # on the leftover tail even though the verify finished immediately.
       if [ -x "$PLUGIN_DIR/verify-tmux-conf.sh" ]; then
           LOG=$(mktemp -t clux-verify)
           "$PLUGIN_DIR/verify-tmux-conf.sh" "$CLUX_CONF" >"$LOG" 2>&1 </dev/null
           if [ $? -eq 0 ]; then
               echo "OK  clux.tmux.conf parses"
           else
               # "returned 127" here means a deployed script is missing, not a
               # syntax error — clux.tmux.conf ends by running
               # session-bar-refresh.sh. Agent A's check says which one.
               echo "FAIL clux.tmux.conf does not parse: $(cat "$LOG")"
           fi
           rm -f "$LOG"
       else
           echo "INFO verify-tmux-conf.sh not available — skipping the parse check"
       fi
       # It must never carry live server state.
       grep -qE '^[[:space:]]*set(-option)?[[:space:]].*@clux-session-order' "$CLUX_CONF" \
           && echo "FAIL clux.tmux.conf sets @clux-session-order — a reload would undo every reorder"
       grep -qE '^[[:space:]]*set(-option)?[[:space:]].*@clux_(session_bar|status)' "$CLUX_CONF" \
           && echo "FAIL clux.tmux.conf sets a runtime @clux_* string — a reload would render a stale bar"
   fi
   ```
2. **The one line, exactly once** in the user's tmux.conf:
   ```bash
   if [ -z "$TMUX_CONF" ]; then
       echo "FAIL no tmux.conf found (~/.config/tmux/tmux.conf or ~/.tmux.conf)"
   else
       N=$(grep -c "source-file .*clux\.tmux\.conf" "$TMUX_CONF")
       case "$N" in
           1) echo "OK  source-file line present exactly once ($TMUX_CONF)" ;;
           0) echo "FAIL source-file line for clux.tmux.conf missing — run /clux:setup" ;;
           *) echo "FAIL source-file line for clux.tmux.conf appears $N times — remove the duplicates" ;;
       esac
   fi
   ```
3. **Both tokens, exactly once each.** The corpus invariant counts the three pieces separately, not the token strings as opaque units — `#{@clux_session_bar}` is always followed by the `quiet` job, but they are counted apart so a half-inserted edit is visible:
   ```bash
   # -F: the tokens contain #, { and }, none of which may be read as a pattern.
   count_tok() {  # count_tok <label> <literal> <required>
       N=$(grep -F -o "$2" "$TMUX_CONF" 2>/dev/null | wc -l | tr -d ' ')
       if [ "$N" = "1" ]; then
           echo "OK  $1 present exactly once"
       elif [ "$N" = "0" ]; then
           if [ "$3" = "required" ]; then
               echo "FAIL $1 missing from $TMUX_CONF"
           else
               echo "INFO $1 not present (this install keeps its own session bar)"
           fi
       else
           echo "FAIL $1 appears $N times — the status line will render it $N times"
       fi
   }
   count_tok "#{@clux_status}"                     '#{@clux_status}'                   required
   count_tok "#{@clux_session_bar}"                '#{@clux_session_bar}'              optional
   count_tok "session-bar-refresh.sh quiet"        'session-bar-refresh.sh quiet'      optional

   # A hand-written bar calls a session-bar-refresh.sh of its own, from
   # ~/.config/tmux/scripts/. That satisfies the bare count above while running
   # the wrong script entirely, so confirm the job clux relies on is clux's.
   if grep -Fq 'session-bar-refresh.sh quiet' "$TMUX_CONF" \
      && ! grep -Fq 'clux/scripts/session-bar-refresh.sh quiet' "$TMUX_CONF"; then
       echo "WARN the 'quiet' refresh job does not point at ~/.config/clux/scripts/ — it is a hand-written copy, not clux's"
   fi
   ```
   `#{@clux_session_bar}` and `session-bar-refresh.sh quiet` must **agree**: one present without the other is a FAIL. With the token but no `quiet` job the bar only updates on a hooked event and never recovers from a missed one; with the job but no token nothing renders at all.
4. **The runtime strings are actually being rendered into**:
   ```bash
   BAR=$(tmux show-option -gqv @clux_session_bar 2>/dev/null)
   if [ -n "$BAR" ]; then
       echo "OK  @clux_session_bar rendered ($(printf '%s' "$BAR" | wc -c | tr -d ' ') bytes)"
   else
       echo "WARN @clux_session_bar empty — session-bar-refresh.sh has not run, or it failed"
   fi
   # Empty here is normal: it means no notification is pending.
   echo "INFO @clux_status: $(tmux show-option -gqv @clux_status 2>/dev/null | head -c 60)"
   ```
5. **The Part 3 options resolve, and the tool each one names still exists.** The option is a setup-time answer; the binary is a per-machine fact that can change afterwards, so check both:
   ```bash
   RESOLVER=$(tmux show-option -gqv @clux-dir-resolver); RESOLVER="${RESOLVER:-path}"
   case "$RESOLVER" in
       path) echo "OK  @clux-dir-resolver (path)" ;;
       autojump|zoxide)
           if command -v "$RESOLVER" >/dev/null 2>&1; then
               echo "OK  @clux-dir-resolver ($RESOLVER, binary present)"
           else
               echo "WARN @clux-dir-resolver ($RESOLVER) but no $RESOLVER on PATH — prefix + A degrades to plain path mode"
           fi ;;
       *) echo "WARN @clux-dir-resolver ($RESOLVER) is not one of autojump|zoxide|path" ;;
   esac

   EDITOR_OPT=$(tmux show-option -gqv @clux-editor)
   if [ -z "$EDITOR_OPT" ]; then
       echo "INFO @clux-editor unset (run-time ladder: nvim, then vim, then none)"
   elif [ "$EDITOR_OPT" = "none" ]; then
       echo "OK  @clux-editor (none — the '---' window opens a shell)"
   elif command -v "${EDITOR_OPT%% *}" >/dev/null 2>&1; then
       echo "OK  @clux-editor ($EDITOR_OPT)"
   else
       echo "WARN @clux-editor ($EDITOR_OPT) is not on PATH — the '---' window will show a command-not-found"
   fi

   AGENTS=$(tmux show-option -gqv @clux-agents-command)
   [ -n "$AGENTS" ] && echo "OK  @clux-agents-command ($AGENTS)" \
                    || echo "INFO @clux-agents-command (using default: claude agents --cwd \"\$PWD\")"
   case "$AGENTS" in
       *--allow-dangerously-skip-permissions*)
           echo "INFO @clux-agents-command carries --allow-dangerously-skip-permissions (confirmed during /clux:setup)" ;;
   esac
   # The literal $PWD must have survived into the option, not been expanded at
   # set-option time. An expanded value pins every workspace to one directory.
   case "$AGENTS" in
       *'$PWD'*|*'$(pwd)'*|'') : ;;
       *"$HOME"*) echo "WARN @clux-agents-command contains an expanded home path — \$PWD was expanded when the option was written" ;;
   esac

   PICKER=$(tmux show-option -gqv @clux-picker); PICKER="${PICKER:-fzf}"
   if [ "$PICKER" = "choose-tree" ]; then
       echo "OK  @clux-picker (choose-tree)"
   elif command -v fzf-tmux >/dev/null 2>&1 || command -v fzf >/dev/null 2>&1; then
       echo "OK  @clux-picker (fzf, binary present)"
   else
       echo "WARN @clux-picker (fzf) but neither fzf-tmux nor fzf is on PATH — prefix + g falls back to choose-tree"
   fi

   REFRESH=$(tmux show-option -gqv @clux-agent-refresh-command)
   if [ -z "$REFRESH" ]; then
       echo "INFO @clux-agent-refresh-command (using default: refresh-client -S)"
   else
       echo "OK  @clux-agent-refresh-command ($REFRESH)"
       # The value is expanded UNQUOTED and word-split into a tmux command, so
       # a ~ never gets expanded and an argument containing a space breaks it.
       case "$REFRESH" in
           *"~"*) echo "WARN @clux-agent-refresh-command contains ~ — it is word-split, not shell-expanded; use an absolute path" ;;
       esac
   fi
   ```
6. **Session order** (INFO — empty is the correct default and means creation order):
   ```bash
   ORDER=$(tmux show-option -gqv @clux-session-order)
   [ -n "$ORDER" ] && echo "INFO @clux-session-order ($ORDER)" \
                   || echo "INFO @clux-session-order empty (creation order — the default)"
   LEGACY_ORDER=$(tmux show-option -gqv @session_order 2>/dev/null)
   [ -n "$LEGACY_ORDER" ] && echo "INFO @session_order still set ($LEGACY_ORDER) — a leftover clux never unsets; nothing reads it"
   ```
7. **Bar theming options** — effective values (INFO; every one has a working default):
   ```bash
   for OPT in @clux-bar-name-length:24 \
              @clux-bar-name-attached-style:'bg=magenta,fg=black,bold' \
              @clux-bar-name-detached-style:'fg=magenta' \
              @clux-bar-window-active-style:'bg=blue,fg=white,bold' \
              @clux-bar-window-inactive-style:'bg=brightblack,fg=white' \
              @clux-bar-bracket-style:'fg=magenta' \
              @clux-bar-separator-style:'fg=brightblack' \
              @clux-bar-window-open:'❰' @clux-bar-window-close:'❱' @clux-bar-separator:'│'; do
       NAME="${OPT%%:*}"
       DEFAULT="${OPT#*:}"
       VAL=$(tmux show-option -gqv "$NAME")
       [ -n "$VAL" ] && echo "OK  $NAME ($VAL)" || echo "INFO $NAME (using default: $DEFAULT)"
   done
   # A non-numeric name length corrupts the whole #{=N:...} format string, so
   # session-list.sh falls back to 24. Say so rather than letting it look applied.
   LEN=$(tmux show-option -gqv @clux-bar-name-length)
   case "${LEN:-24}" in
       ''|*[!0-9]*) echo "WARN @clux-bar-name-length ($LEN) is not numeric — session-list.sh falls back to 24" ;;
   esac
   ```
8. **Agent state options and state dir** — shared with the notification surface, one source of truth for both:
   ```bash
   for OPT in @clux-agent-glyph-busy:'*' @clux-agent-glyph-needs:'!' @clux-agent-glyph-done:v \
              @clux-agent-busy-color:cyan @clux-agent-needs-color:yellow @clux-agent-done-color:green \
              @clux-agent-state-dir:"\${XDG_STATE_HOME:-\$HOME/.local/state}/clux/agents"; do
       NAME="${OPT%%:*}"
       DEFAULT="${OPT#*:}"
       VAL=$(tmux show-option -gqv "$NAME")
       [ -n "$VAL" ] && echo "OK  $NAME ($VAL)" || echo "INFO $NAME (using default: $DEFAULT)"
   done
   STATE_DIR=$(tmux show-option -gqv @clux-agent-state-dir)
   [ -n "$STATE_DIR" ] || STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/clux/agents"
   [ -d "$STATE_DIR" ] && echo "OK  agent state dir exists ($STATE_DIR)" || echo "INFO agent state dir not yet created ($STATE_DIR — created on first hook fire)"
   # State files sit one level down, under a directory named for the tmux
   # server that owns the pane — a pane id repeats across servers, so it is not
   # a key on its own. Report THIS server's directory: "the root exists but
   # holds nothing of mine" is the state a puzzled user is actually in.
   SRV=$(tmux display-message -p '#{pid}-#{start_time}' 2>/dev/null)
   if [ -n "$SRV" ]; then
       if [ -d "$STATE_DIR/$SRV" ]; then
           echo "OK  this tmux server's store ($STATE_DIR/$SRV, $(find "$STATE_DIR/$SRV" -type f 2>/dev/null | wc -l | tr -d ' ') file(s))"
       else
           echo "INFO this tmux server has no store yet ($STATE_DIR/$SRV — created on first hook fire)"
       fi
       # Unscoped files are what clux <= 3.3.0 wrote. The reaper deletes them
       # on its next run, because nothing records which server they came from.
       OLD=$(find "$STATE_DIR" -maxdepth 1 -type f -name '%*' 2>/dev/null | wc -l | tr -d ' ')
       [ "$OLD" -gt 0 ] && echo "INFO $OLD unscoped state file(s) from an older clux (removed on the next hook fire)"
   fi
   ```
9. **Leftovers from a hand-written setup** (INFO/WARN only — clux never deletes outside a confirmed migration):
   ```bash
   OLD_DIR="$HOME/.config/tmux/scripts"
   LEFT=""
   for s in session-order.sh session-list.sh session-reorder.sh switch-session.sh \
            session-bar-refresh.sh fzf-session-switch.sh new-session.sh new-session-prompt.sh; do
       [ -f "$OLD_DIR/$s" ] && LEFT="$LEFT $s"
   done
   [ -n "$LEFT" ] && echo "INFO superseded scripts still in $OLD_DIR:$LEFT (/clux:setup offers to back them up and remove them)"
   # A still-live reference is the real hazard: two renderers fighting over one
   # bar. Match the OLD directory, not the bare filename — clux deploys its own
   # session-bar-refresh.sh, so "scripts/session-bar-refresh.sh" alone would
   # report clux's own correctly-installed token string as a leftover.
   [ -n "$TMUX_CONF" ] && grep -nE "tmux/scripts/(session-order|session-list|session-reorder|switch-session|session-bar-refresh|fzf-session-switch|new-session|new-session-prompt)\.sh" "$TMUX_CONF" \
       && echo "WARN $TMUX_CONF still references a superseded script (above) — it competes with clux's own binding or hook"
   # tpm loading claude-notify.tmux sets the same [90] hooks from a different
   # path, possibly a different version. Functionally identical, so whichever
   # loads last is correct; the hazard is version skew, not breakage.
   [ -n "$TMUX_CONF" ] && grep -q "claude-notify.tmux" "$TMUX_CONF" \
       && echo "WARN tmux.conf loads claude-notify.tmux via tpm — the [90] hooks then point at the tpm cache, not ~/.config/clux/scripts/ (version skew)"
   ```
10. Return all results with clear OK/FAIL/WARN/INFO prefixes.

**Wait for all four agents to complete before proceeding.**

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
    ✓ deploy manifest (19 scripts)
    ✓ jq installed
    ✓ fzf installed
    ~ flock unavailable (mkdir fallback)

  Deployed scripts (~/.config/clux/scripts/, from the manifest):
    ✓ helpers.sh              ✓ session-order.sh
    ✓ path.sh                 ✓ session-list.sh
    ✓ show-notification.sh    ✓ session-bar-refresh.sh
    ✓ jump-to-notification.sh ✓ session-reorder.sh
    ✓ dismiss-notification.sh ✓ switch-session.sh
    ✓ notification-picker.sh  ✓ session-picker.sh
    ✓ notify-sound.sh         ✓ new-workspace.sh
    ✓ truncate-title.sh       ✓ new-workspace-prompt.sh
    ✓ agent-query.sh          ✓ agent-bar.sh
    ✓ agent-clear.sh
    ✓ all scripts in sync with plugin source
    ✓ render-clux-conf.sh, verify-tmux-conf.sh (plugin source, never deployed)

  clux's own file:
    ✓ ~/.config/clux/clux.tmux.conf present
    ✓ parses on a throwaway server
    ✓ sets no runtime state (@clux-session-order, @clux_session_bar, @clux_status)

  The user's tmux.conf (~/.config/tmux/tmux.conf):
    ✓ source-file line present exactly once
    ✓ #{@clux_session_bar} present exactly once
    ✓ session-bar-refresh.sh quiet present exactly once
    ✓ #{@clux_status} present exactly once
    ~ status-interval: 2
    ✓ status-left-length: 150
    ✓ monitor-bell: on
    ✓ bell-action: any
    ✓ notification dir writable

  Session surface:
    ✓ @clux_session_bar rendered (412 bytes)
    ✓ @clux-dir-resolver (autojump, binary present)
    ✓ @clux-editor (nvim)
    ✓ @clux-agents-command (claude agents --cwd "$PWD")
    ✓ @clux-picker (fzf, binary present)
    ✓ @clux-agent-refresh-command (run-shell -b /Users/me/.config/clux/scripts/session-bar-refresh.sh)
    ~ @clux-session-order (work,notes,scratch)
    ~ @session_order still set (leftover, nothing reads it)

  Bar theming:
    ~ @clux-bar-name-length (using default: 24)
    ✓ @clux-bar-name-attached-style (bg=#81A1C1,fg=#2E3440,bold)
    ~ @clux-bar-window-open (using default: ❰)
    …

  Notification style:
    ✓ bg: #EBCB8B  fg: #2E3440

  Agent state:
    ~ @clux-agent-glyph-busy (using default: *)
    ~ @clux-agent-glyph-needs (using default: !)
    ~ @clux-agent-glyph-done (using default: v)
    ~ @clux-agent-busy-color (using default: cyan)
    ~ @clux-agent-needs-color (using default: yellow)
    ~ @clux-agent-done-color (using default: green)
    ~ @clux-agent-state-dir (using default: ~/.local/state/clux/agents)
    ✓ agent state dir exists (~/.local/state/clux/agents)

  Per-notification preferences:
    notification:  visual=on   sound=on
    stop:          visual=off  sound=off
    prompt:        visual=off  sound=off

  Audio playback:
    ✓ audio player (paplay)
    ✓ notification sound file (/usr/share/sounds/freedesktop/stereo/complete.oga)

  Keybindings:
    ✓ prefix N / P   → next / previous session
    ✓ prefix { / }   → move session in the bar
    ✓ prefix g       → session picker
    ✓ prefix A       → new Claude workspace
    ✓ prefix m       → jump to notification
    ✓ prefix ` / DC  → dismiss notification
    ✓ prefix M       → notification picker

  Hooks:
    ✓ hooks.json: Stop, Notification, UserPromptSubmit, SessionEnd → notify-tmux.sh
    ✓ hooks.json: Stop, Notification, UserPromptSubmit, SessionEnd → agent-state.sh
    ✓ notify-tmux.sh executable
    ✓ agent-state.sh executable
    ✓ notify-sound.sh executable
    ✓ after-select-window[90] / client-session-changed[90] → agent-clear.sh
    ✓ six [91] hooks → session-bar-refresh.sh
    ✓ 92-99 band free
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
2. **For WARN results**: Explain the impact and suggest the fix. For a setting clux does not own (`status-interval` and friends), say what value clux prefers and that clux will never write it.
3. **If everything passes**: Report "All checks passed. clux is fully operational."

**Do NOT offer to make changes.** This command is read-only. Direct the user to run `/clux:setup` for fixes.
