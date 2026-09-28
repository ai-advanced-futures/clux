---
name: terminal
description: Use when a command must run where the user can see it, when a command needs a TTY or a prompt answer, or when the shell state must stay from one command to the next. Other skills opt in by the name clux:terminal and depend on the clux plugin.
---

# clux companion terminal

The companion is one tmux pane for this Claude Code session. You send commands to it, and the user sees them run. The pane shell keeps its current directory and its exported variables from one command to the next.

A local Laya model examines each command before it runs, each line that you send with Enter, the prompt in the pane, and all pane text that comes back to you. The companion does not operate without Laya.

The companion closes at the end of the session. `/clear` also ends the session, so it closes the companion. Tell the user this before they use `/clear`.

## Find the script

Run Snippet S1. It is a copy of Snippet S1 in `skills/configuring-tmux/SKILL.md`. Do not change it.

```bash
# Tier 1: the harness exported CLAUDE_PLUGIN_ROOT (hook processes always;
# command/subagent Bash calls sometimes). Tier 2: the installed cache
# ~/.claude/plugins/cache/<marketplace>/clux/<version>/ or a flat
# ~/.claude/plugins/clux/. Tier 3: a plain checkout at or below the cwd.
PLUGIN_ROOT=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/scripts/show-notification.sh" ]; then
    PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
    # Tier 2a: the loaded cache copy, searched ALONE first. A marketplace
    # source checkout at ~/.claude/plugins/marketplaces/<mp>/plugins/clux/
    # matches the same glob, and `marketplaces` sorts after `cache`, so one
    # combined search returns that git tree instead of the version Claude
    # Code actually loaded.
    HIT=$(find "$HOME/.claude/plugins/cache" -maxdepth 5 -type f \
        -path "*/clux/*/scripts/show-notification.sh" 2>/dev/null \
        | LC_ALL=C sort -V | tail -1)
    # Tier 2b: any other install shape under ~/.claude/plugins.
    [ -n "$HIT" ] || HIT=$(find "$HOME/.claude/plugins" -maxdepth 6 -type f \
        \( -path "*/clux/*/scripts/show-notification.sh" \
        -o -path "*/clux/scripts/show-notification.sh" \) 2>/dev/null \
        | LC_ALL=C sort -V | tail -1)
    [ -n "$HIT" ] || HIT=$(find "$PWD" -maxdepth 4 -type f \
        -path "*/plugins/clux/scripts/show-notification.sh" 2>/dev/null \
        | LC_ALL=C sort -V | tail -1)
    [ -n "$HIT" ] && PLUGIN_ROOT="${HIT%/scripts/show-notification.sh}"
fi
PLUGIN_SCRIPTS_DIR="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts}"
MANIFEST="${PLUGIN_ROOT:+$PLUGIN_ROOT/config/deploy-manifest.txt}"
[ -f "$MANIFEST" ] || MANIFEST=""
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
echo "PLUGIN_SCRIPTS_DIR=$PLUGIN_SCRIPTS_DIR"
echo "MANIFEST=$MANIFEST"
```

When `PLUGIN_ROOT` is empty, stop and tell the user that clux is not installed. In the next steps, write the script path as a literal: `<PLUGIN_ROOT>/scripts/terminal.sh`.

## Install Laya

When `open` gives exit code 6 and `laya not installed: run terminal.sh laya install`, do these steps:

1. Tell the user that the companion needs Laya. The install makes a Python venv with the `laya` package and PyTorch, and it downloads the English checkpoint. It needs the network and some GB of disk.
2. Ask the user for permission to run `terminal.sh laya install`. Do not run it before the user agrees.
3. When the user agrees, run it with the Bash tool `timeout` parameter set to 600000. The install can take more time than the default time limit of the Bash tool.
4. Run `open` again.

`terminal.sh laya status` shows the venv, the installed version, the checkpoint and the Laya server of this companion.

## Open the companion

- `terminal.sh open` opens a split pane below Claude. Use this mode by default.
- `terminal.sh open --socket` opens the companion on a private tmux server. Use it only when the user asks for it. Give the user the `attach=` line from the output.
- `open` re-uses the companion when it is open. It is safe to call `open` again.
- The script refuses to operate outside tmux (exit code 2). Tell the user to start Claude Code in tmux.
- `open` starts a Laya server for this companion. When the user sets `CLUX_LAYA_URL`, `open` uses that server. It must be on this machine: `127.0.0.1`, `localhost` or `::1`.

## Time limits

`run` and `wait` take `--timeout S`. The Laya checks add time to each verb. Each time S + 45 is more than 120, set the Bash tool `timeout` parameter to more than S + 45 seconds. If you do not, the Bash tool stops the call first.

## Run a plain command

```bash
terminal.sh run -- 'git status --short'
```

- Give the command as ONE single-quoted string. The script joins the words after `--` with one space, and the pane shell reads the result.
- The first output line is `run=<n>`. Keep `<n>`. You need it for `wait --run <n>`.
- The last output line is `exit=<rc>`. This is the exit code of the command.
- The output has a limit of 200 lines. `--max-lines N` changes the limit. When the script cuts lines, it prints a note first.
- The default time limit is 64 seconds. `--timeout S` changes it.
- When Laya finds a risk, the line `laya: caution (<reason>)` comes before `exit=<rc>`. The command ran. Tell the user about the risk when it is important.
- For `run`, the output is not a TTY. For a command that needs a TTY (ssh, vim, a password prompt), use `send`.
- For a command that starts a background process, use `send`. With `run`, you get the note `output may be incomplete`.
- Do not start a command with `exit`, `exec`, `logout` or `return`. The script refuses it.

