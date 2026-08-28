#!/usr/bin/env bash

# Claude hook bridge — writes per-agent state to the state store.
# Called by Claude Code hooks on UserPromptSubmit, Notification, Stop,
# StopFailure, SessionStart and SessionEnd.
#
# GOVERNING PRINCIPLE: STATE LIVES IN FILES. HOOKS WRITE THOSE FILES. THE BAR
# ONLY READS. This script is the only writer on the Claude Code side.
#
# Two kinds of session, two keys, one store. $STORE is the store root plus the
# key of the tmux server that owns the pane (resolve_agent_server_key, path.sh)
# — a pane id repeats across servers, so it is not a key on its own:
#   interactive (TMUX + TMUX_PANE set)  ->  $STORE/<pane_id>
#   detached agent (neither set)        ->  $STORE/agents/<pane_id>~<session_id>
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
# Usage: agent-state.sh <busy|needs-you|finished|failed|remove>
# `end` is accepted as an alias of `remove` (hooks.json registers `remove`).
#
# `remove` runs on SessionEnd AND on SessionStart (matcher startup|resume|
# clear, never compact): a Claude restarted in a pane whose last session
# died without its SessionEnd would otherwise keep that session's stale
# glyph until the first prompt. `compact` is excluded on purpose — it fires
# mid-turn, and dropping the file there would blank a busy glyph while
# Claude is still working.

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
    failed)
        # StopFailure: the turn ended on an API error. The bar shows it in
        # its own colour so a stalled agent is not mistaken for a finished
        # one. Cleared the same way as `finished` — on view, or on the next
        # prompt.
        WORD="failed"
        ;;
    remove|end)
        WORD=""
        ;;
    needs-you)
        # The ONE payload-dependent branch — the only place the payload's
        # notification type is inspected in this script. The word follows
        # the sub-type, and the table matches map_event_to_type() in
        # helpers.sh so the two hooks stay consistent for the same event:
        #   needs-you  permission_prompt, idle_prompt, agent_needs_input,
        #              elicitation_dialog, elicitation_url_dialog, a quota
        #              pause that will NOT resume by itself, or no
        #              notification_type field at all (grep-fallback parity)
        #   finished   agent_completed — the dashboard's own notice that a
        #              background agent is done
        #   no-op      quota_auto_resume_fired (Claude resumed on its own,
        #              its next event states the real state), auth_success,
        #              elicitation_complete/_response, anything unknown
        # Matched on the exact `"notification_type":"<value>"` field with
        # bash's own pattern matching rather than `printf | grep`: the hook
        # payload is compact JSON, and this spawns nothing on a path that
        # fires on every notification.
        case "$INPUT" in
            *'"notification_type":"agent_completed"'*)
                WORD="finished"
                ;;
            *'"notification_type":"permission_prompt"'*|\
            *'"notification_type":"idle_prompt"'*|\
            *'"notification_type":"agent_needs_input"'*|\
            *'"notification_type":"elicitation_dialog"'*|\
            *'"notification_type":"elicitation_url_dialog"'*|\
            *'"notification_type":"quota_auto_resume_stale"'*|\
            *'"notification_type":"quota_auto_resume_disabled"'*)
                WORD="needs-you"
                ;;
            *'"notification_type"'*)
                # A type is present but is none of the kinds above — true
                # no-op, leave any existing state file exactly as it was.
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

# Which server's namespace this pane id belongs to. Resolved before any other
# key work because BOTH paths need it — the detached path's cache glob lives
# inside $STORE too. Costs one tmux round-trip on every fire; the reap and the
# refresh at the bottom already make three between them.
#
# No key means no tmux server answering, and a state file written outside a
# server directory is a file nobody can attribute later. Writing nothing is
# right: the next event, from a session that does have a server, writes it.
#
# Detached: with TMUX unset this resolves the DEFAULT socket's server, which is
# the same server resolve_agents_pane_by_cwd() lists panes from below, so the
# pane and the key can never come from different servers.
SRV="$(resolve_agent_server_key)"
[ -n "$SRV" ] || exit 0
STORE="$STATE_DIR/$SRV"

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
    for f in "$STORE/agents/"*"~$1"; do
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
    # Interactive path: this pane, in this server's namespace.
    KEY="$TMUX_PANE"
    mkdir -p "$STORE" 2>/dev/null || exit 0
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
    mkdir -p "$STORE/agents" 2>/dev/null || exit 0
fi

# --- Write ------------------------------------------------------------------

if [ -n "$WORD" ]; then
    TMP="$STORE/.tmp.$$"
    printf '%s\n' "$WORD" > "$TMP" 2>/dev/null || exit 0
    mv -f "$TMP" "$STORE/$KEY" 2>/dev/null
    rm -f "$TMP" 2>/dev/null
else
    rm -f "$STORE/$KEY" 2>/dev/null
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
