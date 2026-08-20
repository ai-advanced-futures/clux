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
#
# A pane is included whenever a state file exists for its pane id and the
# pane is still in the listing. The state file is the authoritative signal —
# only hooks/agent-state.sh writes it, and agent-clear.sh --reap /
# reap_agent_state_dir() delete it once the pane is gone. The Claude
# binary's own command name (e.g. `2.1.233` on many installs) is NOT
# consulted.
#
# Only THIS tmux server's state is read. Pane ids repeat across servers — two
# servers both start at %0 — so the store is one directory per server and this
# reads exactly one of them. Another server's agents are that server's bar to
# draw, and its session names are not even resolvable from here.
#
# Detached agents contribute through a second pass: agents/<pane>~<sid> files
# rank into the session that owns <pane> (the `claude agents` dashboard's
# pane), and the existing max-rank roll-up then gives a dashboard column
# needs-you if any agent needs you, else busy if any is busy, else finished.
# Same skip rule: a file whose pane is not in the listing is ignored, never
# deleted.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"

STATE_DIR="$(resolve_agent_state_dir)"
[ -d "$STATE_DIR" ] || exit 0

# The server key leads every row. It is the same on all of them — one server
# answers one listing — so it costs nothing to ask for, and it is what keeps
# this bar from reading the state of a Claude running under a DIFFERENT tmux
# server, which numbers its panes from %0 exactly as this one does. This is the
# hottest path in clux (one run per status redraw, per client), so the key is
# folded into the format already being fetched rather than asked for
# separately.
PANES=$(tmux list-panes -a -F '#{pid}-#{start_time}|#{pane_id}|#{session_name}' 2>/dev/null)
[ -n "$PANES" ] || exit 0

SRV="${PANES%%|*}"
_clux_valid_server_key "$SRV" || exit 0
STORE="$STATE_DIR/$SRV"
[ -d "$STORE" ] || exit 0

ROWS=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Drop the leading server key, which is constant across the listing.
    line="${line#*|}"
    # pane_id has no '|'; session_name may — so split on the first '|' only.
    pane="${line%%|*}"
    sess="${line#*|}"

    [ -n "$pane" ] || continue
    f="$STORE/$pane"
    IFS= read -r st 2>/dev/null < "$f" || continue
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

# Second pass: detached-agent files. The pane id comes from the file NAME
# (before the '~'), so the join against the listing is the same exact-name
# lookup — no tmux call and no ps call is added.
for f in "$STORE"/agents/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    case "$base" in
        .tmp.*) continue ;;
        %*~*) ;;
        *) continue ;;
    esac
    pane="${base%%~*}"

    IFS= read -r st 2>/dev/null < "$f" || continue
    st="${st//[[:space:]]/}"
    case "$st" in
        needs-you) rank=3 ;;
        busy)      rank=2 ;;
        finished)  rank=1 ;;
        *)         continue ;;
    esac

    sess=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        line="${line#*|}"          # drop the leading server key
        if [ "${line%%|*}" = "$pane" ]; then
            sess="${line#*|}"
            break
        fi
    done <<EOF
$PANES
EOF
    [ -n "$sess" ] || continue

    ROWS="${ROWS}${sess}	${rank}
"
done

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
