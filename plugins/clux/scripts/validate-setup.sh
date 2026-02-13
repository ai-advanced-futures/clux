#!/usr/bin/env bash

# Validate clux integration — 10 checks

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

PASS=0
FAIL=0

check() {
    local name="$1" result="$2"
    if [ "$result" -eq 0 ]; then
        printf '  ✓ %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  ✗ %s\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

echo "clux validation"
echo "================"

# 1. tmux running
tmux info &>/dev/null
check "tmux is running" $?

# 2. keybindings registered
tmux list-keys 2>/dev/null | grep -q "claude" || tmux list-keys 2>/dev/null | grep -q "dismiss-notification\|jump-to-notification\|notification-picker"
check "keybindings registered" $?

# 3. status-left contains show-notification
tmux show-option -gv status-left 2>/dev/null | grep -q "show-notification"
check "status-left configured" $?

# 4. notification dir writable
NOTIFY_DIR=$(dirname "$NOTIFY_FILE")
[ -d "$NOTIFY_DIR" ] && [ -w "$NOTIFY_DIR" ]
check "notification dir writable" $?

# 5. Claude hooks configured (plugin hooks.json, ~/.claude/hooks.json, or settings.json)
PLUGIN_HOOKS="$CURRENT_DIR/../hooks/hooks.json"
HOOKS_FILE="$HOME/.claude/hooks.json"
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ -f "$PLUGIN_HOOKS" ] && grep -q "notify-tmux" "$PLUGIN_HOOKS"; then
    check "Claude hooks configured (plugin)" 0
elif [ -f "$HOOKS_FILE" ] && grep -q "notify-tmux" "$HOOKS_FILE"; then
    check "Claude hooks configured (hooks.json)" 0
elif [ -f "$SETTINGS_FILE" ] && grep -q "notify-tmux" "$SETTINGS_FILE"; then
    check "Claude hooks configured (settings.json)" 0
else
    check "Claude hooks configured" 1
fi

# 6. hook script executable
[ -x "$CURRENT_DIR/../hooks/notify-tmux.sh" ]
check "hook script executable" $?

# 7. jq available (required for smart window naming)
command -v jq &>/dev/null
check "jq installed (required for smart titles)" $?

# 8. flock available
if command -v flock &>/dev/null; then
    check "flock available (fast locking)" 0
else
    printf '  ~ flock not available (using mkdir fallback)\n'
    PASS=$((PASS + 1))
fi

# 9. bell/visual-bell
BELL=$(tmux show-option -gv visual-bell 2>/dev/null)
[ "$BELL" != "off" ] 2>/dev/null
check "bell not disabled" $?

# 10. status-interval reasonable
INTERVAL=$(tmux show-option -gv status-interval 2>/dev/null)
[ "${INTERVAL:-15}" -le 5 ]
check "status-interval ≤ 5s" $?

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
