#!/usr/bin/env bash
# The single refresh entry point for both rendered tokens: computes
# @clux_session_bar from session-list.sh and @clux_status from
# show-notification.sh, then issues one redraw.
#
# The status line renders #{@clux_session_bar} and #{@clux_status} (inline
# option lookups, evaluated on every redraw) instead of live #(...) jobs. A
# #() job is cached and only re-runs on status-interval, so session/window
# switches lagged by up to ~2s. Driving the strings through options + hooks
# makes switches reflect instantly.
#
# Called from: tmux hooks (session/window changes, [91] in clux.tmux.conf),
# session-reorder.sh, the periodic safety-net #() literal in the user's
# status-format, and once at config load.
#   arg1 = "quiet" -> skip the forced redraw (periodic path; the next interval
#                     redraw will pick up the new value on its own).
#   arg2 = the rendering client's #{client_pid}, quiet path only. tmux runs a
#          #() job once per attached client rendering that status line, not
#          once per server: with two clients, the periodic literal fires
#          twice per interval, and a single shared frame counter would race
#          (both read N, both write N+1) and advance twice as fast. Passing
#          the client id keys the counter as @clux_frame_idx_<id> instead, so
#          each client owns and advances only its own. A missing or
#          non-numeric id (a manual invocation, an old status-format token, a
#          test) falls back to the shared @clux_frame_idx name — see
#          "Client id" below.
#
# Neither token is written when the script that computes it FAILS —
# deliberately not `set -e`, so one renderer dying does not skip the other,
# and a renderer that dies leaves the previous option value in place rather
# than blanking that half of the bar. Because `tmux set-option` is atomic,
# hooks firing at once need no lock.
#
# The two differ on what an exit-0-with-empty result means, and the
# difference is load-bearing:
#
#   show-notification.sh  empty IS the answer. `[ -f "$NOTIFY_FILE" ] || exit 0`
#                         is its normal "nothing pending" path, reached every
#                         time a notification is dismissed or jumped to. So an
#                         empty result must be WRITTEN, clearing the badge.
#                         Guarding on non-empty here left a dismissed
#                         notification on the bar until an unrelated one
#                         replaced it — a regression against the pre-3.3
#                         wiring, where a live #() job simply rendered nothing.
#                         It is run on EVERY path below, including a cheap
#                         animation tick — it is not part of the animation
#                         throttle at all. notify-tmux.sh only redraws
#                         (`refresh-client -S`), which re-reads a precomputed
#                         option without rebuilding it (path.sh:353); skipping
#                         this call on the periodic path would strand a badge
#                         until an unrelated hook fired and stop its
#                         auto-dismiss loop ticking.
#
#   session-list.sh       empty is never a real answer: a running tmux server
#                         always has at least one session, so the renderer
#                         always has a row to draw. An empty result there means
#                         it failed without saying so, and keeping the previous
#                         bar is the safer reading.
#
# --- Animated busy glyph (2026-08-23 design) -------------------------------
#
# A full render of session-list.sh costs ~110ms and is only needed when the
# bar's CONTENT changes; animation only changes one glyph. So a full render's
# output is cached, sentinel and all, in one option (@clux_bar_tpl, holding
# "<epoch><TAB><template>" so a tick can never pair a template with a
# timestamp written by a different render), and a cheap tick just substitutes
# the current animation frame into that cached string with a bash string
# replace — never a tmux `#{E:...}` re-expansion, which was measured to
# collapse "##" back to "#" and corrupt the bar (the rejected approach this
# design replaced).
#
# Frame index: a COUNTER in a tmux option, not a value derived from the wall
# clock — a clock-derived frame was measured to skip frames, because tmux
# only re-samples a #() job's cached result once per status-interval, checked
# at redraw time, and the two clocks drift. The counter is advanced by
# exactly one, ONLY on the periodic (quiet) path, so every frame is drawn in
# order and a burst of hooks can never fast-forward the animation — the hook
# path reads the counter's CURRENT value and never writes it. See "Client id"
# above for why the counter is per-client.
#
# This script deliberately does NOT source helpers.sh (repo invariant: this
# file and session-list.sh are the hot path, sourcing helpers.sh costs five
# get_tmux_option round-trips at source time, once per redraw per client) —
# so the frame-list parsing below (split on space with `read -r -a`, `#`
# doubled, empty-after-parsing falls back to the single busy glyph) is a
# SECOND COPY of helpers.sh's get_agent_frame(). The two are pinned together
# by the cross-check test in test/session-bar-refresh.bats — change one,
# change the other.
#
# Sentinel: U+E000, a private-use code point that cannot appear in a session
# name, a window name, or a style, so it can be told apart from anything a
# user could type. session-list.sh draws it, instead of the real busy glyph,
# only when invoked with CLUX_AGENT_GLYPH_BUSY set to it — see
# session-list.sh and helpers.sh's get_agent_glyph_busy() for the other half
# of that override. It must never reach the screen: the frame substituted in
# is never empty (falls back to the busy glyph, and to "*" past that), and
# every write path below substitutes it out before writing @clux_session_bar.
#
# Known, accepted jitter: the hook path has no client id, so it always reads
# the SHARED counter (@clux_frame_idx), which a per-client periodic tick never
# advances. This is not limited to a two-client server: on ANY install whose
# status line passes #{client_pid}, the shared counter stays at 0, so every
# hook-driven full render draws frame 0 until the next periodic tick resumes
# the client's own sequence. Advancing the counter on the hook
# path is forbidden by design (a burst of hooks would fast-forward the
# animation); picking one client's counter over another is racy. This
# one-frame jitter on a user-initiated event is the accepted cost.

