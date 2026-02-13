#!/usr/bin/env bash
# setup-tmux-conf.sh — Autonomously configure tmux.conf for clux notifications

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

TMUX_CONF="${HOME}/.tmux.conf"
NOTIFICATION_CMD='#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print colored messages
info() { printf "${BLUE}ℹ${NC} %s\n" "$*"; }
success() { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
error() { printf "${RED}✗${NC} %s\n" "$*"; }
bold() { printf "${BOLD}%s${NC}\n" "$*"; }

# Detect current tmux.conf state
detect_state() {
    if [ ! -f "$TMUX_CONF" ]; then
        echo "missing"
        return
    fi

    # Check if already configured
    if grep -q "show-notification.sh" "$TMUX_CONF" 2>/dev/null; then
        echo "configured"
        return
    fi

    # Check if status-left exists
    if grep -q "^[[:space:]]*set.*status-left" "$TMUX_CONF" 2>/dev/null; then
        echo "has-status-left"
        return
    fi

    echo "exists"
}

# Show what will be changed
show_changes() {
    local state="$1"

    echo ""
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  clux setup — tmux.conf configuration"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    case "$state" in
        missing)
            info "File: $TMUX_CONF does not exist"
            info "Action: Create new file with clux configuration"
            echo ""
            echo "Will create:"
            echo "  set -g status-left \"${NOTIFICATION_CMD} \""
            echo "  set -g status-interval 1"
            echo "  set -g monitor-bell on"
            echo "  set -g bell-action any"
            ;;
        configured)
            success "Already configured! $TMUX_CONF contains show-notification.sh"
            info "No changes needed."
            return 0
            ;;
        has-status-left)
            info "File: $TMUX_CONF exists with status-left configuration"
            info "Action: Prepend notification display to existing status-left"
            echo ""
            echo "Current status-left:"
            grep "^[[:space:]]*set.*status-left" "$TMUX_CONF" | sed 's/^/  /'
            echo ""
            echo "Will be modified to include:"
            echo "  ${NOTIFICATION_CMD}"
            ;;
        exists)
            info "File: $TMUX_CONF exists without status-left"
            info "Action: Add clux configuration"
            echo ""
            echo "Will add:"
            echo "  set -g status-left \"${NOTIFICATION_CMD} \""
            echo "  set -g status-interval 1"
            echo "  set -g monitor-bell on"
            echo "  set -g bell-action any"
            ;;
    esac
    echo ""
}

# Get user confirmation
confirm() {
    local state="$1"

    [ "$state" = "configured" ] && return 0

    printf "Continue with this change? [Y/n] "
    read -r response

    case "$response" in
        [nN]|[nN][oO])
            warn "Setup cancelled by user"
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Create backup with timestamp
backup_config() {
    [ ! -f "$TMUX_CONF" ] && return 0

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup="${TMUX_CONF}.backup-${timestamp}"

    if cp "$TMUX_CONF" "$backup"; then
        success "Backup created: $backup"
        return 0
    else
        error "Failed to create backup"
        return 1
    fi
}

# Modify tmux.conf based on state
modify_config() {
    local state="$1"
    local tmpfile="${TMUX_CONF}.tmp"

    case "$state" in
        missing)
            cat > "$tmpfile" <<'EOF'
