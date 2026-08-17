#!/usr/bin/env bash
# Render the session list for the tmux status bar in the user-defined order
# (see session-order.sh). Backs #{@clux_session_bar} so the order can be
# rearranged live with prefix + { / } (session-reorder.sh).
#
# Output shape, themed entirely through @clux-bar-* / @clux-agent-* options
# (see the batched read below), no hardcoded colour or glyph:
#   attached:  <agent> bg name  <open><windows><close> <sep>
#   detached:  <agent> name <sep>
# Active window uses @clux-bar-window-active-style, inactive uses
# @clux-bar-window-inactive-style. <agent> is one always-present column
# holding the Claude Code agent state for that session, or a space when no
# agent runs there. See glyph() below.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# path.sh is deliberately NOT sourced. This is the hot path — it runs on every
# window switch — and it needs nothing from path.sh: every option it reads
# comes back on the single batched `tmux display-message` call below, which
# costs one fork instead of one per option.

TAB=$'\t'

# Truncation happens in the tmux format (#{=N:...}), not in awk. awk's substr()
# is byte-oriented under mawk (the default awk on Debian/Ubuntu) but
# character-oriented under a UTF-8-aware awk such as the BWK awk macOS ships, so
# the same script cut names at different points per platform — and on mawk it
# could slice a multibyte character in half and emit invalid UTF-8. #{=N:...}
# is character-correct and identical everywhere. N comes from
# @clux-bar-name-length (guarded below), so awk still never calls substr().
#
# Session names are carried twice: field 1 is the raw name (the join key against
# session-order.sh, which knows only full names) and field 3 is the display form.
order=$("$CURRENT_DIR/session-order.sh" | tr '\n' ',')

# Bar theming plus the (pre-existing) agent glyph/colour options, all
# @clux-*. This is the hot path — session-list.sh runs on every window
# switch — so all sixteen fields come back on ONE `tmux display-message -p`
# call instead of sixteen get_tmux_option forks. Reusing the exact
# @clux-agent-glyph-*/@clux-agent-*-color names agent-bar.sh already reads
# keeps the two renderers from ever disagreeing about a glyph.
#
# \037-joined, matching the transport the agents block below uses, so a
# value that turned out to be multi-line could never repeat the
# literal-newline-in-`awk -v` fault: BWK awk (macOS) rejects a newline
# inside a -v assignment and exits 2 printing nothing, which emptied the
# whole status bar on 2026-08-16 — not just the field that held it.
SEP=$'\037'
opts=$(tmux display-message -p \
  "#{@clux-bar-name-length}${SEP}#{@clux-bar-name-attached-style}${SEP}#{@clux-bar-name-detached-style}${SEP}#{@clux-bar-window-active-style}${SEP}#{@clux-bar-window-inactive-style}${SEP}#{@clux-bar-bracket-style}${SEP}#{@clux-bar-separator-style}${SEP}#{@clux-bar-window-open}${SEP}#{@clux-bar-window-close}${SEP}#{@clux-bar-separator}${SEP}#{@clux-agent-glyph-busy}${SEP}#{@clux-agent-glyph-needs}${SEP}#{@clux-agent-glyph-done}${SEP}#{@clux-agent-busy-color}${SEP}#{@clux-agent-needs-color}${SEP}#{@clux-agent-done-color}" \
  2>/dev/null)
IFS="$SEP" read -r \
  name_length name_attached_style name_detached_style \
  window_active_style window_inactive_style bracket_style separator_style \
  window_open window_close separator \
  glyph_busy glyph_needs glyph_done \
  busy_color needs_color done_color \
  <<EOF
$opts
EOF

# A non-numeric N would corrupt the whole tmux format string below, so guard
# it in bash — this is field 1 of the batched read above.
case "$name_length" in
  ''|*[!0-9]*) name_length=24 ;;
esac

# Every other field reproduces get_tmux_option()'s empty-collapses-to-default
# rule by hand, because the hot path above cannot afford a per-option
# get_tmux_option (and therefore tmux IPC) call.
name_attached_style="${name_attached_style:-bg=magenta,fg=black,bold}"
name_detached_style="${name_detached_style:-fg=magenta}"
window_active_style="${window_active_style:-bg=blue,fg=white,bold}"
window_inactive_style="${window_inactive_style:-bg=brightblack,fg=white}"
bracket_style="${bracket_style:-fg=magenta}"
separator_style="${separator_style:-fg=brightblack}"
window_open="${window_open:-❰}"
window_close="${window_close:-❱}"
separator="${separator:-│}"
glyph_busy="${glyph_busy:-*}"
glyph_needs="${glyph_needs:-!}"
glyph_done="${glyph_done:-v}"
busy_color="${busy_color:-cyan}"
needs_color="${needs_color:-yellow}"
done_color="${done_color:-green}"

