#!/usr/bin/env bash

# prefix + A: one text box for the workspace (session) name. Type a name, and
# the saved workspaces that match show under it:
#
#   Enter              go: a new workspace with the typed name (then the
#                      folder question), or the workspace of that exact name
#   Down               pick the top match; Down again moves down the list
#   Up from the top    no row picked again; typing also un-picks
#   Tab                put the name of the current row in the box
#   Esc / Ctrl-C       cancel
#
# The prompt always says what Enter does: "new", "open" (a saved workspace
# that does not run) or "switch to" (a session that runs on this server).
# While you type, the rest of the current row's name shows in gray after the
# typed text. Without fzf, the box is a plain name prompt with no list.
#
# Runs inside `tmux display-popup -E`, so every answer is read here, by this
# shell (or by fzf, whose output this shell reads), and no answer ever reaches
# a tmux command string.
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

# --- fzf helper mode -------------------------------------------------------
#
# fzf runs "new-workspace-prompt.sh --fzf EVENT [FIELD]" on each key, and does
# the actions this prints. It reads fzf's state from $FZF_* and the rows from
# $CLUX_WS_ROWS only — no tmux call and no helpers.sh — so it stays fast, and
# it sits above everything else so nothing else runs first.
#
# The POINTER holds the state: " " = no row picked, "▸" = a row picked. That
# leaves the PROMPT free to say what Enter does.
#
# Each row is "<shown name>\t<shown folder>\t<name>\t<folder>\t<live|saved>";
# FIELD is field 5 (focus, down) or field 3 (ghost) of the current row.
if [ "${1:-}" = --fzf ]; then
    P_NEW='new       ▸ '
    P_OPEN='open      ▸ '
    P_SWITCH='switch to ▸ '
    _row_prompt() {
        if [ "$1" = live ]; then printf '%s' "$P_SWITCH"; else printf '%s' "$P_OPEN"; fi
    }
    # "new", unless the typed text is exactly the name of a row.
    _typed_prompt() {
        local st=""
        if [ -n "${FZF_QUERY:-}" ]; then
            st="$(awk -F'\t' '$3 == ENVIRON["FZF_QUERY"] { print $5; exit }' "${CLUX_WS_ROWS:-/dev/null}" 2>/dev/null)"
        fi
        if [ -n "$st" ]; then _row_prompt "$st"; else printf '%s' "$P_NEW"; fi
    }
    _picked() { [ "${FZF_POINTER:-}" = '▸' ]; }
    case "${2:-}" in
        change)
            label=' recents '
            [ -n "${FZF_QUERY:-}" ] && label=' matches '
            printf 'first+change-pointer( )+change-prompt(%s)+change-list-label(%s)' "$(_typed_prompt)" "$label"
            ;;
        focus)
            _picked && printf 'change-prompt(%s)' "$(_row_prompt "${3:-}")"
            ;;
        down)
            if _picked; then
                printf 'down'
            elif [ "${FZF_MATCH_COUNT:-0}" -gt 0 ]; then
                # The first Down picks the top row; it does not move past it.
                printf 'change-pointer(▸)+change-prompt(%s)' "$(_row_prompt "${3:-}")"
            fi
            ;;
        up)
            if _picked; then
                if [ "${FZF_POS:-1}" -le 1 ]; then
                    printf 'change-pointer( )+change-prompt(%s)' "$(_typed_prompt)"
                else
                    printf 'up'
                fi
            fi
            ;;
        enter)
            if _picked; then printf 'print(OPEN)+accept'; else printf 'print(NEW)+accept'; fi
            ;;
        ghost)
            # The rest of the row's name after the typed text, or "→ name" when
            # the name does not start with it. NOTHING when nothing is left:
            # an empty colour sequence is drawn as text by fzf's info line.
            q="${FZF_QUERY:-}"
            n="${3:-}"
            [ -n "$q" ] && [ -n "$n" ] || exit 0
            case "$n" in
                "$q") ;;
                "$q"*) printf '%s%s\033[0m' "${CLUX_WS_GHOST:-}" "${n#"$q"}" ;;
                *) printf '%s  → %s\033[0m' "${CLUX_WS_GHOST:-}" "$n" ;;
            esac
            ;;
    esac
    exit 0
fi

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
TAB=$'\t'
NL=$'\n'
HISTORY="$CURRENT_DIR/workspace-history.sh"

# A tty means the popup. No tty means a `run-shell` started this the old way,
# from a clux.tmux.conf written before the binding changed — `read` would hit
# EOF at once and prefix + A would look silently broken. Say what to do
# instead. /clux:setup rewrites clux.tmux.conf and redeploys the scripts in
# the same run, so the two normally move together.
if [ ! -t 0 ]; then
    tmux display-message "clux: the prefix + A binding changed — re-run /clux:setup"
    exit 0
