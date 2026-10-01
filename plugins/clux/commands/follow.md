---
description: Mirror mode — make all tmux clients show the same session (on, off, status)
argument-hint: "[on|off|status]"
allowed-tools: Bash, AskUserQuestion
---

# clux Follow: Mirror Mode

Mirror mode makes all clients of the tmux server show the same session. When one client changes session, the others go with it.

The argument is: `$ARGUMENTS`

## Snippet F1: find the script

Use the deployed copy first. Its path does not change when the plugin updates, and the tmux hook keeps the path of the copy that set it.

```bash
FOLLOW="$HOME/.config/clux/scripts/session-follow.sh"
[ -x "$FOLLOW" ] || FOLLOW="${CLAUDE_PLUGIN_ROOT:-}/scripts/session-follow.sh"
[ -x "$FOLLOW" ] || FOLLOW=$(find "$HOME/.claude/plugins/cache" "$HOME/.tmux/plugins" -maxdepth 6 -type f \
    -name session-follow.sh -path "*clux*" 2>/dev/null | LC_ALL=C sort -V | tail -1)
[ -x "$FOLLOW" ] || { echo "session-follow.sh not found: run /clux:setup"; exit 1; }
```

## What to do

1. If tmux has no server (`tmux list-sessions` fails), say so and stop.
2. If the argument is `on`, `off` or `status`, run `"$FOLLOW" <argument>` and go to step 5.
3. With no argument, run `"$FOLLOW" status` and show its output: the state, the sessions and the clients.
4. Ask with AskUserQuestion: turn mirror mode on, turn it off, or leave it. Offer the change of state first (if it is off, offer "Turn on" first). Run `"$FOLLOW" on` or `"$FOLLOW" off` for the answer.
5. Show the output of the script. If mirror mode is now on, add these two lines:
   - A session change in any client moves all the others.
   - Mirror mode stops when the tmux server stops. Run `/clux:follow on` again after a restart.

Do not change `tmux.conf`. Do not set a tmux option. The script sets and removes one hook, `client-session-changed[92]`, and that hook is the full state.
