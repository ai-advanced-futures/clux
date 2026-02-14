# Per-Notification Granular Control Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use Skill('superpowers:executing-plans') to implement this plan task-by-task.

**Goal:** Add per-notification-type sound and visual controls via tmux vars, replacing the global `@claude-notify-sound` with granular `@claude-notify-{type}-{sound|visual}` options.

**Architecture:** Each notification type (stop, notification, prompt) gets independent sound (on/off + file) and visual (on/off) tmux vars. A new centralized `notify-sound.sh` script handles all sound playback. `notify-tmux.sh` becomes the single notification handler for all three event types, checking visual/sound settings before acting. Backward compatible: falls back to old `@claude-notify-sound` if per-type vars aren't set.

**Tech Stack:** Bash, tmux options API (`tmux show-option -gqv`), `afplay` (macOS)

---

## New tmux Options Reference

```bash
# Stop event (Claude finishes) — defaults: OFF
set -g @claude-notify-stop-sound "off"
set -g @claude-notify-stop-sound-file "/System/Library/Sounds/Blow.aiff"
set -g @claude-notify-stop-visual "off"

# Notification event (Claude needs input) — defaults: ON
set -g @claude-notify-notification-sound "on"
set -g @claude-notify-notification-sound-file "/System/Library/Sounds/Blow.aiff"
set -g @claude-notify-notification-visual "on"

# UserPromptSubmit event — defaults: OFF
set -g @claude-notify-prompt-sound "off"
set -g @claude-notify-prompt-sound-file "/System/Library/Sounds/Pop.aiff"
set -g @claude-notify-prompt-visual "off"
```

---

### Task 1: Update helpers.sh — Per-Notification Config Helpers

**Files:**
- Modify: `plugins/clux/scripts/helpers.sh`

#### Step 1: Remove old global NOTIFY_SOUND and play_sound()

In `plugins/clux/scripts/helpers.sh`, remove line 17 (`NOTIFY_SOUND=...`) and the entire `play_sound()` function (lines 52-66).

**Remove this code:**
```bash
NOTIFY_SOUND=$(get_tmux_option "@claude-notify-sound" "on")
```

**Remove this function:**
```bash
play_sound() {
    [ "$NOTIFY_SOUND" = "off" ] && return
    if [ "$NOTIFY_SOUND" != "on" ]; then
        # Custom command
        eval "$NOTIFY_SOUND" &>/dev/null &
        return
    fi
    if [[ "$OSTYPE" == darwin* ]]; then
        afplay /System/Library/Sounds/Blow.aiff &>/dev/null &
    elif command -v paplay &>/dev/null; then
        paplay /usr/share/sounds/freedesktop/stereo/complete.oga &>/dev/null &
    elif command -v aplay &>/dev/null; then
        aplay /usr/share/sounds/freedesktop/stereo/complete.oga &>/dev/null &
    fi
}
```

#### Step 2: Add event-to-type mapping function

Append after the existing config loading block (after line 20, after `NOTIFY_SMART_TITLE`):

```bash
# Map Claude hook event names to notification types
map_event_to_type() {
    case "$1" in
        Stop) echo "stop" ;;
        Notification) echo "notification" ;;
        UserPromptSubmit) echo "prompt" ;;
        *) echo "$1" ;;
    esac
}
```

#### Step 3: Add per-notification config getter functions

Append after the mapping function:

```bash
# Per-notification config defaults
# Falls back to old @claude-notify-sound for backward compatibility
_get_notification_default_sound() {
    case "$1" in
        notification) echo "on" ;;
        *) echo "off" ;;
    esac
}

_get_notification_default_visual() {
    case "$1" in
        notification) echo "on" ;;
        *) echo "off" ;;
    esac
}

_get_notification_default_sound_file() {
    case "$1" in
        prompt) echo "/System/Library/Sounds/Pop.aiff" ;;
        *) echo "/System/Library/Sounds/Blow.aiff" ;;
    esac
}

get_notification_sound_enabled() {
    local type="$1"
    local val
    val=$(get_tmux_option "@claude-notify-${type}-sound" "")
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    # Backward compat: fall back to global @claude-notify-sound
    local global
    global=$(get_tmux_option "@claude-notify-sound" "")
    if [ -n "$global" ]; then
        echo "$global"
        return
    fi
    _get_notification_default_sound "$type"
}

get_notification_sound_file() {
    local type="$1"
    get_tmux_option "@claude-notify-${type}-sound-file" "$(_get_notification_default_sound_file "$type")"
}

get_notification_visual_enabled() {
    local type="$1"
    local val
    val=$(get_tmux_option "@claude-notify-${type}-visual" "")
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    _get_notification_default_visual "$type"
}
```

