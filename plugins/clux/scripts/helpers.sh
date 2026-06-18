#!/usr/bin/env bash

# Shared utilities for clux plugin

# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/path.sh"

get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local value
    value=$(tmux show-option -gqv "$option")
    echo "${value:-$default_value}"
}

# Configuration defaults
NOTIFY_FILE=$(get_tmux_option "@claude-notify-file" "$HOME/.config/tmux/claude_notification")
NOTIFY_BG=$(get_tmux_option "@claude-notify-bg" "yellow")
NOTIFY_FG=$(get_tmux_option "@claude-notify-fg" "black")
NOTIFY_JUMP_KEY=$(get_tmux_option "@claude-notify-jump" "m")
NOTIFY_DISMISS_KEY=$(get_tmux_option "@claude-notify-dismiss" '`')


# Map Claude hook event names to notification types
map_event_to_type() {
    case "$1" in
        Stop) echo "stop" ;;
        Notification) echo "notification" ;;
        UserPromptSubmit) echo "prompt" ;;
        SessionEnd) echo "sessionend" ;;
        *) echo "$1" ;;
    esac
}

# Detect an available audio player for the current OS.
# Echoes the player command name (e.g. "afplay", "paplay") or empty string.
detect_sound_player() {
    if [[ "$OSTYPE" == darwin* ]]; then
        command -v afplay &>/dev/null && { echo "afplay"; return; }
    else
        for p in paplay pw-play aplay play ffplay; do
            command -v "$p" &>/dev/null && { echo "$p"; return; }
        done
    fi
    echo ""
}

# Per-notification config defaults
# Falls back to old @claude-notify-sound for backward compatibility
# Default to "off" when no usable audio player is available on this system,
# so fresh installs (e.g. Linux without PulseAudio) don't attempt playback.
_get_notification_default_sound() {
    if [ -z "$(detect_sound_player)" ]; then
        echo "off"
        return
    fi
    case "$1" in
        notification) echo "on" ;;
        *) echo "off" ;;
    esac
}

_get_notification_default_visual() {
    case "$1" in
        notification) echo "on" ;;
        *) echo "off" ;;
    esac
}

_get_notification_default_sound_file() {
    if [[ "$OSTYPE" == darwin* ]]; then
        case "$1" in
            prompt) echo "/System/Library/Sounds/Pop.aiff" ;;
            *) echo "/System/Library/Sounds/Blow.aiff" ;;
        esac
    else
        # Linux: use freedesktop sound theme if available
        local base="/usr/share/sounds/freedesktop/stereo"
        case "$1" in
            prompt) echo "$base/message.oga" ;;
            *) echo "$base/complete.oga" ;;
        esac
    fi
}

get_notification_sound_enabled() {
    local type="$1"
    local val
    val=$(get_tmux_option "@claude-notify-${type}-sound" "")
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    # Backward compat: fall back to global @claude-notify-sound
    local global
    global=$(get_tmux_option "@claude-notify-sound" "")
    if [ -n "$global" ]; then
        echo "$global"
        return
    fi
    _get_notification_default_sound "$type"
}

get_notification_sound_file() {
    local type="$1"
    get_tmux_option "@claude-notify-${type}-sound-file" "$(_get_notification_default_sound_file "$type")"
}

get_notification_visual_enabled() {
    local type="$1"
    local val
    val=$(get_tmux_option "@claude-notify-${type}-visual" "")
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    _get_notification_default_visual "$type"
}

LOCKDIR="${NOTIFY_FILE}.lock"

acquire_lock() {
    local lockfile="${NOTIFY_FILE}.flock"
    if command -v flock &>/dev/null; then
        exec 9>"$lockfile"
        flock -w 5 9
    else
        local attempts=0
        while ! mkdir "$LOCKDIR" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 50 ]; then
                # Stale lock — force remove
                rm -rf "$LOCKDIR"
                mkdir "$LOCKDIR" 2>/dev/null
                return
            fi
            sleep 0.1
        done
    fi
}

release_lock() {
    if command -v flock &>/dev/null; then
        exec 9>&-
    else
        rm -rf "$LOCKDIR"
    fi
}

# Re-derive LOCKDIR from the current $NOTIFY_FILE value.
# Call this after resolve_notify_file() overrides NOTIFY_FILE in the agent path.
recompute_lock_target() {
    LOCKDIR="${NOTIFY_FILE}.lock"
}

