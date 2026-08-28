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
# Seven sections, in the order the design specifies:
#   1. Header comment (version stamp, ownership rule, hook-band reservation)
#   2. Part 3 answers: @clux-dir-resolver, @clux-editor, @clux-agents-command,
#      @clux-picker, and the optional @clux-agent-refresh-command escape hatch
#   3. Part 4 theming: @clux-bar-* options, emitted only for a value the
#      caller actually passed (unset ones fall through to each reader's own
#      default, so this file stays honest about what it inferred), followed
#      by the §3.6 notification preferences — @claude-notify-<type>-visual /
#      -sound — again only the answers the caller passed
#   4. Key bindings: N P { } g A, plus the existing m ` DC M
#   5. Hooks, hook index band 90-99 (clux's reserved band)
#   6. A drop of the animation runtime state a previous load left behind
#      (@clux_bar_tpl, @clux_frame_idx[_<client_pid>] — see the naming rule
#      below), ABOVE the seed render in section 7
#   7. A load-time reap + one bar render, last, so the bar it seeds carries no
#      marks left over from a previous server
#
# Deliberately absent, per the design: no @clux-session-order line (it is
# live server state, not something this file resets on every reload — that
# would undo every reorder the moment the file is re-sourced), and no
# @clux_session_bar / @clux_status lines (those are the two RUNTIME strings
# clux's hooks render into, never config this file sets). @clux_bar_tpl and
# @clux_frame_idx[_<client_pid>] are two more RUNTIME (@clux_*, underscored)
# options in the same family — added by the animated-busy-glyph design
# (2026-08-23) — and this file's relationship to them is the mirror image:
# it does not SET them either, but it does actively CLEAR them (section 6),
# because a stale @clux_bar_tpl surviving a config reload would keep
# substituting into the bar for up to FULL_EVERY seconds afterward.
# @clux_bar_tpl_at from an earlier design pass no longer exists as a separate
# option — @clux_bar_tpl now carries "<epoch><TAB><template>" in one option,
# so do not add it back.

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

AGENT_BUSY_COLOR=""
AGENT_NEEDS_COLOR=""
AGENT_DONE_COLOR=""
AGENT_FAIL_COLOR=""
AGENT_GLYPH_BUSY=""
AGENT_GLYPH_NEEDS=""
AGENT_GLYPH_DONE=""
AGENT_GLYPH_FAIL=""

