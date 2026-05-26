#!/usr/bin/env bash

# Claude hook bridge — writes notifications to queue file
# Called by Claude Code hooks on Stop, Notification, and UserPromptSubmit events

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/../scripts/helpers.sh"

# Extract message from JSON stdin or argument
if [ -t 0 ]; then
    MESSAGE="$1"
    EVENT=""
    SESSION_ID=""
    NOTIFICATION_TYPE=""
else
    INPUT=$(cat)
    if command -v jq &>/dev/null; then
        # Use a single jq invocation to parse all fields; if jq fails (e.g. due to raw
        # control bytes in the input), EVENT will be empty and we fall back to grep below.
        _JQ_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
        if [ -n "$_JQ_EVENT" ]; then
            # jq succeeded — use its output for all fields
            MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)
            EVENT="$_JQ_EVENT"
            SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
            NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty' 2>/dev/null)
        else
            # jq present but failed to parse (e.g. raw control chars in input) — grep fallback
            MESSAGE=$(echo "$INPUT" | grep -o '"message":"[^"]*"' | sed 's/"message":"\(.*\)"/\1/' 2>/dev/null)
            EVENT=$(echo "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | sed 's/"hook_event_name":"\(.*\)"/\1/' 2>/dev/null)
            SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | sed 's/"session_id":"\(.*\)"/\1/' 2>/dev/null)
            # notification_type NOT parsed in grep fallback path — treated as eligible per spec
        fi
    else
        MESSAGE=$(echo "$INPUT" | grep -o '"message":"[^"]*"' | sed 's/"message":"\(.*\)"/\1/' 2>/dev/null)
        EVENT=$(echo "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | sed 's/"hook_event_name":"\(.*\)"/\1/' 2>/dev/null)
        SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | sed 's/"session_id":"\(.*\)"/\1/' 2>/dev/null)
        # notification_type NOT parsed in grep fallback path — treated as eligible per spec
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

# Play sound (independent of visual and tmux session — handled by notify-sound.sh)
"$CURRENT_DIR/../scripts/notify-sound.sh" "$TYPE" &

# ---------------------------------------------------------------------------
# Agent branch — runs when $TMUX is unset (detached Claude agent session).
# Must come AFTER the sound call above so sound fires in both paths.
# The interactive path below ([ -n "$TMUX" ] || exit 0) is unchanged.
# ---------------------------------------------------------------------------
_sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

_agent_handle_event() {
    # Resolve queue file for the agent (detached) path only.
    # Must NOT be called from the interactive path — helpers.sh's source-time
    # get_tmux_option value for NOTIFY_FILE is correct there.
    NOTIFY_FILE=$(resolve_notify_file)
    recompute_lock_target

    local MARKER="⚡"

    case "$EVENT" in
        UserPromptSubmit|Stop|SessionEnd)
            # Remove queue entry; emit nothing on stdout
            _agent_remove_entry "$SESSION_ID"
            return 0
            ;;
        Notification)
            # jq available: check notification_type eligibility
            if command -v jq &>/dev/null; then
                case "$NOTIFICATION_TYPE" in
                    permission_prompt|idle_prompt|"") : ;;  # eligible — fall through
                    *) return 0 ;;                          # ineligible — skip
                esac
            fi
            # grep fallback path: treat any Notification as eligible (no type check)

            local SAFE_LABEL
            SAFE_LABEL=$(_sanitize "${MESSAGE:-needs input}")

            # Desktop ping — osascript first, terminal-notifier fallback, else skip silently
            if command -v osascript &>/dev/null; then
                osascript -e "display notification \"$SAFE_LABEL\" with title \"Claude\"" >/dev/null 2>&1 || true
            elif command -v terminal-notifier &>/dev/null; then
                terminal-notifier -message "$SAFE_LABEL" -title "Claude" >/dev/null 2>&1 || true
            fi

            # Dedup-on-add: remove any existing entry for this session, then append
            _agent_remove_entry "$SESSION_ID"
            acquire_lock
            printf '%s %s|||agent:%s\n' "$MARKER" "$SAFE_LABEL" "$SESSION_ID" >> "$NOTIFY_FILE"
            release_lock

            # Emit terminalSequence JSON on stdout (ONLY stdout output for agent path)
            # Escape sequences are in the FORMAT STRING; $SAFE_LABEL is the %s arg.
            # Decoded value: BEL ESC ]9;Claude: <label> BEL
            printf '{"terminalSequence":"\\u0007\\u001b]9;Claude: %s\\u0007"}\n' "$SAFE_LABEL"
            return 0
            ;;
    esac
}

if [ -z "$TMUX" ]; then
    _agent_handle_event
    exit 0
fi

# Visual notifications require tmux session context
[ -n "$TMUX" ] || exit 0
_CLUX_MUTED="$(tmux show-option -gqv @clux_muted)"
[ "$_CLUX_MUTED" = "1" ] && exit 0

# Single tmux IPC call for all 4 identifiers
_TMUX_INFO="$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}|||#{window_name}|||#{session_id}|||#{window_id}')"
SESSION="${_TMUX_INFO%%|||*}"; _TMUX_INFO="${_TMUX_INFO#*|||}"
WINDOW_NAME="${_TMUX_INFO%%|||*}"; _TMUX_INFO="${_TMUX_INFO#*|||}"
SESSION_ID="${_TMUX_INFO%%|||*}"
WINDOW_ID="${_TMUX_INFO#*|||}"

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

exit 0
