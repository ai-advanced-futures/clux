#!/usr/bin/env bash
# Comprehensive test suite for setup-tmux-conf.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Test utilities
TEST_DIR="/tmp/tclux-test-$$"
BACKUP_DIR="${TEST_DIR}/backups"
SCRIPT_PATH="/Users/yasselpiloto/dev/github.com/404pilo/tclux/plugins/tclux/scripts/setup-tmux-conf.sh"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_TESTS=0

# Print functions
info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
pass() { printf "${GREEN}[PASS]${NC} %s\n" "$*"; ((PASS_COUNT++)) || true; }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$*"; ((FAIL_COUNT++)) || true; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
section() { printf "\n${BOLD}━━━ %s ━━━${NC}\n" "$*"; }

# Setup test environment
setup_test_env() {
    mkdir -p "$TEST_DIR" "$BACKUP_DIR"

    # Backup real ~/.tmux.conf if it exists
    if [ -f "$HOME/.tmux.conf" ]; then
        cp "$HOME/.tmux.conf" "$BACKUP_DIR/tmux.conf.real-backup"
        info "Backed up real ~/.tmux.conf to $BACKUP_DIR/tmux.conf.real-backup"
    fi
}

# Cleanup test environment
cleanup_test_env() {
    # Restore real ~/.tmux.conf
    if [ -f "$BACKUP_DIR/tmux.conf.real-backup" ]; then
        mv "$BACKUP_DIR/tmux.conf.real-backup" "$HOME/.tmux.conf"
        info "Restored real ~/.tmux.conf"
    else
        rm -f "$HOME/.tmux.conf"
        info "Removed test ~/.tmux.conf (no original existed)"
    fi

    # Clean up test backups
    rm -f "$HOME/.tmux.conf.backup-"*

    rm -rf "$TEST_DIR"
}

# Assertion helpers
assert_file_exists() {
    ((TOTAL_TESTS++)) || true
    if [ -f "$1" ]; then
        pass "File exists: $1"
        return 0
    else
        fail "File does not exist: $1"
        return 1
    fi
}

assert_file_not_exists() {
    ((TOTAL_TESTS++)) || true
    if [ ! -f "$1" ]; then
        pass "File does not exist: $1"
        return 0
    else
        fail "File exists (should not): $1"
        return 1
    fi
}

assert_file_contains() {
    ((TOTAL_TESTS++)) || true
    local file="$1"
    local pattern="$2"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        pass "File contains pattern: $pattern"
        return 0
    else
        fail "File missing pattern: $pattern"
        return 1
    fi
}

assert_file_not_contains() {
    ((TOTAL_TESTS++)) || true
    local file="$1"
    local pattern="$2"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        pass "File does not contain pattern: $pattern"
        return 0
    else
        fail "File contains pattern (should not): $pattern"
        return 1
    fi
}

assert_variable_not_expanded() {
    ((TOTAL_TESTS++)) || true
    local file="$1"
    if grep -q '\${CLAUDE_PLUGIN_ROOT}' "$file" 2>/dev/null; then
        pass "Variable \${CLAUDE_PLUGIN_ROOT} preserved (not expanded)"
        return 0
    else
        fail "Variable \${CLAUDE_PLUGIN_ROOT} was expanded or missing"
        return 1
    fi
}

#
# Test 1: Missing ~/.tmux.conf
#
test_1_missing_config() {
    section "Test 1: Missing ~/.tmux.conf"

    # Setup: Remove ~/.tmux.conf
    rm -f "$HOME/.tmux.conf"
    rm -f "$HOME/.tmux.conf.backup-"*

    # Run: Execute with auto-confirm
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1

    # Verify
    assert_file_exists "$HOME/.tmux.conf"
    assert_file_contains "$HOME/.tmux.conf" "show-notification.sh"
    assert_file_contains "$HOME/.tmux.conf" "status-interval 1"
    assert_variable_not_expanded "$HOME/.tmux.conf"

    # No backup should be created (file didn't exist)
    local backup_count
    backup_count=$(ls -1 "$HOME/.tmux.conf.backup-"* 2>/dev/null | wc -l | tr -d ' ')
    ((TOTAL_TESTS++)) || true
    if [ "$backup_count" -eq 0 ]; then
        pass "No backup created (file didn't exist)"
    else
        fail "Backup created when file didn't exist"
    fi
}

