---
name: setup
description: Validate tclux integration and show tmux status-left configuration
---

Run the tclux validation script to check that hooks, tmux, and notifications are properly configured.

```bash
$CLAUDE_PLUGIN_ROOT/scripts/validate-setup.sh
```

Then print the status-left snippet the user needs to add to their `tmux.conf`:

```
Add this to your tmux.conf status-left (adjust to fit your theme):

  set -g status-left "#{E:#($CLAUDE_PLUGIN_ROOT/scripts/show-notification.sh)} "

Recommended tmux settings:

  set -g status-interval 1
  set -g monitor-bell on
  set -g bell-action any
```
