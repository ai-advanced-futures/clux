#!/usr/bin/env bash
# SOURCING this file is free: no top-level statements, no tmux IPC, no side
# effects. That guarantee is what lets a hook source it before it knows whether
# it has a tmux pane at all.
#
# The path resolvers — resolve_notify_file(), resolve_agent_state_dir() — are
# pure: they read env vars and a sidecar file and print a path.
#
# THREE functions here are deliberately NOT pure. reap_agent_state_dir() calls
# tmux and deletes files; refresh_agent_bar() calls tmux;
# resolve_agents_pane_by_cwd() calls tmux and ps. All live in this file so
# their callers share one copy instead of each rolling its own, and all do
# that work only when CALLED — sourcing still costs nothing. Do not add a
# fourth impure function here without saying so in this header.
# (resolve_agents_pane_by_cwd moved here from helpers.sh: helpers.sh runs five
# get_tmux_option calls at SOURCE time, and hooks/agent-state.sh must stay
# cheap, so it can only source this file.)

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

# Reap state files whose pane id is no longer live on the tmux server — narrows
# the pane-id-reuse hole after a server restart. It does not close it: an id the
# new server has already handed to a different pane is live, so the file is
# kept, and the bar marks a pane that holds no Claude. Shared by the two writers:
# hooks/agent-state.sh (opportunistic, after every write) and agent-clear.sh
# --reap (once at config load). The empty-LIVE guard is load-bearing: a missing
# server or a failed list-panes yields an empty listing and the reap is skipped
# whole, so it can never wipe the store. $1 = state dir.
reap_agent_state_dir() {
    local state_dir="$1" live haystack f base pane
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
    # Detached-agent files live one level down, named <pane_id>~<session_id>
    # (see hooks/agent-state.sh). Same live-pane test, applied to the pane
    # part of the name — a closed dashboard pane sweeps its agents' files.
    # This loop is also the writer's cache invalidation: a write through a
    # stale cached pane lands here in the same invocation and is deleted, so
    # the agent's next event re-resolves (the design doc's self-heal).
    for f in "$state_dir"/agents/*; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        case "$base" in
            .tmp.*) continue ;;
            %*~*) ;;
            *) continue ;;
        esac
        pane="${base%%~*}"
        case "$haystack" in
            *$'\n'"$pane"$'\n'*) ;;
            *) rm -f "$f" 2>/dev/null ;;
        esac
    done
}

# Resolve the tmux pane of the `claude agents` dashboard that OWNS a given cwd.
# Echoes "<session_id> <window_id> <pane_id>" (space-separated, one line) on a
# match, or nothing on no match / no tmux server. Used by BOTH the write side
# (notify-tmux.sh, detached with TMUX unset, over the default socket) and the
# jump side (agent_jump re-resolve).
#
#   $1 = cwd of the agent session (the .cwd hook field)
#
# Strategy (v5 — "detect the dashboard by its PROCESS"):
#   tmux's #{pane_current_command} reports only the bare command name (always
#   "claude" — never the args), #{pane_start_command} is the launching shell
#   (/bin/bash), and the window is named per-project, not "agents". So a running
#   `claude agents` dashboard is INVISIBLE to tmux format matching — the earlier
#   window-name / "claude agents" string filters matched nothing on real setups
#   and every jump fell through to a useless new-window. The process table is the
#   only reliable signal.
#
#   1. Snapshot panes (pane_pid -> session/window/pane/path) and processes
#      (pid ppid args) — one `tmux list-panes` + one `ps`, both portable.
#   2. A dashboard is any process whose OWN binary basename is `claude` carrying
#      the `agents` subcommand. Its managed root is its `--cwd <path>` value (or,
#      absent that, the owning pane's current path). The basename guard excludes
#      `script -qfc claude…`, `bash -c …` wrappers, and background pty hosts.
#   3. Map each dashboard process to its tmux pane by walking the ppid chain
#      (within the same ps snapshot) until a pid equals a pane_pid — robust to a
#      wrapper sitting between the pane shell and the claude process.
#   4. Pick the dashboard whose root is the LONGEST prefix of $1. The pane we land
#      on is the claude pane itself (it is the process we matched), so split
#      claude+bash windows need no extra disambiguation.
# Canonicalize a directory path for prefix comparison. Two spellings of the same
# directory ("/p", "/p/", "/p/.", or a symlinked route to it) must compare equal,
# otherwise the longest-prefix match below silently misses and the caller falls
# through to a server-wide guess. Resolves symlinks when the path exists; falls
# back to lexical cleanup when it does not (a dashboard whose cwd was removed).
_clux_canon_path() {
    local p="$1"
    [ -z "$p" ] && return 0
    if [ -d "$p" ]; then
        ( cd -- "$p" 2>/dev/null && pwd -P ) && return 0
    fi
    # Lexical fallback. One suffix of each kind is enough: the inputs are a tmux
    # pane_current_path (never trailing-slashed) or a single --cwd scrape, so
    # stacked artifacts like "/p/./." do not occur. "" means the path was all
    # separators, i.e. the root.
    p=${p%/.}
    p=${p%/}
    printf '%s\n' "${p:-/}"
}

resolve_agents_pane_by_cwd() {
    local cwd="$1"
    [ -z "$cwd" ] && return 0
    cwd=$(_clux_canon_path "$cwd")

    local panes procs
    panes=$(tmux list-panes -a \
             -F '#{pane_pid}	#{session_id}	#{window_id}	#{pane_id}	#{pane_current_path}' \
             2>/dev/null)
    [ -z "$panes" ] && return 0
    # One process snapshot: "<pid> <ppid> <args...>". No /proc dependency.
    #
    # -A, not -e: on Linux they are synonyms ("-A  Select all processes.
    # Identical to -e"), but on BSD/macOS -e means "display the environment as
    # well" and -A is the flag that selects every process. The previous -e
    # therefore scanned only the caller's own terminal-attached processes on
    # macOS — and appended env vars to args, which the --cwd sed below can
    # mis-scrape. -A is unambiguous on both.
    #
    # -ww disables column truncation: BSD ps clips args to the terminal width
    # (80 when not a tty, i.e. inside a hook), which lands mid-path on a real
    # `claude agents --cwd …` line and leaves $aroot a partial directory.
    procs=$(ps -A -ww -o pid=,ppid=,args= 2>/dev/null)
    [ -z "$procs" ] && return 0

    local best_len=-1 best_sid="" best_wid="" best_pid="" IFS_save=$IFS

    while IFS= read -r prow; do
        local apid aargs first base aroot
        prow="${prow#"${prow%%[![:space:]]*}"}"   # ltrim leading ps padding
        apid=${prow%% *}; prow=${prow#* }
        prow="${prow#"${prow%%[![:space:]]*}"}"
        # second field is ppid (skipped here; the chain walk re-reads it), rest is args
        prow=${prow#* }
        aargs=$prow
        [ -z "$apid" ] && continue
        first=${aargs%% *}; base=${first##*/}
        [ "$base" = "claude" ] || continue
        case " $aargs " in *" agents "*) ;; *) continue ;; esac

        # Managed root = the dashboard's --cwd value (pane path filled in later).
        aroot=$(printf '%s' "$aargs" | sed -n 's/.*--cwd \([^ ][^ ]*\).*/\1/p')

        # Walk the ppid chain (same ps snapshot) until a pid hits a tmux pane_pid.
        local cur=$apid depth=0 pane_row=""
        while [ -n "$cur" ] && [ "$cur" != "0" ] && [ "$cur" != "1" ] && [ "$depth" -lt 12 ]; do
            pane_row=$(printf '%s\n' "$panes" | awk -F'\t' -v p="$cur" '$1==p{print; exit}')
            [ -n "$pane_row" ] && break
            cur=$(printf '%s\n' "$procs" | awk -v p="$cur" '{if ($1==p){print $2; exit}}')
            depth=$((depth + 1))
        done
        [ -z "$pane_row" ] && continue

        local p_pid p_sid p_wid p_paneid p_path
        IFS=$'\t' read -r p_pid p_sid p_wid p_paneid p_path <<<"$pane_row"
        IFS=$IFS_save
        [ -z "$aroot" ] && aroot="$p_path"
        aroot=$(_clux_canon_path "$aroot")

        case "$cwd" in
            "$aroot"|"$aroot"/*)
                if [ "${#aroot}" -gt "$best_len" ]; then
                    best_len=${#aroot}
                    best_sid=$p_sid
                    best_wid=$p_wid
                    best_pid=$p_paneid
                fi
                ;;
        esac
    done <<EOF
$procs
EOF
    IFS=$IFS_save

    [ -z "$best_wid" ] && return 0
    printf '%s %s %s\n' "$best_sid" "$best_wid" "$best_pid"
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
refresh_agent_bar() {
    local cmd
    cmd=$(tmux show-option -gqv "@clux-agent-refresh-command" 2>/dev/null)
    [ -n "$cmd" ] || cmd="refresh-client -S"
    # shellcheck disable=SC2086
    tmux $cmd 2>/dev/null || true
}