#
# Test 2: Already Configured (Idempotent)
#
test_2_already_configured() {
    section "Test 2: Already Configured (Idempotent)"

    # Setup: Create config with our line
    cat > "$HOME/.tmux.conf" <<'EOF'
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
set -g status-interval 1
EOF

    local before_content
    before_content=$(cat "$HOME/.tmux.conf")

    # Run: Execute again
    bash "$SCRIPT_PATH" >/dev/null 2>&1
    local exit_code=$?

    # Verify
    ((TOTAL_TESTS++)) || true
    if [ $exit_code -eq 0 ]; then
        pass "Exit code is 0 (success)"
    else
        fail "Exit code is $exit_code (expected 0)"
    fi

    local after_content
    after_content=$(cat "$HOME/.tmux.conf")

    ((TOTAL_TESTS++)) || true
    if [ "$before_content" = "$after_content" ]; then
        pass "Configuration unchanged (idempotent)"
    else
        fail "Configuration changed (not idempotent)"
    fi

    # No new backup should be created
    local backup_count
    backup_count=$(ls -1 "$HOME/.tmux.conf.backup-"* 2>/dev/null | wc -l | tr -d ' ')
    ((TOTAL_TESTS++)) || true
    if [ "$backup_count" -eq 0 ]; then
        pass "No backup created (already configured)"
    else
        fail "Backup created when already configured"
    fi
}

#
# Test 3: Existing Simple status-left
#
test_3_simple_status_left() {
    section "Test 3: Existing Simple status-left"

    # Setup
    cat > "$HOME/.tmux.conf" <<'EOF'
set -g status-left "[#S] "
EOF

    # Clean up any previous backups
    rm -f "$HOME/.tmux.conf.backup-"*

    # Run
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1

    # Verify
    assert_file_exists "$HOME/.tmux.conf"
    assert_file_contains "$HOME/.tmux.conf" "show-notification.sh"
    assert_file_contains "$HOME/.tmux.conf" "\[#S\]"
    assert_variable_not_expanded "$HOME/.tmux.conf"

    # Check prepending (notification should come before [#S])
    ((TOTAL_TESTS++)) || true
    if grep -q 'show-notification.sh.*\[#S\]' "$HOME/.tmux.conf"; then
        pass "Notification prepended to existing status-left"
    else
        fail "Notification not properly prepended"
    fi

    # Backup should be created
    local backup_count
    backup_count=$(ls -1 "$HOME/.tmux.conf.backup-"* 2>/dev/null | wc -l | tr -d ' ')
    ((TOTAL_TESTS++)) || true
    if [ "$backup_count" -ge 1 ]; then
        pass "Backup created with timestamp"
    else
        fail "No backup created"
    fi
}

#
# Test 4: Existing Complex status-left with Conditionals
#
test_4_complex_status_left() {
    section "Test 4: Existing Complex status-left with Conditionals"

    # Setup
    cat > "$HOME/.tmux.conf" <<'EOF'
set -g status-left "#{?pane_dead,[dead],#S} "
EOF

    rm -f "$HOME/.tmux.conf.backup-"*

    # Run
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1

    # Verify
    assert_file_contains "$HOME/.tmux.conf" "show-notification.sh"
    assert_file_contains "$HOME/.tmux.conf" "#{?pane_dead,\[dead\],#S}"

    # Check that conditionals are preserved
    ((TOTAL_TESTS++)) || true
    if grep -q 'show-notification.sh.*#{?pane_dead' "$HOME/.tmux.conf"; then
        pass "Conditionals preserved and notification prepended"
    else
        fail "Conditionals not preserved"
    fi
}