# Notification preferences (§3.6) and colours. Bash 3.2 has no associative
# arrays, so the preferences accumulate as "<type>-<visual|sound>=<value>"
# lines and are emitted in the order they were given.
NOTIFY_BG=""
NOTIFY_FG=""
NOTIFY_PREFS=""
# The closed set of clux notification types — one per @claude-notify-<type>-*
# family. Must match map_event_to_type() in helpers.sh.
NOTIFY_TYPES="notification stop failure quota prompt teammate sessionend"

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
  --agent-busy-color VALUE        colour of the busy glyph in the bar's
  --agent-needs-color VALUE        per-session agent column, and of the
  --agent-done-color VALUE         glyph agent-bar.sh draws
  --agent-fail-color VALUE
  --agent-glyph-busy VALUE        one column each — a two-column glyph
  --agent-glyph-needs VALUE        (emoji, nerd-font icon) reflows the bar,
  --agent-glyph-done VALUE         and the caller owns that reflow
  --agent-glyph-fail VALUE
                                (@clux-agent-glyph-busy-frames is deliberately
                                 NOT a flag: it needs single-quoting for its
                                 backslash frame, and an animation choice is
                                 not something detection reads off an old bar)
  --notify-visual TYPE on|off     one @claude-notify-TYPE-visual line; repeat
  --notify-sound TYPE on|off       per type. TYPE is one of: notification stop
                                   failure quota prompt teammate sessionend.
                                   Pass only an answer that differs from the
                                   default in helpers.sh — a line restating a
                                   default only makes the file longer
  --notify-bg VALUE               @claude-notify-bg / -fg, the colours of the
  --notify-fg VALUE                notification token (only when detected)
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
        --agent-busy-color) AGENT_BUSY_COLOR="${2:-}"; shift 2 ;;
        --agent-needs-color) AGENT_NEEDS_COLOR="${2:-}"; shift 2 ;;
        --agent-done-color) AGENT_DONE_COLOR="${2:-}"; shift 2 ;;
        --agent-glyph-busy) AGENT_GLYPH_BUSY="${2:-}"; shift 2 ;;
        --agent-glyph-needs) AGENT_GLYPH_NEEDS="${2:-}"; shift 2 ;;
        --agent-glyph-done) AGENT_GLYPH_DONE="${2:-}"; shift 2 ;;
        --agent-fail-color) AGENT_FAIL_COLOR="${2:-}"; shift 2 ;;
        --agent-glyph-fail) AGENT_GLYPH_FAIL="${2:-}"; shift 2 ;;
        --notify-bg) NOTIFY_BG="${2:-}"; shift 2 ;;
        --notify-fg) NOTIFY_FG="${2:-}"; shift 2 ;;
        --notify-visual|--notify-sound)
            _kind="${1#--notify-}"
            _type="${2:-}"; _val="${3:-}"
            case " $NOTIFY_TYPES " in
                *" $_type "*) ;;
                *)
                    echo "render-clux-conf.sh: $1: unknown notification type '$_type' (one of: $NOTIFY_TYPES)" >&2
                    exit 1
                    ;;
            esac
            case "$_val" in
                on|off) ;;
                *)
                    echo "render-clux-conf.sh: $1 $_type: value must be on or off, got '$_val'" >&2
                    exit 1
                    ;;
            esac
            NOTIFY_PREFS="${NOTIFY_PREFS}${_type}-${_kind}=${_val}
