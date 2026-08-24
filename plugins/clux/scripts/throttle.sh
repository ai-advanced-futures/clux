#!/usr/bin/env bash
set -u

# throttle.sh <seconds> <command> [args...]
#
# Memoizes the stdout of any command, keyed on its full argument list, so a
# `#()` job wired into tmux's status line is not re-run on every redraw.
# tmux re-runs EVERY `#()` job on the status line on every redraw — there is
# no per-segment refresh rate, only caching — so a fast status-interval makes
# the *user's* jobs pay too, exactly like clux's own bar. This script gives
# a user's job the same treatment clux's own bar gets for itself:
#
#   #(~/.config/clux/scripts/throttle.sh 10 ~/.config/tmux/scripts/git.sh "#{pane_current_path}")
#
# Cache layout: ${XDG_CACHE_HOME:-$HOME/.cache}/clux/throttle/<key>, one file
# per distinct argv — <seconds> included, so changing the interval starts a
# fresh entry. Line 1 of the file is the epoch it was last (re)stamped;
# everything after is the command's stdout, verbatim (no trailing newline
# stripped — a command substitution would do that, so the body is always
# read and written through file redirection, never through `$( )`).
#
# A command that fails keeps the previous cache's output but still re-stamps
# the epoch. That is deliberate: a command that fails every time would
# otherwise never be "younger than N seconds", so it would re-run on every
# redraw — a stampede exactly when the command is slow and failing, which is
# what throttling exists to stop. Blanking the segment on a transient
# failure is the other half of the same rule.
#
# No `stat`, no `tmux`, nothing sourced: this is a status-bar hot path, and
# the whole point of the cache hit is to cost one bash start (~5 ms).

usage() {
    echo "usage: throttle.sh <seconds> <command> [args...]" >&2
}

# Need at least <seconds> and one command word.
if [ $# -lt 2 ]; then
    usage
    exit 1
fi

seconds="$1"
case "$seconds" in
    ''|*[!0-9]*)
        usage
        exit 1
        ;;
esac

# Key covers the full argv, <seconds> included — computed before the shift
# below, while "$@" still holds it. A job that takes "#{pane_current_path}"
# as an argument then caches one entry per path, not one entry total.
key=$(printf '%s\n' "$@" | cksum | awk '{print $1 "-" $2}')
shift

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/clux/throttle"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 1
cache_file="$CACHE_DIR/$key"

now=$(date +%s)

# --- hit path -----------------------------------------------------------
if [ -f "$cache_file" ]; then
    cached_at=""
    IFS= read -r cached_at < "$cache_file"
    case "$cached_at" in
        ''|*[!0-9]*) cached_at="" ;;  # garbled or foreign file — treat as a miss
    esac
    if [ -n "$cached_at" ] && [ $(( now - cached_at )) -lt "$seconds" ]; then
        # Straight to stdout, never through a variable: a variable would
        # strip a trailing newline and change what tmux draws.
        tail -n +2 "$cache_file"
        exit 0
    fi
fi

# --- miss path ------------------------------------------------------------
# Sweep entries older than a day before adding a new one. The cache key is
# the full argv, so a job taking a changing argument (e.g.
# "#{pane_current_path}") writes one file per value ever seen; without a
# sweep the directory grows forever. The sweep belongs on the miss path
# only — the hit path above is the ~5 ms budget.
for f in "$CACHE_DIR"/*; do
    [ -e "$f" ] || continue    # no matches — the glob was left unexpanded
    [ -f "$f" ] || continue
    first_line=""
    IFS= read -r first_line < "$f" 2>/dev/null
    case "$first_line" in
        ''|*[!0-9]*) continue ;;   # not this script's file — leave it alone
    esac
    if [ $(( now - first_line )) -gt 86400 ]; then
        rm -f "$f"
    fi
done

# The command's stdout goes into a temp file in $CACHE_DIR (never /tmp), so
# the final `mv` below is a rename inside one filesystem, not a cross-device
# copy that could be interrupted mid-write.
out_tmp=$(mktemp "$CACHE_DIR/.tmp.XXXXXX") || exit 1
"$@" >"$out_tmp" 2>/dev/null
status=$?

if [ "$status" -ne 0 ]; then
    # Failure: keep the previous body (empty if there was none) and let
    # only the epoch move forward — see the header comment for why.
    if [ -f "$cache_file" ]; then
        tail -n +2 "$cache_file" > "$out_tmp"
    else
        : > "$out_tmp"
    fi
fi

epoch=$(date +%s)
final_tmp=$(mktemp "$CACHE_DIR/.tmp.XXXXXX") || { rm -f "$out_tmp"; exit 1; }
{
    printf '%s\n' "$epoch"
    cat "$out_tmp"
} > "$final_tmp"
rm -f "$out_tmp"
# Single atomic rename: a client reading $cache_file mid-write never sees a
# torn file — it sees either the old one or the fully-written new one.
mv -f "$final_tmp" "$cache_file"

tail -n +2 "$cache_file"