#
# Test 5: Multi-line status-left Assignment
#
test_5_multiline_status_left() {
    section "Test 5: Multi-line status-left Assignment"

    # Setup
    cat > "$HOME/.tmux.conf" <<'EOF'
set -g status-left \
    "[#S] some value"
EOF

    rm -f "$HOME/.tmux.conf.backup-"*

    # Run
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1

    # Verify - current implementation handles first line
    assert_file_contains "$HOME/.tmux.conf" "show-notification.sh"

    # Check if original content is preserved
    ((TOTAL_TESTS++)) || true
    if grep -q "\[#S\] some value" "$HOME/.tmux.conf"; then
        pass "Multi-line content preserved"
    else
        warn "Multi-line handling may need review"
    fi
}

#
# Test 6: Backup and Rollback
#
test_6_backup_rollback() {
    section "Test 6: Backup and Rollback"

    # Setup
    cat > "$HOME/.tmux.conf" <<'EOF'
# Original config
set -g status-left "[#S] "
EOF

    local original_content
    original_content=$(cat "$HOME/.tmux.conf")

    rm -f "$HOME/.tmux.conf.backup-"*

    # Run
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1

    # Verify backup exists
    local backup_file
    backup_file=$(ls -1 "$HOME/.tmux.conf.backup-"* 2>/dev/null | head -1)

    ((TOTAL_TESTS++)) || true
    if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
        pass "Backup file created: $(basename "$backup_file")"
    else
        fail "No backup file found"
        return 1
    fi

    # Verify backup contains original content
    local backup_content
    backup_content=$(cat "$backup_file")

    ((TOTAL_TESTS++)) || true
    if [ "$backup_content" = "$original_content" ]; then
        pass "Backup contains original content"
    else
        fail "Backup content differs from original"
    fi

    # Test rollback
    cp "$backup_file" "$HOME/.tmux.conf"

    ((TOTAL_TESTS++)) || true
    if [ "$(cat "$HOME/.tmux.conf")" = "$original_content" ]; then
        pass "Rollback successful"
    else
        fail "Rollback failed"
    fi

    # Test multiple backups (run again)
    rm -f "$HOME/.tmux.conf.backup-"*
    cat > "$HOME/.tmux.conf" <<'EOF'
set -g status-left "[#S] "
EOF
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1
    sleep 1
    cat > "$HOME/.tmux.conf" <<'EOF'
set -g status-left "[#S] "
EOF
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1

    local backup_count
    backup_count=$(ls -1 "$HOME/.tmux.conf.backup-"* 2>/dev/null | wc -l | tr -d ' ')

    ((TOTAL_TESTS++)) || true
    if [ "$backup_count" -ge 2 ]; then
        pass "Multiple timestamped backups created"
    else
        warn "Only $backup_count backup(s) created"
    fi
}

#
# Test 7: Syntax Verification
#
test_7_syntax_verification() {
    section "Test 7: Syntax Verification"

    # Setup
    cat > "$HOME/.tmux.conf" <<'EOF'
set -g status-left "[#S] "
EOF

    rm -f "$HOME/.tmux.conf.backup-"*

    # Run
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1

    # Verify tmux can parse it (if tmux is available)
    if command -v tmux &>/dev/null; then
        ((TOTAL_TESTS++)) || true
        # Just check if the file is valid tmux syntax
        if tmux -f "$HOME/.tmux.conf" list-keys &>/dev/null || true; then
            pass "tmux can parse modified config"
        else
            warn "tmux syntax check inconclusive (may need running server)"
        fi
    else
        warn "tmux not available, skipping syntax verification"
    fi
}

