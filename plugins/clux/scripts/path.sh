#!/usr/bin/env bash
# SOURCING this file is free: no top-level statements, no tmux IPC, no side
# effects. That guarantee is what lets a hook source it before it knows whether
# it has a tmux pane at all. CLUX_VERSION below is a bare constant — no
# process, no tmux IPC — for the same reason.
#
# The path resolvers — resolve_notify_file(), resolve_agent_state_dir() — are
# pure: they read env vars and a sidecar file and print a path.
#
# FOUR functions here are deliberately NOT pure:
#   reap_agent_state_dir()    calls tmux and deletes files.
#   refresh_agent_bar()       calls tmux, and (when the bar segment is active)
#                             WRITES the @clux-agent-bar option before redrawing.
#   clux_ensure_installed()   calls tmux to register the two indexed hooks and
#                             the status-right segment against the live server.
#   _clux_install_bar_segment() calls tmux to append the bar segment or record
#                             that it could not be reached.
# All four live in this file so the writers share one copy instead of each
# rolling its own, and all four do that work only when CALLED — sourcing still
# costs nothing. Do not add a fifth impure function here without saying so in
# this header.

# Runtime source of truth for the reinstall marker (@clux-installed). Must
# equal the "version" field in .claude-plugin/plugin.json — test/path.bats
# enforces that. Kept as a bare constant, not read from plugin.json at
# runtime: configure-tmux.sh deploy_scripts() copies path.sh alone to
# $HOME/.config/clux/scripts, where no ../.claude-plugin/plugin.json sibling
# exists, and a jq call per hook fire would break the "sourcing is free"
# promise above.
CLUX_VERSION="3.2.0"

_CLUX_SIDECAR="${HOME}/.config/clux/notify-file-path"
_CLUX_AGENT_SIDECAR="${HOME}/.config/clux/agent-state-dir"

