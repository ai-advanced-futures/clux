# clux companion terminal — design

Date: 2026-09-26. Status: agreed with the user. Target version: 3.9.0 (minor: a new feature).

## 1. Goal

Claude Code runs operating-system commands in a tmux pane that the user can see.
The pane stays open for the full Claude Code session. Other skills (for example
op or ssh) and the user can use it when they need it. The name of this pane is the
**companion**.

The pattern comes from the openclaw 1password skill ("REQUIRED tmux session").
That pattern has these problems. This design must fix all of them:

| Problem in the source pattern | Fix in this design |
|---|---|
| It reads the screen immediately after it sends the keys, so it can read too early. | `run` waits until a result file and a done marker are present. |
| It gets no exit code. | The wrapper writes the exit code to a file. |
| The output comes from the screen, so it contains the prompt and the echoed command. | `run` copies the output to a file. The file contains only the output of the command. |
| The user sees nothing unless they attach to the socket. | The default mode is a split pane in the user's own tmux window. |
| Secrets stay in the scrollback. | `close` clears the history, and the shell keeps no history file. |

## 2. Decisions

These decisions come from the user (2026-09-26).

- **Purpose.** The user watches the commands live. Claude can run interactive commands. The shell state (current directory, exported variables) stays from one command to the next.
- **Pane location.** The user selects one of two modes:
  - `split` (default): a split pane in the user's current tmux window.
  - `socket`: a session on a private tmux server with its own socket.
- **Not inside tmux.** The script refuses to open a companion in both modes when `$TMUX` or `$TMUX_PANE` is not set.
- **Socket server.** Each Claude Code session has its own private server. There is no shared server.
- **Lifetime.** One companion for each Claude Code session. It stays open until `close` or the end of the session.
- **Session end.** A clux `SessionEnd` hook closes the companion. It clears the scrollback, closes the pane (or stops the private server), and deletes the private directory.
- **Results.** There are two kinds:
  - Plain commands (`run`): the exit code, plus the output from a 0600 file in a private directory. The script deletes the file immediately after it reads it.
  - Interactive commands (`send` + `read`): Claude reads the screen.
- **Approval.** The normal Claude Code permission prompt only. The full command text is on the Bash tool line, so the user sees it in the prompt.
- **Prompts.** Claude answers plain prompts (y/N, menus). The user answers credential prompts in the pane.
- **Credential detection.** A list of patterns and keywords (section 6). When the pane shows a credential prompt, the script tells Claude that a credential prompt is in the pane. Claude does not type into the pane and does not get the output.
- **Secret output.** A per-call flag `--secret` stops the output from going back to Claude. The pane can show secrets. The scrollback is cleared on close. No logs are kept.
- **Scope.** Skills opt in. There is no general rule that sends all commands to the companion.
- **Packaging.** A clux skill plus one script. Skills that use it depend on clux.

### Assumed, not confirmed

- The skill name is `clux:terminal` (directory `plugins/clux/skills/terminal/`).
- The script is `plugins/clux/scripts/terminal.sh`, with the verbs `open`, `run`, `send`, `read`, `wait`, `close` and `list`.

## 3. Identity and files

- **Owner key.** `<server-key>-<owner-pane>`. `<server-key>` comes from `resolve_agent_server_key` (`scripts/path.sh`). `<owner-pane>` is `$TMUX_PANE` of the Claude Code process, with the `%` removed. The Bash tool and the `SessionEnd` hook both get `TMUX` and `TMUX_PANE` from Claude Code.
- **Root directory.** `${CLUX_TERMINAL_DIR:-${TMPDIR:-/tmp}/clux-terminal-$(id -u)}`, mode 0700.
- **Private directory `$D`.** `<root>/<owner-key>`, mode 0700, made with `umask 077`. It contains:
  - `state`: `mode`, `pane` (target pane id), `socket` (socket mode only), `seq`.
  - `rc.bash`: the rc file for the pane shell.
  - `<n>.cmd`: the command for run `n`.
  - `<n>.out`: the output of run `n` (0600).
  - `<n>.done`: an empty marker. The `tee` process writes it after it closes `<n>.out`.
  - `<n>.rc`: the exit code of run `n`.
  - `<n>.secret`: an empty marker for a run with `--secret`.
  - `busy`: a lock directory (`mkdir`), present while a run is not complete.
  - `sock`: the private socket (socket mode only).

## 4. The pane shell

`open` starts the pane with `bash --rcfile "$D/rc.bash" -i`. The pane always uses bash,
also when the user's login shell is zsh. This gives one known wrapper syntax.