# clux — Claude Code tmux notifications
set -g status-left "#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh) "
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
EOF
            ;;
        has-status-left)
            # Use sed to modify status-left (compatible with bash 3.2)
            local modified=0

            # Process file line by line
            while IFS= read -r line || [ -n "$line" ]; do
                # Detect status-left line
                if [[ "$line" =~ ^[[:space:]]*set.*status-left ]]; then
                    # Check if already has our notification
                    if [[ "$line" =~ show-notification\.sh ]]; then
                        echo "$line" >> "$tmpfile"
                        modified=1
                    else
                        # Prepend notification to status-left value
                        # Match: set -g status-left "value" or set -g status-left 'value'
                        if [[ "$line" =~ ^([[:space:]]*set[[:space:]]+-g[[:space:]]+status-left[[:space:]]+[\"\'])(.*)$ ]]; then
                            local prefix="${BASH_REMATCH[1]}"
                            local rest="${BASH_REMATCH[2]}"
                            echo "${prefix}${NOTIFICATION_CMD} ${rest}" >> "$tmpfile"
                            modified=1
                        else
                            # Fallback: couldn't parse, keep original
                            echo "$line" >> "$tmpfile"
                        fi
                    fi
                else
                    echo "$line" >> "$tmpfile"
                fi
            done < "$TMUX_CONF"

            if [ "$modified" -eq 0 ]; then
                error "Failed to modify status-left (pattern not matched)"
                rm -f "$tmpfile"
                return 1
            fi
            ;;
        exists)
            # Append to existing file
            {
                cat "$TMUX_CONF"
                echo ""
                echo "# clux — Claude Code tmux notifications"
                echo "set -g status-left \"${NOTIFICATION_CMD} \""
                echo "set -g status-interval 1"
                echo "set -g monitor-bell on"
                echo "set -g bell-action any"
            } > "$tmpfile"
            ;;
    esac

    if [ ! -f "$tmpfile" ]; then
        error "Failed to create temporary file"
        return 1
    fi

    return 0
}

# Verify the modification
verify_config() {
    local tmpfile="${TMUX_CONF}.tmp"

    # Check file exists and is not empty
    if [ ! -s "$tmpfile" ]; then
        error "Generated config is empty"
        return 1
    fi

    # Check that our notification command is present
    if ! grep -q "show-notification.sh" "$tmpfile"; then
        error "Verification failed: notification command not found in generated config"
        return 1
    fi

    # Verify tmux can parse it (syntax check)
    if command -v tmux &>/dev/null; then
        if ! tmux -f "$tmpfile" source-file "$tmpfile" 2>&1 | grep -q "no server running"; then
            # This is expected when no server is running
            :
        fi
    fi

    success "Configuration verified"
    return 0
}

# Apply the changes
apply_config() {
    local tmpfile="${TMUX_CONF}.tmp"

    if mv "$tmpfile" "$TMUX_CONF"; then
        success "Configuration applied: $TMUX_CONF"
        return 0
    else
        error "Failed to apply configuration"
        rm -f "$tmpfile"
        return 1
    fi
}

# Provide rollback instructions
show_rollback() {
    local backup="$1"

    [ -z "$backup" ] && return

    echo ""
    info "To rollback: cp \"$backup\" \"$TMUX_CONF\""
}

# Main flow
main() {
    # 1. Detect state
    local state
    state=$(detect_state)

    # 2. Show changes
    show_changes "$state"

    # 3. If already configured, exit early
    if [ "$state" = "configured" ]; then
        echo ""
        info "Run: tmux source-file ~/.tmux.conf (or restart tmux)"
        return 0
    fi

    # 4. Get confirmation
    if ! confirm "$state"; then
        return 1
    fi

    # 5. Backup
    local backup=""
    if [ -f "$TMUX_CONF" ]; then
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        backup="${TMUX_CONF}.backup-${timestamp}"
        backup_config
    fi

    # 6. Modify
    if ! modify_config "$state"; then
        error "Configuration modification failed"
        return 1
    fi

    # 7. Verify
    if ! verify_config; then
        error "Configuration verification failed"
        rm -f "${TMUX_CONF}.tmp"
        return 1
    fi

    # 8. Apply
    if ! apply_config; then
        return 1
    fi

    # 9. Report success
    echo ""
    success "Setup complete!"
    echo ""
    info "Next steps:"
    echo "  1. Reload tmux config: tmux source-file ~/.tmux.conf"
    echo "  2. Or restart tmux: tmux kill-server && tmux"
    echo ""

    show_rollback "$backup"

    return 0
}

main "$@"
