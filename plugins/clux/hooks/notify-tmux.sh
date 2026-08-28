#!/usr/bin/env bash

# Claude hook bridge — writes notifications to queue file
# Called by Claude Code hooks on Stop, StopFailure, Notification,
# TeammateIdle, UserPromptSubmit and SessionEnd events.
#
# Every event maps to ONE clux notification type (map_event_to_type in
# helpers.sh), and that type names the @claude-notify-<type>-visual /
# -sound options that decide what happens. The interactive path (a Claude in
# a tmux pane) and the agent path (a detached `claude agents` session) read
# the SAME options, so one answer in /clux:setup §3.6 governs both.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/../scripts/helpers.sh"

# Extract message from JSON stdin or argument
if [ -t 0 ]; then
    MESSAGE="$1"
    EVENT=""
    SESSION_ID=""
    NOTIFICATION_TYPE=""
    CWD=""
    TRANSCRIPT_PATH=""
    ERROR_TYPE=""
    TEAMMATE=""
else
    INPUT=$(cat)
    # Fallback parser for a payload jq cannot read (raw control bytes in the
    # message) or a machine without jq. Compact JSON, string fields only.
    _grep_field() {
        echo "$INPUT" | grep -o "\"$1\":\"[^\"]*\"" | sed "s/\"$1\":\"\\(.*\\)\"/\\1/" 2>/dev/null
    }
    _JQ_EVENT=""
    if command -v jq &>/dev/null; then
        _JQ_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
    fi
    if [ -n "$_JQ_EVENT" ]; then
        # jq succeeded — use its output for all fields
        MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)
        EVENT="$_JQ_EVENT"
        SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
        NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty' 2>/dev/null)
        CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
        TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
        ERROR_TYPE=$(echo "$INPUT" | jq -r '.error_type // empty' 2>/dev/null)
        TEAMMATE=$(echo "$INPUT" | jq -r '.teammate_name // .teammate_id // empty' 2>/dev/null)
    else
        MESSAGE=$(_grep_field message)
        EVENT=$(_grep_field hook_event_name)
        SESSION_ID=$(_grep_field session_id)
        NOTIFICATION_TYPE=$(_grep_field notification_type)
        CWD=$(_grep_field cwd)
        TRANSCRIPT_PATH=$(_grep_field transcript_path)
        ERROR_TYPE=$(_grep_field error_type)
        TEAMMATE=$(_grep_field teammate_name)
    fi
fi

# Resolve the clux notification type. Empty means "a Notification sub-type
# clux ignores" (auth_success and friends): no sound, no entry, nothing.
TYPE=$(map_event_to_type "$EVENT" "$NOTIFICATION_TYPE")
[ -n "$TYPE" ] || exit 0

# Default message based on event / type. The payload's own message wins when
# it has one, except for the two that would otherwise be opaque.
if [ -z "$MESSAGE" ]; then
    case "$TYPE" in
        stop)     MESSAGE="Task complete" ;;
        failure)  MESSAGE="Stopped: ${ERROR_TYPE:-error}" ;;
        teammate) MESSAGE="Teammate idle${TEAMMATE:+: $TEAMMATE}" ;;
        quota)
            case "$NOTIFICATION_TYPE" in
                quota_auto_resume_fired) MESSAGE="Resumed after quota" ;;
                *)                       MESSAGE="Paused on usage quota" ;;
            esac
            ;;
        notification)     MESSAGE="Waiting for input" ;;
        prompt)           MESSAGE="Prompt submitted" ;;
        *)                MESSAGE="Notification" ;;
    esac
elif [ "$TYPE" = "failure" ] && [ -n "$ERROR_TYPE" ]; then
    MESSAGE="Stopped: $ERROR_TYPE"
fi

# Play sound (independent of visual and tmux session — handled by notify-sound.sh)
"$CURRENT_DIR/../scripts/notify-sound.sh" "$TYPE" &

# ---------------------------------------------------------------------------
# Agent branch — runs when $TMUX is unset (detached Claude agent session).
# Must come AFTER the sound call above so sound fires in both paths.
# The interactive path below ([ -n "$TMUX" ] || exit 0) is unchanged.
# ---------------------------------------------------------------------------
_sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

