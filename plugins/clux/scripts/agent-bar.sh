#!/usr/bin/env bash

# agent-bar.sh — the renderer. Pure stdout, read-only: a pure function of the
# state directory plus the @clux-agent-* options. This is the seam a later
# config-updater precompute step can capture into a status option with no
# change to this file.
#
# Two modes, chosen by argument count alone (an explicitly passed empty
# argument selects one-column mode and prints a space — that is what a bar
# passing #{session_name} needs):
#
#   agent-bar.sh <session-name>   one column: the coloured glyph for that
#                                  session, or a single space when idle. No
#                                  trailing newline.
#   agent-bar.sh                  compact roll-up of the non-idle sessions
#                                  only: "<glyph><session>" pairs separated by
#                                  a single space. Empty when all idle.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/helpers.sh"

ROWS=$("$CURRENT_DIR/agent-query.sh" 2>/dev/null)

# Render one state's glyph, coloured. Options are resolved lazily here (only
# when a non-idle state is actually rendered) so the all-idle case costs zero
# option reads.
_render() {
    case "$1" in
        needs-you) printf '#[fg=%s]%s#[default]' "$(get_agent_needs_color)" "$(get_agent_glyph_needs)" ;;
        busy)      printf '#[fg=%s]%s#[default]' "$(get_agent_busy_color)"  "$(get_agent_glyph_busy)" ;;
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