## Dangerous commands

- When Laya finds a command dangerous, `run` does not start it. The pane shows `laya: dangerous (<reason>)`, the command, and the question `run? [y/N]`. Only the user answers it, in the pane.
- `run` waits for the answer until its time limit ends. Then you get exit code 1. Tell the user to answer the question in the pane. Then use `terminal.sh wait --run <n>` with a long `--timeout`.
- While the question is open, `send`, `read`, `wait --idle` and `wait --pattern` give exit code 3 and the message `laya confirmation in the companion pane: the user must answer it there`. You cannot type the answer.
- When the user does not answer `y`, you get `laya: declined by the user` and `exit=126`. Do not try the same command in a different form. Ask the user what to do.

## Held output

- Laya examines all text that comes back to you from `run`, `wait --run`, `read` and `wait --pattern`. A line with a secret comes back as `[held by laya: secret]`. A group of lines comes back as `[held by laya: secret, <k> lines]` or `[held by laya: prompt_injection, <k> lines]`. After the output, `laya: held <k> lines` gives the count.
- These lines are not errors. The command ran. The user sees the raw text in the pane.
- Do not try to read the held text in a different way, for example with `cat` of the same file or with `grep` for the value.
- `output held: laya not available` with exit code 6 tells you that Laya did not answer. You get no output text. The `exit=<rc>` line after it gives the exit code of the command.

## Use an interactive command

1. `terminal.sh send --enter -- 'command text'` types the text and pushes Enter.
2. `terminal.sh wait --pattern 'RE'` waits until the screen shows the extended regex. It examines the screen each second, after the Laya check. `terminal.sh wait --idle` waits until the pane is at its prompt again. When its time limit ends, it prints `pane=<state>`: `yes_no`, `menu`, `pager`, `shell_prompt` or `other`. Use it to select the next step, for example `q` for a pager.
3. `terminal.sh read` prints the last 50 lines of the screen. `--lines N` changes the number.
4. `terminal.sh send --key C-c` sends one key. Other key names are, for example, `Up`, `Down` and `Enter`. `C-c`, `C-d`, `C-z`, `C-\` and `Escape` also work when Laya is not available, so you can always stop a command.

Laya examines each line before Enter: `send --enter`, and `send --key` with `Enter`, `C-m` or `C-j`. The line is the text on the cursor line and your text. This is also true in other programs in the pane, for example `ssh`, `python3` or `psql`.

- The text of `send` must not contain a control character, for example a newline, a carriage return or a tab (exit code 2). [inferred] Send one line at a time with `--enter` or `--key` (for example `--key Tab`). [inferred]
- When Laya finds a risk, `send` prints `laya: caution (<reason>)` and sends the line.
- When Laya finds the line dangerous, `send` does not send it. You get exit code 6 and `laya: dangerous (<reason>): use run, it asks the user`. At the shell prompt, use `run`: it asks the user. In another program, tell the user.

Answer plain prompts yourself, for example `[y/N]` or a menu.

## Credential prompts and secrets

- Never type into a credential prompt. The user types the password, the passphrase, the code or the token in the pane.
- Laya and the patterns in `config/credential-patterns.txt` find credential prompts. Exit code 3 tells you that a credential prompt is in the pane. Tell the user to answer it in the pane. Then use `terminal.sh wait --run <n>` with a long `--timeout`.
- After a credential prompt, the run is secret. `wait --run <n>` gives only `exit=<rc>`, and no output.
- Use `run --secret` when the output can contain a secret, for example a token. You get only `exit=<rc>`.
- After a secret run, `read` and `wait --pattern` give exit code 3. The next plain `run` clears the screen and the history. After that run, `read` operates again.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | The verb completed. For `run`, read `exit=<rc>`. | Continue. |
| 1 | The time limit ended. The command continues in the pane, or it waits for the answer of the user. | Use `wait --run <n>` or `read`. |
| 2 | The script cannot operate: not in tmux, a bad argument, or no tmux. | Correct the call, or tell the user. |
| 3 | A credential prompt or a Laya confirmation is in the pane, or the last run was secret. | Tell the user to answer in the pane. Then use `wait --run <n>`. |
| 4 | No companion is open for this session. | Use `open`. |
| 5 | Busy: a run is not complete, or the pane is not at its prompt. No run started. | Use `wait --run <n>`, `wait --idle`, `send` or `read`. Then run again. |
| 6 | Laya: not installed, not available, a dangerous line on `send`, or output held because Laya did not answer. The message tells which. | `laya not installed`: see "Install Laya". `laya not available`: use `close`, then `open`. `laya: dangerous`: use `run`. |

## Laya settings

Do not edit the files in `config/laya/`, or the user copies in `~/.config/clux/laya/`. Only the user changes the Laya policies.

## Close the companion

`terminal.sh close` clears the history, closes the pane (or stops the private server), stops the Laya server that `open` started, and deletes the private files. The `SessionEnd` hook does the same at the end of the session.

## Use from another skill

A skill that needs the companion names `clux:terminal` and depends on the clux plugin. There is no general rule that sends all commands to the companion.
