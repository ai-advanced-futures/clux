# Design: Autonomous `/tclux:setup` Command

## Overview

Transform `/tclux:setup` from a print-instructions-and-copy-paste flow into an autonomous command that detects, backs up, and modifies the user's `tmux.conf` to integrate the tclux notification snippet.

---

## 1. Detection Logic

### 1.1 Locate tmux.conf

tmux reads config from multiple locations. Check in order of precedence:

```bash
TMUX_CONF=""
for candidate in \
    "$HOME/.tmux.conf" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
    if [ -f "$candidate" ]; then
        TMUX_CONF="$candidate"
        break
    fi
done
```

If neither exists, default to `$HOME/.tmux.conf` (most common).

### 1.2 Determine plugin root path

`$CLAUDE_PLUGIN_ROOT` is set by Claude Code at hook execution time but is **not** available inside tmux.conf at parse time. The path must be **hardcoded** (expanded) when injected into tmux.conf.

Resolve the absolute path at setup time:

```bash
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIPPET_PATH="$PLUGIN_ROOT/scripts/show-notification.sh"
```

Verify the script exists and is executable before proceeding.

### 1.3 Check existing configuration

Three states to detect:

| State | Detection | Action |
|-------|-----------|--------|
| **Already configured** | `grep -qF "show-notification.sh" "$TMUX_CONF"` | Skip, report success |
| **Has `status-left` but no tclux** | `grep -q '^[[:space:]]*set.*-g.*status-left' "$TMUX_CONF"` | Prepend snippet into existing value |
| **No `status-left` at all** | grep returns non-zero | Append new `set -g status-left` line |

### 1.4 Writable check

```bash
if [ -f "$TMUX_CONF" ] && [ ! -w "$TMUX_CONF" ]; then
    echo "Error: $TMUX_CONF is not writable"
    exit 1
fi
```

---

## 2. Modification Strategy

### 2.1 The snippet to inject

The exact line that needs to be present in tmux.conf:

```bash
set -g status-left "#{E:#(/absolute/path/to/show-notification.sh)} "
```

With `$PLUGIN_ROOT` expanded at setup time to the real absolute path.

### 2.2 Case A: No tmux.conf exists

Create a new file with minimal config:

```bash
# tclux: Claude Code tmux notification plugin
set -g status-left "#{E:#($SNIPPET_PATH)} "
set -g status-interval 1
```

### 2.3 Case B: tmux.conf exists, no `status-left`

Append to end of file with a section comment:

```bash
# --- tclux: Claude Code notifications (added by /tclux:setup) ---
set -g status-left "#{E:#($SNIPPET_PATH)} "
# --- end tclux ---
```

### 2.4 Case C: tmux.conf has existing `status-left`

This is the complex case. Strategy: **prepend** the notification call to the existing value.

**Detection of current value:**

```bash
# Extract the existing status-left line (last occurrence wins in tmux)
EXISTING_LINE=$(grep '^[[:space:]]*set\(-option\)\?[[:space:]]\+.*-g[[:space:]]\+status-left' "$TMUX_CONF" | tail -1)
```

**Parsing the value:**

The value is the part after `status-left`, typically quoted. Examples:

- Simple: `set -g status-left " #S "`
- Complex: `set -g status-left "#[fg=green]#S #[fg=yellow]#I"`
- With conditionals: `set -g status-left "#{?client_prefix,#[reverse],} #S "`

**Modification approach:**

Rather than parsing and rewriting the value (fragile), use **sed** to inject the notification call at the beginning of the quoted value:

```bash
# Escape the snippet for sed replacement
ESCAPED_SNIPPET=$(printf '%s\n' "#{E:#($SNIPPET_PATH)} " | sed 's/[&/\]/\\&/g')

# Inject after the opening quote of status-left value
sed -i.bak "s|\(set\(-option\)\?[[:space:]]\+.*-g[[:space:]]\+status-left[[:space:]]\+\"\)|\1${ESCAPED_SNIPPET}|" "$TMUX_CONF"
```

This inserts our snippet right after the opening `"` of the status-left value, preserving whatever the user already had.

**Result example:**
- Before: `set -g status-left " #S "`
- After: `set -g status-left "#{E:#(/path/to/show-notification.sh)}  #S "`

### 2.5 Case D: Already configured

Detected by `grep -qF "show-notification.sh" "$TMUX_CONF"`.

Print a message and skip modification entirely. This makes the command idempotent.

---

## 3. Edge Case Handling

### 3.1 Multiple `status-left` lines

tmux uses last-wins semantics. Our grep/sed targets the **last** occurrence. If the user has conditional includes or multiple lines, we modify the last one.

