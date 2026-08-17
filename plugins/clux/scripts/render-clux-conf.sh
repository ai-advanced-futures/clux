#!/usr/bin/env bash
# render-clux-conf.sh — writes ~/.config/clux/clux.tmux.conf WHOLE, every time.
#
# This is Tier 1 of the config-updater design
# (docs/superpowers/specs/2026-08-10-clux-config-updater-skill-design.md): a
# file clux fully owns, so it needs no markers inside it and no diffing
# against a previous version — every run replaces the file outright. The
# skill that drives /clux:setup is the judgement layer; this script is the
# mechanical writer it calls once it has decided every value below. It never
# talks to tmux itself and never asks a question — every value it needs
# arrives as a flag.
#
# Six sections, in the order the design specifies:
#   1. Header comment (version stamp, ownership rule, hook-band reservation)
#   2. Part 3 answers: @clux-dir-resolver, @clux-editor, @clux-agents-command,
#      @clux-picker, and the optional @clux-agent-refresh-command escape hatch
#   3. Part 4 theming: @clux-bar-* options, emitted only for a value the
#      caller actually passed (unset ones fall through to each reader's own
#      default, so this file stays honest about what it inferred)
#   4. Key bindings: N P { } g A, plus the existing m ` DC M
#   5. Hooks, hook index band 90-99 (clux's reserved band)
#   6. A load-time reap + one bar render, last, so the bar it seeds carries no
#      marks left over from a previous server
#
# Deliberately absent, per the design: no @clux-session-order line (it is
# live server state, not something this file resets on every reload — that
# would undo every reorder the moment the file is re-sourced), and no
# @clux_session_bar / @clux_status lines (those are the two RUNTIME strings
# clux's hooks render into, never config this file sets).

set -uo pipefail

SCRIPTS_DIR="$HOME/.config/clux/scripts"
OUT="$HOME/.config/clux/clux.tmux.conf"
VERSION=""

DIR_RESOLVER=""
EDITOR_CMD=""
AGENTS_COMMAND=""
PICKER=""
AGENT_REFRESH_COMMAND=""

BAR_NAME_ATTACHED_STYLE=""
BAR_NAME_DETACHED_STYLE=""
BAR_WINDOW_ACTIVE_STYLE=""
BAR_WINDOW_INACTIVE_STYLE=""
BAR_BRACKET_STYLE=""
BAR_SEPARATOR_STYLE=""
BAR_WINDOW_OPEN=""
BAR_WINDOW_CLOSE=""
BAR_SEPARATOR=""
BAR_NAME_LENGTH=""

usage() {
    cat <<'USAGE'
Usage: render-clux-conf.sh --dir-resolver V --editor V --agents-command V --picker V [options]

Required (the Part 3 answers — always written, every install has one):
  --dir-resolver VALUE          autojump | zoxide | path
  --editor VALUE                nvim | vim | none | ...
  --agents-command VALUE        the command sent into the claude window, or "none"
  --picker VALUE                fzf | choose-tree

Optional:
  --agent-refresh-command VALUE   written only when passed (the "clux renders
                                   the bar" branch); omitted entirely otherwise,
                                   leaving whatever the user's own file sets
  --bar-name-attached-style VALUE
  --bar-name-detached-style VALUE
  --bar-window-active-style VALUE
  --bar-window-inactive-style VALUE
  --bar-bracket-style VALUE
  --bar-separator-style VALUE
  --bar-window-open VALUE
  --bar-window-close VALUE
  --bar-separator VALUE
  --bar-name-length VALUE
  --scripts-dir PATH            default: ~/.config/clux/scripts (the deployed
                                 location bind-key/hook lines point at)
  --out PATH                    default: ~/.config/clux/clux.tmux.conf
  --version VALUE                default: read from plugin.json when running
                                 from the plugin source tree, else "unknown"
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir-resolver) DIR_RESOLVER="${2:-}"; shift 2 ;;
        --editor) EDITOR_CMD="${2:-}"; shift 2 ;;
        --agents-command) AGENTS_COMMAND="${2:-}"; shift 2 ;;
        --picker) PICKER="${2:-}"; shift 2 ;;
        --agent-refresh-command) AGENT_REFRESH_COMMAND="${2:-}"; shift 2 ;;
        --bar-name-attached-style) BAR_NAME_ATTACHED_STYLE="${2:-}"; shift 2 ;;
        --bar-name-detached-style) BAR_NAME_DETACHED_STYLE="${2:-}"; shift 2 ;;
        --bar-window-active-style) BAR_WINDOW_ACTIVE_STYLE="${2:-}"; shift 2 ;;
        --bar-window-inactive-style) BAR_WINDOW_INACTIVE_STYLE="${2:-}"; shift 2 ;;
        --bar-bracket-style) BAR_BRACKET_STYLE="${2:-}"; shift 2 ;;
        --bar-separator-style) BAR_SEPARATOR_STYLE="${2:-}"; shift 2 ;;
        --bar-window-open) BAR_WINDOW_OPEN="${2:-}"; shift 2 ;;
        --bar-window-close) BAR_WINDOW_CLOSE="${2:-}"; shift 2 ;;
        --bar-separator) BAR_SEPARATOR="${2:-}"; shift 2 ;;
        --bar-name-length) BAR_NAME_LENGTH="${2:-}"; shift 2 ;;
        --scripts-dir) SCRIPTS_DIR="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "render-clux-conf.sh: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$DIR_RESOLVER" ] || [ -z "$EDITOR_CMD" ] || [ -z "$AGENTS_COMMAND" ] || [ -z "$PICKER" ]; then
    echo "render-clux-conf.sh: --dir-resolver, --editor, --agents-command, and --picker are all required" >&2
    usage >&2
    exit 1
