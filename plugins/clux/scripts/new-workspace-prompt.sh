#!/usr/bin/env bash

# prefix + A: one text box for the workspace (session) name. Type a name, and
# the saved workspaces that match show under it:
#
#   Enter              go: a new workspace with the typed name (then the
#                      folder question), or the workspace of that exact name
#   Down               pick the top match; Down again moves down the list
#   Up from the top    no row picked again; typing also un-picks (each fzf
#                      key that moves up does what Up does)
#   Tab                put the name of the current row in the box
#   Esc / Ctrl-C       cancel
#
# The prompt always says what Enter does: "new", "open" (a saved workspace
# that does not run) or "switch to" (a session that runs on this server).
# While you type, the rest of the current row's name shows in gray after the
# typed text. Without fzf, or with an fzf older than 0.66, the box is a plain
# name prompt with no list. There too, the exact name of a saved workspace or
# a live session opens it.
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

# --- Shared by the fzf helper mode and the box ------------------------------

P_NEW='new       ▸ '
P_OPEN='open      ▸ '
P_SWITCH='switch to ▸ '
L_RECENTS=' recents '
L_MATCHES=' matches '

# _ws_exact NAME FIELD — FIELD of the row whose name (field 3) is exactly NAME,
# from the rows file $CLUX_WS_ROWS. Nothing when no row has that name.
#
# The "" makes awk compare text. Without it, awk compares two values that
# look like numbers as numbers: "01" is then the row "1", and "007" is the
# session "7", so Enter opens a workspace that the user did not type. The
# name goes in through ENVIRON, not `awk -v`: -v would read a backslash in
# the name as an escape.
_ws_exact() {
    _WS_N="$1" awk -F'\t' -v f="$2" '($3 "") == (ENVIRON["_WS_N"] "") { print $f; exit }' \
        "${CLUX_WS_ROWS:-/dev/null}" 2>/dev/null
}

# --- fzf helper mode -------------------------------------------------------
#
# fzf runs "new-workspace-prompt.sh --fzf EVENT [FIELD]" on each key, and does
# the actions this prints. It reads fzf's state from $FZF_* and the rows from
# $CLUX_WS_ROWS only — no tmux call and no helpers.sh — so it stays fast, and
# it sits above every line that runs a command, so nothing else runs first.
#
# The POINTER holds the state: " " = no row picked, "▸" = a row picked. That
# leaves the PROMPT free to say what Enter does.
#
# Each row is "<shown name>\t<shown folder>\t<name>\t<folder>\t<live|saved>";
# FIELD is field 5 (focus, down) or field 3 (ghost) of the current row. For
# up, it is an fzf action (see there).
if [ "${1:-}" = --fzf ]; then
    _row_prompt() {
        if [ "$1" = live ]; then printf '%s' "$P_SWITCH"; else printf '%s' "$P_OPEN"; fi
    }
    # "new", unless the typed text is exactly the name of a row.
    _typed_prompt() {
        local st=""
        [ -n "${FZF_QUERY:-}" ] && st="$(_ws_exact "$FZF_QUERY" 5)"
        if [ -n "$st" ]; then _row_prompt "$st"; else printf '%s' "$P_NEW"; fi
    }
    _picked() { [ "${FZF_POINTER:-}" = '▸' ]; }
    case "${2:-}" in
        change)
            label="$L_RECENTS"
            [ -n "${FZF_QUERY:-}" ] && label="$L_MATCHES"
            printf 'first+change-pointer( )+change-prompt(%s)+change-list-label(%s)' "$(_typed_prompt)" "$label"
            ;;
        focus)
            if _picked; then
                printf 'change-prompt(%s)' "$(_row_prompt "${3:-}")"
            elif [ "${FZF_POS:-1}" -gt 1 ]; then
                # The cursor is off the top row, but no row is picked: an fzf
                # key that is not Down moved it (Ctrl-N, Page Down and others).
                # The row under the cursor is then the picked row, as after
                # Down, so the pointer and the prompt show it, and Enter opens
                # it.
                printf 'change-pointer(▸)+change-prompt(%s)' "$(_row_prompt "${3:-}")"
            fi
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
            # FIELD is the fzf action that moves the cursor up from a lower
            # row: up, or page-up for Page Up.
            if _picked; then
                if [ "${FZF_POS:-1}" -le 1 ]; then
                    printf 'change-pointer( )+change-prompt(%s)' "$(_typed_prompt)"
                else
                    printf '%s' "${3:-up}"
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
            # With no row picked, Enter opens the row whose name is exactly
            # the typed text. The name of a different row here would tell the
            # user the wrong row.
            if ! _picked && [ -n "$(_ws_exact "$q" 3)" ]; then exit 0; fi
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
# Each option is read one time (each read is one tmux call), and the box uses
# the same values for its fzf colours.
SEP_STYLE="$(get_bar_separator_style)"
BUSY_COLOR="$(get_agent_busy_color)"
CHIP="$(clux_ansi "$(get_bar_name_attached_style)")"
BRACKET="$(clux_ansi "$(get_bar_bracket_style)")"
DIM="$(clux_ansi "$SEP_STYLE")"
MARK="$(clux_ansi "$BUSY_COLOR")"
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
# The rows file. NOT exported: the box gives it to fzf (and so to the helper
# mode) only, and new-workspace.sh does not get a path to a removed file.
CLUX_WS_ROWS=""
_CLUX_NOTE=""

