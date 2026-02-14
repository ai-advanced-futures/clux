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

# Get configured sound file
SOUND_FILE=$(get_notification_sound_file "$TYPE")

# Verify sound file exists
if [ ! -f "$SOUND_FILE" ]; then
    tmux display-message "clux: sound file not found: $SOUND_FILE" 2>/dev/null
    exit 1
fi

# Play sound (macOS)
if [[ "$OSTYPE" == darwin* ]]; then
    afplay "$SOUND_FILE" &>/dev/null &
fi

exit 0
