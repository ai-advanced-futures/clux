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

# --- Esc and Ctrl-C both cancel --------------------------------------------
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
# No raw mode, and the line keeps its normal editing.
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
trap 'exit 0' INT QUIT

_CLUX_STTY_SAVED="$(stty -g 2>/dev/null)"
# A terminal that takes neither keeps the old behaviour rather than none: Esc
# cannot cancel, and Ctrl-C is untouched because `intr` never moved.
stty intr '^[' 2>/dev/null || :
stty quit '^C' 2>/dev/null || :

# The guard for a terminal that took `intr` but not `quit`: Ctrl-C would then
# be a literal \003 in the line, and the reject list below names no control
# character, so the workspace would be created under a name carrying one. A
# control character is never part of a name anybody typed on purpose, so it is
# read as the cancel the user meant.
_clux_cancelled_line() {
    case "$1" in
        *[[:cntrl:]]*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- The saved workspaces ------------------------------------------------
#
# When workspace-history.sh holds a workspace, the popup opens on that list,
# newest first, before it asks for a name:
#
#   1-9      open that row now          j / k    move down / up
#   Enter    open the selected row      Space    set the folder of the row
#   x        delete the row             a        open all saved workspaces
#   n        type a new workspace       q        cancel (Esc and Ctrl-C too)
#
# Any other letter or digit starts a new workspace with that character as the
# first character of the name, so a user who types a name at once still can.
# Backspace cannot remove that character (bash 3.2 has no `read -i`); Esc and
# a new start can.
#
# To open a row is to hand its name and folder to new-workspace.sh, the same
# path a typed name takes: a live session gets a switch, a gone one is built
# again in its saved folder. A row whose session is gone, while a live session
# that is NOT in the list has the same folder, is a renamed workspace (prefix +
# $): the client switches to that session, and the row takes its name.
#
# Keys are read one at a time with `IFS= read -rsn1 -d ''`. Each part counts:
# without IFS= and -d '', Enter AND Space both read as an empty string, so
# Space would open the row. Esc stays the interrupt character set above, so
# Esc and every arrow key (which starts with Esc) cancel here as well.

HISTORY="$CURRENT_DIR/workspace-history.sh"
NL=$'\n'
PRESET=""
WS_MSG=""
WS_SEL=0
WS_TOP=0

_ws_load() {
    WS_NAMES=()
    WS_DIRS=()
    local n d
    while IFS=$'\t' read -r n d; do
        [ -n "$n" ] || continue
        WS_NAMES+=("$n")
        WS_DIRS+=("$d")
    done < <("$HISTORY" list 2>/dev/null)
    WS_COUNT=${#WS_NAMES[@]}
    [ "$WS_SEL" -lt "$WS_COUNT" ] || WS_SEL=$((WS_COUNT - 1))
    [ "$WS_SEL" -ge 0 ] || WS_SEL=0
    _ws_read_live
}

# Name and folder of each live session. Read at each load and again when a
# row opens, so a session made or closed while the popup is open counts.
_ws_read_live() {
    WS_LIVE="$NL$(tmux list-sessions -F '#{session_name}' 2>/dev/null)$NL"
    WS_LIVE_PATHS="$(tmux list-sessions -F "#{session_path}"$'\t'"#{session_name}" 2>/dev/null)"
}

_ws_is_live() {
    case "$WS_LIVE" in *"$NL$1$NL"*) return 0 ;; esac
    return 1
}

_ws_in_list() {
    local n
    for n in "${WS_NAMES[@]}"; do [ "$n" = "$1" ] && return 0; done
    return 1
}

# _ws_short PATH WIDTH — ~ for the home folder, cut from the left to WIDTH.
_ws_short() {
    local p="$1" w="$2"
    case "$p" in
        "$HOME") p="~" ;;
        "$HOME"/*) p="~/${p#"$HOME"/}" ;;
    esac
    if [ "${#p}" -gt "$w" ]; then
        p="…${p:$((${#p} - w + 1))}"
    fi
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

_ws_draw() {
    local rows cols vis i n d mark state path_w size
    size="$(stty size 2>/dev/null)"
    rows="${size% *}"
    cols="${size#* }"
    case "$rows" in ''|*[!0-9]*) rows=13 ;; esac
    case "$cols" in ''|*[!0-9]*) cols=60 ;; esac
    # Header, blank, message, keys: the rows that stay are for the list. A
    # popup from a clux.tmux.conf before 4.3.0 is 5 rows high, so this can be
    # 1, and the list scrolls to keep the selected row on the screen.
    vis=$((rows - 4))
    [ "$vis" -ge 1 ] || vis=1
    [ "$WS_SEL" -ge "$WS_TOP" ] || WS_TOP=$WS_SEL
    [ "$WS_SEL" -lt $((WS_TOP + vis)) ] || WS_TOP=$((WS_SEL - vis + 1))
    path_w=$((cols - 24))
    [ "$path_w" -ge 10 ] || path_w=10

    printf '\033[H\033[2J'
    printf '%s Workspaces %s %s%s%s %srecent%s %s%s%s   %s1-9 · j/k · esc%s\n' \
        "$CHIP" "$RESET" "$BRACKET" "$OPEN" "$RESET" "$DIM" "$RESET" \
        "$BRACKET" "$CLOSE" "$RESET" "$DIM" "$RESET"
    printf '\n'
    i=$WS_TOP
    while [ "$i" -lt "$WS_COUNT" ] && [ "$i" -lt $((WS_TOP + vis)) ]; do
        n="${WS_NAMES[$i]}"
        d="${WS_DIRS[$i]}"
        mark=" "
        [ "$i" -eq "$WS_SEL" ] && mark="${MARK}▸${RESET}"
        if _ws_is_live "$n"; then
            state="${MARK}●${RESET}"
        elif [ ! -d "$d" ]; then
            state="${BAD}✗${RESET}"
        else
            state=" "
        fi
        printf '%s %s%d%s %s %s%s%s %s\n' "$mark" "$DIM" $((i + 1)) "$RESET" \
            "$(_ws_pad "$n" 16)" "$DIM" "$(_ws_pad "$(_ws_short "$d" "$path_w")" "$path_w")" "$RESET" "$state"
        i=$((i + 1))
    done
    printf '%s\n' "$WS_MSG"
    printf '%s⏎ open · ␣ folder · x delete · a open all · n new%s' "$DIM" "$RESET"
}

# _ws_open — open the selected row. Returns only when the row cannot open.
_ws_open() {
    local n="${WS_NAMES[$WS_SEL]}" d="${WS_DIRS[$WS_SEL]}" p other
    _ws_read_live
    if ! _ws_is_live "$n"; then
        # A renamed workspace: a live session that the list does not know,
        # with the folder of this row.
        while IFS=$'\t' read -r p other; do
            if [ "$p" = "$d" ] && [ -n "$other" ] && ! _ws_in_list "$other"; then
                "$HISTORY" remove "$n"
                "$HISTORY" add "$other" "$d"
                tmux switch-client -t "=$other"
                exit 0
            fi
        done <<EOF
$WS_LIVE_PATHS
EOF
        if [ ! -d "$d" ]; then
            WS_MSG="  ${BAD}!${RESET} the folder is gone: press space to set one"
            return 1
        fi
    fi
    tmux set-option -g "@clux-new-workspace-name" "$n"
    _clux_term_restore
    exec "$CURRENT_DIR/new-workspace.sh" "$d"
}

# _ws_set_folder — Space: ask for a folder, resolve it the way a new
# workspace does (new-workspace.sh --resolve), and save it on the row.
_ws_set_folder() {
    local n="${WS_NAMES[$WS_SEL]}" answer dir
    printf '\033[H\033[2J'
    printf '%s Folder %s %s%s%s %s%s%s %s%s%s   %s⏎ save · esc cancel%s\n\n' \
        "$CHIP" "$RESET" "$BRACKET" "$OPEN" "$RESET" "$DIM" "$n" "$RESET" \
        "$BRACKET" "$CLOSE" "$RESET" "$DIM" "$RESET"
    printf '  %snow%s     %s\n' "$DIM" "$RESET" "$(_ws_short "${WS_DIRS[$WS_SEL]}" 48)"
    printf '  %s▸%s folder  ' "$MARK" "$RESET"
    IFS= read -r answer || exit 0
    if [ -z "$answer" ] || _clux_cancelled_line "$answer"; then
        return 0
    fi
    if dir="$("$CURRENT_DIR/new-workspace.sh" --resolve "$answer" 2>/dev/null)" && [ -n "$dir" ]; then
        "$HISTORY" set-dir "$n" "$dir"
        WS_MSG="  folder set"
        _ws_is_live "$n" && WS_MSG="  folder set: the live session keeps its folder"
    else
        WS_MSG="  ${BAD}!${RESET} no folder for $(_ws_short "$answer" 36)"
    fi
}

# _ws_open_all — a: build each saved workspace that is not live, in the
# background (new-workspace.sh --restore: no switch, the list keeps its order).
# It asks first: each workspace starts its own agents command.
_ws_open_all() {
    local i todo=0 key done_n=0
    for ((i = 0; i < WS_COUNT; i++)); do
        _ws_is_live "${WS_NAMES[$i]}" && continue
        [ -d "${WS_DIRS[$i]}" ] && todo=$((todo + 1))
    done
    if [ "$todo" -eq 0 ]; then
        WS_MSG="  all saved workspaces are open"
        return 0
    fi
    WS_MSG="  open $todo workspaces? y/n"
    _ws_draw
    IFS= read -rsn1 -d '' key || exit 0
    case "$key" in
        y|Y) ;;
        *) WS_MSG=""; return 0 ;;
    esac
    for ((i = 0; i < WS_COUNT; i++)); do
        _ws_is_live "${WS_NAMES[$i]}" && continue
        [ -d "${WS_DIRS[$i]}" ] || continue
        tmux set-option -g "@clux-new-workspace-name" "${WS_NAMES[$i]}"
        "$CURRENT_DIR/new-workspace.sh" --restore "${WS_DIRS[$i]}" >/dev/null 2>&1 \
            && done_n=$((done_n + 1))
    done
    tmux display-message "clux: opened $done_n of $todo workspaces"
    exit 0
}

# _ws_list — the key loop. Returns 0 to go on to the name prompt.
_ws_list() {
    local key
    _ws_load
    [ "$WS_COUNT" -gt 0 ] || return 0
    while :; do
        _ws_draw
        IFS= read -rsn1 -d '' key || exit 0
        WS_MSG=""
        case "$key" in
            [1-9])
                if [ "$key" -le "$WS_COUNT" ]; then
                    WS_SEL=$((key - 1))
                    _ws_open
                fi
                ;;
            j) [ "$WS_SEL" -lt $((WS_COUNT - 1)) ] && WS_SEL=$((WS_SEL + 1)) ;;
            k) [ "$WS_SEL" -gt 0 ] && WS_SEL=$((WS_SEL - 1)) ;;
            "$NL"|$'\r') _ws_open ;;
            ' ') _ws_set_folder; _ws_load ;;
            x)
                "$HISTORY" remove "${WS_NAMES[$WS_SEL]}"
                _ws_load
                [ "$WS_COUNT" -gt 0 ] || { printf '\033[H\033[2J'; return 0; }
                ;;
            a) _ws_open_all; _ws_load ;;
            n) printf '\033[H\033[2J'; return 0 ;;
            q) exit 0 ;;
            [[:alnum:]]|-|_|.)
                PRESET="$key"
                printf '\033[H\033[2J'
                return 0
                ;;
        esac
    done
}

_ws_list

# Header: the same chip and brackets the bar draws, then the key hints.
printf '%s New workspace %s %s%s%s %sname + folder%s %s%s%s   %s⏎ create · esc cancel%s\n\n' \
    "$CHIP" "$RESET" "$BRACKET" "$OPEN" "$RESET" "$DIM" "$RESET" \
    "$BRACKET" "$CLOSE" "$RESET" "$DIM" "$RESET"

printf '  %s▸%s name    %s' "$MARK" "$RESET" "$PRESET"
IFS= read -r SESSION_NAME || exit 0
SESSION_NAME="$PRESET$SESSION_NAME"

# Empty means the prompt was cancelled — not an error. So does a control
# character: on a terminal that took the stty above, that is the Ctrl-C the
# user pressed to get out.
if [ -z "$SESSION_NAME" ] || _clux_cancelled_line "$SESSION_NAME"; then
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
        # One SHORT line, and no blank line before it: `-h 7` minus the popup
        # border leaves five rows of sixty columns, and the sentence this used
        # to be was sixty-seven — it wrapped, which pushed the header off the
        # top. Header, blank, name, this, and the pause are exactly five.
        printf '  %s!%s a name cannot hold  '"'"' " \\ ; : or #\n' "$BAD" "$RESET"
        printf '  %spress any key%s' "$DIM" "$RESET"
        read -rsn1
        exit 0
        ;;
esac

# Enter alone means "same as the session name", which is exactly what
# new-workspace.sh already does with an empty folder. The old second prompt
# prefilled "<name>/" for the user to complete; bash 3.2 (macOS) has no
# `read -i`, and a stated default reads better than a prefill nobody can edit.
# The default is STATED, not prefilled — that is what the comment above is
# about, and a bare "folder" prompt hides it. The dim suffix is the whole
# reason Enter alone is usable here.
printf '  %s▸%s folder  %s[%s]%s ' "$MARK" "$RESET" "$DIM" "$SESSION_NAME" "$RESET"
IFS= read -r FOLDER_NAME || exit 0
if _clux_cancelled_line "$FOLDER_NAME"; then
    exit 0
fi
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