fi

# @clux-bar-name-length guard: a bad N corrupts the whole tmux format string
# session-list.sh builds from it, so a non-numeric value is refused here
# rather than written — the same guard session-list.sh itself applies when
# reading it back.
if [ -n "$BAR_NAME_LENGTH" ]; then
    case "$BAR_NAME_LENGTH" in
        ''|*[!0-9]*)
            echo "render-clux-conf.sh: --bar-name-length must be numeric, got '$BAR_NAME_LENGTH'" >&2
            exit 1
            ;;
    esac
fi

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$VERSION" ]; then
    _plugin_json="$CURRENT_DIR/../.claude-plugin/plugin.json"
    if [ -f "$_plugin_json" ]; then
        VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_plugin_json" | head -1)
    fi
    [ -n "$VERSION" ] || VERSION="unknown"
fi

render() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null)"

    cat <<HEADER
# ~/.config/clux/clux.tmux.conf — generated by /clux:setup (clux $VERSION)
#
# DO NOT EDIT BY HAND. clux rewrites this file whole on every /clux:setup run
# and re-sources it on every "prefix + r" reload — a manual edit here is
# silently discarded on the next of either. Change a value through
# /clux:setup, or with "tmux set-option -g <name> <value>" for a quick trial
# (a rewrite still overwrites it).
#
# Naming rule: a hyphenated @clux-* option (@clux-dir-resolver, @clux-editor,
# every @clux-bar-* and @clux-agent-*) is a configuration input clux sets
# here. An underscored @clux_* option (@clux_session_bar, @clux_status) is a
# RUNTIME string clux's hooks render into on every event — never set by this
# file, because a "set -g" here would reset it to a stale value on every
# reload.
#
# Hook index band 90-99 is reserved for clux, ascending within the band in
# the order clux needs them to run:
#   [90] agent-clear.sh   — already shipped at this index; never move it
#   [91] session-bar-refresh.sh — runs after [90], so a mark agent-clear.sh
#        just cleared reaches the bar in the same pass instead of a redraw
#        late
#   [92]-[99] reserved for future clux hooks
#
# Generated: $ts
HEADER

    echo
    echo "# --- Part 3: how the workspace behaves (see /clux:setup) ---"
    printf 'set -g @clux-dir-resolver "%s"\n' "$DIR_RESOLVER"
    printf 'set -g @clux-editor "%s"\n' "$EDITOR_CMD"
    # Single-quoted: @clux-agents-command must carry a literal $PWD through to
    # the target shell unexpanded. Double-quoting here would let tmux's own
    # parser expand it at set-option time, long before the option ever
    # reaches the pane it is send-keys'd into.
    printf "set -g @clux-agents-command '%s'\n" "$AGENTS_COMMAND"
    printf 'set -g @clux-picker "%s"\n' "$PICKER"
    if [ -n "$AGENT_REFRESH_COMMAND" ]; then
        printf 'set -g @clux-agent-refresh-command "%s"\n' "$AGENT_REFRESH_COMMAND"
    fi

    # Part 4 theming. Bash 3.2 has no associative arrays, so this walks a
    # "BASH_VARNAME:@clux-option-name" list and reads each value through
    # indirect expansion (${!varname} — plain bash 2+ indirection, not an
    # associative array). A line is emitted only when the caller actually
    # passed that flag, per the design: detection writes a line only for a
    # value it found, and everything else is left to the reader's own
    # default so this file stays honest about what it inferred.
    local bar_pairs="BAR_NAME_ATTACHED_STYLE:@clux-bar-name-attached-style
