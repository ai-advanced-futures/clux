#!/usr/bin/env bash
# Move the notification queue of a tmux server to its new name.
#
#   rename-notify-file.sh OLD NEW
#
# Each tmux server has its own queue, named for the server
# (notify_file_for_server, path.sh). A script that renames a server calls this
# after the rename, so the notifications that wait keep their server. When the
# new name already has a queue, the old lines go at its end. The move holds
# the locks of the old and the new queue, so a writer that still has the old
# name waits for it, and a remove on the new queue does not lose the lines.
# The lock files of the old name go after: no server reads them any more.

[ $# -eq 2 ] || { echo "usage: rename-notify-file.sh OLD NEW" >&2; exit 2; }

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/helpers.sh"

OLD_FILE=$(resolve_notify_file "$1")
NEW_FILE=$(resolve_notify_file "$2")
[ "$OLD_FILE" = "$NEW_FILE" ] && exit 0

# The lock of the new queue, both kinds, as notification-line.sh takes them:
# a remove on that queue (grep, then mv) must not drop the lines that go to
# its end. A lock directory that stays 5 seconds is the leftover of a killed
# process, so it goes, as in acquire_lock (helpers.sh).
_lock_new() {
    local i=0
    if command -v flock >/dev/null 2>&1; then
        exec 8>"$NEW_FILE.flock" && flock -w 5 8
    fi
    while ! mkdir "$NEW_FILE.lock" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -ge 50 ]; then
            rm -rf "$NEW_FILE.lock"
            mkdir "$NEW_FILE.lock" 2>/dev/null
            return
        fi
        sleep 0.1
    done
}
_unlock_new() {
    rm -rf "$NEW_FILE.lock"
    exec 8>&-
}

NOTIFY_FILE="$OLD_FILE"
recompute_lock_target
acquire_lock
_lock_new
status=0
if [ -s "$OLD_FILE" ]; then
    if [ -e "$NEW_FILE" ]; then
        cat "$OLD_FILE" >> "$NEW_FILE" || status=1
    else
        mv -f "$OLD_FILE" "$NEW_FILE" || status=1
    fi
fi
[ "$status" -eq 0 ] && rm -f "$OLD_FILE" "$OLD_FILE.tmp"
_unlock_new
release_lock
[ "$status" -eq 0 ] && rm -rf "$OLD_FILE.lock" "$OLD_FILE.flock"
exit "$status"
