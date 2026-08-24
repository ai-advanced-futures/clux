#!/usr/bin/env bash

# agent-bar.sh — the renderer. Pure stdout, read-only: a pure function of the
# state directory plus the @clux-agent-* options. This is the seam a later
# config-updater precompute step can capture into a status option with no
# change to this file.
#
# An optional leading "--frame N" pair (animated busy glyph, 2026-08-23
# design) is shifted off BEFORE anything else, so the two modes below stay
# chosen by argument count alone once the shift is done:
#
#   agent-bar.sh [--frame N] <session-name>
#                                  one column: the coloured glyph for that
#                                  session, or a single space when idle. No
#                                  trailing newline.
#   agent-bar.sh [--frame N]      compact roll-up of the non-idle sessions
#                                  only: "<glyph><session>" pairs separated by
#                                  a single space. Empty when all idle.
#
# --frame N renders frame N of @clux-agent-glyph-busy-frames for the busy
# glyph only; needs-you/finished are unaffected, they never animate. Without
# --frame, output is byte-identical to before this option existed — that is
# what keeps SKILL.md §3.7's standalone-glyph installs looking the same on
# upgrade. This script never reads @clux_frame_idx itself (that counter is
# session-bar-refresh.sh's, advanced once per periodic tick); a caller
# supplies the frame index explicitly, so this renderer's tests stay
# deterministic.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/helpers.sh"

FRAME=""
if [ "${1:-}" = "--frame" ]; then
    FRAME="${2:-0}"
    shift 2 2>/dev/null || shift $#
fi

ROWS=$("$CURRENT_DIR/agent-query.sh" 2>/dev/null)

# Render one state's glyph, coloured. Options are resolved lazily here (only
# when a non-idle state is actually rendered) so the all-idle case costs zero
# option reads.
_render() {
    case "$1" in
        needs-you) printf '#[fg=%s]%s#[default]' "$(get_agent_needs_color)" "$(get_agent_glyph_needs)" ;;
        busy)
            if [ -n "$FRAME" ]; then
                printf '#[fg=%s]%s#[default]' "$(get_agent_busy_color)" "$(get_agent_frame "$FRAME")"
            else
                printf '#[fg=%s]%s#[default]' "$(get_agent_busy_color)" "$(get_agent_glyph_busy)"
            fi
            ;;
        finished)  printf '#[fg=%s]%s#[default]' "$(get_agent_done_color)"  "$(get_agent_glyph_done)" ;;
    esac
}

if [ $# -ge 1 ]; then
    target="$1"
    found=""
    while IFS=$'\t' read -r s st; do
        [ -n "$s" ] || continue
        if [ "$s" = "$target" ]; then
            found="$st"
            break
        fi
    done <<EOF
$ROWS
EOF
    if [ -n "$found" ]; then
        _render "$found"
    else
        printf ' '
    fi
else
    first=1
    while IFS=$'\t' read -r s st; do
        [ -n "$s" ] || continue
        if [ "$first" -eq 0 ]; then
            printf ' '
        fi
        first=0
        _render "$st"
        printf '%s' "$s"
    done <<EOF
$ROWS
EOF
fi

exit 0
