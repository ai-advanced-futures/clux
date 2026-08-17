#!/usr/bin/env bash
# Switch tmux sessions following the custom status-bar order.
# Usage: switch-session.sh [next|prev]   (bound to prefix + N / P)
#
# Traverses the order resolved by session-order.sh (the @clux-session-order
# option), so prefix + N / P move through sessions exactly as they appear in
# the bar and as prefix + { / } reorders them. Wraps around at the edges.
#
# Uses a plain indexed array, not an associative one: macOS ships bash 3.2,
# which has never had associative arrays but has always had indexed ones.

direction="${1:-next}"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

current=$(tmux display-message -p '#S')

names=()
while IFS= read -r line; do
    [[ -n "$line" ]] && names+=("$line")
done < <("$CURRENT_DIR/session-order.sh")

count=${#names[@]}
[[ $count -le 1 ]] && exit 0

for i in "${!names[@]}"; do
    if [[ "${names[$i]}" == "$current" ]]; then
        if [[ "$direction" == "next" ]]; then
            target=${names[$(( (i + 1) % count ))]}
        else
            target=${names[$(( (i - 1 + count) % count ))]}
        fi
        tmux switch-client -t "$target"
        exit 0
    fi
done
