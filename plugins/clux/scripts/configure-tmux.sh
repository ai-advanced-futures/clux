#!/usr/bin/env bash
# configure-tmux.sh — Autonomously detect, back up, and modify tmux.conf
# for clux notification integration.
#
# Exit codes: 0 = success (or already configured), 1 = cancel/error

set -euo pipefail

# --- Resolve paths ---
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$CURRENT_DIR/.." && pwd)"
source "$CURRENT_DIR/helpers.sh"

DEPLOY_DIR="$HOME/.config/clux/scripts"
SNIPPET_PATH="$DEPLOY_DIR/show-notification.sh"
BACKUP_DIR="$HOME/.config/clux/backups"
DRY_RUN=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${BLUE}ℹ${NC} %s\n" "$*"; }
success() { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
error()   { printf "${RED}✗${NC} %s\n" "$*"; }
bold()    { printf "${BOLD}%s${NC}\n" "$*"; }

# --- Parse flags ---
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
    esac
done

# --- Functions ---

deploy_scripts() {
    mkdir -p "$DEPLOY_DIR"
    local scripts=(
        helpers.sh
        show-notification.sh
        jump-to-notification.sh
        dismiss-notification.sh
        notification-picker.sh
    )
    for script in "${scripts[@]}"; do
        cp "$PLUGIN_ROOT/scripts/$script" "$DEPLOY_DIR/$script"
        chmod +x "$DEPLOY_DIR/$script"
    done
    success "Scripts deployed to $DEPLOY_DIR"
}

find_tmux_conf() {
    for candidate in \
        "$HOME/.tmux.conf" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    # Default to most common location
    echo "$HOME/.tmux.conf"
}

is_already_configured() {
    local conf="$1"
    [ -f "$conf" ] && grep -qF "show-notification.sh" "$conf" 2>/dev/null
}

has_status_left() {
    local conf="$1"
    grep -q '^[[:space:]]*set\(-option\)\?[[:space:]].*status-left' "$conf" 2>/dev/null
}

create_backup() {
    local conf="$1"
    [ ! -f "$conf" ] && return 0

    mkdir -p "$BACKUP_DIR"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup="$BACKUP_DIR/tmux.conf.$timestamp"

    if cp "$conf" "$backup"; then
        success "Backup saved to: $backup" >&2
        echo "$backup"
    else
        error "Failed to create backup"
        return 1
    fi

    # Keep only the 5 most recent backups
    ls -1t "$BACKUP_DIR"/tmux.conf.* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
}

check_single_quotes() {
    local conf="$1"
    local line
    line=$(grep '^[[:space:]]*set\(-option\)\?[[:space:]].*status-left' "$conf" | tail -1)
    if echo "$line" | grep -q "status-left[[:space:]]*'"; then
        return 0  # has single quotes
    fi
    return 1
}

portable_sed_inplace() {
    local expr="$1"
    local file="$2"
    if [[ "$OSTYPE" == darwin* ]]; then
        sed -i '' "$expr" "$file"
    else
        sed -i "$expr" "$file"
    fi
}

inject_snippet() {
    local conf="$1"
    local state="$2"
    local notification=" #($SNIPPET_PATH)"

    case "$state" in
        no-file)
            # Case A: No tmux.conf — create new file
            cat > "$conf" <<EOF
# --- clux: Claude Code notifications (added by /clux:setup) ---
set -g status-left "#S${notification} "
set -g status-interval 1
bind-key ${NOTIFY_JUMP_KEY:-m} run-shell "$DEPLOY_DIR/jump-to-notification.sh"
bind-key ${NOTIFY_DISMISS_KEY:-\`} run-shell "$DEPLOY_DIR/dismiss-notification.sh"
bind-key DC run-shell "$DEPLOY_DIR/dismiss-notification.sh"
bind-key M display-popup -w 80% -h 60% -E "$DEPLOY_DIR/notification-picker.sh"
# --- end clux ---
EOF
            ;;

        no-status-left)
            # Case B: File exists, no status-left — append with markers
            cat >> "$conf" <<EOF

# --- clux: Claude Code notifications (added by /clux:setup) ---
set -g status-left "#S${notification} "
bind-key ${NOTIFY_JUMP_KEY:-m} run-shell "$DEPLOY_DIR/jump-to-notification.sh"
bind-key ${NOTIFY_DISMISS_KEY:-\`} run-shell "$DEPLOY_DIR/dismiss-notification.sh"
bind-key DC run-shell "$DEPLOY_DIR/dismiss-notification.sh"
bind-key M display-popup -w 80% -h 60% -E "$DEPLOY_DIR/notification-picker.sh"
# --- end clux ---
EOF
            ;;

        has-status-left)
            # Case C: Existing status-left — append snippet to value

            # Handle single-quoted values by converting to double quotes
            if check_single_quotes "$conf"; then
                warn "status-left uses single quotes. Converting to double quotes for clux compatibility."
                portable_sed_inplace "s|^\([[:space:]]*set\(-option\)\{0,1\}[[:space:]].*status-left[[:space:]]*\)'\(.*\)'|\1\"\3\"|" "$conf"
            fi

            # Escape the snippet for sed replacement
            local escaped_snippet
            escaped_snippet=$(printf '%s\n' "$notification" | sed 's/[&/\]/\\&/g')

            # Inject before the closing quote of the last status-left value
            portable_sed_inplace "s|\(set\(-option\)\{0,1\}[[:space:]].*-g[[:space:]]\{1,\}status-left[[:space:]]\{1,\}\"[^\"]*\)\"|\1${escaped_snippet}\"|" "$conf"

            # Add keybindings after status-left line (within clux markers)
            # Find the status-left line and append keybindings after it
            local keybind_block
            keybind_block=$(cat <<KEYBINDS
# --- clux: Claude Code notifications (added by /clux:setup) ---
bind-key ${NOTIFY_JUMP_KEY:-m} run-shell "$DEPLOY_DIR/jump-to-notification.sh"
bind-key ${NOTIFY_DISMISS_KEY:-\`} run-shell "$DEPLOY_DIR/dismiss-notification.sh"
bind-key DC run-shell "$DEPLOY_DIR/dismiss-notification.sh"
bind-key M display-popup -w 80% -h 60% -E "$DEPLOY_DIR/notification-picker.sh"
# --- end clux ---
KEYBINDS
)
            # Append keybindings to end of file
            printf '\n%s\n' "$keybind_block" >> "$conf"
            ;;
    esac
}

verify_syntax() {
    local conf="$1"

    # Basic checks
    if [ ! -s "$conf" ]; then
        error "Generated config is empty"
        return 1
    fi

    if ! grep -qF "show-notification.sh" "$conf"; then
        error "Verification failed: notification command not found"
        return 1
    fi

    return 0
}

suggest_settings() {
    local conf="$1"

    # Check status-interval
    local interval
    interval=$(tmux show-option -gv status-interval 2>/dev/null || echo "15")
    if [ "${interval:-15}" -gt 5 ]; then
        echo ""
        info "Recommended: set -g status-interval 1"
        info "  (Current: ${interval:-15}s — notifications may appear delayed)"
    fi

    # Check status-left-length
    local length
    length=$(tmux show-option -gv status-left-length 2>/dev/null || echo "10")
    if [ "${length:-10}" -lt 200 ]; then
        echo ""
        info "Consider increasing status-left-length for full notification display:"
        info "  set -g status-left-length 200"
    fi
}

# --- Main ---
main() {
    # 1. Verify source scripts exist in plugin tree
    if [ ! -f "$PLUGIN_ROOT/scripts/show-notification.sh" ]; then
        error "show-notification.sh not found in plugin at: $PLUGIN_ROOT/scripts/"
        error "Please reinstall the clux plugin."
        exit 1
    fi

    # 2. Find tmux.conf
    local tmux_conf
    tmux_conf=$(find_tmux_conf)

    # 3. Check if already configured — exit early (idempotent)
    if is_already_configured "$tmux_conf"; then
        echo ""
        success "clux is already configured in $tmux_conf. Nothing to do."
        echo ""
        info "Run: tmux source-file \"$tmux_conf\" (or restart tmux)"
        exit 0
    fi

    # 4. Determine state
    local state
    if [ ! -f "$tmux_conf" ]; then
        state="no-file"
    elif has_status_left "$tmux_conf"; then
        state="has-status-left"
    else
        state="no-status-left"
    fi

    # 5. Writable check
    if [ -f "$tmux_conf" ] && [ ! -w "$tmux_conf" ]; then
        error "$tmux_conf is not writable"
        info "Try: chmod u+w \"$tmux_conf\""
        exit 1
    fi

    # 6. Show preview
    echo ""
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bold "  clux setup — tmux.conf configuration"
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local notification=" #($SNIPPET_PATH)"

    case "$state" in
        no-file)
            info "Detected: $tmux_conf does not exist"
            info "Action: Create new file with clux configuration"
            echo ""
            echo "Will create:"
            echo "  set -g status-left \"${notification}\""
            echo "  set -g status-interval 1"
            ;;
        no-status-left)
            info "Detected: $tmux_conf exists without status-left"
            info "Action: Append clux notification section"
            echo ""
            echo "Will add:"
            echo "  # --- clux: Claude Code notifications (added by /clux:setup) ---"
            echo "  set -g status-left \"${notification}\""
            echo "  # --- end clux ---"
            ;;
        has-status-left)
            local existing_line
            existing_line=$(grep '^[[:space:]]*set\(-option\)\?[[:space:]].*status-left' "$tmux_conf" | tail -1)
            info "Detected: $tmux_conf has existing status-left"
            info "Action: Append notification display to existing value"
            echo ""
            echo "Current:"
            echo "  $existing_line"
            echo ""
            echo "After:"
            # Show a preview of the modified line
            echo "  (notification snippet appended to status-left value)"
            ;;
    esac

    echo ""

    # --dry-run exits here
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] No changes made."
        exit 0
    fi

    # 7. Confirm
    printf "Continue with this change? [Y/n] "
    read -r response
    case "$response" in
        [nN]|[nN][oO])
            warn "Setup cancelled by user."
            exit 1
            ;;
    esac

    # 8. Backup (if file exists)
    local backup_path=""
    if [ -f "$tmux_conf" ]; then
        backup_path=$(create_backup "$tmux_conf")
    fi

    # 9. Deploy scripts to stable location
    deploy_scripts

    # 10. Apply modification
    inject_snippet "$tmux_conf" "$state"

    # 10. Verify
    if ! verify_syntax "$tmux_conf"; then
        error "Verification failed after modification"
        if [ -n "$backup_path" ] && [ -f "$backup_path" ]; then
            warn "Restoring from backup..."
            cp "$backup_path" "$tmux_conf"
        fi
        exit 1
    fi

    success "tmux.conf updated"

    # 11. Reload tmux config and refresh status bar
    if tmux source-file "$tmux_conf" 2>/dev/null; then
        tmux refresh-client -S 2>/dev/null
        success "tmux config reloaded"
    else
        info "Run manually: tmux source-file \"$tmux_conf\" && tmux refresh-client -S"
    fi

    # 12. Print summary
    echo ""
    success "Setup complete!"
    if [ -n "$backup_path" ]; then
        echo ""
        info "To undo: cp '$backup_path' '$tmux_conf' && tmux source '$tmux_conf'"
    fi

    # 13. Suggest additional settings
    suggest_settings "$tmux_conf"
}

main "$@"