set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TAB=$'\t'
# U+E001, private use. NOT a control byte: tmux 3.4's `display-message -p`
# escapes those on the way out (a literal 0x1F returns as the four characters
# \037), so the batched read below never split and the escaped text leaked
# into the bar. TAB survives 3.4, but it cannot be the separator here —
# @clux_bar_tpl holds "<epoch><TAB><template>" and is field 1 of that read.
# Octal UTF-8 form for the same bash-3.2 reason as SENTINEL below.
SEP=$'\356\200\201'
# U+E000, private use. Bash 3.2 on macOS mis-parses the dollar-quote
# \u escape form of this code point into six literal backslash-u-e000
# characters instead of the code point itself -- do not use that form.
# $'\356\200\200' (octal UTF-8) IS the single character on both bash 3.2
# and bash 5.x (verified on this repo's target machine).
SENTINEL=$'\356\200\200'
# The periodic safety-net role of the #() job (a session created by something
# that fires no hook) stays at this cadence instead of every tick. A script
# constant, not a tmux option — clux adds no config it does not need.
FULL_EVERY=5

mode="${1:-}"

# --- Client id (quiet path only) -------------------------------------------
# Validated against ^[0-9]+$ before it is ever interpolated into a
# display-message FORMAT STRING below — an unvalidated value there is a
# format-injection hole. Anything that is not purely digits (including empty)
# falls back to the shared counter name.
client_id=""
if [ "$mode" = "quiet" ]; then
    case "${2:-}" in
        ''|*[!0-9]*) client_id="" ;;
        *)           client_id="$2" ;;
    esac
fi
if [ -n "$client_id" ]; then
    idx_opt="@clux_frame_idx_${client_id}"
else
    idx_opt="@clux_frame_idx"
fi

# --- One batched read, the shape session-list.sh:49-60 already uses --------
# Do NOT use `#{E:...}` here — it was measured to collapse a literal "##" in
# the cached template back to "#", which is the corruption that killed the
# ticker-daemon approach this design replaced. A plain `#{@name}` lookup
# round-trips a value byte for byte, including a literal TAB and "##"
# (verified).
now=$(date +%s)
opts=$(tmux display-message -p \
  "#{@clux_bar_tpl}${SEP}#{${idx_opt}}${SEP}#{@clux-agent-glyph-busy-frames}${SEP}#{@clux-agent-glyph-busy}" \
  2>/dev/null)
IFS="$SEP" read -r tpl_raw idx_raw frames_raw busy_raw <<EOF
$opts
EOF

# @clux_bar_tpl holds "<epoch><TAB><template>" in ONE option, so a tick can
# never pair a template with a timestamp written by a different render. Split
# on the FIRST tab; a value with no tab (unset, or a stray legacy value) is
# treated as missing entirely.
case "$tpl_raw" in
    *"$TAB"*) tpl_at="${tpl_raw%%"$TAB"*}"; tpl_body="${tpl_raw#*"$TAB"}" ;;
    *)        tpl_at=""; tpl_body="" ;;
esac