fi

# --- Esc and Ctrl-C both cancel the plain prompts --------------------------
#
# fzf reads its own keys, so this is for the `read` prompts: the name prompt
# without fzf, and the folder question.
#
# `read -r` cannot see Esc: in the terminal's canonical mode it is just another
# character in the line, which is why Esc used to echo "^[" and wait. Rather
# than read key by key in raw mode, the terminal is told that Esc IS the
# interrupt character, so Esc raises SIGINT and the trap below closes the
# popup.
#
# `intr` names ONE character, so that alone would TAKE Ctrl-C away: it would
# stop raising SIGINT and land in the line as a literal \003. Ctrl-C is
# therefore moved onto `quit`, which raises SIGQUIT, and the trap catches both
# signals. Both keys cancel, and the key `quit` gave up (Ctrl-\) has no use in
# a two-field prompt.
#
# No raw mode, and the line keeps its normal editing. The cost is that every
# escape SEQUENCE starts with Esc, so an arrow key cancels too; bash 3.2 —
# what macOS ships and what runs this — rejects the fractional `read -t` that
# telling the two apart would need.
_CLUX_STTY_SAVED=""
_CLUX_WS_ROWS=""

# Restores the terminal and removes the rows file on EVERY exit path. The
# `exec`s below skip the EXIT trap, so each one calls _clux_cleanup first.
_clux_cleanup() {
    [ -n "$_CLUX_STTY_SAVED" ] && stty "$_CLUX_STTY_SAVED" 2>/dev/null
    _CLUX_STTY_SAVED=""
    [ -n "$_CLUX_WS_ROWS" ] && rm -f "$_CLUX_WS_ROWS"
    _CLUX_WS_ROWS=""
}
trap '_clux_cleanup' EXIT TERM
# A cancel is not an error: the popup closes and nothing is created. `exit`
# from inside a trap handler still runs the EXIT trap (checked on bash 3.2).
trap 'exit 0' INT QUIT

_clux_plain_keys() {
    [ -n "$_CLUX_STTY_SAVED" ] && return 0
    _CLUX_STTY_SAVED="$(stty -g 2>/dev/null)"
    # A terminal that takes neither keeps the old behaviour rather than none:
    # Esc cannot cancel, and Ctrl-C is untouched because `intr` never moved.
    stty intr '^[' 2>/dev/null || :
    stty quit '^C' 2>/dev/null || :
}

# The guard for a terminal that took `intr` but not `quit`: Ctrl-C would then
# be a literal \003 in the line, and the reject list below names no control
# character. A control character is never part of a name anybody typed on
# purpose, so it is read as the cancel the user meant.
_clux_cancelled_line() {
    case "$1" in
        *[[:cntrl:]]*) return 0 ;;
        *) return 1 ;;
    esac
}

# The header the plain prompts draw: the same chip and brackets the bar draws.
_clux_header() {
    printf '\033[H\033[2J'
    printf '%s New workspace %s %s%s%s %sname + folder%s %s%s%s   %s⏎ create · esc cancel%s\n\n' \
        "$CHIP" "$RESET" "$BRACKET" "$OPEN" "$RESET" "$DIM" "$RESET" \
        "$BRACKET" "$CLOSE" "$RESET" "$DIM" "$RESET"
}

# _clux_ask_folder NAME — the folder question, with NAME as the stated
# default. Sets FOLDER_NAME, or exits on a cancel.
_clux_ask_folder() {
    _clux_plain_keys
    # Enter alone means "same as the session name", which is exactly what
    # new-workspace.sh already does with an empty folder. The default is
    # STATED, not prefilled — bash 3.2 has no `read -i` — and the dim suffix is
    # the whole reason Enter alone is usable here.
    printf '  %s▸%s folder  %s[%s]%s ' "$MARK" "$RESET" "$DIM" "$1" "$RESET"
    IFS= read -r FOLDER_NAME || exit 0
    if _clux_cancelled_line "$FOLDER_NAME"; then
        exit 0
    fi
    [ -n "$FOLDER_NAME" ] || FOLDER_NAME="$1"
}

# _clux_go NAME FOLDER — hand both to new-workspace.sh. Never returns.
_clux_go() {
    # Overwritten on every A press, so a cancelled folder prompt never leaves a
    # stale name that a later, unrelated new-workspace.sh run could pick up.
    tmux set-option -g "@clux-new-workspace-name" "$1"
    _clux_cleanup
    exec "$CURRENT_DIR/new-workspace.sh" "$2"
}

