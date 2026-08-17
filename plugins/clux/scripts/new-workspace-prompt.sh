#!/usr/bin/env bash

# prefix + A, both steps: asks for the workspace (session) name and for the
# folder, then hands both to new-workspace.sh. Runs inside
# `tmux display-popup -E`, so BOTH answers are read here, by this shell, and
# neither one ever reaches a tmux command string.
#
# That is the entire reason this is a popup rather than two command-prompts.
# `command-prompt` substitutes the typed answer into its command template
# BEFORE tmux parses that template, and tmux offers no way to escape the
# substitution. In the previous shape
#
#     bind-key A command-prompt -p "Session name:" \
#         "run-shell '.../new-workspace-prompt.sh \"%1\"'"
#
# a double quote in the answer closed the shell's quote and everything after it
# ran as a command. Typing
#
#     ws" ; touch /tmp/pwned ; "
#
# at the "Session name:" prompt created /tmp/pwned (observed on tmux 3.7b). A
# single quote instead closed tmux's own quote, and the workspace was created
# under a silently truncated name. The second command-prompt this script used
# to issue for the folder had the identical shape and the identical hole,
# despite the folder being described as the lower-risk value.
#
# No validation inside this script could have closed either one: the
# substitution happens before the script is started. The reject list below is
# therefore hygiene and not a security boundary — it keeps out a name that
# would confuse tmux's own target syntax or the status-bar format — and the
# popup is what actually makes the values safe.
#
# The name still travels to new-workspace.sh through the transient
# @clux-new-workspace-name option rather than as an argument, unchanged: tmux
# never re-parses an option value, and new-workspace.sh reads it back and
# unsets it before doing any other work.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A tty means the popup. No tty means a `run-shell` started this the old way,
# from a clux.tmux.conf written before the binding changed — `read` would hit
# EOF at once and prefix + A would look silently broken. Say what to do
# instead. /clux:setup rewrites clux.tmux.conf and redeploys the scripts in
# the same run, so the two normally move together.
if [ ! -t 0 ]; then
    tmux display-message "clux: the prefix + A binding changed — re-run /clux:setup"
    exit 0
fi

printf 'New clux workspace\n\n'

printf 'Session name: '
IFS= read -r SESSION_NAME || exit 0

# Empty means the prompt was cancelled — not an error.
if [ -z "$SESSION_NAME" ]; then
    exit 0
fi

# `read -r` stops at a newline, so a name can no longer contain one and the
# old newline arm of this case is unreachable — dropped rather than left in
# as dead reassurance.
case "$SESSION_NAME" in
    *\'*|*\"*|*\\*|*';'*|*'#'*)
        tmux display-message "clux: workspace name cannot contain a quote, backslash, semicolon, or #"
        exit 0
        ;;
esac

# Enter alone means "same as the session name", which is exactly what
# new-workspace.sh already does with an empty folder. The old second prompt
# prefilled "<name>/" for the user to complete; bash 3.2 (macOS) has no
# `read -i`, and a stated default reads better than a prefill nobody can edit.
printf 'Folder [%s]: ' "$SESSION_NAME"
IFS= read -r FOLDER_NAME || exit 0
if [ -z "$FOLDER_NAME" ]; then
    FOLDER_NAME="$SESSION_NAME"
fi

# Overwritten on every A press, so a cancelled folder prompt never leaves a
# stale name that a later, unrelated new-workspace.sh run could pick up.
tmux set-option -g "@clux-new-workspace-name" "$SESSION_NAME"

exec "$CURRENT_DIR/new-workspace.sh" "$FOLDER_NAME"
