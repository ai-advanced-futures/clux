#!/usr/bin/env bash

# Claude hook bridge — writes per-agent state to the state store.
# Called by Claude Code hooks on UserPromptSubmit, Notification, Stop, and
# SessionEnd.
#
# GOVERNING PRINCIPLE: STATE LIVES IN FILES. HOOKS WRITE THOSE FILES. THE BAR
# ONLY READS. This script is the only writer on the Claude Code side.
#
# Two kinds of session, two keys, one store:
#   interactive (TMUX + TMUX_PANE set)  ->  $STATE_DIR/<pane_id>
#   detached agent (neither set)        ->  $STATE_DIR/agents/<pane_id>~<session_id>
# where <pane_id> for a detached agent is the pane of the `claude agents`
# dashboard that owns it (resolve_agents_pane_by_cwd, path.sh). The pane id in
# the file NAME is what lets the bar draw the mark on the dashboard's session
# column, and what lets the reaper sweep the file when that pane closes. A
# detached agent whose cwd matches no dashboard has no column to draw in, so
# nothing is written. Do NOT read @clux_muted here: muting suppresses
# notifications, but per-pane state is the data the bar draws — muting it
# would leave a stale glyph on screen.
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

# Map the argument to the word to write — BEFORE any key work, so an unknown
# argument or an ineligible notification type costs no resolve and creates no
# directory on either path.
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
        # The ONE payload-dependent branch — the only place the payload's
        # notification type is inspected in this script. Matches
        # notify-tmux.sh's eligibility rule (permission_prompt, idle_prompt,
        # or no notification_type field at all) so the two hooks stay
        # consistent for the same event.
        # Matched with bash's own pattern matching rather than `printf | grep`:
        # identical semantics, and it spawns nothing on a path that fires on
        # every notification.
        case "$INPUT" in
            *permission_prompt*|*idle_prompt*)
                WORD="needs-you"
                ;;
            *'"notification_type"'*)
                # A type is present but is not one of the two eligible kinds
                # (auth_success and friends) — true no-op, leave any existing
                # state file exactly as it was.
                exit 0
                ;;
            *)
                WORD="needs-you"
                ;;
        esac
        ;;
    *)
        # Unknown argument — silent no-op.
        exit 0
        ;;
esac

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/../scripts/path.sh"

STATE_DIR="$(resolve_agent_state_dir)"
[ -n "$STATE_DIR" ] || exit 0

# --- Key resolution ---------------------------------------------------------

# Read session_id from the payload with pure bash. A session id is a UUID —
# hex and dashes only — and the hook payload is compact JSON (the same
# assumption notify-tmux.sh's grep fallback makes). Anything else is treated
# as absent.
_agent_session_id() {
    local sid="${INPUT#*\"session_id\":\"}"
    [ "$sid" = "$INPUT" ] && return 0
    sid="${sid%%\"*}"
    case "$sid" in
        ''|*[!0-9a-fA-F-]*) return 0 ;;
    esac
    printf '%s' "$sid"
}

# Cache lookup: an existing agents/<pane>~<sid> file gives the pane back from
# its own name — no ps, no tmux. At most one file per sid survives between
# reaps, and a stale hit self-heals (see the write below).
_agent_cached_key() {
    local f
    for f in "$STATE_DIR/agents/"*"~$1"; do
        [ -f "$f" ] || return 0
        printf '%s' "agents/${f##*/}"
        return 0
    done
}

# Cache miss: read cwd from the payload (jq, sed fallback — the shape
# notify-tmux.sh uses; being right about the target pane matters more than
# the cost of a path that runs once per agent session) and resolve the owning
# dashboard pane. tmux/ps here run detached over the default socket — the
# precedent notify-tmux.sh's agent branch already set.
_agent_resolve_key() {
    local cwd="" coords pane
    if command -v jq &>/dev/null; then
        cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
    fi
    [ -z "$cwd" ] && cwd=$(printf '%s' "$INPUT" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p')
    [ -n "$cwd" ] || return 0
    coords=$(resolve_agents_pane_by_cwd "$cwd")
    [ -n "$coords" ] || return 0
    pane="${coords##* }"
    case "$pane" in
        %*) printf '%s' "agents/${pane}~$1" ;;
    esac
}

if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
    # Interactive path — unchanged: the store is keyed by this pane.
    KEY="$TMUX_PANE"
    mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
else
    SID="$(_agent_session_id)"
    [ -n "$SID" ] || exit 0
    KEY="$(_agent_cached_key "$SID")"
    if [ -z "$KEY" ]; then
        # remove/end never resolves: with no cached file there is nothing to
        # delete, and scanning ps for a session that is ending buys nothing.
        [ -n "$WORD" ] || exit 0
        KEY="$(_agent_resolve_key "$SID")"
        [ -n "$KEY" ] || exit 0
    fi
    mkdir -p "$STATE_DIR/agents" 2>/dev/null || exit 0
fi

# --- Write ------------------------------------------------------------------

if [ -n "$WORD" ]; then
    TMP="$STATE_DIR/.tmp.$$"
    printf '%s\n' "$WORD" > "$TMP" 2>/dev/null || exit 0
    mv -f "$TMP" "$STATE_DIR/$KEY" 2>/dev/null
    rm -f "$TMP" 2>/dev/null
else
    rm -f "$STATE_DIR/$KEY" 2>/dev/null
fi

# Reap — the writer's job, done opportunistically. Shared with agent-clear.sh
# --reap; the empty-listing guard inside is load-bearing (see path.sh). For a
# detached write through a stale cached pane, this is also what deletes the
# stale file so the next event re-resolves.
reap_agent_state_dir "$STATE_DIR"

# Refresh, decoupled from the user's bar. A failure never changes the exit
# status. Shared with agent-clear.sh (see path.sh).
refresh_agent_bar

exit 0