# Removes the rows file and restores the terminal on EVERY exit path. The
# `exec` in _clux_go skips the EXIT trap, so it calls _clux_cleanup first.
# The rows file goes first: after a hangup, the stty below can fail.
_clux_cleanup() {
    [ -n "$CLUX_WS_ROWS" ] && rm -f "$CLUX_WS_ROWS"
    CLUX_WS_ROWS=""
    [ -n "$_CLUX_STTY_SAVED" ] && stty "$_CLUX_STTY_SAVED" 2>/dev/null
    _CLUX_STTY_SAVED=""
}
# The EXIT trap ignores the signals before it cleans up. When the terminal
# closes, the script can get a second hangup during the clean-up, and that
# hangup stopped the script before it removed the rows file.
trap 'trap "" HUP INT QUIT TERM; _clux_cleanup' EXIT
# A cancel is not an error: the popup closes and nothing is created. `exit`
# from inside a trap handler still runs the EXIT trap (checked on bash 3.2).
trap 'exit 0' INT QUIT
# A TERM stops the script too. When the trap only cleaned up, the script
# continued with no rows file and no saved terminal state.
trap 'exit 143' TERM

_clux_plain_keys() {
    [ -n "$_CLUX_STTY_SAVED" ] && return 0
    _CLUX_STTY_SAVED="$(stty -g 2>/dev/null)"
    # A terminal that takes neither keeps the old behaviour rather than none:
    # Esc cannot cancel, and Ctrl-C is untouched because `intr` never moved.
    stty intr '^[' 2>/dev/null || :
    stty quit '^C' 2>/dev/null || :
}

# The guard for a terminal that took `intr` but not `quit`: Ctrl-C would then
# be a literal \003 in the line. The reject list below refuses a control
# character with an error, but the user pressed Ctrl-C to cancel. A control
# character is never part of a name anybody typed on purpose, so it is read
# as the cancel the user meant.
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

# _clux_bad_name NAME — true when NAME holds a character that _clux_reject
# refuses (see there).
_clux_bad_name() {
    case "$1" in
        *\'*|*\"*|*\\*|*';'*|*'#'*|*:*|*[[:cntrl:]]*) return 0 ;;
    esac
    return 1
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
    _clux_bad_name "$1" || return 0
    # Both, on purpose: display-message is what a caller outside a popup sees,
    # and the popup covers the status line it writes to, so the same text is
    # printed here as well. The pause is what keeps `-E` from closing the popup
    # before the reason can be read.
    tmux display-message "clux: workspace name cannot contain a quote, backslash, semicolon, colon, or #"
    # One SHORT line: the popup is seventy columns wide inside its border (less
    # on a narrow terminal), and a longer sentence wraps and pushes the header
    # off.
    printf '  %s!%s a name cannot hold  '"'"' " \\ ; : or #\n' "$BAD" "$RESET"
    printf '  %spress any key%s' "$DIM" "$RESET"
    read -rsn1
    exit 0
}

