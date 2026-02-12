---
name: auto-setup
description: Intelligently configure tmux for tclux using Claude API
allowed-tools: Read, Write, Bash, AskUserQuestion
---

# tclux Auto-Setup: Intelligent tmux Configuration

This command uses Claude to intelligently merge tclux notification integration into your tmux.conf while preserving all existing configuration.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Resolve plugin paths
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
STRATEGY_DOC="$PLUGIN_ROOT/docs/REFERENCE-tmux-setup-strategy.md"
CONFIG_YAML="$PLUGIN_ROOT/config/tmux-config.yaml"
TMUX_CONF="$HOME/.tmux.conf"
BACKUP_DIR="$HOME/.config/tclux/backups"

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

# === STEP 1: Verify prerequisites ===
info "Checking prerequisites..."

if [ ! -f "$STRATEGY_DOC" ]; then
    error "Strategy documentation not found: $STRATEGY_DOC"
    exit 1
fi

if [ ! -f "$CONFIG_YAML" ]; then
    error "Configuration not found: $CONFIG_YAML"
    exit 1
fi

if [ -z "$OPENAI_API_KEY" ]; then
    error "OPENAI_API_KEY not set. Claude API is required for intelligent configuration."
    exit 1
fi

if ! command -v jq &>/dev/null; then
    error "jq is required for JSON parsing"
    exit 1
fi

if ! command -v tmux &>/dev/null; then
    error "tmux is not installed"
    exit 1
fi

success "Prerequisites verified"

# === STEP 2: Read current configuration ===
info "Reading current tmux configuration..."

CURRENT_CONFIG=""
if [ -f "$TMUX_CONF" ]; then
    CURRENT_CONFIG=$(cat "$TMUX_CONF")
    info "Current config size: $(echo "$CURRENT_CONFIG" | wc -c) bytes"
else
    info "No existing ~/.tmux.conf found"
fi

# === STEP 3: Load strategy documentation ===
info "Loading configuration strategy..."
STRATEGY_DOC_CONTENT=$(cat "$STRATEGY_DOC")
CONFIG_YAML_CONTENT=$(cat "$CONFIG_YAML")

# === STEP 4: Build Claude API request ===
info "Preparing intelligent configuration merge..."

# Determine expansion path for show-notification.sh
SCRIPT_PATH="$PLUGIN_ROOT/scripts/show-notification.sh"

# Create the system prompt for Claude
read -r -d '' SYSTEM_PROMPT << 'EOF' || true
You are an expert tmux configuration assistant. Your task is to intelligently merge tclux notification integration into a tmux configuration file while preserving all existing settings.

