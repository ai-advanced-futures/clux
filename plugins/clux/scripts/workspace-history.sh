#!/usr/bin/env bash

# workspace-history.sh — the saved workspaces prefix + A lists.
#
# One line per workspace, "<name><TAB><absolute folder>", newest first, at
# most CLUX_WORKSPACE_MAX (9) lines, so the keys 1-9 reach every row.
#
#   workspace-history.sh path              print the file path
#   workspace-history.sh list              print the lines, newest first
#   workspace-history.sh add NAME DIR      put NAME on top (remove its old line)
#   workspace-history.sh remove NAME       remove the line of NAME
#   workspace-history.sh set-dir NAME DIR  change the folder of NAME, keep its place
#
# The file is per user, not per tmux server: it records folders, and a folder
# is the same for every server. It sits next to the agent state, under
# XDG_STATE_HOME, because clux writes it and the user does not edit it.
#
# A TAB or a newline in a name or a folder would break the line format, so
# such a value is refused (exit 1). tmux forbids neither in a session name,
# but new-workspace-prompt.sh refuses control characters before it gets here.
#
# Each write goes to a temp file next to the history and is then renamed, so a
# reader never sees half a file. Two writes at the same moment can lose one of
# the two changes; for a list that prefix + A writes, that is acceptable.

CLUX_WORKSPACE_MAX=9
HISTORY_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/clux/workspaces"

_usage() {
    echo "usage: workspace-history.sh path | list | add NAME DIR | remove NAME | set-dir NAME DIR" >&2
    exit 2
}

_bad_value() {
    case "$1" in
        *$'\t'*|*$'\n'*|'') return 0 ;;
    esac
    return 1
}

_list() {
    [ -f "$HISTORY_FILE" ] || return 0
    awk -F'\t' 'NF == 2 && $1 != "" && $2 != ""' "$HISTORY_FILE"
}

# _write <text> — replace the file with <text> (lines with a newline at the end).
_write() {
    local dir tmp
    dir="$(dirname "$HISTORY_FILE")"
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "$HISTORY_FILE.XXXXXX" 2>/dev/null)" || return 1
    chmod 600 "$tmp" 2>/dev/null
    printf '%s' "$1" > "$tmp" && mv "$tmp" "$HISTORY_FILE" || { rm -f "$tmp"; return 1; }
}

# _without NAME — the current lines, less the line of NAME.
_without() {
    _list | _WS_N="$1" awk -F'\t' '$1 != ENVIRON["_WS_N"]'
}

cmd="${1:-}"
case "$cmd" in
    path)
        printf '%s\n' "$HISTORY_FILE"
        ;;
    list)
        _list
        ;;
    add)
        [ $# -eq 3 ] || _usage
        if _bad_value "$2" || _bad_value "$3"; then exit 1; fi
        rest="$(_without "$2" | head -n $((CLUX_WORKSPACE_MAX - 1)))"
        if [ -n "$rest" ]; then
            _write "$2"$'\t'"$3"$'\n'"$rest"$'\n'
        else
            _write "$2"$'\t'"$3"$'\n'
        fi
        ;;
    remove)
        [ $# -eq 2 ] || _usage
        rest="$(_without "$2")"
        if [ -n "$rest" ]; then _write "$rest"$'\n'; else _write ""; fi
        ;;
    set-dir)
        [ $# -eq 3 ] || _usage
        if _bad_value "$3"; then exit 1; fi
        out="$(_list | _WS_N="$2" _WS_D="$3" awk -F'\t' -v OFS='\t' '$1 == ENVIRON["_WS_N"] { $2 = ENVIRON["_WS_D"] } { print }')"
        if [ -n "$out" ]; then _write "$out"$'\n'; fi
        ;;
    *)
        _usage
        ;;
esac
