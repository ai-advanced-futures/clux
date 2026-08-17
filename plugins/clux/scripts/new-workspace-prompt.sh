#!/usr/bin/env bash

# Step 1 of 2 for prefix + A: receives the typed workspace (session) name,
# validates it, then prompts for a folder name (prepopulated with the
# session name) before calling new-workspace.sh.
#
# Port of new-session-prompt.sh (404pilo/config, tmux/scripts/). What changed:
# the session name no longer gets embedded into the second command-prompt's
# run-shell string — that string only ever carries %1 (the folder). The name
# travels instead through the transient global option @clux-new-workspace-name,
# which new-workspace.sh reads back and unsets before doing any other work.
# Only the lower-risk value (the folder) still reaches a tmux command string
# this way; tmux never re-parses an option value, so the option hop is the
# safe one.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_NAME="$1"

# Empty means the prompt was cancelled (Escape) — not an error.
if [ -z "$SESSION_NAME" ]; then
    exit 0
fi

# Reject a name containing a quote, backslash, semicolon, #, or a newline.
# These are exactly the characters that would be dangerous if this value were
# ever embedded in a tmux command string; the option hop above means it no
# longer needs to be, but the reject list stays as the defense-in-depth spec
# calls for.
case "$SESSION_NAME" in
    *\'*|*\"*|*\\*|*';'*|*'#'*|*$'\n'*)
        tmux display-message "clux: workspace name cannot contain a quote, backslash, semicolon, #, or a newline"
        exit 0
        ;;
esac

# Overwritten on every A press, so a cancelled folder prompt never leaves a
# stale name that a later, unrelated new-workspace.sh run could pick up.
tmux set-option -g "@clux-new-workspace-name" "$SESSION_NAME"

# Prefill with "<name>/" — a trailing slash the user completes, e.g. into an
# autojump-friendly prefix. The command text carries only %1 (the folder);
# new-workspace.sh reads the session name back from the option.
tmux command-prompt -I "${SESSION_NAME}/" -p "Folder name:" \
    "run-shell '$CURRENT_DIR/new-workspace.sh \"%1\"'"