resolve_notify_file() {
    # Tier 1: explicit env var (set by tmux setenv -g in claude-notify.tmux)
    if [ -n "${CLUX_NOTIFY_FILE:-}" ]; then
        echo "$CLUX_NOTIFY_FILE"
        return
    fi
    # Tier 2: sidecar written at plugin load time by claude-notify.tmux
    local sidecar_val
    sidecar_val=$(cat "$_CLUX_SIDECAR" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$sidecar_val" ]; then
        echo "$sidecar_val"
        return
    fi
    # Tier 3: HOME default
    echo "${HOME}/.config/tmux/claude_notification"
}

# Resolve the agent-state directory — one file per tmux pane, holding one word
# (busy / needs-you / finished). Mirrors resolve_notify_file() exactly, same
# three tiers, so the writer (hooks/agent-state.sh) and the readers
# (agent-query.sh, agent-bar.sh, agent-clear.sh) can never disagree about where
# the store lives. Never emits a trailing slash — every caller joins with "/".
#
# XDG_STATE_HOME (not the queue's ~/.config/tmux) is correct here: this data is
# per-machine, regenerable, and not configuration.
resolve_agent_state_dir() {
    # Tier 1: explicit env var (set by tmux setenv -g in claude-notify.tmux)
    if [ -n "${CLUX_AGENT_STATE_DIR:-}" ]; then
        echo "$CLUX_AGENT_STATE_DIR"
        return
    fi
    # Tier 2: sidecar written at plugin load time by claude-notify.tmux.
    # Command substitution already strips the single trailing newline the
    # writer adds; do NOT `tr -d '[:space:]'` — that would also delete real
    # spaces inside a state-dir path (e.g. an XDG_STATE_HOME with a space).
    local sidecar_val
    sidecar_val=$(cat "$_CLUX_AGENT_SIDECAR" 2>/dev/null)
    if [ -n "$sidecar_val" ]; then
        echo "$sidecar_val"
        return
    fi
    # Tier 3: XDG default
    echo "${XDG_STATE_HOME:-$HOME/.local/state}/clux/agents"
}

# Reap state files whose pane id is no longer live on the tmux server — closes
# the pane-id-reuse hole after a server restart. Shared by the two writers:
# hooks/agent-state.sh (opportunistic, after every write) and agent-clear.sh
# --reap (once at config load). The empty-LIVE guard is load-bearing: a missing
# server or a failed list-panes yields an empty listing and the reap is skipped
# whole, so it can never wipe the store. $1 = state dir.
reap_agent_state_dir() {
    local state_dir="$1" live haystack f base
    [ -n "$state_dir" ] || return 0
    live=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)
    [ -n "$live" ] || return 0
    # Wrap the listing in newlines ONCE so a whole-line match becomes a plain
    # substring test done by bash itself. The delimiters are what keep `%1`
    # from matching `%10`, exactly as `grep -qxF` did. This runs after every
    # hook fire, so the previous `printf | grep` per state file cost two
    # processes per file per fire; this costs none.
    haystack=$'\n'"$live"$'\n'
    for f in "$state_dir"/*; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        case "$base" in
            .tmp.*) continue ;;
            %*) ;;
            *) continue ;;
        esac
        case "$haystack" in
            *$'\n'"$base"$'\n'*) ;;
            *) rm -f "$f" 2>/dev/null ;;
        esac
    done
}

# Ask tmux to redraw whatever shows agent state. Shared by the two writers so
# they can never disagree about how a change reaches the screen.
#
# The default, `refresh-client -S`, is enough when the bar reads agent state
# through a `#(...)` shell job: tmux re-runs the job and redraws. It is NOT
# enough when the bar is a precomputed tmux option — a `#{@some_bar}` built by
# a separate script — because a redraw re-reads that option without rebuilding
# it, so the stale value comes back. Such a configuration sets
# @clux-agent-refresh-command to its own rebuild command instead.
#
# The option is expanded unquoted on purpose: it holds a tmux command line, and
# word splitting is what turns it into arguments. An argument containing a
# space therefore cannot be expressed through this option.
#
# When the precomputed-option bar segment is active (_CLUX_BAR_OPTION_ACTIVE=1,
# set by clux_ensure_installed()/_clux_install_bar_segment()), the option is
# re-rendered and WRITTEN before the redraw — a redraw first would show the
# stale value. The gate is what keeps the cost promise: a user whose bar is a
# `#(agent-bar.sh)` job (the pre-3.2.0 shape) never pays the extra render, and
# the flag is unset (so treated as 0) whenever clux_ensure_installed() was
# never called or returned early.
refresh_agent_bar() {
    local cmd
    if [ "${_CLUX_BAR_OPTION_ACTIVE:-0}" = "1" ]; then
        local self_dir rendered
        self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        rendered=$("$self_dir/agent-bar.sh" 2>/dev/null)
        tmux set-option -g @clux-agent-bar "$rendered" 2>/dev/null || true
    fi
    cmd=$(tmux show-option -gqv "@clux-agent-refresh-command" 2>/dev/null)
    [ -n "$cmd" ] || cmd="refresh-client -S"
    # shellcheck disable=SC2086
    tmux $cmd 2>/dev/null || true
}

# clux_ensure_installed — the self-installer. Registers, against the LIVE tmux
# server only (never a file the user owns), the two indexed hooks that clear
# `finished` marks on window/session switch, and the `#{@clux-agent-bar}`
# status-right segment. Idempotent: costs one `tmux show-options -g` on the
# common already-installed case, and nothing at all when TMUX is unset or this
# copy is not the plugin's own (see guards below). Called from the top of
# hooks/agent-state.sh and scripts/agent-clear.sh so the install piggybacks on
# hooks that already fire — no new Claude Code hook event, no tmux.conf edit.
#
# Guards are ordered cheapest-first:
clux_ensure_installed() {
    # a. No tmux pane, nothing to install against.
    [ -n "${TMUX:-}" ] || return 0

    # b. Resolve the directory of the RUNNING copy of this file. Inside a
    # function defined in path.sh, BASH_SOURCE[0] is path.sh itself — this
    # resolves to the plugin tree's scripts dir when running from the plugin,
    # and to a deployed tree's scripts dir when running from there.
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # c. ONLY the plugin's own copy installs. A stat, not an IPC. A deployed
    # copy under ~/.config/clux/scripts has no .claude-plugin sibling, so it
    # can never register hooks pointing at the deployed dir, and can never
    # write a stale/different version into the one global marker — the two
    # copies can never fight over hook index [90].
    [ -f "$self_dir/../.claude-plugin/plugin.json" ] || return 0

    # d. ONE tmux IPC, carrying every fact this function needs.
    local opts
    opts=$(tmux show-options -g 2>/dev/null) || return 0
    [ -n "$opts" ] || return 0

    # e. Publish flag for refresh_agent_bar(), read straight from the dump —
    # decision (a): the question is only whether a clux segment exists
    # SOMEWHERE (status-right, a status-format[N] entry, or anywhere else the
    # user parked it), never where. No false positive: the option's own
    # definition line in the dump reads `@clux-agent-bar <value>`, never the
    # format-reference text `#{@clux-agent-bar}`.
    case "$opts" in
        *'#{@clux-agent-bar}'*) _CLUX_BAR_OPTION_ACTIVE=1 ;;
        *)                      _CLUX_BAR_OPTION_ACTIVE=0 ;;
    esac

    # f. Same delimiter idiom as reap_agent_state_dir(): wrap once so a
    # whole-line match becomes a plain substring test.
    local haystack need_hooks need_bar
    haystack=$'\n'"$opts"$'\n'

    case "$haystack" in
        *$'\n'"@clux-installed $CLUX_VERSION"$'\n'*) need_hooks=0 ;;
        *)                                           need_hooks=1 ;;
    esac

    if [ "$_CLUX_BAR_OPTION_ACTIVE" = "1" ]; then
        need_bar=0
    else
        case "$haystack" in
            *$'\n'"@clux-agent-bar-unreachable 1"$'\n'*) need_bar=0 ;;
            *)                                           need_bar=1 ;;
        esac
    fi

    # Idempotent skip — the common case, after the first install of a version.
    # This is also the ratchet fix: a user who reloads tmux.conf gets
    # status-right rebuilt from their file, the clux token disappears, and
    # need_bar catches it on the NEXT fire even though @clux-installed still
    # matches — at zero extra IPC, since the same dump already answered it.
    [ "$need_hooks" = "1" ] || [ "$need_bar" = "1" ] || return 0

    if [ "$need_hooks" = "1" ]; then
        tmux set-hook -g 'after-select-window[90]' \
            "run-shell \"$self_dir/agent-clear.sh '#{window_id}'\"" 2>/dev/null
        tmux set-hook -g 'client-session-changed[90]' \
            "run-shell \"$self_dir/agent-clear.sh '#{window_id}'\"" 2>/dev/null
    fi

    if [ "$need_bar" = "1" ]; then
        _clux_install_bar_segment "$opts"
    fi

    if [ "$need_hooks" = "1" ]; then
        tmux set-option -g @clux-installed "$CLUX_VERSION" 2>/dev/null
    fi

    # Publish content immediately rather than waiting for the next state
    # change — otherwise a freshly-installed segment shows nothing until the
    # next hook fire.
    refresh_agent_bar
}

# _clux_install_bar_segment — appends `#{@clux-agent-bar}` to status-right, or
# records that the bar is unreachable and warns once. $1 = the option dump
# already read by clux_ensure_installed() — never a second `show-options -g`.
_clux_install_bar_segment() {
    local opts="$1"

    # a. Belt and braces for a direct caller: a segment already present
    # anywhere means there is nothing to install.
    case "$opts" in
        *'#{@clux-agent-bar}'*)
            _CLUX_BAR_OPTION_ACTIVE=1
            return 0
            ;;
    esac

    # b. Tier B detection: status-format[0] is non-empty and does not
    # reference status-right at all (the tmux default does, via
    # `#{T;=/#{status-right-length}:status-right}`) — the segment can never
    # reach the bar through the status-right append below. Empty/unreadable
    # fmt0 is treated as Tier A on purpose: a harmless append beats a false
    # "your bar is unreachable" warning. Only status-format[0] is inspected;
    # a user with `status` 2..5 and clux parked on a different bar line is
    # misclassified (accepted, low frequency).
    local fmt0
    fmt0=$(tmux show-option -gqv 'status-format[0]' 2>/dev/null)
    if [ -n "$fmt0" ]; then
        case "$fmt0" in
            *status-right*) ;;
            *)
                tmux set-option -g @clux-agent-bar-unreachable 1 2>/dev/null
                tmux display-message "clux: cannot reach the status bar automatically — status-format[0] does not reference status-right. Add #{@clux-agent-bar} to your bar manually (see agent-bar.sh / agent-query.sh) or run /clux:validate." 2>/dev/null
                _CLUX_BAR_OPTION_ACTIVE=0
                return 0
                ;;
        esac
    fi

    # d. Tier A: tmux's own `-a` append is one IPC, cannot clobber (unlike a
    # read-then-append with a failed read), and needs no rc guard. A
    # `#{status-right}` self-reference (an earlier draft) is rejected: tmux
    # expands an option reference exactly one level and draws the rest
    # literally, so that shape renders the literal text `#{status-right}` on
    # the bar.
    tmux set-option -ag status-right " #{@clux-agent-bar}" 2>/dev/null
    _CLUX_BAR_OPTION_ACTIVE=1
    # Clear a stale unreachable flag now that the segment is installed.
    tmux set-option -gu @clux-agent-bar-unreachable 2>/dev/null
}