#### Step 4: Verify helpers.sh sources correctly

Run:
```bash
bash -n plugins/clux/scripts/helpers.sh
```
Expected: No output (syntax OK)

#### Step 5: Commit

```bash
git add plugins/clux/scripts/helpers.sh
git commit -m "refactor(helpers): add per-notification config getters, remove global play_sound"
```

---

### Task 2: Create notify-sound.sh — Centralized Sound Script

**Files:**
- Create: `plugins/clux/scripts/notify-sound.sh`

#### Step 1: Create the script

Create `plugins/clux/scripts/notify-sound.sh` with this content:

```bash
#!/usr/bin/env bash

# Centralized sound playback for clux notifications
# Usage: notify-sound.sh <type>
#   type: stop | notification | prompt
#
# Reads per-notification tmux vars:
#   @claude-notify-<type>-sound      (on/off)
#   @claude-notify-<type>-sound-file (path to sound file)
#
# Falls back to @claude-notify-sound for backward compatibility.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

TYPE="${1:-}"
[ -z "$TYPE" ] && exit 1

# Check if sound is enabled for this notification type
ENABLED=$(get_notification_sound_enabled "$TYPE")
[ "$ENABLED" = "off" ] && exit 0

# Handle custom command (backward compat with @claude-notify-sound "custom cmd")
if [ "$ENABLED" != "on" ]; then
    eval "$ENABLED" &>/dev/null &
    exit 0
fi

# Get configured sound file
SOUND_FILE=$(get_notification_sound_file "$TYPE")

# Verify sound file exists
if [ ! -f "$SOUND_FILE" ]; then
    tmux display-message "clux: sound file not found: $SOUND_FILE" 2>/dev/null
    exit 1
fi

# Play sound (macOS)
if [[ "$OSTYPE" == darwin* ]]; then
    afplay "$SOUND_FILE" &>/dev/null &
fi

exit 0
```

#### Step 2: Make executable

Run:
```bash
chmod +x plugins/clux/scripts/notify-sound.sh
```

#### Step 3: Verify syntax

Run:
```bash
bash -n plugins/clux/scripts/notify-sound.sh
```
Expected: No output (syntax OK)

#### Step 4: Manual test — sound disabled

Run (from within tmux):
```bash
plugins/clux/scripts/notify-sound.sh stop
```
Expected: No sound (stop defaults to off). Exit code 0.

#### Step 5: Manual test — sound enabled

Run:
```bash
tmux set -g @claude-notify-notification-sound "on"
plugins/clux/scripts/notify-sound.sh notification
```
Expected: Hear Blow.aiff sound.

Cleanup:
```bash
tmux set -gu @claude-notify-notification-sound
```

#### Step 6: Manual test — custom sound file

Run:
```bash
tmux set -g @claude-notify-prompt-sound "on"
tmux set -g @claude-notify-prompt-sound-file "/System/Library/Sounds/Ping.aiff"
plugins/clux/scripts/notify-sound.sh prompt
```
Expected: Hear Ping.aiff sound.

Cleanup:
```bash
tmux set -gu @claude-notify-prompt-sound
tmux set -gu @claude-notify-prompt-sound-file
```

#### Step 7: Manual test — missing sound file shows error

Run:
```bash
tmux set -g @claude-notify-stop-sound "on"
tmux set -g @claude-notify-stop-sound-file "/nonexistent/sound.aiff"
plugins/clux/scripts/notify-sound.sh stop
```
Expected: tmux displays message "clux: sound file not found: /nonexistent/sound.aiff"

Cleanup:
```bash
tmux set -gu @claude-notify-stop-sound
tmux set -gu @claude-notify-stop-sound-file
```

#### Step 8: Commit

```bash
git add plugins/clux/scripts/notify-sound.sh
git commit -m "feat: add centralized notify-sound.sh for per-notification sound control"
```

---

### Task 3: Update notify-tmux.sh — Visual Check + notify-sound.sh

**Files:**
- Modify: `plugins/clux/hooks/notify-tmux.sh`

#### Step 1: Add notification type resolution

After the event/message extraction block (after line 31, after the `esac`), add type resolution:

```bash
# Resolve notification type from event
TYPE=$(map_event_to_type "$EVENT")
```

#### Step 2: Add visual check before queue write

Replace lines 45-59 (from `acquire_lock` through `tmux refresh-client`) with:

```bash
# Check if visual notification is enabled for this type
VISUAL_ENABLED=$(get_notification_visual_enabled "$TYPE")

if [ "$VISUAL_ENABLED" != "off" ]; then
    acquire_lock

    # Skip duplicate for same session/window
    if [ -f "$NOTIFY_FILE" ] && grep -qF "$CONTEXT" "$NOTIFY_FILE"; then
        release_lock
    else
        echo "$CONTEXT $MESSAGE|||$SESSION_ID:$WINDOW_ID" >> "$NOTIFY_FILE"
        release_lock
        # Bell alert + refresh
        printf '\a'
        tmux refresh-client -S 2>/dev/null
    fi
fi

# Play sound (independent of visual — handled by notify-sound.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/../scripts/notify-sound.sh" "$TYPE" &
```

This replaces the old `play_sound` call and the hardcoded `printf '\a'` / `tmux refresh-client` with conditional logic.

#### Step 3: Remove the old exit 0 at the bottom

The final `exit 0` should remain at the very end of the script.

#### Step 4: Verify the complete file

The final `notify-tmux.sh` should look like:

```bash
#!/usr/bin/env bash

# Claude hook bridge — writes notifications to queue file
# Called by Claude Code hooks on Stop, Notification, and UserPromptSubmit events

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/../scripts/helpers.sh"

# Extract message from JSON stdin or argument
if [ -t 0 ]; then
    MESSAGE="$1"
    EVENT=""
else
    INPUT=$(cat)
    if command -v jq &>/dev/null; then
        MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)
        EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
    else
        MESSAGE=$(echo "$INPUT" | grep -o '"message":"[^"]*"' | sed 's/"message":"\(.*\)"/\1/' 2>/dev/null)
        EVENT=$(echo "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | sed 's/"hook_event_name":"\(.*\)"/\1/' 2>/dev/null)
    fi
fi

# Default message based on event
if [ -z "$MESSAGE" ]; then
    case "$EVENT" in
        Stop) MESSAGE="Task complete" ;;
        Notification) MESSAGE="Waiting for input" ;;
        UserPromptSubmit) MESSAGE="Prompt submitted" ;;
        *) MESSAGE="Notification" ;;
    esac
fi

# Resolve notification type from event
TYPE=$(map_event_to_type "$EVENT")

# Must be in tmux
[ -n "$TMUX" ] || exit 0

SESSION=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}')
WINDOW_NAME=$(tmux display-message -t "$TMUX_PANE" -p '#{window_name}')
SESSION_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{session_id}')
WINDOW_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}')

[ -n "$SESSION" ] && [ -n "$WINDOW_NAME" ] || exit 0

CONTEXT="$SESSION:$WINDOW_NAME"

# Check if visual notification is enabled for this type
VISUAL_ENABLED=$(get_notification_visual_enabled "$TYPE")

if [ "$VISUAL_ENABLED" != "off" ]; then
    acquire_lock

    # Skip duplicate for same session/window
    if [ -f "$NOTIFY_FILE" ] && grep -qF "$CONTEXT" "$NOTIFY_FILE"; then
        release_lock
    else
        echo "$CONTEXT $MESSAGE|||$SESSION_ID:$WINDOW_ID" >> "$NOTIFY_FILE"
        release_lock
        # Bell alert + refresh
        printf '\a'
        tmux refresh-client -S 2>/dev/null
    fi
fi

# Play sound (independent of visual — handled by notify-sound.sh)
"$CURRENT_DIR/../scripts/notify-sound.sh" "$TYPE" &

exit 0
```

#### Step 5: Verify syntax

Run:
```bash
bash -n plugins/clux/hooks/notify-tmux.sh
```
Expected: No output (syntax OK)

#### Step 6: Commit

```bash
git add plugins/clux/hooks/notify-tmux.sh
git commit -m "feat(notify-tmux): add per-notification visual check, use notify-sound.sh"
```

---

### Task 4: Update hooks.json — Route UserPromptSubmit to notify-tmux.sh

**Files:**
- Modify: `plugins/clux/hooks/hooks.json`

#### Step 1: Add notify-tmux.sh as second hook for UserPromptSubmit

Replace the entire content of `plugins/clux/hooks/hooks.json` with:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "matcher": "", "hooks": [
      { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/rename-window.sh", "timeout": 5 },
      { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/notify-tmux.sh", "timeout": 5 }
    ] }],
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/notify-tmux.sh", "timeout": 5 }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/notify-tmux.sh", "timeout": 5 }] }]
  }
}
```

This adds `notify-tmux.sh` as a second hook for `UserPromptSubmit`, so prompt sound/visual is handled by the same centralized flow. `rename-window.sh` continues to handle window renaming independently.

#### Step 2: Verify JSON is valid

Run:
```bash
python3 -c "import json; json.load(open('plugins/clux/hooks/hooks.json')); print('OK')"
```
Expected: `OK`

#### Step 3: Commit

```bash
git add plugins/clux/hooks/hooks.json
git commit -m "feat(hooks): route UserPromptSubmit through notify-tmux.sh for sound/visual"
```

---

### Task 5: Update configure-tmux.sh — Deploy notify-sound.sh

**Files:**
- Modify: `plugins/clux/scripts/configure-tmux.sh:44`

#### Step 1: Add notify-sound.sh to deployed scripts list

In `plugins/clux/scripts/configure-tmux.sh`, find the `deploy_scripts()` function (line 42). Add `notify-sound.sh` to the scripts array.

Change:
```bash
    local scripts=(
        helpers.sh
        show-notification.sh
        jump-to-notification.sh
        dismiss-notification.sh
        notification-picker.sh
    )