# Remove all queue entries whose id field matches |||agent:<session_id> followed
# by either the new @@-segment delimiter (agent:SID@@TMUXSID:WID:PID@@CWD) or
# end-of-line (legacy agent:SID). The ([@]{2}|$) boundary clears BOTH formats for
# a session while never over-matching a longer id (e.g. abc-123 must not clear
# abc-123-extra — validated by prototype P4).
# Skips silently when $1 is empty (prevents matching everything) or when the queue
# file does not exist yet.
# NOTE: mv runs UNCONDITIONALLY after a successful filter (no `&& mv`). grep -v exits 1
# when every line matches (queue becomes empty) — gating mv on grep's exit would leave
# the stale file in place, silently failing to remove the last/only matching entries.
_agent_remove_entry() {
    [ -z "$1" ] && return 0
    [ -f "$NOTIFY_FILE" ] || return 0
    acquire_lock
    grep -v -E "[|][|][|]agent:${1}([@]{2}|$)" "$NOTIFY_FILE" > "${NOTIFY_FILE}.tmp"
    mv "${NOTIFY_FILE}.tmp" "$NOTIFY_FILE"
    release_lock
}

# @clux-agent-* option getters (reader/jump side — hardcoded defaults per spec §5).
get_agent_visual_enabled()  { get_tmux_option "@clux-agent-visual"  "on"; }
get_agent_desktop_enabled() { get_tmux_option "@clux-agent-desktop" "on"; }
get_agent_sound_enabled()   { get_tmux_option "@clux-agent-sound"   "on"; }
get_agent_osc_code()        { get_tmux_option "@clux-agent-osc"     "9"; }
get_agent_marker()          { get_tmux_option "@clux-agent-marker"  "⚡"; }
get_agent_window()          { get_tmux_option "@clux-agent-window"  "agents"; }
# Key sent to the agents pane right after landing, to force the `claude agents`
# TUI back to its main list (in case it was showing a single sub-agent). Empty
# string disables the keystroke. Default "Left" — the TUI's back navigation.
get_agent_nav_key()         { get_tmux_option "@clux-agent-nav-key" "Left"; }