BAR_NAME_DETACHED_STYLE:@clux-bar-name-detached-style
BAR_WINDOW_ACTIVE_STYLE:@clux-bar-window-active-style
BAR_WINDOW_INACTIVE_STYLE:@clux-bar-window-inactive-style
BAR_BRACKET_STYLE:@clux-bar-bracket-style
BAR_SEPARATOR_STYLE:@clux-bar-separator-style
BAR_WINDOW_OPEN:@clux-bar-window-open
BAR_WINDOW_CLOSE:@clux-bar-window-close
BAR_SEPARATOR:@clux-bar-separator
BAR_NAME_LENGTH:@clux-bar-name-length"

    local any_theme=0 varname optname val
    while IFS=: read -r varname optname; do
        [ -n "$varname" ] || continue
        val="${!varname}"
        if [ -n "$val" ]; then
            if [ "$any_theme" -eq 0 ]; then
                echo
                echo "# --- Part 4: theming (only values detection found) ---"
                any_theme=1
            fi
            printf 'set -g "%s" "%s"\n' "$optname" "$val"
        fi
    done <<PAIRS
$bar_pairs
PAIRS

    echo
    echo "# --- Key bindings ---"
    printf 'bind-key N run-shell "%s/switch-session.sh next"\n' "$SCRIPTS_DIR"
    printf 'bind-key P run-shell "%s/switch-session.sh prev"\n' "$SCRIPTS_DIR"
    printf "bind-key '{' run-shell \"%s/session-reorder.sh left\"\n" "$SCRIPTS_DIR"
    printf "bind-key '}' run-shell \"%s/session-reorder.sh right\"\n" "$SCRIPTS_DIR"
    printf 'bind-key g run-shell -b "%s/session-picker.sh"\n' "$SCRIPTS_DIR"
    # Two-step prompt, exactly the shape new-workspace-prompt.sh expects: this
    # first command-prompt is the ONLY user value that ever reaches a tmux
    # command string directly (the session name); new-workspace-prompt.sh
    # validates it, then issues its own second command-prompt for the folder
    # and passes that one through @clux-new-workspace-name instead.
    printf 'bind-key A command-prompt -p "Session name:" "run-shell '"'"'%s/new-workspace-prompt.sh \\"%%1\\"'"'"'"\n' "$SCRIPTS_DIR"
    printf 'bind-key m run-shell "%s/jump-to-notification.sh"\n' "$SCRIPTS_DIR"
    printf 'bind-key ` run-shell "%s/dismiss-notification.sh"\n' "$SCRIPTS_DIR"
    printf 'bind-key DC run-shell "%s/dismiss-notification.sh"\n' "$SCRIPTS_DIR"
    printf 'bind-key M display-popup -w 80%% -h 60%% -E "%s/notification-picker.sh"\n' "$SCRIPTS_DIR"

    echo
    echo "# --- Hooks (band 90-99, see header) ---"
    printf 'set-hook -g '"'"'after-select-window[90]'"'"' "run-shell \\"%s/agent-clear.sh '"'"'#{window_id}'"'"'\\""\n' "$SCRIPTS_DIR"
    printf 'set-hook -g '"'"'client-session-changed[90]'"'"' "run-shell \\"%s/agent-clear.sh '"'"'#{window_id}'"'"'\\""\n' "$SCRIPTS_DIR"
    printf 'set-hook -g '"'"'client-session-changed[91]'"'"' "run-shell -b %s/session-bar-refresh.sh"\n' "$SCRIPTS_DIR"
    printf 'set-hook -g '"'"'after-select-window[91]'"'"' "run-shell -b %s/session-bar-refresh.sh"\n' "$SCRIPTS_DIR"
    printf 'set-hook -g '"'"'session-created[91]'"'"' "run-shell -b %s/session-bar-refresh.sh"\n' "$SCRIPTS_DIR"
    printf 'set-hook -g '"'"'session-closed[91]'"'"' "run-shell -b %s/session-bar-refresh.sh"\n' "$SCRIPTS_DIR"
    printf 'set-hook -g '"'"'window-linked[91]'"'"' "run-shell -b %s/session-bar-refresh.sh"\n' "$SCRIPTS_DIR"
    printf 'set-hook -g '"'"'window-unlinked[91]'"'"' "run-shell -b %s/session-bar-refresh.sh"\n' "$SCRIPTS_DIR"

    echo
    echo "# --- Seed the bar (reap dead marks first, so nothing stale renders) ---"
    printf 'run-shell "%s/agent-clear.sh --reap"\n' "$SCRIPTS_DIR"
    printf 'run-shell "%s/session-bar-refresh.sh"\n' "$SCRIPTS_DIR"
}

TMP="$(mktemp "${OUT}.XXXXXX" 2>/dev/null)" || TMP="${OUT}.tmp.$$"
if ! render > "$TMP"; then
    echo "render-clux-conf.sh: failed to render config" >&2
    rm -f "$TMP"
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
mv "$TMP" "$OUT"
echo "$OUT"