**CRITICAL REQUIREMENTS:**
1. Preserve ALL existing tmux configuration exactly as-is
2. Intelligently handle all 4 modification cases (see strategy doc)
3. Detect if already configured and skip if needed (idempotent)
4. Never remove or modify user's existing settings
5. Preserve all conditional syntax, formatting, and comments
6. Double-quote the status-left value (required for #{E:} expansion)
7. Expand ${CLAUDE_PLUGIN_ROOT} to the ABSOLUTE PATH provided

**OUTPUT FORMAT:**
Return ONLY valid tmux configuration as the response, no explanations. The output will be written directly to ~/.tmux.conf.

**IMPORTANT:**
- Do not add explanations or markdown
- Output must be valid tmux syntax
- The configuration will be verified with: tmux source-file ~/.tmux.conf
EOF

# Create the user prompt with context
read -r -d '' USER_PROMPT << EOF || true
Please intelligently merge tclux notification integration into this tmux configuration.

**Current Configuration:**
\`\`\`
${CURRENT_CONFIG:-# (no existing config)}
\`\`\`

**Integration Strategy:**
Reference the following strategy document for guidance on how to handle all cases:

\`\`\`markdown
$STRATEGY_DOC_CONTENT
\`\`\`

**Configuration Requirements:**
\`\`\`yaml
$CONFIG_YAML_CONTENT
\`\`\`

**Specific values to use:**
- Absolute path to show-notification.sh: $SCRIPT_PATH
- Status-left prefix command: #{E:#($SCRIPT_PATH)}

**What to do:**
1. If show-notification.sh is already in the config → return config unchanged (idempotent)
2. If status-left exists → prepend the notification command to its value
3. If no status-left but config exists → append tclux section with markers
4. If no config exists → create new config with tclux settings

Return the complete, valid tmux configuration.
EOF

# === STEP 5: Call Claude API ===
info "Calling Claude API for intelligent configuration..."

API_RESPONSE=$(curl -s -X POST https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $OPENAI_API_KEY" \
  -d @- << PAYLOAD
{
  "model": "claude-opus-4-6",
  "max_tokens": 4096,
  "system": $(printf '%s' "$SYSTEM_PROMPT" | jq -Rs .),
  "messages": [
    {
      "role": "user",
      "content": $(printf '%s' "$USER_PROMPT" | jq -Rs .)
    }
  ]
}
PAYLOAD
)

# Check for API errors
if echo "$API_RESPONSE" | jq -e '.error' &>/dev/null; then
    ERROR_MSG=$(echo "$API_RESPONSE" | jq -r '.error.message')
    error "Claude API error: $ERROR_MSG"
    exit 1
fi

# Extract the generated configuration
GENERATED_CONFIG=$(echo "$API_RESPONSE" | jq -r '.content[0].text')

if [ -z "$GENERATED_CONFIG" ]; then
    error "Claude returned empty configuration"
    exit 1
fi

success "Configuration generated by Claude"

# === STEP 6: Show preview and ask for approval ===
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bold "  tclux Auto-Setup: Configuration Preview"
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -z "$CURRENT_CONFIG" ]; then
    echo "Creating new ~/.tmux.conf with:"
else
    echo "Modifying ~/.tmux.conf:"
fi

echo ""
echo "New configuration:"
echo "————————————————————————————————————"
echo "$GENERATED_CONFIG"
echo "————————————————————————————————————"
echo ""

# Use AskUserQuestion to get approval
# This simulates the tool interaction - in actual implementation, use the AskUserQuestion tool
printf "Apply this configuration? [y/N] "
read -r response

case "$response" in
    [yY]|[yY][eE][sS])
        ;;
    *)
        warn "Setup cancelled by user"
        exit 1
        ;;
esac

# === STEP 7: Backup existing config ===
if [ -f "$TMUX_CONF" ]; then
    info "Creating backup..."
    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup="$BACKUP_DIR/tmux.conf.$timestamp"

    if cp "$TMUX_CONF" "$backup"; then
        success "Backup saved: $backup"
    else
        error "Failed to create backup"
        exit 1
    fi

    # Keep only 5 most recent backups
    ls -1t "$BACKUP_DIR"/tmux.conf.* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
fi

# === STEP 8: Apply configuration ===
info "Applying configuration..."

# Write generated config to temporary file first for validation
TMPFILE="/tmp/tmux.conf.$$"
echo "$GENERATED_CONFIG" > "$TMPFILE"

# Validate syntax with tmux
if ! tmux -f "$TMPFILE" source-file "$TMPFILE" 2>&1 | grep -q "no server running"; then
    # Some other error occurred (not just "no server running")
    error "tmux configuration has syntax errors"
    cat "$TMPFILE"
    rm -f "$TMPFILE"
    exit 1
fi

# Apply the configuration
mkdir -p "$(dirname "$TMUX_CONF")"
mv "$TMPFILE" "$TMUX_CONF"

success "Configuration applied: $TMUX_CONF"

# === STEP 9: Reload tmux ===
info "Reloading tmux configuration..."

if tmux source-file "$TMUX_CONF" 2>/dev/null; then
    success "tmux configuration reloaded"
else
    warn "Could not reload tmux (server may not be running)"
    info "Reload manually with: tmux source-file ~/.tmux.conf"
fi

# === STEP 10: Report success ===
echo ""
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "tclux setup complete!"
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f "$backup" ]; then
    info "To undo: cp '$backup' '$TMUX_CONF' && tmux source-file '$TMUX_CONF'"
fi

echo ""
info "Next steps:"
echo "  1. Verify notifications appear: /tclux:validate"
echo "  2. Customize colors: edit ~/.tmux.conf"
echo "  3. Learn more: https://github.com/404pilo/tclux"
echo ""

exit 0
```

## How It Works

1. **Prerequisite Check**: Verifies OPENAI_API_KEY, jq, tmux are available
2. **Read Configuration**: Loads current ~/.tmux.conf (if exists) and reference strategy
3. **Build Claude Prompt**: Combines strategy, config requirements, and user's current settings
4. **Call Claude API**: Uses claude-opus-4-6 for intelligent configuration merging
5. **Show Preview**: Displays what will be written before applying
6. **Get Approval**: Prompts user for confirmation
7. **Backup**: Creates timestamped backup before modification
8. **Apply**: Writes generated config and validates syntax
9. **Reload**: Reloads tmux configuration
10. **Report**: Shows success and rollback instructions

## Advantages of LLM-Driven Approach

- **Intelligent merging**: Understands tmux syntax and user's existing configuration
- **Edge case handling**: Claude naturally handles complex conditionals, multi-line syntax, etc.
- **Idempotent**: Detects if already configured and skips
- **User-safe**: Shows diff before applying, creates backups automatically
- **Flexible**: Can adapt to new edge cases without code changes
- **Maintainable**: Logic described in documentation, not fragile regex patterns

## When to Use

- **First-time setup**: Configure tmux for tclux integration
- **Re-run safely**: Idempotent - safe to run multiple times
- **Undo if needed**: Backups provided with rollback instructions

## Troubleshooting

If Claude returns an empty configuration:
- Check OPENAI_API_KEY is set and valid
- Verify jq is installed for JSON parsing
- Check API rate limits haven't been exceeded

If tmux validation fails:
- Check error message in command output
- Verify your current ~/.tmux.conf is valid: `tmux source-file ~/.tmux.conf`
- Check backups at `~/.config/tclux/backups/`