# _clux_reject NAME — refuse a name tmux cannot address. Exits when refused.
#
# `read -r` stops at a newline and fzf's query is one line, so a name cannot
# contain one. ":" is rejected for a different reason than the quoting
# characters: tmux ACCEPTS it in a session name but reads it as the
# session/window separator in every target. `has-session -t "=a:b"` reports
# "can't find session: a", so new-workspace.sh never sees the existing
# workspace; `new-window -t "a:b"` reports "can't find window: b"; and
# `move-window -t "a:b:0"` fails the same way. The result is a half-built
# workspace the user cannot reach. Refusing the name up front is the only place
# this can be stopped.
_clux_reject() {
    case "$1" in
        *\'*|*\"*|*\\*|*';'*|*'#'*|*:*|*[[:cntrl:]]*)
            # Both, on purpose: display-message is what a caller outside a
            # popup sees, and the popup covers the status line it writes to, so
            # the same text is printed here as well. The pause is what keeps
            # `-E` from closing the popup before the reason can be read.
            tmux display-message "clux: workspace name cannot contain a quote, backslash, semicolon, colon, or #"
            # One SHORT line: the popup is sixty columns wide inside its
            # border, and a longer sentence wraps and pushes the header off.
            printf '  %s!%s a name cannot hold  '"'"' " \\ ; : or #\n' "$BAD" "$RESET"
            printf '  %spress any key%s' "$DIM" "$RESET"
            read -rsn1
            exit 0
            ;;
    esac
}

# --- The saved workspaces --------------------------------------------------

LIVE="$NL$(tmux list-sessions -F '#{session_name}' 2>/dev/null)$NL"
_ws_is_live() {
    case "$LIVE" in *"$NL$1$NL"*) return 0 ;; esac
    return 1
}

