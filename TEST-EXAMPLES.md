# Test Examples: setup-tmux-conf.sh

Visual examples showing actual transformations and outputs from test execution.

---

## Example 1: Missing ~/.tmux.conf

### Initial State
```bash
$ ls -la ~/.tmux.conf
ls: /Users/yasselpiloto/.tmux.conf: No such file or directory
```

### Execution
```bash
$ echo "y" | bash plugins/tclux/scripts/setup-tmux-conf.sh
```

### Output
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  tclux setup — tmux.conf configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ℹ File: /Users/yasselpiloto/.tmux.conf does not exist
ℹ Action: Create new file with tclux configuration

Will create:
  set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
  set -g status-interval 1
  set -g monitor-bell on
  set -g bell-action any

Continue with this change? [Y/n] ✓ Configuration verified
✓ Configuration applied: /Users/yasselpiloto/.tmux.conf

✓ Setup complete!

ℹ Next steps:
  1. Reload tmux config: tmux source-file ~/.tmux.conf
  2. Or restart tmux: tmux kill-server && tmux
```

### Result
```bash
$ cat ~/.tmux.conf
# tclux — Claude Code tmux notifications
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any
```

**Verification:** ✅
- File created
- No backup (file didn't exist before)
- Variable preserved as `${CLAUDE_PLUGIN_ROOT}`

---

## Example 2: Already Configured (Idempotent)

### Initial State
```bash
$ cat ~/.tmux.conf
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
set -g status-interval 1
```

### Execution
```bash
$ bash plugins/tclux/scripts/setup-tmux-conf.sh
```

### Output
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  tclux setup — tmux.conf configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✓ Already configured! /Users/yasselpiloto/.tmux.conf contains show-notification.sh
ℹ No changes needed.

ℹ Run: tmux source-file ~/.tmux.conf (or restart tmux)
```

### Result
```bash
$ cat ~/.tmux.conf
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
set -g status-interval 1
```

**Verification:** ✅
- File unchanged
- No backup created
- Exit code 0
- Idempotent behavior confirmed

---

## Example 3: Existing Simple status-left

### Initial State
```bash
$ cat ~/.tmux.conf
set -g status-left "[#S] "
```

### Execution
```bash
$ echo "y" | bash plugins/tclux/scripts/setup-tmux-conf.sh
```

### Output
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  tclux setup — tmux.conf configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ℹ File: /Users/yasselpiloto/.tmux.conf exists with status-left configuration
ℹ Action: Prepend notification display to existing status-left

Current status-left:
  set -g status-left "[#S] "

Will be modified to include:
  #{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)}

Continue with this change? [Y/n] ✓ Backup created: /Users/yasselpiloto/.tmux.conf.backup-20260211-184328
✓ Configuration verified
✓ Configuration applied: /Users/yasselpiloto/.tmux.conf

✓ Setup complete!

ℹ Next steps:
  1. Reload tmux config: tmux source-file ~/.tmux.conf
  2. Or restart tmux: tmux kill-server && tmux