"
            shift 3
            ;;
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
BAR_NAME_LENGTH:@clux-bar-name-length
AGENT_BUSY_COLOR:@clux-agent-busy-color
AGENT_NEEDS_COLOR:@clux-agent-needs-color
AGENT_DONE_COLOR:@clux-agent-done-color
AGENT_FAIL_COLOR:@clux-agent-fail-color
AGENT_GLYPH_BUSY:@clux-agent-glyph-busy
AGENT_GLYPH_NEEDS:@clux-agent-glyph-needs
AGENT_GLYPH_DONE:@clux-agent-glyph-done
AGENT_GLYPH_FAIL:@clux-agent-glyph-fail
NOTIFY_BG:@claude-notify-bg
NOTIFY_FG:@claude-notify-fg"

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

    # §3.6 answers. Only what the caller passed, which the skill limits to
    # answers that differ from helpers.sh's defaults. The option names are
    # @claude-notify-<type>-<visual|sound>, read by notify-tmux.sh (both the
    # pane path and the agents path) and notify-sound.sh.
    if [ -n "$NOTIFY_PREFS" ]; then
        echo
        echo "# --- Notifications: per-event preferences (only answers that differ from the defaults) ---"
        printf '%s' "$NOTIFY_PREFS" | while IFS='=' read -r optname val; do
            [ -n "$optname" ] || continue
            printf 'set -g "@claude-notify-%s" "%s"\n' "$optname" "$val"
        done
    fi

    echo
    echo "# --- Key bindings ---"
    printf 'bind-key N run-shell "%s/switch-session.sh next"\n' "$SCRIPTS_DIR"
    printf 'bind-key P run-shell "%s/switch-session.sh prev"\n' "$SCRIPTS_DIR"
    printf "bind-key '{' run-shell \"%s/session-reorder.sh left\"\n" "$SCRIPTS_DIR"
    printf "bind-key '}' run-shell \"%s/session-reorder.sh right\"\n" "$SCRIPTS_DIR"
    printf 'bind-key g run-shell -b "%s/session-picker.sh"\n' "$SCRIPTS_DIR"
    # A popup, NOT a command-prompt. `command-prompt` substitutes the typed
    # answer into its command template before tmux parses it, with no way to
    # escape the substitution, so a quote in the answer breaks out of the
    # template — the earlier two-command-prompt shape here ran arbitrary shell
    # commands typed at the "Session name:" prompt. new-workspace-prompt.sh
    # reads both answers itself instead; see its header. No user-supplied value
    # reaches a tmux command string on this path any more.
    # Fixed rows, not a percentage: the popup holds four lines whatever the
    # terminal is, and `-h 30%%` grew it to fifteen on a tall one. `-x 0 -y S`
    # pins it to the top-left corner, just clear of the status line — S
    # resolves to the line below the bar when status-position is top and the
    # line above it when it is bottom, so the popup follows the bar rather
    # than needing a second setting.
    printf 'bind-key A display-popup -w 62 -h 7 -x 0 -y S -E "%s/new-workspace-prompt.sh"\n' "$SCRIPTS_DIR"
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
    echo "# --- Drop animation runtime state a previous load left behind ---"
    # @clux_bar_tpl and @clux_frame_idx[_<client_pid>] are RUNTIME options the
    # animated-busy-glyph design (2026-08-23) reads and writes on every status
    # redraw — never config this file sets going forward, same rule as
    # @clux_session_bar / @clux_status above. Dropping them here matters on
    # "prefix + r" (a re-source of a LIVE server): without this, a stale
    # @clux_bar_tpl from before the reload would keep substituting into the bar
    # for up to FULL_EVERY (5s) seconds after a config change. Both are cleared
    # ABOVE the seed render below, so the seed render is the first thing to
    # repopulate them — never the reverse.
    printf '%s\n' 'set -gu @clux_bar_tpl'
    # printf, not echo: this line carries \( \) and \1, which xpg_echo (or a
    # /bin/sh-ish echo) would interpret before they ever reach the sed
    # expression written into the conf file — the same trap
    # get_agent_glyph_busy_frames() in helpers.sh documents for its own
    # backslash-bearing default.
    #
    # Single-quoted in the GENERATED conf, not double-quoted: tmux expands a
    # "$name" inside its own double-quoted run-shell argument before /bin/sh
    # ever sees it, so the double-quoted form of this line fails at runtime
    # with `set-option -gu ""` (verified on tmux 3.7b). xargs -n1 runs its
    # command zero times on empty input, so this is a no-op on a fresh server
    # that has never animated (verified).
    printf '%s\n' "run-shell 'tmux show-options -g | sed -n \"s/^\\(@clux_frame_idx[^ ]*\\) .*/\\1/p\" | xargs -n1 tmux set-option -gu'"
    echo
    echo "# --- Seed the bar (reap dead marks first, so nothing stale renders) ---"
    printf 'run-shell "%s/agent-clear.sh --reap"\n' "$SCRIPTS_DIR"
    printf 'run-shell "%s/session-bar-refresh.sh"\n' "$SCRIPTS_DIR"
}

# The directory must exist BEFORE mktemp, not after: the temp file is created
# next to $OUT so the later mv is a rename inside one filesystem. On a bare
# machine ~/.config/clux does not exist yet, and creating it afterwards is too
# late — mktemp fails, the "${OUT}.tmp.$$" fallback points into the same
# missing directory, the render redirect fails, and the script exits 1 without
# ever creating the directory it was about to write into.
if ! mkdir -p "$(dirname "$OUT")"; then
    echo "render-clux-conf.sh: cannot create $(dirname "$OUT")" >&2
    exit 1
fi

TMP="$(mktemp "${OUT}.XXXXXX" 2>/dev/null)" || TMP="${OUT}.tmp.$$"
if ! render > "$TMP"; then
    echo "render-clux-conf.sh: failed to render config" >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$OUT"
echo "$OUT"
