#!/usr/bin/env bash

# agent-query.sh — the read path. Joins one tmux pane listing against the
# agent-state directory and prints the per-session roll-up.
#
# READ ONLY — never creates, writes, truncates, renames or deletes anything,
# not even a stale state file and not even a `mkdir -p` of the state
# directory. Reaping is a writer's job (hooks/agent-state.sh, agent-clear.sh).
#
# Output contract: one line per NON-IDLE session, `<session_name><TAB><state>`
# where state is needs-you|busy|finished. Nothing at all when every session is
# idle. Lines are sorted by precedence rank DESC, then session name ASC, in
# byte order (LC_ALL=C). Idle sessions are never printed.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"

STATE_DIR="$(resolve_agent_state_dir)"
[ -d "$STATE_DIR" ] || exit 0

PANES=$(tmux list-panes -a -F '#{pane_id}|#{session_name}|#{pane_current_command}' 2>/dev/null)
[ -n "$PANES" ] || exit 0

ROWS=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Split by hand, not IFS='|' read: a session name may itself contain '|'.
    # A pane id and pane_current_command never do.
    pane="${line%%|*}"
    rest="${line#*|}"
    cmd="${rest##*|}"
    sess="${rest%|*}"

    [ -n "$pane" ] || continue
    [ "$cmd" = "claude" ] || continue
    f="$STATE_DIR/$pane"
    [ -f "$f" ] || continue

    st=""
    IFS= read -r st < "$f" 2>/dev/null || true
    st="${st//[[:space:]]/}"

    case "$st" in
        needs-you) rank=3 ;;
        busy)      rank=2 ;;
        finished)  rank=1 ;;
        *)         continue ;;
    esac

    ROWS="${ROWS}${sess}	${rank}
"
done <<EOF
$PANES
EOF

[ -n "$ROWS" ] || exit 0

# Roll up to the highest rank per session (awk iteration order is undefined,
# hence the sort that follows), then sort rank DESC, session ASC, then map the
# rank back to its state word.
printf '%s' "$ROWS" \
    | awk -F'\t' '{ if ($2+0 > r[$1]+0) r[$1]=$2 } END { for (s in r) printf "%s\t%s\n", s, r[s] }' \
    | LC_ALL=C sort -t"$(printf '\t')" -k2,2nr -k1,1 \
    | awk -F'\t' '{
        state = ($2 == 3) ? "needs-you" : ($2 == 2) ? "busy" : "finished";
        printf "%s\t%s\n", $1, state
    }'

exit 0