```

To:
```bash
    local scripts=(
        helpers.sh
        show-notification.sh
        jump-to-notification.sh
        dismiss-notification.sh
        notification-picker.sh
        notify-sound.sh
    )
```

#### Step 2: Verify syntax

Run:
```bash
bash -n plugins/clux/scripts/configure-tmux.sh
```
Expected: No output (syntax OK)

#### Step 3: Commit

```bash
git add plugins/clux/scripts/configure-tmux.sh
git commit -m "chore(configure): deploy notify-sound.sh with other scripts"
```

---

### Task 6: Bump Plugin Version

**Files:**
- Modify: `plugins/clux/.claude-plugin/plugin.json:4`

#### Step 1: Bump version 2.0.3 → 2.0.4

In `plugins/clux/.claude-plugin/plugin.json`, change:
```json
  "version": "2.0.3",
```
To:
```json
  "version": "2.0.4",
```

#### Step 2: Commit

```bash
git add plugins/clux/.claude-plugin/plugin.json
git commit -m "chore(plugin): bump version to 2.0.4"
```

---

### Task 7: End-to-End Verification

#### Step 1: Verify all scripts have valid syntax

Run:
```bash
bash -n plugins/clux/scripts/helpers.sh && \
bash -n plugins/clux/scripts/notify-sound.sh && \
bash -n plugins/clux/hooks/notify-tmux.sh && \
bash -n plugins/clux/hooks/rename-window.sh && \
bash -n plugins/clux/scripts/configure-tmux.sh && \
echo "All scripts OK"
```
Expected: `All scripts OK`

#### Step 2: Test default behavior (notification sound ON, stop sound OFF)

In tmux, simulate a Notification event:
```bash
echo '{"hook_event_name":"Notification","message":"Need input"}' | plugins/clux/hooks/notify-tmux.sh
```
Expected:
- Hear Blow.aiff sound
- See notification in status bar (if configured)

Simulate a Stop event:
```bash
echo '{"hook_event_name":"Stop","message":"Task complete"}' | plugins/clux/hooks/notify-tmux.sh
```
Expected:
- NO sound (stop defaults to off)
- NO visual notification (stop visual defaults to off)

#### Step 3: Test enabling stop notifications

```bash
tmux set -g @claude-notify-stop-sound "on"
tmux set -g @claude-notify-stop-visual "on"
echo '{"hook_event_name":"Stop","message":"Task complete"}' | plugins/clux/hooks/notify-tmux.sh
```
Expected:
- Hear Blow.aiff sound
- See notification in status bar

Cleanup:
```bash
tmux set -gu @claude-notify-stop-sound
tmux set -gu @claude-notify-stop-visual
```

#### Step 4: Test backward compatibility with old global option

```bash
tmux set -g @claude-notify-sound "off"
echo '{"hook_event_name":"Notification","message":"Need input"}' | plugins/clux/hooks/notify-tmux.sh
```
Expected:
- NO sound (global override applies as fallback)

Cleanup:
```bash
tmux set -gu @claude-notify-sound
```

#### Step 5: Test custom sound file per type

```bash
tmux set -g @claude-notify-notification-sound "on"
tmux set -g @claude-notify-notification-sound-file "/System/Library/Sounds/Ping.aiff"
echo '{"hook_event_name":"Notification","message":"Need input"}' | plugins/clux/hooks/notify-tmux.sh
```
Expected: Hear Ping.aiff (not Blow.aiff)

Cleanup:
```bash
tmux set -gu @claude-notify-notification-sound
tmux set -gu @claude-notify-notification-sound-file
```

#### Step 6: Clean up debate artifacts

Remove the research/debate files created during brainstorming:
```bash
rm -rf research-needs/ research-results/ proposals/ deliberation/ RECOMMENDATION.md
```

#### Step 7: Final commit (if cleanup done)

```bash
git add -A
git commit -m "chore: clean up brainstorming artifacts"
```