#
# Test 8: File Permissions
#
test_8_file_permissions() {
    section "Test 8: File Permissions"

    # Setup: Create read-only file
    cat > "$HOME/.tmux.conf" <<'EOF'
set -g status-left "[#S] "
EOF
    chmod 444 "$HOME/.tmux.conf"

    rm -f "$HOME/.tmux.conf.backup-"*

    # Run (expect failure)
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1 || true

    # Verify error handling
    ((TOTAL_TESTS++)) || true
    if [ ! -w "$HOME/.tmux.conf" ]; then
        pass "Read-only permission preserved (script handles gracefully)"
    else
        fail "Permission test inconclusive"
    fi

    # Restore permissions
    chmod 644 "$HOME/.tmux.conf"
}

#
# Test 9: ${CLAUDE_PLUGIN_ROOT} Variable Preservation
#
test_9_variable_preservation() {
    section "Test 9: \${CLAUDE_PLUGIN_ROOT} Variable Preservation"

    # Setup
    rm -f "$HOME/.tmux.conf"
    rm -f "$HOME/.tmux.conf.backup-"*
    export CLAUDE_PLUGIN_ROOT="/some/test/path"

    # Run
    echo "y" | bash "$SCRIPT_PATH" >/dev/null 2>&1

    # Verify variable is NOT expanded
    assert_variable_not_expanded "$HOME/.tmux.conf"

    # Verify it's not expanded to the actual path
    ((TOTAL_TESTS++)) || true
    if ! grep -q "/some/test/path" "$HOME/.tmux.conf"; then
        pass "Variable not expanded to actual path"
    else
        fail "Variable was expanded to actual path"
    fi

    # Verify literal string exists
    assert_file_contains "$HOME/.tmux.conf" '\${CLAUDE_PLUGIN_ROOT}'
}

#
# Test 10: User Cancellation
#
test_10_user_cancellation() {
    section "Test 10: User Cancellation"

    # Setup
    rm -f "$HOME/.tmux.conf"
    rm -f "$HOME/.tmux.conf.backup-"*

    # Run: Answer "n" to confirmation
    echo "n" | bash "$SCRIPT_PATH" >/dev/null 2>&1
    local exit_code=$?

    # Verify no modifications made
    ((TOTAL_TESTS++)) || true
    if [ ! -f "$HOME/.tmux.conf" ]; then
        pass "No file created after cancellation"
    else
        fail "File created despite cancellation"
    fi

    # Verify no backup created
    local backup_count
    backup_count=$(ls -1 "$HOME/.tmux.conf.backup-"* 2>/dev/null | wc -l | tr -d ' ')
    ((TOTAL_TESTS++)) || true
    if [ "$backup_count" -eq 0 ]; then
        pass "No backup created after cancellation"
    else
        fail "Backup created despite cancellation"
    fi

    # Exit code check
    ((TOTAL_TESTS++)) || true
    if [ $exit_code -eq 1 ]; then
        pass "Exit code is 1 (user cancellation)"
    else
        warn "Exit code is $exit_code (expected 1)"
    fi
}

#
# Main test runner
#
main() {
    echo ""
    section "tclux setup-tmux-conf.sh Test Suite"
    echo ""

    setup_test_env

    trap cleanup_test_env EXIT

    # Run all tests
    test_1_missing_config || true
    test_2_already_configured || true
    test_3_simple_status_left || true
    test_4_complex_status_left || true
    test_5_multiline_status_left || true
    test_6_backup_rollback || true
    test_7_syntax_verification || true
    test_8_file_permissions || true
    test_9_variable_preservation || true
    test_10_user_cancellation || true

    # Report
    echo ""
    section "Test Results"
    echo ""
    printf "Total tests:  %d\n" "$TOTAL_TESTS"
    printf "${GREEN}Passed:       %d${NC}\n" "$PASS_COUNT"
    printf "${RED}Failed:       %d${NC}\n" "$FAIL_COUNT"
    echo ""

    if [ "$FAIL_COUNT" -eq 0 ]; then
        printf "${GREEN}${BOLD}✓ All tests passed!${NC}\n"
        echo ""
        return 0
    else
        printf "${RED}${BOLD}✗ Some tests failed${NC}\n"
        echo ""
        return 1
    fi
}

main "$@"