_agent_handle_event() {
    # Clear-on-jump ONLY. UserPromptSubmit / SessionEnd fire autonomously in
    # the agent view (permission_mode=auto drives the loop on its own), so
    # clearing on them made notifications flash and vanish before the user
    # could act. An entry is removed only when the user jumps to it (the jump
    # and picker scripts call _agent_remove_entry). Here we ONLY ADD.
    #
    # Which types add, and their marker. The marker is the first thing on
    # the status line, so it says at a glance WHY the agent wants you.
    local MARKER
    case "$TYPE" in
        notification|teammate) MARKER="⚡" ;;
        stop)                  MARKER="✓" ;;
        failure)               MARKER="✗" ;;
        quota)                 MARKER="⏳" ;;
        *) return 0 ;;   # prompt, sessionend: never an entry on this path
    esac

    # The same per-type visual option the interactive path reads. `stop` is
    # off by default — 3.7.0 never queued a finished agent — so a user who
    # never ran /clux:setup §3.6 sees no change.
    [ "$(get_notification_visual_enabled "$TYPE")" != "off" ] || return 0

    # Resolve queue file for the agent (detached) path only.
    # Must NOT run on the interactive path — helpers.sh's source-time
    # get_tmux_option value for NOTIFY_FILE is correct there.
    NOTIFY_FILE=$(resolve_notify_file)
    recompute_lock_target

    # Display label = "agents / <session name>", where <session name> is
    # the name shown in the `claude agents` view (the transcript's
    # custom-title). The "agents /" prefix marks it as coming from the
    # agents view and distinguishes multiple waiting sessions; the human
    # message (e.g. "Claude needs your permission") goes to the desktop
    # banner instead. resolve_agent_name falls back to the cwd basename.
    #
    # For a failure, a quota pause or an idle teammate the message carries
    # the one fact the marker cannot (WHICH error, WHICH teammate), so it is
    # appended to the bar text too. needs-you and finished keep the short
    # 3.7.0 form — their marker already says everything.
    local NAME LABEL MSG TEXT
    NAME=$(_sanitize "$(resolve_agent_name "$SESSION_ID" "$CWD" "$TRANSCRIPT_PATH")")
    [ -z "$NAME" ] && NAME="agent"
    LABEL="agents / $NAME"
    MSG=$(_sanitize "${MESSAGE:-needs input}")
    case "$TYPE" in
        failure|quota|teammate) TEXT="$LABEL — $MSG" ;;
        *)                      TEXT="$LABEL" ;;
    esac

    # Desktop ping — osascript first, terminal-notifier fallback, else skip silently
    if command -v osascript &>/dev/null; then
        osascript -e "display notification \"$MSG\" with title \"$LABEL\"" >/dev/null 2>&1 || true
    elif command -v terminal-notifier &>/dev/null; then
        terminal-notifier -message "$MSG" -title "$LABEL" >/dev/null 2>&1 || true
    fi

    # Resolve the owning dashboard pane by longest-prefix cwd match so the
    # jump can fast-path straight to it. Runs detached (TMUX unset) over the
    # default socket (prototype P1). When no dashboard / no tmux server is
    # reachable the resolver echoes empty cleanly → seg2 stays empty (@@@@)
    # and the jump side re-resolves by CWD at click time.
    local _coords seg2 sid wid pid entry_id
    _coords=$(resolve_agents_pane_by_cwd "$CWD")
    if [ -n "$_coords" ]; then
        read -r sid wid pid <<< "$_coords"
        seg2="${sid}:${wid}:${pid}"
    else
        seg2=""
    fi
    # Routing data lives AFTER the ||| (three @@-segments: SID, tmux coords,
    # CWD) so the status-bar display text (before |||) is unchanged.
    entry_id="agent:${SESSION_ID}@@${seg2}@@${CWD}"

    # Dedup-on-add: remove any existing entry for this session, then append.
    # A finished entry replacing a needs-you one is correct — the finish
    # supersedes the question. _agent_remove_entry matches by seg1
    # (SESSION_ID) via the widened regex.
    _agent_remove_entry "$SESSION_ID"
    acquire_lock
    printf '%s %s|||%s\n' "$MARKER" "$TEXT" "$entry_id" >> "$NOTIFY_FILE"
    release_lock

    # Emit terminalSequence JSON on stdout (ONLY stdout output for agent path)
    # Escape sequences are in the FORMAT STRING; the label is the %s arg.
    # Decoded value: BEL ESC ]9;<label> BEL
    printf '{"terminalSequence":"\\u0007\\u001b]9;%s\\u0007"}\n' "$LABEL"
    return 0
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