# --- The saved workspaces --------------------------------------------------

# _ws_read_live — read the sessions that run now. LIVE holds their names, one
# per line between newlines, for _ws_is_live. LIVE_ROWS holds one
# "<name>\t<folder>" line for each. The box can stay open for a long time, so
# _ws_open reads them again: a session made or closed meanwhile counts.
_ws_read_live() {
    local n d
    LIVE="$NL"
    LIVE_ROWS=""
    while IFS="$TAB" read -r n d; do
        [ -n "$n" ] || continue
        LIVE="$LIVE$n$NL"
        LIVE_ROWS="$LIVE_ROWS$n$TAB$d$NL"
    done < <(tmux list-sessions -F "#{session_name}${TAB}#{session_path}" 2>/dev/null)
}
_ws_is_live() {
    case "$LIVE" in *"$NL$1$NL"*) return 0 ;; esac
    return 1
}

# _ws_short VAR PATH — set VAR to PATH with ~ for the home folder.
_ws_short() {
    local p="$2"
    case "$p" in
        "$HOME") p="~" ;;
        "$HOME"/*) p="~/${p#"$HOME"/}" ;;
    esac
    printf -v "$1" '%s' "$p"
}

# _ws_cols NAME FOLDER WIDTH — set SHOWN to the two shown columns of a row.
#
# The name is padded to 18 characters and is NEVER cut: fzf finds a row by
# this text only (--nth=1 applies to the shown text), so a cut name does not
# match after the cut. The folder is cut from the LEFT to WIDTH, less what a
# long name takes, because the end of a folder tells the most. Both count
# characters, not bytes, so a non-ASCII letter keeps the columns straight.
#
# It sets SHOWN and prints nothing: a $( ) for each column of each row costs
# one process each, which is most of the start time with 50 rows.
_ws_cols() {
    local a="$1" b w="$3"
    _ws_short b "$2"
    [ "${#a}" -gt 18 ] && w=$((w - ${#a} + 18))
    [ "$w" -ge 10 ] || w=10
    while [ "${#a}" -lt 18 ]; do a="$a "; done
    [ "${#b}" -gt "$w" ] && b="…${b:$((${#b} - w + 1))}"
    while [ "${#b}" -lt "$w" ]; do b="$b "; done
    SHOWN="$a$TAB$b"
}

# _ws_rows — one row per workspace (the shape the helper mode documents):
# the saved ones newest first, then the live sessions the list does not hold.
# A ✗ marks a saved folder that is gone. A name that _clux_reject refuses is
# not a row: tmux cannot address it, so the row could not open.
_ws_rows() {
    local n d m st seen="$NL" size w
    # The folder column takes the width the popup has, so the ✗ at the end of
    # a row shows in a narrow popup too. 70 columns give a folder of 40.
    size="$(stty size 2>/dev/null)"
    w="${size#* }"
    case "$w" in ''|*[!0-9]*) w=70 ;; esac
    w=$((w - 30))
    while IFS="$TAB" read -r n d; do
        [ -n "$n" ] || continue
        seen="$seen$n$NL"
        _clux_bad_name "$n" && continue
        st=saved
        _ws_is_live "$n" && st=live
        m=" "
        [ "$st" = saved ] && [ ! -d "$d" ] && m="${BAD}✗${RESET}"
        _ws_cols "$n" "$d" "$w"
        printf '%s %s\t%s\t%s\t%s\n' "$SHOWN" "$m" "$n" "$d" "$st"
    done < <("$HISTORY" list 2>/dev/null)
    while IFS="$TAB" read -r n d; do
        [ -n "$n" ] || continue
        case "$seen" in *"$NL$n$NL"*) continue ;; esac
        _clux_bad_name "$n" && continue
        _ws_cols "$n" "$d" "$w"
        printf '%s  \t%s\t%s\tlive\n' "$SHOWN" "$n" "$d"
    done <<ROWS
$LIVE_ROWS
ROWS
}

# _ws_open NAME DIR — open a workspace from the list. Never returns.
#
# A live session gets a switch (new-workspace.sh does that); a gone one is
# built again in its saved folder. A row whose session is gone, while a live
# session that is NOT in the list has the same folder, is a renamed workspace
# (prefix + $): the client switches to that session, and the row takes its
# name. A row whose folder is gone asks for a folder first.
_ws_open() {
    local n="$1" d="$2" p other sd
    _ws_read_live
    if ! _ws_is_live "$n"; then
        while IFS="$TAB" read -r other p; do
            if [ "$p" = "$d" ] && [ -n "$other" ] \
                && ! "$HISTORY" list 2>/dev/null | cut -f1 | grep -qxF -- "$other"; then
                "$HISTORY" remove "$n"
                "$HISTORY" add "$other" "$d"
                tmux switch-client -t "=$other"
                exit 0
            fi
        done <<ROWS
$LIVE_ROWS
ROWS
        if [ ! -d "$d" ]; then
            _clux_header
            _ws_short sd "$d"
            printf '  %s!%s the folder is gone: %s\n' "$BAD" "$RESET" "$sd"
            _clux_ask_folder "$n"
            d="$FOLDER_NAME"
        fi
    fi
    _clux_go "$n" "$d"
}

# _ws_open_exact NAME — when NAME is exactly the name of a saved workspace or
# a live session, open it with no folder question, and do not return. The
# rows hold no name that _clux_reject refuses, so such a name never opens
# here.
_ws_open_exact() {
    local d
    d="$(_ws_exact "$1" 4)"
    [ -n "$d" ] && _ws_open "$1" "$d"
}

# _ws_box — the text box. Sets SESSION_NAME for a new workspace, or opens a
# picked one and does not return. Returns 1 when fzf cannot show the box, and
# the caller then asks with the plain prompt.
_ws_box() {
    local out rc mode row n d h text
    [ -n "$CLUX_WS_ROWS" ] || return 1
    h="'$CURRENT_DIR/new-workspace-prompt.sh' --fzf"
    text="$(clux_fzf_color "$(get_workspace_text_color)")"
    # The user's own FZF_DEFAULT_OPTS (a border, a preview, a height) would
    # change this box; it is built to fit the popup exactly, so none apply.
    #
    # --no-mouse: a double-click is fzf's own Enter, and a click moves the
    # cursor with no key that this box knows. Ctrl-J is Enter, as in a shell:
    # the terminal turns an Enter that the user types before fzf starts into
    # a Ctrl-J, which fzf's default reads as Down.
    #
    # fzf moves the cursor up with Ctrl-K, Ctrl-P, Alt-Up, Shift-Tab and
    # Page Up too. On the top row, these keys do not move the cursor, so no
    # focus event comes, and the row stayed picked. Each one now does what Up
    # does: from the top row, it goes back to a new name.
    #
    # SC2094: the CLUX_WS_ROWS= before fzf gives fzf the path. Nothing writes
    # the file here.
    # shellcheck disable=SC2094
    out="$(CLUX_WS_ROWS="$CLUX_WS_ROWS" CLUX_WS_GHOST="$DIM" \
        FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' fzf --ansi --layout=reverse --height=100% --no-scrollbar \
        --no-mouse --print-query --delimiter="$TAB" --with-nth=1,2 --nth=1 --tabstop=1 \
        --no-separator --tiebreak=index --with-shell 'sh -c' \
        --list-border=top --list-label="$L_RECENTS" \
        --info='inline:' --info-command="$h ghost {s3}" \
        --header "${CHIP} Workspace ${RESET}" --header-first \
        --pointer ' ' --gutter ' ' --prompt "$P_NEW" \
        --color "fg:$text,fg+:$text,bg+:-1,hl:-1:bold,hl+:-1:bold,header:-1" \
        --color "prompt:$(clux_fzf_color "$(get_agent_done_color),bold")" \
        --color "pointer:$(clux_fzf_color "$BUSY_COLOR")" \
        --color "list-border:$(clux_fzf_color "$SEP_STYLE"),list-label:$text" \
        --bind "change:transform:$h change" \
        --bind "focus:transform:$h focus {5}" \
        --bind 'tab:transform-query:[ "$FZF_MATCH_COUNT" -gt 0 ] && printf %s {s3} || printf %s {q}' \
        --bind "down:transform:$h down {5}" \
        --bind "up:transform:$h up" \
        --bind "ctrl-k:transform:$h up" \
        --bind "ctrl-p:transform:$h up" \
        --bind "alt-up:transform:$h up" \
        --bind "btab:transform:$h up" \
        --bind "pgup:transform:$h up page-up" \
        --bind "enter:transform:$h enter" \
        --bind "ctrl-j:transform:$h enter" < "$CLUX_WS_ROWS")"
    rc=$?
    case "$rc" in
        # 1: no row matches. After Enter, that is a new name.
        0|1) ;;
        # 2: an error, before the box shows. The usual cause is an fzf older
        # than 0.66, which does not know --gutter. The plain prompt works with
        # each fzf, so the user gets it, with the reason.
        2) _CLUX_NOTE="the list needs fzf 0.66 or later"; return 1 ;;
        # 130: Esc or Ctrl-C.
        *) exit 0 ;;
    esac

    { IFS= read -r SESSION_NAME; IFS= read -r mode; IFS= read -r row; } <<OUT
$out
OUT
    if [ "$mode" = OPEN ] && [ -n "$row" ]; then
        # No field of a row is empty (the shown columns are padded, and the
        # list holds no line with an empty name or folder), so tabs cannot
        # shift the fields.
        IFS="$TAB" read -r _ _ n d _ <<ROW
$row
ROW
        _ws_open "$n" "$d"
    fi
}

# --- Main ------------------------------------------------------------------

_ws_read_live
CLUX_WS_ROWS="$(mktemp "${TMPDIR:-/tmp}/clux-ws.XXXXXX" 2>/dev/null)" || CLUX_WS_ROWS=""
[ -n "$CLUX_WS_ROWS" ] && _ws_rows > "$CLUX_WS_ROWS"

SESSION_NAME=""
if command -v fzf >/dev/null 2>&1 && _ws_box; then
    [ -n "$SESSION_NAME" ] || exit 0
    # Exactly the name of a saved or live workspace: open it, no folder
    # question. The prompt said "open" or "switch to" for this name.
    _ws_open_exact "$SESSION_NAME"
    _clux_header
    printf '  %s▸%s name    %s\n' "$MARK" "$RESET" "$SESSION_NAME"
    _clux_reject "$SESSION_NAME"
else
    _clux_plain_keys
    _clux_header
    [ -n "$_CLUX_NOTE" ] && printf '  %s!%s %s\n' "$BAD" "$RESET" "$_CLUX_NOTE"
    printf '  %s▸%s name    ' "$MARK" "$RESET"
    IFS= read -r SESSION_NAME || exit 0
    # Empty means the prompt was cancelled — not an error. So does a control
    # character: on a terminal that took the stty above, that is the Ctrl-C
    # the user pressed to get out.
    if [ -z "$SESSION_NAME" ] || _clux_cancelled_line "$SESSION_NAME"; then
        exit 0
    fi
    _clux_reject "$SESSION_NAME"
    # As in the box: the exact name of a saved workspace opens it in its
    # saved folder, and the exact name of a live session switches to it.
    _ws_open_exact "$SESSION_NAME"
fi

_clux_ask_folder "$SESSION_NAME"
_clux_go "$SESSION_NAME" "$FOLDER_NAME"