# Resolve the agent session's display name — the name shown in the `claude agents`
# view. Source of truth: the latest "custom-title" entry in the session
# transcript, which is keyed by the hook's session_id for BOTH interactive
# (worktree) and background agent sessions (verified v2.1.150). This is more
# reliable than sessions-index.json (often absent) or the cwd basename (the
# folder, which the session name frequently does NOT match, e.g. a session named
# "sdlc-84-review" living in ".../avonrisk-sdlc").
#
#   $1 = session_id   $2 = cwd   $3 = transcript_path (may be empty)
#
# Falls back to the cwd basename when the session is unnamed or the transcript is
# unreadable. Pure stdout — no tmux IPC, no queue side effects.
resolve_agent_name() {
    local sid="$1" cwd="$2" transcript="$3"
    local tfile="" name="" line=""

    if [ -n "$transcript" ] && [ -f "$transcript" ]; then
        tfile="$transcript"
    elif [ -n "$sid" ] && [ -n "$cwd" ]; then
        # Claude encodes the project dir under ~/.claude/projects by replacing
        # every '/' and '.' in the cwd with '-'. Used only when the hook payload
        # omits transcript_path (some Notification shapes do).
        tfile="$HOME/.claude/projects/$(printf '%s' "$cwd" | sed 's#[/.]#-#g')/$sid.jsonl"
    fi

    if [ -n "$tfile" ] && [ -f "$tfile" ]; then
        # grep-filter first (cheap even on multi-MB transcripts), keep the most
        # recent rename, then parse that single line (jq if available, else sed).
        line=$(grep '"type":"custom-title"' "$tfile" 2>/dev/null | tail -1)
        if [ -n "$line" ]; then
            if command -v jq &>/dev/null; then
                name=$(printf '%s' "$line" | jq -r '.customTitle // empty' 2>/dev/null)
            else
                name=$(printf '%s' "$line" | sed -n 's/.*"customTitle":"\([^"]*\)".*/\1/p')
            fi
        fi
    fi

    [ -z "$name" ] && name=$(basename "$cwd" 2>/dev/null)
    printf '%s' "$name"
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
resolve_agents_pane_by_cwd() {
    local cwd="$1"
    [ -z "$cwd" ] && return 0

    local panes procs
    panes=$(tmux list-panes -a \
             -F '#{pane_pid}	#{session_id}	#{window_id}	#{pane_id}	#{pane_current_path}' \
             2>/dev/null)
    [ -z "$panes" ] && return 0
    # One process snapshot: "<pid> <ppid> <args...>". `ps -eo pid=,ppid=,args=`
    # is accepted by both GNU (Linux) and BSD (macOS) ps; no /proc dependency.
    procs=$(ps -eo pid=,ppid=,args= 2>/dev/null)
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

# Navigate to the tmux pane that hosts the `claude agents` dashboard.
# Used by both jump-to-notification.sh and notification-picker.sh.
#
# Strategy (v3 — "detect the running pane"):
#   The agent view is a single `claude agents` TUI. The individual agent
#   sessions live INSIDE that TUI — there is no per-session tmux pane to land on
#   and no CLI to deep-link a session by id, so the jump target is the dashboard
#   pane itself; the user picks the session from there.
#
#   1. Primary — find the pane actually running `claude agents`, identified by
#      its #{pane_start_command} OR the title the TUI sets ("… · claude agents").
#      This is what the docs promise ("checks whether a claude agents pane is
#      already open") and is robust to window NAMING, which varies by host:
#      with automatic-rename off (or when launched in a project-named window)
#      the window is never named "agents", so the old v2 name match silently
#      missed it and every jump spawned a brand-new window — and the nav-key
#      nudge (existing-pane only) never fired. (Linux-vs-macOS divergence: macOS
#      happened to have a window literally named "agents"; Linux did not.)
#   2. Fallback — legacy window-name convention (@clux-agent-window, default
#      "agents") for setups that still rely on it.
#   3. If neither matches, open the dashboard in a new window of that name.
# agent_jump [target] [cwd]
#   target = "SID WID PID" tmux coords embedded in the queue entry (may be empty)
#   cwd    = the agent session cwd, for self-healing re-resolution (may be empty)
#
# Multi-session routing (spec §2.6):
#   FAST-PATH  — if target is non-empty AND the embedded pane id STILL exists,
#                route straight to it.
#   RE-RESOLVE — else if cwd is non-empty, resolve the owning dashboard pane by
#                process-based longest-prefix match and route there.
#   FALLBACK   — else (no args, or both miss) drop through to the v3 body:
#                detect a `claude agents` pane, else open one in a new window.
agent_jump() {
    local _target="$1" _cwd="$2"
    local wname match="" nav_key sess_id win_id pane_id
    wname=$(get_agent_window)
    nav_key=$(get_agent_nav_key)

    # FAST-PATH: honour the embedded pane id if it STILL exists. Dashboards are
    # no longer identified by window name (they live in per-project windows), so
    # the gate is bare existence. tmux pane ids (%N) increase monotonically and
    # are not reused within a server's lifetime, so a surviving id is the same
    # pane it was at ping time; any miss falls through to the cwd re-resolve.
    if [ -n "$_target" ]; then
        local _t_sid _t_wid _t_pid _probe
        read -r _t_sid _t_wid _t_pid <<< "$_target"
        if [ -n "$_t_pid" ]; then
            _probe=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null \
                       | grep -Fx "$_t_pid")
            if [ -n "$_probe" ]; then
                tmux switch-client -t "$_t_sid" 2>/dev/null
                tmux select-window -t "$_t_wid" 2>/dev/null
                [ -n "$nav_key" ] && tmux send-keys -t "$_t_pid" "$nav_key" 2>/dev/null
                return 0
            fi
        fi
    fi

    # RE-RESOLVE: self-heal by longest-prefix cwd match against live agents panes.
    if [ -n "$_cwd" ]; then
        local _coords _r_sid _r_wid _r_pid
        _coords=$(resolve_agents_pane_by_cwd "$_cwd")
        if [ -n "$_coords" ]; then
            read -r _r_sid _r_wid _r_pid <<< "$_coords"
            tmux switch-client -t "$_r_sid" 2>/dev/null
            tmux select-window -t "$_r_wid" 2>/dev/null
            [ -n "$nav_key" ] && tmux send-keys -t "${_r_pid:-$_r_wid}" "$nav_key" 2>/dev/null
            return 0
        fi
    fi

    # FALLBACK (v3, unchanged) — reached by no-arg callers and both miss paths.
    # Primary: the pane whose start-command or title says "claude agents".
    match=$(tmux list-panes -a \
              -f '#{||:#{m:*claude agents*,#{pane_start_command}},#{m:*claude agents*,#{pane_title}}}' \
              -F '#{session_id} #{window_id} #{pane_id}' 2>/dev/null | head -1)

    # Fallback: legacy window-name convention.
    if [ -z "$match" ]; then
        match=$(tmux list-windows -a -f "#{==:#{window_name},$wname}" \
                  -F '#{session_id} #{window_id} #{pane_id}' 2>/dev/null | head -1)
    fi

    if [ -n "$match" ]; then
        read -r sess_id win_id pane_id <<< "$match"
        tmux switch-client -t "$sess_id" 2>/dev/null
        tmux select-window -t "$win_id" 2>/dev/null
        # Nudge the agents TUI back to its main list. send-keys writes straight
        # to the pane's input, independent of client focus, so this lands even
        # if switch-client hasn't fully settled. Target the specific pane so the
        # key lands in multi-pane windows. Only on an existing dashboard — a
        # freshly launched `claude agents` (else branch) is already on main.
        [ -n "$nav_key" ] && tmux send-keys -t "${pane_id:-$win_id}" "$nav_key" 2>/dev/null
    else
        tmux new-window -n "$wname" "claude agents" 2>/dev/null
    fi
}