# _ws_short PATH — ~ for the home folder.
_ws_short() {
    local p="$1"
    case "$p" in
        "$HOME") p="~" ;;
        "$HOME"/*) p="~/${p#"$HOME"/}" ;;
    esac
    printf '%s' "$p"
}

# _ws_pad TEXT WIDTH — cut or pad TEXT to WIDTH characters (not bytes, so a
# name with a non-ASCII letter keeps the columns straight).
_ws_pad() {
    local t="$1" w="$2"
    if [ "${#t}" -gt "$w" ]; then
        t="${t:0:$((w - 1))}…"
    fi
    while [ "${#t}" -lt "$w" ]; do t="$t "; done
    printf '%s' "$t"
}

# _ws_rows — one row per workspace (the shape the helper mode documents):
# the saved ones newest first, then the live sessions the list does not hold.
# A ✗ marks a saved folder that is gone.
_ws_rows() {
    local n d m st seen="$NL"
    while IFS="$TAB" read -r n d; do
        [ -n "$n" ] || continue
        seen="$seen$n$NL"
        st=saved
        _ws_is_live "$n" && st=live
        m=" "
        [ "$st" = saved ] && [ ! -d "$d" ] && m="${BAD}✗${RESET}"
        printf '%s\t%s %s\t%s\t%s\t%s\n' "$(_ws_pad "$n" 18)" "$(_ws_pad "$(_ws_short "$d")" 40)" "$m" "$n" "$d" "$st"
    done < <("$HISTORY" list 2>/dev/null)
    while IFS="$TAB" read -r n d; do
        [ -n "$n" ] || continue
        case "$seen" in *"$NL$n$NL"*) continue ;; esac
        printf '%s\t%s  \t%s\t%s\tlive\n' "$(_ws_pad "$n" 18)" "$(_ws_pad "$(_ws_short "$d")" 40)" "$n" "$d"
    done < <(tmux list-sessions -F "#{session_name}${TAB}#{session_path}" 2>/dev/null)
}

# _ws_open NAME DIR — open a workspace from the list. Never returns.
#
# A live session gets a switch (new-workspace.sh does that); a gone one is
# built again in its saved folder. A row whose session is gone, while a live
# session that is NOT in the list has the same folder, is a renamed workspace
# (prefix + $): the client switches to that session, and the row takes its
# name. A row whose folder is gone asks for a folder first.
_ws_open() {
    local n="$1" d="$2" p other
    if ! _ws_is_live "$n"; then
        while IFS="$TAB" read -r p other; do
            if [ "$p" = "$d" ] && [ -n "$other" ] \
                && ! "$HISTORY" list 2>/dev/null | cut -f1 | grep -qxF -- "$other"; then
                "$HISTORY" remove "$n"
                "$HISTORY" add "$other" "$d"
                tmux switch-client -t "=$other"
                exit 0
            fi
        done < <(tmux list-sessions -F "#{session_path}${TAB}#{session_name}" 2>/dev/null)
        if [ ! -d "$d" ]; then
            _clux_header
            printf '  %s!%s the folder is gone: %s\n' "$BAD" "$RESET" "$(_ws_short "$d")"
            _clux_ask_folder "$n"
            d="$FOLDER_NAME"
        fi
    fi
    _clux_go "$n" "$d"
}

# _ws_box — the text box. Sets SESSION_NAME for a new workspace, or opens a
# picked one and does not return.
_ws_box() {
    local out rc mode row
    _CLUX_WS_ROWS="$(mktemp "${TMPDIR:-/tmp}/clux-ws.XXXXXX")" || exit 0
    _ws_rows > "$_CLUX_WS_ROWS"
    export CLUX_WS_ROWS="$_CLUX_WS_ROWS"
    CLUX_WS_GHOST="$DIM"
    export CLUX_WS_GHOST

    local h text
    h="'$CURRENT_DIR/new-workspace-prompt.sh' --fzf"
    text="$(clux_fzf_color "$(get_workspace_text_color)")"
    # The user's own FZF_DEFAULT_OPTS (a border, a preview, a height) would
    # change this box; it is built to fit the popup exactly, so none apply.
    out="$(FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' fzf --ansi --layout=reverse --height=100% --no-scrollbar \
        --print-query --delimiter="$TAB" --with-nth=1,2 --nth=1 --tabstop=1 \
        --no-separator --tiebreak=index --with-shell 'sh -c' \
        --list-border=top --list-label=' recents ' \
        --info='inline:' --info-command="$h ghost {3}" \
        --header "${CHIP} Workspace ${RESET}" --header-first \
        --pointer ' ' --gutter ' ' --prompt 'new       ▸ ' \
        --color "fg:$text,fg+:$text,bg+:-1,hl:-1:bold,hl+:-1:bold,header:-1" \
        --color "prompt:$(clux_fzf_color "$(get_agent_done_color),bold")" \
        --color "pointer:$(clux_fzf_color "$(get_agent_busy_color)")" \
        --color "list-border:$(clux_fzf_color "$(get_bar_separator_style)"),list-label:$text" \
        --bind "change:transform:$h change" \
        --bind "focus:transform:$h focus {5}" \
        --bind 'tab:transform-query:[ "$FZF_MATCH_COUNT" -gt 0 ] && printf %s {3} || printf %s {q}' \
        --bind "down:transform:$h down {5}" \
        --bind "up:transform:$h up" \
        --bind "enter:transform:$h enter" < "$_CLUX_WS_ROWS")"
    rc=$?
    # fzf exits 1 when no row matches, even after Enter: that is a new name.
    # 130 is Esc or Ctrl-C, 2 is an error.
    case "$rc" in 0|1) ;; *) exit 0 ;; esac

    SESSION_NAME="$(printf '%s\n' "$out" | sed -n 1p)"
    mode="$(printf '%s\n' "$out" | sed -n 2p)"
    row="$(printf '%s\n' "$out" | sed -n 3p)"
    if [ "$mode" = OPEN ] && [ -n "$row" ]; then
        _ws_open "$(printf '%s' "$row" | cut -f3)" "$(printf '%s' "$row" | cut -f4)"
    fi
}

# --- Main ------------------------------------------------------------------

SESSION_NAME=""
if command -v fzf >/dev/null 2>&1; then
    _ws_box
    [ -n "$SESSION_NAME" ] || exit 0
    # Exactly the name of a saved or live workspace: open it, no folder
    # question. The prompt said "open" or "switch to" for this name. ENVIRON,
    # not `awk -v`: -v would read a backslash in the name as an escape.
    dir="$(_N="$SESSION_NAME" awk -F'\t' '$3 == ENVIRON["_N"] { print $4; exit }' "$_CLUX_WS_ROWS")"
    [ -n "$dir" ] && _ws_open "$SESSION_NAME" "$dir"
    _clux_header
    printf '  %s▸%s name    %s\n' "$MARK" "$RESET" "$SESSION_NAME"
    _clux_reject "$SESSION_NAME"
else
    _clux_plain_keys
    _clux_header
    printf '  %s▸%s name    ' "$MARK" "$RESET"
    IFS= read -r SESSION_NAME || exit 0
    # Empty means the prompt was cancelled — not an error. So does a control
    # character: on a terminal that took the stty above, that is the Ctrl-C
    # the user pressed to get out.
    if [ -z "$SESSION_NAME" ] || _clux_cancelled_line "$SESSION_NAME"; then
        exit 0
    fi
    _clux_reject "$SESSION_NAME"
fi

_clux_ask_folder "$SESSION_NAME"
_clux_go "$SESSION_NAME" "$FOLDER_NAME"