- `split` mode: `tmux split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" -e PATH="$PATH" -e CLUX_TERMINAL_D="$D" <shell>`. `-d` keeps the focus on Claude.
- `socket` mode: `tmux -S "$D/sock" new-session -d -s clux-terminal -e ... <shell>`. `open` prints the attach command: `tmux -S "$D/sock" attach`.
- The pane title is `clux-terminal` (`select-pane -T`).

`rc.bash` must:

1. Set `unset HISTFILE` and `set +o history`, so no command goes to a history file.
2. Set a known prompt, `PS1='clux$ '`, so `wait --idle` can find a return to the prompt.
3. Define the wrapper `__clux_run N`. It must be valid in bash 3.2.

The wrapper, in outline:

```bash
__clux_run() {
  local n="$1" D="$CLUX_TERMINAL_D" cmd
  cmd=$(cat "$D/$n.cmd")
  printf '$ %s\n' "$cmd"
  { eval "$cmd"; } > >(tee "$D/$n.out"; : > "$D/$n.done") 2>&1
  local rc=$?
  printf '%s\n' "$rc" > "$D/$n.rc.tmp" && mv "$D/$n.rc.tmp" "$D/$n.rc"
}
```

- `eval` runs in the main shell, not in a pipeline subshell. Thus `cd` and `export` stay.
- The process substitution sends the output to the pane and to the file.
- The `tee` process ends after the command. Thus the reader waits for **both** `<n>.rc` and `<n>.done`. Without `<n>.done`, the reader can get a file that is not complete.
- For `run`, stdout is not a TTY. A command that needs a TTY (ssh, vim, the password entry of `op signin`) must use `send`.

## 5. Verbs

All verbs refuse, with exit code 2 and a message on stderr, when `$TMUX` or `$TMUX_PANE` is not set.
All verbs except `open` and `list` fail with exit code 4 when no companion is open for this owner.
All time limits use a poll loop (`sleep 0.2`) and a `$SECONDS` deadline. The script does not
use `timeout` or `tmux wait-for`. `timeout` is not on macOS, and `wait-for` has no time limit.

| Verb | Usage | Result |
|---|---|---|
| `open` | `terminal.sh open [--socket] [--size N%]` | Opens the companion, or re-uses the open one. First removes the private directories of owner panes that are gone (a reaper, like the one in `agent-state.sh`). Prints `pane=<id>`, `mode=<m>`, and in socket mode `attach=<cmd>`. |
| `run` | `terminal.sh run [--secret] [--timeout S] [--max-lines N] -- <command…>` | Writes the command to `<n>.cmd` and sends only `__clux_run <n>` and Enter. Waits for `<n>.rc` and `<n>.done`. Prints the output (at most `--max-lines`, default 200, with a note when it cuts lines), then the line `exit=<rc>`. Deletes `<n>.out`. Exits 0 when the run completed, whatever the exit code of the command. |
| `send` | `terminal.sh send [--enter] [--key NAME] [--] <text>` | Sends text with `send-keys -l`, or one named key with `--key` (for example `C-c`, `Up`). `--enter` sends Enter after the text. Before it sends, it checks the screen. On a credential prompt it sends nothing and exits 3. There is no flag to skip this check. |
| `read` | `terminal.sh read [--lines N]` | Prints the screen with `capture-pane -p -J -S -N` (default 50). Refuses, with exit code 3, when the screen shows a credential prompt or the current run has `--secret`. |
| `wait` | `terminal.sh wait [--timeout S] (--idle \| --pattern RE \| --run N)` | Waits for the prompt `clux$ ` on the last line, for a pattern, or for run `n` to complete. Exit 0 on a match, 1 on timeout, 3 on a credential prompt. |
| `close` | `terminal.sh close [--owner PANE]` | `clear-history`, then `kill-pane` (split) or `kill-server` on the private socket. Deletes `$D`. Silent when nothing is open. The hook calls it with `--owner "$TMUX_PANE"`. |
| `list` | `terminal.sh list` | Prints one line for each open companion on this machine: owner key, mode, pane, alive or gone. |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | The verb completed. For `run`, read `exit=<rc>` for the result of the command. |
| 1 | The time limit ended. The run continues in the pane. Use `wait --run N` or `read`. |
| 2 | The script cannot operate: not inside tmux, a bad argument, or tmux is missing. |
| 3 | A credential prompt is in the pane. The user must answer it in the pane. |
| 4 | No companion is open for this owner. |
| 5 | Busy: a run is not complete. Use `wait`, `send` or `read`. |

### One run at a time

`run` makes the lock directory `$D/busy` with `mkdir`. When the lock is present and the
last run has no `<n>.rc`, `run` fails with exit code 5. `run` removes the lock when it
reads the result. When `run` ends on its time limit, the lock stays. The next `wait --run N`
or `read` that finds `<n>.rc` removes it.

