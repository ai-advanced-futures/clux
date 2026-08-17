#!/usr/bin/env bash

# Builds the clux workspace: window "---" at index 0 running the editor,
# window "claude" at index 1 running the agents dashboard, both names pinned
# with automatic-rename off. That layout is the one default shape and does
# not change (see docs/superpowers/specs/2026-08-16-clux-session-surface-design.md).
#
# Port of new-session.sh (404pilo/config, tmux/scripts/). What changed:
#   - the directory resolver, the editor, and the agents-dashboard command are
#     now @clux-* options instead of hardcoded autojump/nvim/claude, each with
#     a documented fallback so a bare machine still gets a working workspace;
#   - windows are addressed by the window ID new-session/new-window hand back
#     (-P -F '#{window_id}'), not by index, removing a whole class of
#     renumbering bugs;
#   - base-index is read from tmux, not hardcoded — the move-window to index 0
#     runs only when base-index > 0;
#   - has-session is checked with a leading "=" for exact matching before
#     creating, so a name that is a prefix of an existing session no longer
#     collides with it;
#   - the script derives its own socket from $TMUX so it also runs detached —
#     from a plain shell, or under bats.
#
# Usage: new-workspace.sh <folder-name>
# The workspace (session) name is NOT an argument here — it is read back from
# the transient @clux-new-workspace-name option (written by
# new-workspace-prompt.sh) and unset immediately, before any other work, so a
# stale value can never leak into an unrelated invocation.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/helpers.sh"

FOLDER_NAME="$1"

# Socket derivation: -S "${TMUX%%,*}" when $TMUX is set, plain "tmux"
# (default socket) otherwise. Every tmux call below goes through this one
# wrapper, so the script works the same attached or fully detached.
if [ -n "${TMUX:-}" ]; then
    TMUX_SOCKET="${TMUX%%,*}"
    _tmux() { tmux -S "$TMUX_SOCKET" "$@"; }
else
    _tmux() { tmux "$@"; }
fi

SESSION_NAME=$(_tmux show-option -gqv "@clux-new-workspace-name" 2>/dev/null)
_tmux set-option -gu "@clux-new-workspace-name" 2>/dev/null

if [ -z "$SESSION_NAME" ]; then
    exit 0
fi

# Default folder name to the session name.
if [ -z "$FOLDER_NAME" ]; then
    FOLDER_NAME="$SESSION_NAME"
fi

# Exact match ("=name") — "has-session -t foo" without the "=" also matches
# "foobar", a live bug in the original. On a hit, land on the existing
# session instead of failing.
if _tmux has-session -t "=$SESSION_NAME" 2>/dev/null; then
    if [ -n "${TMUX:-}" ]; then
        _tmux switch-client -t "$SESSION_NAME"
    else
        printf '%s\n' "$SESSION_NAME"
    fi
    exit 0
fi

_clux_expand_tilde() {
    case "$1" in
        "~") printf '%s' "$HOME" ;;
        "~/"*) printf '%s' "${HOME}/${1#\~/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Existing-directory short-circuit: absolute, ~-prefixed, or relative to the
