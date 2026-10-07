---
description: Upgrade clux in tmux to the installed plugin version, with the answers of the last setup and no questions
allowed-tools: Bash, AskUserQuestion
---

# clux Upgrade

Upgrade the clux install in tmux to the installed plugin version. Keep each answer of the last `/clux:setup`. Do not ask a question, except where a step below says to ask.

## Snippet U1: find the plugin tree

```bash
ROOT="${CLAUDE_PLUGIN_ROOT:-}"
# Then the plugin cache, then a plain checkout at or below the cwd.
[ -x "$ROOT/scripts/plugin-version.sh" ] || ROOT=$(find "$HOME/.claude/plugins/cache" -maxdepth 5 -type f \
    -path "*/clux/*/scripts/plugin-version.sh" 2>/dev/null | LC_ALL=C sort -V | tail -1)
[ -x "${ROOT%/scripts/plugin-version.sh}/scripts/plugin-version.sh" ] || ROOT=$(find "$PWD" -maxdepth 4 -type f \
    -path "*/plugins/clux/scripts/plugin-version.sh" 2>/dev/null | head -1)
ROOT="${ROOT%/scripts/plugin-version.sh}"
[ -x "$ROOT/scripts/plugin-version.sh" ] || { echo "clux plugin tree not found"; exit 1; }
"$ROOT/scripts/plugin-version.sh"
```

## What to do

1. Run snippet U1. It prints `loaded`, `installed`, `installed_root`, `marketplace`, `latest` and `status`.
2. Do what the `status` line says:
   - **`update-available`:** do not upgrade. Show the installed and the latest version, and give these commands, with `<marketplace>` from the output:

     ```
     $ claude plugin marketplace update <marketplace>
     $ claude plugin update clux@<marketplace>
     ```

     Tell the user to restart Claude Code after the update and then to run `/clux:upgrade` again. Stop.
   - **`restart-needed`:** continue. At the end, tell the user to restart Claude Code, so that the hooks of the new version load.
   - **`unknown`:** continue. Tell the user that the latest version could not be read, so the upgrade uses the installed version.
   - **`current`:** continue.
3. Run the upgrade from the installed tree:

   ```bash
   "<installed_root>/scripts/upgrade-clux.sh"
   ```

4. Act on the exit code:
   - **0:** go to step 5.
   - **3** (`needs-setup`): no `clux.tmux.conf` from setup exists. Tell the user to run `/clux:setup`. Stop.
   - **4** (`missing: --<flag>` lines): the old file has no value for a required answer. Ask only for those answers with AskUserQuestion. Use the options that `/clux:setup` gives for that answer. Then run the script again with the answers after `--`, for example `upgrade-clux.sh -- --editor nvim`.
   - **5 or 6:** the backup is back in place, and tmux is not changed. Show the error output. Stop.
5. Show the result in a short list: the old and the new version, the scripts deployed, the backup path, and each `dropped:` line (a setting that this version removed).
6. If the output has `warn:` lines about the tmux.conf, show them. Ask with AskUserQuestion whether to run `/clux:setup` now to add the missing parts. If the answer is yes, run `/clux:setup`. If not, stop.
7. If the output has `reloaded: no`, tell the user to reload tmux:

   ```
   $ tmux source-file ~/.config/clux/clux.tmux.conf
   ```

8. Give the rollback command, with the backup path from the output:

   ```
   $ cp <backup> ~/.config/clux/clux.tmux.conf && tmux source-file ~/.config/clux/clux.tmux.conf
   ```

Do not edit the user's tmux.conf or `~/.claude/settings.json` in this command. For those changes, use `/clux:setup`.