### 3.2 Single-quoted values

tmux accepts both `'` and `"` quoting. The `#{E:...}` expansion requires double quotes to work. If the existing line uses single quotes:

```bash
if echo "$EXISTING_LINE" | grep -q "status-left[[:space:]]*'"; then
    echo "Warning: status-left uses single quotes. #{E:...} requires double quotes."
    echo "Converting single quotes to double quotes for tclux compatibility."
    # Replace the single quotes with double quotes on that specific line
fi
```

### 3.3 `status-left` set via `source-file`

If status-left is configured in a sourced file rather than the main tmux.conf, our grep won't find it. In this case:
- `tmux show-option -gv status-left` will still show the runtime value
- If tmux reports status-left includes `show-notification.sh` (runtime check) but the file doesn't have it, warn the user that the setting may be in a sourced file and print the manual snippet as fallback.

### 3.4 macOS `sed` vs GNU `sed`

macOS ships BSD sed which requires `-i ''` (empty string extension) vs GNU sed's `-i` (no argument). Handle portably:

```bash
if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$SED_EXPR" "$TMUX_CONF"
else
    sed -i "$SED_EXPR" "$TMUX_CONF"
fi
```

### 3.5 `status-left-length`

If the user hasn't set `status-left-length`, the default (10) may truncate our notification. Add a check:

```bash
LENGTH=$(tmux show-option -gv status-left-length 2>/dev/null)
if [ "${LENGTH:-10}" -lt 80 ]; then
    echo "Note: Consider increasing status-left-length for full notification display:"
    echo "  set -g status-left-length 100"
fi
```

### 3.6 `status-right` alternative

Some users may prefer `status-right`. Our default targets `status-left`, but if setup detects that `status-left` is already very long (>100 chars) or the user has a complex theme, suggest `status-right` as an alternative. This is informational only — the automated path always uses `status-left`.

---

## 4. Backup & Rollback

### 4.1 Backup strategy

Before any modification, create a timestamped backup:

```bash
BACKUP_DIR="$HOME/.config/tclux/backups"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/tmux.conf.$TIMESTAMP"
cp "$TMUX_CONF" "$BACKUP_FILE"
```

**Why `~/.config/tclux/backups/`:**
- Survives `/tmp` cleanup
- Grouped under the plugin's own config namespace
- Not mixed into tmux's own config directory

### 4.2 Rollback mechanism

Provide a restore command:

```bash
# The setup script outputs this after modification:
echo "Backup saved to: $BACKUP_FILE"
echo "To undo: cp '$BACKUP_FILE' '$TMUX_CONF' && tmux source '$TMUX_CONF'"
```

A dedicated uninstall function in the setup script:

```bash
tclux_uninstall() {
    # Remove the tclux lines from tmux.conf
    # Pattern: remove lines between tclux markers, or remove the show-notification.sh reference
    sed -i '/# --- tclux:/,/# --- end tclux ---/d' "$TMUX_CONF"
    # Also handle case C where snippet was prepended into existing line
    sed -i "s|#{E:#($SNIPPET_PATH)} ||" "$TMUX_CONF"
    tmux source-file "$TMUX_CONF" 2>/dev/null
    echo "tclux removed from tmux.conf"
}
```

### 4.3 Backup cleanup

Keep only the 5 most recent backups:

```bash
ls -1t "$BACKUP_DIR"/tmux.conf.* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
```

---

## 5. User Experience

### 5.1 Setup flow (happy path)

```
/tclux:setup

tclux validation
================
  ✓ tmux is running
  ✓ keybindings registered
  ✗ status-left configured
  ✓ notification dir writable
  ... (remaining checks)

8 passed, 2 failed

Detected tmux config: ~/.tmux.conf
Current status-left: " #S "

tclux will prepend the notification display to your status-left.

Before: set -g status-left " #S "
After:  set -g status-left "#{E:#(/Users/you/.claude/plugins/tclux/scripts/show-notification.sh)}  #S "

Backup: ~/.config/tclux/backups/tmux.conf.20260211_143022

Applying changes...
✓ tmux.conf updated
✓ tmux config reloaded

To undo: cp ~/.config/tclux/backups/tmux.conf.20260211_143022 ~/.tmux.conf && tmux source ~/.tmux.conf
```

### 5.2 Already configured

```
/tclux:setup

tclux validation
================
  ✓ tmux is running
  ✓ status-left configured
  ... (all green)

10 passed, 0 failed

✓ tclux is already configured in your tmux.conf. Nothing to do.
```

### 5.3 Error cases