# invoking pane's path. Wins in EVERY @clux-dir-resolver mode, before the
# resolver is consulted. With no invoking pane ($TMUX unset — a plain shell
# or bats), the script's own working directory stands in for the pane path.
_clux_resolve_existing_dir() {
    local input="$1" pane_path="$2" expanded
    expanded=$(_clux_expand_tilde "$input")
    case "$expanded" in
        /*)
            [ -d "$expanded" ] && { printf '%s' "$expanded"; return 0; }
            return 1
            ;;
    esac
    if [ -n "$pane_path" ] && [ -d "$pane_path/$expanded" ]; then
        printf '%s' "$pane_path/$expanded"
        return 0
    fi
    return 1
}

if [ -n "${TMUX:-}" ]; then
    PANE_PATH=$(_tmux display-message -p '#{pane_current_path}' 2>/dev/null)
else
    PANE_PATH="$PWD"
fi

PROJECT_DIR=""
if resolved=$(_clux_resolve_existing_dir "$FOLDER_NAME" "$PANE_PATH"); then
    PROJECT_DIR="$resolved"
fi

# @clux-dir-resolver: autojump | zoxide | path (default path). A missing
# resolver binary degrades to path mode plus one display-message; "path" mode
# adds nothing beyond the existing-directory check above, since it IS that
# check (treat the input as a path, expand ~).
if [ -z "$PROJECT_DIR" ]; then
    RESOLVER_MODE=$(get_tmux_option "@clux-dir-resolver" "path")
    case "$RESOLVER_MODE" in
        autojump)
            if command -v autojump >/dev/null 2>&1; then
                # autojump requires this env var when called outside shell integration
                export AUTOJUMP_SOURCED=1
                candidate=$(autojump "$FOLDER_NAME" 2>/dev/null)
                [ -n "$candidate" ] && [ -d "$candidate" ] && PROJECT_DIR="$candidate"
            else
                _tmux display-message "clux: autojump not found, using plain path" 2>/dev/null
            fi
            ;;
        zoxide)
            if command -v zoxide >/dev/null 2>&1; then
                candidate=$(zoxide query -- "$FOLDER_NAME" 2>/dev/null)
                [ -n "$candidate" ] && [ -d "$candidate" ] && PROJECT_DIR="$candidate"
            else
                _tmux display-message "clux: zoxide not found, using plain path" 2>/dev/null
            fi
            ;;
    esac
fi

# Unresolvable: create nothing — a session with a window in the wrong
# directory is worse than no session.
if [ -z "$PROJECT_DIR" ]; then
    _tmux display-message "clux: no directory for '$FOLDER_NAME'" 2>/dev/null
    exit 1
fi

# @clux-editor: value as configured; when unset entirely, the run-time ladder
# is nvim, then vim, then the "none" sentinel. $EDITOR is a SETUP-time-only
# signal (the configuring-tmux skill's --allow-env path) — never read here,
# so the workspace cannot differ per client environment.
_clux_get_editor() {
    local val
    val=$(get_tmux_option "@clux-editor" "")
    if [ -n "$val" ]; then
        printf '%s' "$val"
        return
    fi
    if command -v nvim >/dev/null 2>&1; then
        printf 'nvim'
    elif command -v vim >/dev/null 2>&1; then
        printf 'vim'
    else
        printf 'none'
    fi
}

# @clux-agents-command: default 'claude agents --cwd "$PWD"'. The literal
# $PWD must survive — it is expanded by the target pane's own shell after
# send-keys, not by this script — so the fallback here is single-quoted.
_clux_get_agents_command() {
    get_tmux_option "@clux-agents-command" 'claude agents --cwd "$PWD"'
}

EDITOR_CMD=$(_clux_get_editor)
AGENTS_CMD=$(_clux_get_agents_command)

BASE_INDEX=$(_tmux show-option -gqv base-index 2>/dev/null)
[ -z "$BASE_INDEX" ] && BASE_INDEX=0

# Create session — window starts at base-index, named "---".
if [ -n "${TMUX:-}" ]; then
    WIN_ID_EDITOR=$(TMUX="" tmux -S "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" \
        -c "$PROJECT_DIR" -n "---" -P -F '#{window_id}')
else
    WIN_ID_EDITOR=$(tmux new-session -d -s "$SESSION_NAME" \
        -c "$PROJECT_DIR" -n "---" -P -F '#{window_id}')
fi

# Pin the name. The "---" window is always created and pinned, regardless of
# the editor choice — the "none" sentinel means nothing is sent to it, not
# that it does not exist, so the workspace shape stays the one default shape.
_tmux set-option -w -t "$WIN_ID_EDITOR" automatic-rename off
if [ "$EDITOR_CMD" != "none" ]; then
    _tmux send-keys -t "$WIN_ID_EDITOR" "$EDITOR_CMD" Enter
fi

# Move to index 0 only when base-index put it somewhere else.
if [ "$BASE_INDEX" -gt 0 ] 2>/dev/null; then
    _tmux move-window -s "$WIN_ID_EDITOR" -t "${SESSION_NAME}:0"
fi

# Create "claude" window (next available index after the editor window).
WIN_ID_CLAUDE=$(_tmux new-window -t "$SESSION_NAME" -n "claude" -c "$PROJECT_DIR" \
    -P -F '#{window_id}')
_tmux set-option -w -t "$WIN_ID_CLAUDE" automatic-rename off
if [ "$AGENTS_CMD" != "none" ]; then
    _tmux send-keys -t "$WIN_ID_CLAUDE" "$AGENTS_CMD" Enter
fi

# Select the editor window.
_tmux select-window -t "$WIN_ID_EDITOR"

# Switch to the new session when there is a client to switch; otherwise print
# the name and let the caller (a plain shell, or bats) decide what to do.
if [ -n "${TMUX:-}" ]; then
    _tmux switch-client -t "$SESSION_NAME"
else
    printf '%s\n' "$SESSION_NAME"
fi

exit 0
