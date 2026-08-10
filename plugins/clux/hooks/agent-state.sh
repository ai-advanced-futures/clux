#!/usr/bin/env bash

# Claude hook bridge — writes per-pane agent state to the state store.
# Called by Claude Code hooks on UserPromptSubmit, Notification, Stop, and
# SessionEnd.
#
# GOVERNING PRINCIPLE: STATE LIVES IN FILES. HOOKS WRITE THOSE FILES. THE BAR
# ONLY READS. This script is the only writer on the Claude Code side.
#
# No `set -e` / `set -u` / `set -o pipefail` — every path must reach `exit 0`.
# Nothing is ever written to stdout or stderr: a non-zero exit or stray stdout
# is visible to the user inside Claude Code.
#
# Usage: agent-state.sh <busy|needs-you|finished|remove>
# `end` is accepted as an alias of `remove` (hooks.json registers `remove`).

STATE="${1:-}"

# Drain stdin ONCE, unconditionally, before anything else — this is what stops
# a broken pipe on the branches that do not care about the payload.
INPUT=""
[ -t 0 ] || INPUT=$(cat 2>/dev/null)

# A detached agent has no tmux pane, and the store is keyed by pane id, so
# there is nothing to key on. Do NOT read @clux_muted here: muting suppresses
# notifications, but per-pane state is the data the bar draws — muting it
# would leave a stale glyph on screen.
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/../scripts/path.sh"

STATE_DIR="$(resolve_agent_state_dir)"
[ -n "$STATE_DIR" ] || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

WORD=""
case "$STATE" in
    busy)
        WORD="busy"
        ;;
    finished)
        WORD="finished"
        ;;
    remove|end)
        WORD=""
        ;;
    needs-you)
        # The ONE payload-dependent branch — the only place any payload is
        # inspected in this script. Matches notify-tmux.sh's eligibility rule
        # (permission_prompt, idle_prompt, or no notification_type field at all)
        # so the two hooks stay consistent for the same event.
        if printf '%s' "$INPUT" | grep -qE 'permission_prompt|idle_prompt'; then
            WORD="needs-you"
        elif printf '%s' "$INPUT" | grep -q '"notification_type"'; then
            # A type is present but is not one of the two eligible kinds
            # (auth_success and friends) — true no-op, leave any existing
            # state file exactly as it was.
            exit 0
        else
            WORD="needs-you"
        fi
        ;;
    *)
        # Unknown argument — silent no-op.
        exit 0
        ;;
esac

if [ -n "$WORD" ]; then
    TMP="$STATE_DIR/.tmp.$$"
    printf '%s\n' "$WORD" > "$TMP" 2>/dev/null || exit 0
    mv -f "$TMP" "$STATE_DIR/$TMUX_PANE" 2>/dev/null
    rm -f "$TMP" 2>/dev/null
else
    rm -f "$STATE_DIR/$TMUX_PANE" 2>/dev/null
fi

# Reap — the writer's job, done opportunistically. The `[ -n "$LIVE" ]` guard
# is load-bearing: without it, a missing tmux server or a failed call would
# wipe the whole store instead of just skipping the reap.
LIVE=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)
if [ -n "$LIVE" ]; then
    for f in "$STATE_DIR"/*; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        case "$base" in
            .tmp.*) continue ;;
            %*) ;;
            *) continue ;;
        esac
        printf '%s\n' "$LIVE" | grep -qxF "$base" || rm -f "$f" 2>/dev/null
    done
fi

# Refresh, decoupled from the user's bar. A failure never changes the exit
# status.
REFRESH_CMD=$(tmux show-option -gqv "@clux-agent-refresh-command" 2>/dev/null)
[ -n "$REFRESH_CMD" ] || REFRESH_CMD="refresh-client -S"
# shellcheck disable=SC2086
tmux $REFRESH_CMD 2>/dev/null || true

exit 0