- **tmux not running**: Print error, exit early (validation catches this).
- **File not writable**: Print error with suggestion (`chmod` or `sudo`).
- **show-notification.sh missing**: Print error asking user to reinstall plugin.

### 5.4 Post-modification reload

After modifying tmux.conf, automatically reload:

```bash
tmux source-file "$TMUX_CONF" 2>/dev/null && echo "✓ tmux config reloaded"
```

### 5.5 Recommended settings

After the main setup, check and suggest additional settings:

```bash
INTERVAL=$(tmux show-option -gv status-interval 2>/dev/null)
if [ "${INTERVAL:-15}" -gt 5 ]; then
    echo ""
    echo "Recommended: set -g status-interval 1"
    echo "  (Current: ${INTERVAL:-15}s — notifications may appear delayed)"
fi
```

---

## 6. Implementation Approach

### 6.1 File structure

Create a single new script:

```
plugins/tclux/scripts/configure-tmux.sh
```

This script handles all detection, backup, modification, and rollback logic. It is called by the setup command instead of printing manual instructions.

### 6.2 Updated setup command (`commands/setup.md`)

```markdown
---
name: setup
description: Validate tclux integration and automatically configure tmux
---

Run the tclux validation script first:

\`\`\`bash
$CLAUDE_PLUGIN_ROOT/scripts/validate-setup.sh
\`\`\`

Then run the autonomous configuration script to detect and modify tmux.conf:

\`\`\`bash
$CLAUDE_PLUGIN_ROOT/scripts/configure-tmux.sh
\`\`\`
```

### 6.3 Script outline for `configure-tmux.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$CURRENT_DIR/.." && pwd)"
SNIPPET_PATH="$PLUGIN_ROOT/scripts/show-notification.sh"

# --- Functions ---
find_tmux_conf()        # Returns path to tmux.conf (existing or default)
is_already_configured() # grep for show-notification.sh in file
has_status_left()       # grep for status-left setting in file
backup_file()           # Timestamped backup to ~/.config/tclux/backups/
inject_snippet()        # Case B (append) or Case C (prepend into existing)
suggest_settings()      # Check status-interval, status-left-length, bell

# --- Main ---
main() {
    # 1. Verify show-notification.sh exists
    # 2. Find tmux.conf
    # 3. Check if already configured → exit early
    # 4. Backup
    # 5. Detect status-left state
    # 6. Apply modification (Case A, B, or C)
    # 7. Reload tmux config
    # 8. Print summary with rollback instructions
    # 9. Suggest additional settings
}

main "$@"
```

### 6.4 Key implementation decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Path expansion | Hardcode absolute path at setup time | `$CLAUDE_PLUGIN_ROOT` is not available at tmux.conf parse time |
| Injection position | Prepend to status-left value | Notifications should be the first thing visible |
| Backup location | `~/.config/tclux/backups/` | Persistent, namespaced, doesn't pollute tmux config dir |
| Modification tool | `sed` with OS detection | Available everywhere, handles in-place edits, macOS/Linux compat |
| Marker comments | `# --- tclux: ...` / `# --- end tclux ---` | Enables clean uninstall/re-run detection |
| Idempotency | grep for `show-notification.sh` | Simple, reliable, covers both case B and C injections |
| Single script | `configure-tmux.sh` | Keeps all logic in one place; setup.md just calls validate + configure |

### 6.5 Testing considerations

The `configure-tmux.sh` script should support a `--dry-run` flag that prints what it would do without modifying any files. This enables safe testing:

```bash
./configure-tmux.sh --dry-run
# Would modify: /Users/you/.tmux.conf
# Would backup to: ~/.config/tclux/backups/tmux.conf.20260211_143022
# Would change: set -g status-left " #S "
# To:           set -g status-left "#{E:#(/path/to/show-notification.sh)}  #S "
```

---

## 7. Sequence Diagram

```
User runs /tclux:setup
       │
       ▼
  validate-setup.sh  ──→  Prints pass/fail for 10 checks
       │
       ▼
  configure-tmux.sh
       │
       ├── find_tmux_conf()
       │     └── ~/.tmux.conf or ~/.config/tmux/tmux.conf
       │
       ├── is_already_configured()?
       │     └── YES → "Already configured" → exit
       │
       ├── backup_file()
       │     └── cp to ~/.config/tclux/backups/tmux.conf.<timestamp>
       │
       ├── has_status_left()?
       │     ├── NO tmux.conf  → Case A: create file with snippet
       │     ├── NO status-left → Case B: append section with markers
       │     └── YES           → Case C: sed prepend into existing value
       │
       ├── tmux source-file
       │
       └── Print summary + rollback instructions
```
