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
# shellcheck source=./helpers.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/helpers.sh"

# The popup draws in the colours the BAR was configured with, translated to
# ANSI by clux_ansi() — a popup is a real terminal and cannot use a tmux
# `#[...]` format. Reusing the bar's own options is what keeps the chip here
# identical to the session chip on the bar with nothing configured twice.
CHIP="$(clux_ansi "$(get_bar_name_attached_style)")"
BRACKET="$(clux_ansi "$(get_bar_bracket_style)")"
DIM="$(clux_ansi "$(get_bar_separator_style)")"
MARK="$(clux_ansi "$(get_agent_busy_color)")"
BAD="$(clux_ansi "$(get_agent_needs_color)")"
RESET=$'\033[0m'
OPEN="$(get_tmux_option "@clux-bar-window-open" "❰")"
CLOSE="$(get_tmux_option "@clux-bar-window-close" "❱")"

# A tty means the popup. No tty means a `run-shell` started this the old way,
# from a clux.tmux.conf written before the binding changed — `read` would hit
# EOF at once and prefix + A would look silently broken. Say what to do
# instead. /clux:setup rewrites clux.tmux.conf and redeploys the scripts in
# the same run, so the two normally move together.
if [ ! -t 0 ]; then
    tmux display-message "clux: the prefix + A binding changed — re-run /clux:setup"
    exit 0
fi

# --- Esc cancels -----------------------------------------------------------
#
# `read -r` cannot see Esc: in the terminal's canonical mode it is just another
# character in the line, which is why Esc used to echo "^[" and wait. Rather
# than read key by key in raw mode, the terminal is told that Esc IS the
# interrupt character. Esc then takes the identical path Ctrl-C already took —
# SIGINT, the trap below, exit 0, and tmux closes the popup on the exit.
#
# One stty call, no raw mode, and the line keeps its normal editing.
#
# The cost is that every escape SEQUENCE starts with Esc, so an arrow key
# cancels too. In a two-field prompt with no cursor movement that is a fair
# trade for not hand-rolling a key decoder; the alternative needs a sub-second
# wait to tell Esc from an arrow, and bash 3.2 — what macOS ships and what
# runs this — rejects a fractional `read -t`.
_CLUX_STTY_SAVED=""

# Restores the terminal on EVERY exit path, including the `exec` at the end.
# The popup's pty dies with the popup anyway; this is for the case where the
# script is run from an ordinary terminal.
_clux_term_restore() {
    [ -n "$_CLUX_STTY_SAVED" ] && stty "$_CLUX_STTY_SAVED" 2>/dev/null
    _CLUX_STTY_SAVED=""
}
trap '_clux_term_restore' EXIT TERM
# A cancel is not an error: the popup closes and nothing is created. `exit`
# from inside a trap handler still runs the EXIT trap, so the restore above is
# the only one needed here (checked on bash 3.2).
trap 'exit 0' INT

_CLUX_STTY_SAVED="$(stty -g 2>/dev/null)"
# A terminal that will not take this keeps the old behaviour rather than none:
# Esc cannot cancel, Ctrl-C still can.
stty intr '^[' 2>/dev/null || :

# Header: the same chip and brackets the bar draws, then the key hints.
printf '%s New workspace %s %s%s%s %sname + folder%s %s%s%s   %s⏎ create · esc cancel%s\n\n' \
    "$CHIP" "$RESET" "$BRACKET" "$OPEN" "$RESET" "$DIM" "$RESET" \
    "$BRACKET" "$CLOSE" "$RESET" "$DIM" "$RESET"

printf '  %s▸%s name    ' "$MARK" "$RESET"
IFS= read -r SESSION_NAME || exit 0

# Empty means the prompt was cancelled — not an error.
if [ -z "$SESSION_NAME" ]; then
    exit 0
fi

# `read -r` stops at a newline, so a name can no longer contain one and the
# old newline arm of this case is unreachable — dropped rather than left in
# as dead reassurance.
#
# ":" is rejected for a different reason than the quoting characters: tmux
# ACCEPTS it in a session name but reads it as the session/window separator in
# every target. `has-session -t "=a:b"` reports "can't find session: a", so
# new-workspace.sh never sees the existing workspace; `new-window -t "a:b"`
# reports "can't find window: b"; and `move-window -t "a:b:0"` fails the same
# way. The result is a half-built workspace the user cannot reach. Refusing
# the name up front is the only place this can be stopped.
case "$SESSION_NAME" in
    *\'*|*\"*|*\\*|*';'*|*'#'*|*:*)
        # Both, on purpose: display-message is what a caller outside a popup
        # sees, and the popup covers the status line it writes to, so the same
        # text is printed here as well. The pause is what keeps `-E` from
        # closing the popup before the reason can be read.
        tmux display-message "clux: workspace name cannot contain a quote, backslash, semicolon, colon, or #"
        printf '\n  %s!%s a name cannot contain a quote, backslash, semicolon, colon or #\n' "$BAD" "$RESET"
        printf '  %spress any key%s' "$DIM" "$RESET"
        read -rsn1
        exit 0
        ;;
esac

# Enter alone means "same as the session name", which is exactly what
# new-workspace.sh already does with an empty folder. The old second prompt
# prefilled "<name>/" for the user to complete; bash 3.2 (macOS) has no
# `read -i`, and a stated default reads better than a prefill nobody can edit.
printf '  %s▸%s folder  ' "$MARK" "$RESET"
IFS= read -r FOLDER_NAME || exit 0
if [ -z "$FOLDER_NAME" ]; then
    FOLDER_NAME="$SESSION_NAME"
fi

# Overwritten on every A press, so a cancelled folder prompt never leaves a
# stale name that a later, unrelated new-workspace.sh run could pick up.
tmux set-option -g "@clux-new-workspace-name" "$SESSION_NAME"

# `exec` replaces this process, so the EXIT trap above never runs on the
# success path. Put the interrupt character back before handing over.
_clux_term_restore

exec "$CURRENT_DIR/new-workspace.sh" "$FOLDER_NAME"