# A missing or non-numeric counter is 0 — first tick ever, or a value some
# other process clobbered.
case "$idx_raw" in ''|*[!0-9]*) idx_raw=0 ;; esac
idx_raw=$(( 10#$idx_raw ))   # base ten: a leading zero must not read as octal

# --- Frame list — the second copy of helpers.sh's get_agent_frame() rule ---
# Unset -frames falls back to the RAW @clux-agent-glyph-busy value (not
# through any override), so a user who customised only the single glyph and
# never touched -frames keeps a STATIC glyph — only when BOTH are genuinely
# unset does the shipped four-frame default take over. Only then, if parsing
# still yields zero frames (e.g. an all-whitespace value), fall back to the
# busy glyph (default "*") as a one-frame list. The frame substituted is
# never empty.
if [ -n "$frames_raw" ]; then
    frames_list="$frames_raw"
elif [ -n "$busy_raw" ]; then
    frames_list="$busy_raw"
else
    frames_list='- \ | /'
fi
IFS=' ' read -r -a frames <<< "$frames_list"   # -r: a bare `read -a` eats the backslash a second time
nframes=${#frames[@]}
if [ "$nframes" -eq 0 ]; then
    frames=( "${busy_raw:-*}" )
    nframes=1
fi

# _frame_at <index> — the frame at <index> mod the frame count, "#" doubled
# so it can be substituted into a finished bar string without injecting a
# style (session-list.sh's own esc() does the same for names; this
# substitution happens downstream of that, so a user-supplied frame
# containing "#" would otherwise bypass it).
_frame_at() {
    local i="$1" f
    case "$i" in ''|*[!0-9]*) i=0 ;; esac
    # 10# forces base ten. A digits-only value can still carry a leading zero
    # ("08"), which bash would read as octal and reject with "value too great
    # for base" — an error on a path whose whole job is to never fail.
    i=$(( 10#$i ))
    f="${frames[$(( i % nframes ))]}"
    [ -n "$f" ] || f='*'
    printf '%s' "${f//#/##}"
}

# --- Template freshness (periodic path only) --------------------------------
_tpl_fresh() {
    case "$tpl_at" in ''|*[!0-9]*) return 1 ;; esac
    tpl_at=$(( 10#$tpl_at ))
    [ -n "$tpl_body" ] || return 1
    [ "$(( now - tpl_at ))" -lt "$FULL_EVERY" ]
}

# --- A full render: session-list.sh draws the sentinel in place of the real
# busy glyph, so a busy bar can be re-animated later without a second render.
# Writes BOTH options together; a failing or empty session-list.sh leaves
# both untouched — "session-list.sh empty" is never a real answer, see the
# header comment above.
_full_render() {
    local bar_out
    if bar_out=$(CLUX_AGENT_GLYPH_BUSY="$SENTINEL" "$CURRENT_DIR/session-list.sh") \
       && [ -n "$bar_out" ]; then
        tmux set-option -g @clux_bar_tpl "${now}${TAB}${bar_out}"
        tmux set-option -g @clux_session_bar "${bar_out//$SENTINEL/$1}"
    fi
}

if [ "$mode" = "quiet" ]; then
    # Periodic path: render the frame at the counter's CURRENT value, then
    # advance the counter by exactly one for next time — ALWAYS, before the
    # staleness branch below, so a full render on a periodic tick still
    # advances the animation and frame N is never repeated on the tick that
    # happens to also be a full render. (Rendering current-then-storing-next
    # is what keeps tick 1 drawing frame 0 while the counter option already
    # reads 1 — the on-disk counter is "the frame the NEXT tick will draw",
    # not "the frame just drawn".)
    frame="$(_frame_at "$idx_raw")"
    new_idx=$(( (idx_raw + 1) % nframes ))
    tmux set-option -g "$idx_opt" "$new_idx" 2>/dev/null

    if _tpl_fresh; then
        # Cheap tick: substitute the frame into the cached template with a
        # plain bash string replace. If the template holds no sentinel,
        # nothing is busy — skip the write, the idle bar has not changed.
        case "$tpl_body" in
            *"$SENTINEL"*) tmux set-option -g @clux_session_bar "${tpl_body//$SENTINEL/$frame}" ;;
        esac
    else
        _full_render "$frame"
    fi
else
    # Hook path: use the shared counter's CURRENT value, never advance it —
    # a burst of hooks must not fast-forward the animation. Agent state
    # changes (busy -> needs-you -> finished) arrive here, so they must show
    # at once: always a full render, no staleness check.
    frame="$(_frame_at "$idx_raw")"
    _full_render "$frame"
fi

# show-notification.sh is not part of the throttle above — see the header
# comment. It runs on every path, including a cheap animation tick.
if status_out=$("$CURRENT_DIR/show-notification.sh"); then
    tmux set-option -g @clux_status "$status_out"
fi

# A redraw needs a client, and there is very often no client here.
# `tmux refresh-client -S` exits 1 with "no current client" whenever none is
# attached — the state at config-load time after `tmux new-session -d`, and on
# every session-created[91] hook fired by a script that creates a session
# detached. Both are ordinary. Both used to leave tmux reporting
# "'session-bar-refresh.sh' returned 1" to the next client that attached,
# which is the first thing a user saw on a fresh detached start.
#
# Nothing has actually failed in that case: both options were already written
# above, and there is no client to redraw them on. So the redraw is
# best-effort, and its failure is not this script's failure — hence the
# explicit exit 0 rather than falling off the end on refresh-client's status.
# stderr is dropped for the same reason: tmux surfaces a run-shell command's
# output too, so letting "no current client" through would swap one spurious
# message for another.
if [ "$mode" != "quiet" ]; then
    tmux refresh-client -S 2>/dev/null
fi

exit 0
