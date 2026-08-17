#!/usr/bin/env bash
# Session picker with pane preview (bound to prefix + g).
# Port of fzf-session-switch.sh, generalized: fzf is OPTIONAL here, not a
# dependency. @clux-picker names the preferred picker, but the binary is
# re-checked at run time regardless of the option, because it is a
# per-machine fact that can change after setup:
#
#   @clux-picker = choose-tree   -> tmux choose-tree -Zs, always
#   @clux-picker = fzf (default) -> fzf-tmux -p when present
#                                    else plain fzf inside `tmux display-popup -E`
#                                    else choose-tree -Zs + one display-message
#
# This always leaves the user a working `g` key, which a blank popup or a
# silent no-op does not.
#
# Lists sessions in session-order.sh's order (never tmux's own list-sessions
# order), excluding the current session, and keeps the original's
# "No other sessions" message.
#
# Emits <raw name>\t<display line> per session, runs fzf with
# --delimiter=\t --with-nth=2.., and extracts the choice with `cut -f1`. This
# replaces the original's `sed 's/:.*//'`, which silently truncated any
# session name containing ": " -- tmux forbids `.` and `:` in a session name
# only for *target* syntax, not in the name itself, so that extraction was a
# live bug. A TAB cannot occur in a session name, so it is a lossless key.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/helpers.sh"

run_choose_tree() {
    tmux choose-tree -Zs
}

have_fzf_tmux() { command -v fzf-tmux >/dev/null 2>&1; }
have_fzf()      { command -v fzf      >/dev/null 2>&1; }

current_session=$(tmux display-message -p '#S')
picker=$(get_tmux_option "@clux-picker" "fzf")

if [ "$picker" != "fzf" ]; then
    run_choose_tree
    exit 0
fi

if ! have_fzf_tmux && ! have_fzf; then
    tmux display-message "clux: fzf not found, using choose-tree"
    run_choose_tree
    exit 0
fi

order=$("$CURRENT_DIR/session-order.sh")
meta=$(tmux list-sessions -F $'#{session_name}\t#{session_windows}\t#{session_attached}' 2>/dev/null)

workdir=$(mktemp -d "${TMPDIR:-/tmp}/clux-picker.XXXXXX") || exit 1
trap 'rm -rf "$workdir"' EXIT
tmpfile="$workdir/sessions"
outfile="$workdir/selected"
: > "$tmpfile"

while IFS= read -r name; do
    [ -z "$name" ] && continue
    [ "$name" = "$current_session" ] && continue
    row=$(printf '%s\n' "$meta" | awk -F'\t' -v n="$name" '$1 == n { print; exit }')
    [ -z "$row" ] && continue
    windows=$(printf '%s' "$row" | cut -f2)
    attached=$(printf '%s' "$row" | cut -f3)
    suffix=""
    [ "$attached" = "1" ] && suffix=" (attached)"
    printf '%s\t%s: %s windows%s\n' "$name" "$name" "$windows" "$suffix" >> "$tmpfile"
done <<EOF
$order
EOF

if [ ! -s "$tmpfile" ]; then
    tmux display-message "No other sessions"
    exit 0
fi

fzf_opts=(
    --delimiter=$'\t' --with-nth=2..
    --prompt="Switch to> "
    --header="Sessions (current: ${current_session})"
    --preview="tmux capture-pane -t {1} -p -e 2>/dev/null || echo 'No preview'"
    --preview-window=right:60%
)

if have_fzf_tmux; then
    selected=$(fzf-tmux -p "${fzf_opts[@]}" < "$tmpfile")
else
    # Only plain fzf is on PATH: run it inside a popup so it still gets a
    # reasonable amount of screen. The arguments reach it through a generated
    # wrapper script (via printf %q), not interpolated into a literal string
    # handed to `display-popup -E` -- so a session name holding a quote or a
    # `$` cannot break the popup's command line.
    popup_script="$workdir/run-fzf.sh"
    {
        printf '#!/usr/bin/env bash\nfzf'
        for opt in "${fzf_opts[@]}"; do
            printf ' %q' "$opt"
        done
        printf ' < %q > %q\n' "$tmpfile" "$outfile"
    } > "$popup_script"
    chmod +x "$popup_script"
    tmux display-popup -E "$popup_script"
    selected=$(cat "$outfile" 2>/dev/null)
fi

[ -z "$selected" ] && exit 0

target=$(printf '%s\n' "$selected" | cut -f1)
[ -n "$target" ] && tmux switch-client -t "$target"
