#!/usr/bin/env bash
# One parse of one notification queue line, for every caller.
#
#   notification-line.sh path             prints the queue path
#   notification-line.sh jump "<line>"    goes to the window of a line
#   notification-line.sh remove "<line>"  takes a line out of the queue
#
# Before this file, jump-to-notification.sh and notification-picker.sh each
# held their own copy of the parse, and they already disagreed: the picker
# jumped by name and the key jumped by id. The Claude Code notifications pane
# would have been a third copy, so the parse lives here alone and every
# caller runs this script.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"
NOTIFY_FILE=$(resolve_notify_file)
LOCKDIR="${NOTIFY_FILE}.lock"

VERB="${1:-}"
LINE="${2:-}"

# Take the queue lock. The writers (acquire_lock in helpers.sh) use flock on
# "<queue>.flock" when flock is installed, and the mkdir directory when it is
# not; dismiss-notification.sh uses the mkdir directory only. This remove
# takes BOTH, so it excludes every writer on every host: with only one of the
# two, a notification that a writer appends between the grep and the mv below
# is lost. flock waits 1 second at most: a whole number, because some flock
# builds do not accept a fraction. mkdir is atomic on every filesystem; five
# tries at 100 ms is the 500 ms budget of a key the person pressed. A lock
# directory older than 10
# seconds is the leftover of a killed process, so it goes.
_take_lock() {
    local now mtime i=0
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${NOTIFY_FILE}.flock" || return 1
        flock -w 1 9 || return 1
    fi
    if [ -d "$LOCKDIR" ]; then
        now=$(date +%s)
        # GNU stat (-c %Y) first: on Linux `stat -f` means --file-system and
        # "succeeds" with garbage instead of failing, so it must not be tried
        # first. BSD/macOS stat rejects -c and falls through to -f %m.
        mtime=$(stat -c %Y "$LOCKDIR" 2>/dev/null || stat -f %m "$LOCKDIR" 2>/dev/null || echo "$now")
        [ $(( now - mtime )) -gt 10 ] && rm -rf "$LOCKDIR"
    fi
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -ge 5 ] && return 1
        sleep 0.1
    done
    trap 'rm -rf "$LOCKDIR"' EXIT
    return 0
}

# Remove each line EQUAL to $LINE. The picker used `grep -vF`, which also
# removes a longer line that holds the argument inside it; -x removes an equal
# line only. The new file goes into place with mv, so a reader never sees a
# part list. grep exits 1 when every line matched, which is the "queue is now
# empty" case and not a failure. grep exits 2 when it cannot read the queue:
# then the empty .tmp says nothing about the queue, so the queue stays as it
# is and the remove is a failure. -e keeps a line that starts with "-" a
# pattern, not an option.
_remove() {
    local rc
    [ -n "$LINE" ] || return 0
    [ -s "$NOTIFY_FILE" ] || return 0
    _take_lock || return 1
    grep -vxF -e "$LINE" "$NOTIFY_FILE" > "${NOTIFY_FILE}.tmp" 2>/dev/null
    rc=$?
    if [ "$rc" -gt 1 ]; then
        rm -f "${NOTIFY_FILE}.tmp"
        return 1
    fi
    if [ -s "${NOTIFY_FILE}.tmp" ]; then
        mv "${NOTIFY_FILE}.tmp" "$NOTIFY_FILE"
    else
        rm -f "${NOTIFY_FILE}.tmp" "$NOTIFY_FILE"
    fi
    return 0
}

# A "<session_id>:<window_id>" tail, from ||| or from the legacy |ID: marker.
# A tail with no colon leaves both halves equal to the whole tail, which is a
# line that names no target, so the equality guard is the target test.
_jump_ids() {
    local id_part="$1" session_id window_id
    session_id="${id_part%%:*}"
    window_id="${id_part#*:}"
    [ -n "$session_id" ] && [ -n "$window_id" ] && [ "$session_id" != "$window_id" ] || return 1
    tmux select-window -t "$session_id:$window_id" 2>/dev/null || return 1
    tmux switch-client -t "$session_id" 2>/dev/null || return 1
    return 0
}

# The oldest shape: "<session>:<window> <message>", by name.
_jump_name() {
    local session remainder window
    case "$LINE" in
        *:*) ;;
        *) return 1 ;;
    esac
    session="${LINE%%:*}"
    remainder="${LINE#*:}"
    window="${remainder%% *}"
    [ -n "$session" ] && [ -n "$window" ] || return 1
    tmux select-window -t "$session:$window" 2>/dev/null || return 1
    tmux switch-client -t "$session" 2>/dev/null || return 1
    return 0
}

case "$VERB" in
    path)
        printf '%s\n' "$NOTIFY_FILE"
        exit 0
        ;;
    remove)
        _remove
        exit $?
        ;;
    jump) ;;
    *)
        printf 'usage: notification-line.sh path|jump <line>|remove <line>\n' >&2
        exit 2
        ;;
esac

# --- jump --------------------------------------------------------------
[ -n "$LINE" ] || exit 1

case "$LINE" in
    # FIRST, before the generic ||| arm below: an agent line also holds |||.
    *"|||agent:"*) ;;
    *"|||"*)
        _jump_ids "${LINE##*|||}"
        exit $?
        ;;
    *"|ID:"*)
        _jump_ids "${LINE##*|ID:}"
        exit $?
        ;;
    *)
        _jump_name
        exit $?
        ;;
esac

# --- jump, an agent line -------------------------------------------------
# Line shape (new):    "<marker> <label>|||agent:<SID>@@<TMUXSID>:<WID>:<PID>@@<CWD>"
# Line shape (legacy): "<marker> <label>|||agent:<SID>"
#
# agent_jump always returns 0, and the jump clears the line after it. With no
# tmux server there is no place to go, so stop here with exit 1 and keep the
# line: the pane then says it could not jump, as it does for a window line.
tmux list-sessions >/dev/null 2>&1 || exit 1

_AGENT_QUEUE="$NOTIFY_FILE"   # the queue the three tiers resolved
# shellcheck source=./helpers.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/helpers.sh"
# helpers.sh re-derives NOTIFY_FILE from get_tmux_option at source time, which
# knows nothing of the three tiers — put the resolved queue back, so
# _agent_remove_entry locks and clears the file this script read.
NOTIFY_FILE="$_AGENT_QUEUE"
recompute_lock_target

rest="${LINE##*|||agent:}"
# Split rest on @@ into three segments. For a legacy line (no @@) seg2 and
# seg3 MUST be force-emptied: ${rest#*@@} returns rest UNCHANGED when there is
# no delimiter, which would make seg2 wrongly equal the SID.
seg1="${rest%%@@*}"
if [[ "$rest" != *@@* ]]; then
    seg2=""
    seg3=""
else
    after1="${rest#*@@}"
    seg2="${after1%%@@*}"
    seg3="${after1#*@@}"
fi
remove_key="$seg1"   # the dedup key is the display SID, NOT the pane coords

# The pane id is seg2's LAST colon token (TMUXSID:WID:PID), not seg1.
if [ -n "$seg2" ]; then
    pane_id="${seg2##*:}"
    sid="${seg2%%:*}"
    _mid="${seg2#*:}"
    wid="${_mid%%:*}"
    target="$sid $wid $pane_id"
else
    target=""
fi

agent_jump "$target" "$seg3"      # fast-path / re-resolve / v3 fallback
_agent_remove_entry "$remove_key" # clear-on-jump, both line formats
tmux refresh-client -S 2>/dev/null
exit 0
