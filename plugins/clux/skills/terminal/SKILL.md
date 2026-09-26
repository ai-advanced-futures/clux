---
name: terminal
description: Use when visible persistent shell state or an interactive TTY is needed. Other skills can opt in as clux:terminal and depend on the clux plugin.
---

# clux companion terminal

Use one companion for the current Claude Code session. It keeps its directory and exported variables.

## Resolve the script

```bash
TERMINAL="${CLAUDE_PLUGIN_ROOT:-}/scripts/terminal.sh"
[ -x "$TERMINAL" ] && echo "TERMINAL=$TERMINAL"
```

When `CLAUDE_PLUGIN_ROOT` is not set, resolve the plugin root with Snippet S1 in
`skills/configuring-tmux/SKILL.md` — that snippet is the only home for the rule.
Refuse when the root stays empty. Do not write a second resolver here.

## Use

- Open the default pane with `"$TERMINAL" open`; use `open --socket` only when requested.
- Run a complete command as `"$TERMINAL" run -- 'command text'`. Read `run=<n>` then `exit=<rc>`.
- On exit 1, run `wait --run <n>`. Use `send`, `read`, and `wait --pattern` for interactive commands.
- Use `send` for a command that starts a background process.
- Never type into a credential prompt. Exit 3 means the user must answer in the pane.
- Use `run --secret -- 'command text'` when output may contain a secret.
- `/clear` closes the companion because it ends the current session.

Other skills opt in by naming `clux:terminal`; each depends on the clux plugin.