sess=$(tmux list-sessions -F "#{session_name}${TAB}#{session_attached}${TAB}#{=${name_length}:session_name}")
wins=$(tmux list-windows -a -F "#{session_name}${TAB}#{window_active}${TAB}#{window_index}${TAB}#{=${name_length}:window_name}" \
  | sort -t"$TAB" -k1,1 -k3,3n)

# Claude Code agent state, one "session<TAB>state" line per session that has a
# live agent (clux). ONE call renders the whole bar: agent-query.sh already
# rolls every pane up to its session, so asking per session would cost a fork
# per session for the same answer. Absent, unreadable or slow, the bar renders
# exactly as it did before — the glyph column is the only thing that goes away.
#
# The rows travel to awk on \037 (unit separator), not on newlines. awk -v
# rejects a literal newline in a value ("awk: newline in string ... at source
# line 1" on the BWK awk macOS ships) and exits 2, printing nothing — which
# empties the whole bar, not just the glyph column. \037 cannot occur in a tmux
# session name or in a clux state word, so the swap is lossless.
#
# Resolved next to this script, never through a literal ~/.config/clux path:
# clux runs from the plugin tree as well as from the deploy directory, and
# render-clux-conf.sh --scripts-dir points the whole install somewhere else on
# purpose. A hardcoded deploy path silently blanks the glyph column in every
# one of those cases, because a missing agent-query.sh is indistinguishable
# here from "no agent is running". This matches agent-bar.sh.
agents=$("$CURRENT_DIR/agent-query.sh" 2>/dev/null) || agents=""
agents=$(printf '%s' "$agents" | tr '\n' '\037')

awk -v order="$order" -v agents="$agents" \
    -v name_attached_style="$name_attached_style" \
    -v name_detached_style="$name_detached_style" \
    -v window_active_style="$window_active_style" \
    -v window_inactive_style="$window_inactive_style" \
    -v bracket_style="$bracket_style" \
    -v separator_style="$separator_style" \
    -v window_open="$window_open" \
    -v window_close="$window_close" \
    -v separator="$separator" \
    -v glyph_busy="$glyph_busy" \
    -v glyph_needs="$glyph_needs" \
    -v glyph_done="$glyph_done" \
    -v busy_color="$busy_color" \
    -v needs_color="$needs_color" \
    -v done_color="$done_color" \
    -F '\t' '
  # @clux_session_bar is rendered through #{@clux_session_bar}, and the status
  # line interprets #[...] sequences — that is how the styling below works. So
  # a window or session name containing "#" would inject styling into the bar
  # or swallow the following characters. "##" is tmux notation for a literal
  # "#". Applied after tmux has truncated, so the visible width stays exact.
  function esc(s) { gsub(/#/, "##", s); return s }

  # One reserved column per session, so a name never moves sideways when its
  # agent changes state.
  function glyph(s,   st) {
    st = state[s]
    if (st == "needs-you") return "#[fg=" needs_color "]" glyph_needs "#[default]"
    if (st == "busy")      return "#[fg=" busy_color  "]" glyph_busy  "#[default]"
    if (st == "finished")  return "#[fg=" done_color  "]" glyph_done  "#[default]"
    return " "
  }

  # agent-query.sh output, parsed once. It is passed as a variable rather than a
  # third input file because the two files below are told apart by NR==FNR, and
  # that test does not extend to a third. Rows arrive \037-separated; see the
  # tr above for why they cannot arrive newline-separated.
  BEGIN {
    na = split(agents, rows, "\037")
    for (ai = 1; ai <= na; ai++) {
      if (split(rows[ai], af, "\t") == 2) state[af[1]] = af[2]
    }
  }

  # First file: session -> attached client count, and display name.
  NR==FNR { attached[$1]=$2; disp[$1]=$3; next }

  # Second file: accumulate per-session window segments (already index-sorted).
  {
    if ($2 == 1)
      wins[$1]=wins[$1] " #[" window_active_style "]" esc($4) "#[default]"
    else
      wins[$1]=wins[$1] " #[" window_inactive_style "]" esc($4) "#[default]"
  }

  END {
    n=split(order, ord, ",")
    out=""
    for (i=1; i<=n; i++) {
      s=ord[i]; if (s == "") continue
      # disp[] is absent only if the session vanished between the two tmux
      # calls; fall back to the raw name rather than rendering an empty slot.
      name=esc((s in disp) ? disp[s] : s)
      if (attached[s] + 0 > 0)
        out=out glyph(s) "#[" name_attached_style "] " name " #[default] #[" bracket_style "]" window_open "#[default]" wins[s] " #[" bracket_style "]" window_close "#[default] #[" separator_style "]" separator "#[default] "
      else
        out=out glyph(s) "#[" name_detached_style "] " name " #[default] #[" separator_style "]" separator "#[default] "
    }
    printf "%s", out
  }
' <(printf '%s\n' "$sess") <(printf '%s\n' "$wins")
