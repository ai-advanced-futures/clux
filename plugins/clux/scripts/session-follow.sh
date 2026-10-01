#!/usr/bin/env bash
# session-follow.sh — mirror mode: all clients of this tmux server show the
# same session. When one client changes session, the others go with it.
# Usage: session-follow.sh [status|on|off]     (run by /clux:follow)
#        session-follow.sh sync '<client>'     (run by the tmux hook)
#
# The state is the hook itself. `on` sets client-session-changed[92] and `off`
# removes it, so there is no option that can disagree with the hook, and mirror
# mode costs nothing while it is off. The hook is server state: a new tmux
# server starts with mirror mode off.
#
# `sync` moves only the clients that are on a DIFFERENT session. That is what
# stops a loop: tmux fires client-session-changed for each client that `sync`
# moves, and also for a switch to the session a client is on already (seen on
# tmux 3.5a). With the difference test, the second pass finds nothing to move.
#
# `sync` reads the session of the client when it runs, not from a format in the
# hook line. A format in the hook line gives the old session for a client that
# another `sync` moved (seen on tmux 3.5a), and that also makes a loop.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK='client-session-changed[92]'
TAB=$'\t'

is_on() {
    tmux show-hooks -g 2>/dev/null | grep -F "$HOOK" | grep -qF 'session-follow.sh'
}

# sync <client> — move each client on a different session to the session of
# <client>.
#
# The session is read, compared and targeted by its id ($3), never by its
# name. A name is not a safe target: tmux reads `a.c` as window a pane c, `a:c`
# as session a window c, and `%2` and `$9` as a pane id and a session id.
sync() {
    local leader="$1" target name session
    [[ -n "$leader" ]] || return 0
    target=$(tmux display-message -p -c "$leader" '#{session_id}' 2>/dev/null)
    [[ "$target" == \$* ]] || return 0
    while IFS="$TAB" read -r name session; do
        [[ -n "$name" && "$session" != "$target" ]] || continue
        tmux switch-client -c "$name" -t "$target" 2>/dev/null
    done < <(tmux list-clients -F "#{client_name}${TAB}#{session_id}" 2>/dev/null)
    return 0
}

status() {
    if is_on; then echo "follow: on"; else echo "follow: off"; fi
    echo "sessions:"
    tmux list-sessions -F '  #{session_name}  #{session_windows} windows#{?session_attached,  (attached),}' 2>/dev/null
    echo "clients:"
    tmux list-clients -F '  #{client_name}  #{client_session}  #{client_width}x#{client_height}' 2>/dev/null
}

case "${1:-status}" in
    on)
        tmux set-hook -g "$HOOK" "run-shell \"$CURRENT_DIR/session-follow.sh sync '#{hook_client}'\"" || exit 1
        # The clients can be on different sessions now. The client that was
        # used last is the one the user looks at, so the others go to it.
        latest=$(tmux list-clients -F "#{client_activity}${TAB}#{client_name}" 2>/dev/null \
            | sort -n | tail -1 | cut -f2)
        sync "$latest"
        status
        ;;
    off)
        tmux set-hook -gu "$HOOK" 2>/dev/null
        status
        ;;
    status)
        status
        ;;
    sync)
        sync "${2:-}"
        ;;
    *)
        echo "usage: session-follow.sh [status|on|off]" >&2
        exit 2
        ;;
esac
