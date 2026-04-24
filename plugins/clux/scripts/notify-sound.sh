#!/usr/bin/env bash

# Centralized sound playback for clux notifications
# Usage: notify-sound.sh <type>
#   type: stop | notification | prompt
#
# Reads per-notification tmux vars:
#   @claude-notify-<type>-sound      (on/off)
#   @claude-notify-<type>-sound-file (path to sound file)
#
# Falls back to @claude-notify-sound for backward compatibility.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

TYPE="${1:-}"
[ -z "$TYPE" ] && exit 1

# Check if sound is enabled for this notification type
ENABLED=$(get_notification_sound_enabled "$TYPE")
[ "$ENABLED" = "off" ] && exit 0

# Handle custom command (backward compat with @claude-notify-sound "custom cmd")
if [ "$ENABLED" != "on" ]; then
    eval "$ENABLED" &>/dev/null &
    exit 0
fi

# Log helper — only writes when CLUX_DEBUG=1 is set.
# Never surfaces to the tmux status bar (that would flash over real notifications).
_debug_log() {
    [ "${CLUX_DEBUG:-0}" = "1" ] || return 0
    printf '[clux notify-sound %s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" >>/tmp/clux.log 2>/dev/null
}

# Get configured sound file
SOUND_FILE=$(get_notification_sound_file "$TYPE")

# Silent no-op if no file is configured or the file is missing.
if [ -z "$SOUND_FILE" ] || [ ! -f "$SOUND_FILE" ]; then
    _debug_log "sound file not found: '$SOUND_FILE' (type=$TYPE)"
    exit 0
fi

# Pick a player for this OS. Silent no-op if none is installed.
PLAYER=$(detect_sound_player)
if [ -z "$PLAYER" ]; then
    _debug_log "no audio player detected on this system (type=$TYPE)"
    exit 0
fi

case "$PLAYER" in
    ffplay) "$PLAYER" -nodisp -autoexit "$SOUND_FILE" &>/dev/null & ;;
    *)      "$PLAYER" "$SOUND_FILE" &>/dev/null & ;;
esac

exit 0