## 6. Credential prompts

- The pattern list is in `plugins/clux/config/credential-patterns.txt`, one extended regex on each line, case-insensitive. Comments start with `#`. The first list is:
  `password`, `passphrase`, `passcode`, `\bpin\b`, `\botp\b`, `one-time`, `verification code`, `2fa`, `mfa`, `token:`, `secret`, `private key`, `enter .*key`, `sudo\]`, `authenticat`.
- The check reads the last non-empty line of `capture-pane -p -J -S -5` and compares it with the list.
- `run` and `wait` do the check in each poll step while the run is not complete. On a match, they stop and exit with code 3. They print: `credential prompt in the companion pane: the user must answer it there`. They do not print the screen.
- When a run had a credential match, the script marks it as secret (`<n>.secret`). When the run completes, `run` and `wait --run` return only `exit=<rc>` and delete `<n>.out`. The output after a password prompt can contain a token.
- `--secret` on `run` has the same result from the start.
- `read` refuses (exit code 3) when the check matches.
- The skill body tells Claude: on exit code 3, tell the user to type in the pane, then use `wait --run N`. Never type into a credential prompt.
- The user can add patterns in a file set by `@clux-terminal-patterns` (a tmux option). The shipped list always applies.

## 7. Session end

- `hooks.json` gets a third command in `SessionEnd`: `${CLAUDE_PLUGIN_ROOT}/scripts/terminal.sh close --hook`.
- In hook mode the script reads and discards stdin, writes nothing to stdout or stderr, and always exits 0. This follows the rule in the header of `agent-state.sh`.
- `SessionEnd` does not always occur (for example, when the terminal is killed). Thus `open` also runs the reaper: it deletes the private directory of each owner pane that is gone from the server, and closes its companion pane.

## 8. Skill

`plugins/clux/skills/terminal/SKILL.md`, written with `superpowers:writing-skills`, in ASD-STE100.
The body tells Claude:

- when to use `run` and when to use `send` + `read`;
- how to read each exit code;
- to never type into a credential prompt;
- to use `--secret` when the output can contain a secret;
- that other skills opt in by name (`clux:terminal`) and depend on clux.

## 9. Repository changes

- `plugins/clux/scripts/terminal.sh` (new). It runs from `CLAUDE_PLUGIN_ROOT` and is not deployed. Thus add it to the not-deployed list in `test/deploy-manifest.bats` and to the note in the manifest header. Do not add it to `deploy-manifest.txt`.
- `plugins/clux/config/credential-patterns.txt` (new).
- `plugins/clux/skills/terminal/SKILL.md` (new).
- `plugins/clux/hooks/hooks.json`: the `SessionEnd` line.
- `plugins/clux/.claude-plugin/plugin.json`: version 3.9.0.
- `CHANGELOG.md`: a `[3.9.0]` section in the voice of the file.
- `CONTRIBUTING.md`: the new files in the plugin tree.
- `/clux:validate` (`commands/validate.md`): check the new `SessionEnd` command.

## 10. Tests

- `test/terminal.bats`: argument parsing, the refusal outside tmux, exit codes, and the credential-pattern match. Use the tmux stub where a real server is not necessary.
- `test/terminal-e2e.bats`: a real throwaway server, `tmux -S "$BATS_TEST_TMPDIR/sock"`, with a fake `TMUX` and `TMUX_PANE`. Use the pattern in `test/render-clux-conf.bats`. Cases:
  1. `open` makes a pane; a second `open` re-uses it.
  2. `run -- echo hi` prints `hi` and `exit=0`; `run -- false` prints `exit=1`.
  3. `run -- cd /tmp` then `run -- pwd` prints `/tmp` (the shell state stays).
  4. `run -- export X=1` then `run -- echo $X` prints `1`.
  5. The output file is gone after `run`; the modes of `$D` and the files are 0700 and 0600.
  6. `run --timeout 1 -- sleep 5` exits 1; `wait --run N` then exits 0.
  7. A second `run` while the first is not complete exits 5.
  8. `run -- 'read -s -p "Password: " p'` exits 3 and prints no screen text; `read` exits 3.
  9. `run --secret -- echo token` prints only `exit=0`.
  10. `send` + `wait --pattern` + `read` work with a small interactive command.
  11. `close` removes the pane and `$D`; `close --hook` with no companion exits 0 with no output.
  12. The reaper removes the directory of a gone owner pane.
  13. Outside tmux (`TMUX` not set), every verb exits 2.
- `bats test/` must pass in full.

## 11. Out of scope

- A nested attach, or a new window that attaches to the private socket for the user.
- A general rule that sends every Bash command to the companion.
- More than one companion for each Claude Code session.