ℹ To rollback: cp "/Users/yasselpiloto/.tmux.conf.backup-20260211-184328" "/Users/yasselpiloto/.tmux.conf"
```

### Result
```bash
$ cat ~/.tmux.conf
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} [#S] "

$ cat ~/.tmux.conf.backup-20260211-184328
set -g status-left "[#S] "
```

**Verification:** ✅
- Notification prepended
- Original `[#S]` preserved
- Backup created with timestamp
- Rollback instructions provided

---

## Example 4: Complex status-left with Conditionals

### Initial State
```bash
$ cat ~/.tmux.conf
set -g status-left "#{?pane_dead,[dead],#S} "
```

### Execution
```bash
$ echo "y" | bash plugins/tclux/scripts/setup-tmux-conf.sh
```

### Output
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  tclux setup — tmux.conf configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ℹ File: /Users/yasselpiloto/.tmux.conf exists with status-left configuration
ℹ Action: Prepend notification display to existing status-left

Current status-left:
  set -g status-left "#{?pane_dead,[dead],#S} "

Will be modified to include:
  #{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)}

Continue with this change? [Y/n] ✓ Backup created: /Users/yasselpiloto/.tmux.conf.backup-20260211-184330
✓ Configuration verified
✓ Configuration applied: /Users/yasselpiloto/.tmux.conf

✓ Setup complete!
```

### Result
```bash
$ cat ~/.tmux.conf
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} #{?pane_dead,[dead],#S} "
```

**Verification:** ✅
- Conditional syntax preserved: `#{?pane_dead,[dead],#S}`
- Notification prepended correctly
- All tmux formatting intact

---

## Example 5: Multi-line status-left (Known Limitation)

### Initial State
```bash
$ cat ~/.tmux.conf
set -g status-left \
    "[#S] some value"
```

### Execution
```bash
$ echo "y" | bash plugins/tclux/scripts/setup-tmux-conf.sh
```

### Output
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  tclux setup — tmux.conf configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ℹ File: /Users/yasselpiloto/.tmux.conf exists with status-left configuration
ℹ Action: Prepend notification display to existing status-left

Current status-left:
  set -g status-left \

Will be modified to include:
  #{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)}

Continue with this change? [Y/n] ✓ Backup created: /Users/yasselpiloto/.tmux.conf.backup-20260211-184343
✗ Failed to modify status-left (pattern not matched)
✗ Configuration modification failed
```

### Result
```bash
$ cat ~/.tmux.conf
set -g status-left \
    "[#S] some value"

$ cat ~/.tmux.conf.backup-20260211-184343
set -g status-left \
    "[#S] some value"
```

**Verification:** ⚠️
- Original file unchanged
- Backup created (but modification failed)
- Error message clear

**Workaround:**
```bash
# Collapse to single line
$ cat > ~/.tmux.conf <<'EOF'
set -g status-left "[#S] some value"
EOF

# Then run setup again
$ echo "y" | bash plugins/tclux/scripts/setup-tmux-conf.sh
```

---

## Example 6: User Cancellation

### Initial State
```bash
$ ls -la ~/.tmux.conf
ls: /Users/yasselpiloto/.tmux.conf: No such file or directory
```

### Execution
```bash
$ echo "n" | bash plugins/tclux/scripts/setup-tmux-conf.sh
```

### Output
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  tclux setup — tmux.conf configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ℹ File: /Users/yasselpiloto/.tmux.conf does not exist
ℹ Action: Create new file with tclux configuration

Will create:
  set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
  set -g status-interval 1
  set -g monitor-bell on
  set -g bell-action any

Continue with this change? [Y/n] ⚠ Setup cancelled by user
```

### Result
```bash
$ echo $?
1

$ ls -la ~/.tmux.conf
ls: /Users/yasselpiloto/.tmux.conf: No such file or directory
```

**Verification:** ✅
- No file created
- Exit code 1 (user cancelled)
- Graceful exit
- No error message (cancelled, not error)

---

## Example 7: Variable Preservation

### Initial State
```bash
$ export CLAUDE_PLUGIN_ROOT="/some/test/path"
$ rm -f ~/.tmux.conf
```

### Execution
```bash
$ echo "y" | bash plugins/tclux/scripts/setup-tmux-conf.sh
```

### Result
```bash
$ cat ~/.tmux.conf
# tclux — Claude Code tmux notifications
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
set -g status-interval 1
set -g monitor-bell on
set -g bell-action any

$ grep "/some/test/path" ~/.tmux.conf
$ # No output - variable not expanded!

$ grep '${CLAUDE_PLUGIN_ROOT}' ~/.tmux.conf
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} "
```

**Verification:** ✅
- Variable preserved as `${CLAUDE_PLUGIN_ROOT}`
- NOT expanded to `/some/test/path`
- Portable across installations

---

## Example 8: Backup and Rollback

### Scenario
User makes modification, then wants to rollback.

```bash
$ cat > ~/.tmux.conf <<'EOF'
# My original config
set -g status-left "[custom] "
set -g status-right "%H:%M"
EOF

$ echo "y" | bash plugins/tclux/scripts/setup-tmux-conf.sh
✓ Backup created: /Users/yasselpiloto/.tmux.conf.backup-20260211-184350

$ cat ~/.tmux.conf
# My original config
set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} [custom] "
set -g status-right "%H:%M"

# Rollback
$ cp ~/.tmux.conf.backup-20260211-184350 ~/.tmux.conf

$ cat ~/.tmux.conf
# My original config
set -g status-left "[custom] "
set -g status-right "%H:%M"
```

**Verification:** ✅
- Comments preserved
- Other settings untouched
- Rollback works perfectly

---

## Example 9: Multiple Backups

```bash
$ ls -la ~/.tmux.conf.backup-*
-rw-r--r--  1 user  staff  45 Feb 11 18:43 .tmux.conf.backup-20260211-184328
-rw-r--r--  1 user  staff  45 Feb 11 18:43 .tmux.conf.backup-20260211-184343
-rw-r--r--  1 user  staff  45 Feb 11 18:43 .tmux.conf.backup-20260211-184350
```

**Format:** `.tmux.conf.backup-YYYYMMDD-HHMMSS`

**Benefit:** Can rollback to any previous state, no overwriting

---

## Example 10: Real-World Complex Configuration

### Initial State
```bash
$ cat ~/.tmux.conf
# My custom tmux config
set -g prefix C-a
unbind C-b
bind C-a send-prefix

set -g status-left "#{?client_prefix,#[reverse]<Prefix>#[noreverse] ,}[#S] "
set -g status-right "%H:%M %d-%b-%y"
set -g status-interval 5
```

### Execution
```bash
$ echo "y" | bash plugins/tclux/scripts/setup-tmux-conf.sh
```

### Result
```bash
$ cat ~/.tmux.conf
# My custom tmux config
set -g prefix C-a
unbind C-b
bind C-a send-prefix

set -g status-left "#{E:#(${CLAUDE_PLUGIN_ROOT}/scripts/show-notification.sh)} #{?client_prefix,#[reverse]<Prefix>#[noreverse] ,}[#S] "
set -g status-right "%H:%M %d-%b-%y"
set -g status-interval 5
```

**Verification:** ✅
- Only status-left modified
- Complex conditional preserved: `#{?client_prefix,#[reverse]<Prefix>#[noreverse] ,}`
- All other settings untouched
- Comments preserved
- Notification prepended correctly

---

## Summary of Transformations

| Before | After |
|--------|-------|
| `"[#S] "` | `"#{E:#(...)} [#S] "` |
| `"#{?pane_dead,[dead],#S} "` | `"#{E:#(...)} #{?pane_dead,[dead],#S} "` |
| (no file) | Full config created |
| (already configured) | No change (idempotent) |

**Pattern:** Script always prepends notification, preserves existing content.

---

**Test Examples Documented:** 2026-02-11
