#!/usr/bin/env bash

# Dismiss the top notification without jumping to it

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

[ -f "$NOTIFY_FILE" ] || exit 0

acquire_lock

FIRST=$(head -1 "$NOTIFY_FILE")
if [ -z "$FIRST" ]; then
    release_lock
    exit 0
fi

REMAINING=$(tail -n +2 "$NOTIFY_FILE")
if [ -n "$REMAINING" ]; then
    echo "$REMAINING" > "$NOTIFY_FILE"
else
    rm -f "$NOTIFY_FILE"
fi

release_lock
exit 0
