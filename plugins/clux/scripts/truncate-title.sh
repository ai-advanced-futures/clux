#!/usr/bin/env bash
# truncate-title.sh MAX_LEN TITLE...
# Word-aware truncation: keep as many whole words as fit in MAX_LEN chars.
# Falls back to hard truncation if the first word alone exceeds MAX_LEN.

max="${1:-25}"
shift || true
title="$*"

[ -z "$title" ] && exit 0

if [ "${#title}" -le "$max" ]; then
    printf '%s' "$title"
    exit 0
fi

result=""
for word in $title; do
    if [ -z "$result" ]; then
        candidate="$word"
    else
        candidate="$result $word"
    fi
    if [ "${#candidate}" -le "$max" ]; then
        result="$candidate"
    else
        break
    fi
done

if [ -z "$result" ]; then
    result="${title:0:$max}"
fi

printf '%s' "$result"
