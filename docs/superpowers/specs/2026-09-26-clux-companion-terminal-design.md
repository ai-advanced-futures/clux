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

- `split` mode: `tmux split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" -e PATH="$PATH" -e CLUX_TERMINAL_D="$D" <shell>`. `-d` keeps the focus on Claude. The split goes below Claude (`-v`), with the default size `-l 30%`. `--size N%` maps to `-l N%`. [inferred]
- `socket` mode: `tmux -S "$D/sock" -f /dev/null new-session -d -s clux-terminal -e ... <shell>`. `open` prints the attach command: `tmux -S "$D/sock" attach`. `-f /dev/null` stops the private server from loading the user's tmux.conf. Thus the private server runs no clux plugin and no session bar. [inferred]
- The minimum tmux version is 3.2, because `split-window -e` and `new-session -e` need it. `open` reads `tmux -V`, compares the version, and exits 2 with a message on an older version. [inferred]
- A socket path has a limit of about 104 bytes. `open` exits 2 with a clear message when `$D/sock` is longer than 100 bytes. Tests set a short root, for example `CLUX_TERMINAL_DIR=$(mktemp -d /tmp/ct.XXXX)`. [inferred]
- The pane title is `clux-terminal` (`select-pane -T`).

`rc.bash` must:

1. Set `unset HISTFILE` and `set +o history`, so no command goes to a history file.
2. Set a known prompt, `PS1='clux$ '`, so `wait --idle` can find a return to the prompt. The prompt test is a suffix test, because the output of a command can leave the prompt on the same row as the output. [inferred]
3. Define the wrapper `__clux_run N`. It must be valid in bash 3.2.
4. Not set `umask` at the top of the file. The umask of the pane shell applies to every command Claude and the user run there, so a umask at the top gives mode 0600 to the files of the user's own work. [inferred] The wrapper sets `umask 077` inside the process substitution, where only `tee` runs. [inferred] Thus `<n>.out` gets mode 0600 and no other file changes. [inferred]
5. Define the functions `exit`, `exec` and `logout`. Each function prints `refused: this word closes the companion` and returns 1. [inferred] In bash 3.2 a function with one of these names takes precedence over the builtin, also inside `eval`. [inferred] Thus a word later in the command, for example `echo a; exit`, cannot close the pane shell. [inferred]
6. Define the function `__clux_clear() { printf '\033[2J\033[H'; }`. [inferred] `run` uses this function to clear the screen after a secret run, as section 6 says. [inferred]

The wrapper, in outline:

```bash
__clux_run() {
  local __clux_n="$1" __clux_d="$CLUX_TERMINAL_D" __clux_cmd __clux_rc __clux_i
  __clux_cmd=$(cat "$__clux_d/$__clux_n.cmd")
  printf '$ %s\n' "$__clux_cmd"
  { eval "$__clux_cmd"; } > >(umask 077; tee "$__clux_d/$__clux_n.out"; : > "$__clux_d/$__clux_n.done") 2>&1
  __clux_rc=$?
  __clux_i=0
  while [ ! -e "$__clux_d/$__clux_n.done" ] && [ $__clux_i -lt 20 ]; do sleep 0.05; __clux_i=$((__clux_i+1)); done
  printf '%s\n' "$__clux_rc" > "$__clux_d/$__clux_n.rc.tmp" && mv "$__clux_d/$__clux_n.rc.tmp" "$__clux_d/$__clux_n.rc"
}
```

- `eval` runs in the main shell, not in a pipeline subshell. Thus `cd` and `export` stay.
- `eval` runs in the scope of the function. Thus each wrapper variable has the prefix `__clux_`, so a user command cannot change it. [inferred] With the plain names `n` and `D` the command `for n in 7 8; do echo $n; done` writes `8.rc`, and the command `D=oops; echo hi` writes no `.rc` file at all. [inferred] The wrapper sets `__clux_rc=$?` on the line directly after the eval, before any other command. [inferred]
- `umask 077` is inside the process substitution. Thus only `tee` gets that umask, and `<n>.out` gets mode 0600. [inferred] The umask of the pane shell stays as the user set it. [inferred]
- The process substitution sends the output to the pane and to the file.
- The `tee` process ends after the command. Thus the reader waits for **both** `<n>.rc` and `<n>.done`. Without `<n>.done`, the reader can get a file that is not complete.
- Bash does not wait for the process substitution. Thus the pane shell can print the next prompt before `tee` writes the rest of the output. [inferred] With a large output the prompt then scrolls off the screen, the cursor line is empty, and the prompt test in the section *One run at a time* fails. [inferred] The wrapper polls for `<n>.done` for at most 1 second, so the prompt comes after the output. [inferred] The reader keeps its own 1-second grace for `<n>.done`, because a background process can hold the pipe open. [inferred]
- A command that starts a background process keeps the pipe open. Then `<n>.rc` comes and `<n>.done` does not. [inferred] Thus the reader waits at most 1 second more for `<n>.done` after it finds `<n>.rc`. If `<n>.done` does not come, the reader prints the output it has, adds the note `output may be incomplete: a process still holds the output`, removes the lock, and gives a normal result. [inferred] The skill tells Claude to use `send` for a command that starts a background process. [inferred]
- For `run`, stdout is not a TTY. A command that needs a TTY (ssh, vim, the password entry of `op signin`) must use `send`.

## 5. Verbs

All verbs refuse, with exit code 2 and a message on stderr, when `$TMUX` or `$TMUX_PANE` is not set.
`close --hook` is the one exception. It exits 0 in every case, also outside tmux, and it prints nothing. [inferred]
`check-line` is the other exception. It reads only a line of text, so it needs no tmux. [inferred] It exits 0 or 1 outside tmux, and it does not call `resolve_agent_server_key`. [inferred]
All verbs except `open`, `list`, `check-line` and `close` fail with exit code 4 when no companion is open for this owner. `close` exits 0 when no companion is open. It never exits 4. [inferred]
All time limits use a poll loop (`sleep 0.2`) and a `$SECONDS` deadline. The script does not
use `timeout` or `tmux wait-for`. `timeout` is not on macOS, and `wait-for` has no time limit.

| Verb | Usage | Result |
|---|---|---|
| `open` | `terminal.sh open [--socket] [--size N%]` | Opens the companion, or re-uses the open one. It re-uses the pane only when the pane is alive: it reads `pane` from `state` and asks tmux (`list-panes -a -F '#{pane_id}'` on the user's server, or the same command with `-S "$D/sock"` in socket mode). When the pane is gone, `open` deletes `$D` and opens a new companion. [inferred] The screen is empty for about 0.4 seconds after tmux makes the pane. Thus `open` polls for the prompt with the test in the section *One run at a time*, with a limit of 5 seconds, before it prints `pane=<id>`. [inferred] On a time-out `open` closes the pane, deletes `$D`, prints a message, and exits 1. [inferred] First removes the private directories of owner panes that are gone (a reaper, like the one in `agent-state.sh`). Prints `pane=<id>`, `mode=<m>`, and in socket mode `attach=<cmd>`. |
| `run` | `terminal.sh run [--secret] [--timeout S] [--max-lines N] -- <command…>` | Clears the screen and the history first when the last run was secret, as section 6 says. [inferred] Joins the words after `--` with one space and writes the result unchanged to `<n>.cmd`. The pane shell parses that text. Thus the user sees the full command on the Bash tool line, and the skill tells Claude to pass the command as one single-quoted string. [inferred] Sends only `__clux_run <n>` and Enter. Prints `run=<n>` as its first line, so Claude knows the number for `wait --run N`. [inferred] Waits for `<n>.rc` and `<n>.done`. Prints the output (at most `--max-lines`, default 200, with a note when it cuts lines), then the line `exit=<rc>`. Deletes `<n>.out`. Before it starts, it also deletes each `*.out` of an earlier completed run. [inferred] Exits 0 when the run completed, whatever the exit code of the command. The default time limit is 100 seconds. [inferred] The Claude Code Bash tool stops a command after 120 seconds, so the limit of `run` must stay below that value. Claude then gets the output and `exit=<rc>`, and not a tool time-out. [inferred] It refuses a command whose first word is `exit`, `exec`, `logout` or `return`, with exit code 2, because that word closes the pane or leaves the wrapper. [inferred] `return` inside the command leaves the wrapper before it writes `<n>.rc`, so the run never completes. [inferred] This test is only the fast path. The functions in `rc.bash` stop the same words later in the command. [inferred] |
| `send` | `terminal.sh send [--enter] [--key NAME] [--] <text>` | Sends text with `send-keys -l`, or one named key with `--key` (for example `C-c`, `Up`). `--enter` sends Enter after the text. Before it sends, it checks the screen. On a credential prompt it sends nothing and exits 3. There is no flag to skip this check. |
| `read` | `terminal.sh read [--lines N]` | Prints the screen with `capture-pane -p -J -S -N` (default 50). Refuses, with exit code 3, when the screen shows a credential prompt. It also refuses while the highest run number has a `<n>.secret` marker, complete or not. [inferred] The next plain `run` lifts this block when it clears the screen and the history, as section 6 says. [inferred] It removes the lock when it finds `<n>.rc`, but it never deletes `<n>.out`. [inferred] |
| `wait` | `terminal.sh wait [--timeout S] (--idle \| --pattern RE \| --run N)` | Waits for the prompt on the cursor line, with the test in the section *One run at a time* [inferred], for a pattern, or for run `n` to complete. Exit 0 on a match, 1 on timeout, 3 on a credential prompt. `--pattern RE` tests the visible screen (`capture-pane -p -J` of the pane) with `grep -E`. [inferred] `--pattern` refuses with exit code 3 under the same rule as `read`: the highest run number has a `<n>.secret` marker, complete or not. [inferred] `--idle` and `--pattern` both do the credential check before each poll, and both exit 3 on a match. [inferred] `--idle` has no secret-run block, because it tests only for `clux$`. [inferred] Only `--run N` skips the credential check, and only when `<n>.secret` is present, as section 6 says. [inferred] `--run N` gives the same result as a completed `run`: the output, cut to `--max-lines`, then the line `exit=<rc>`. It then deletes `<n>.out` and removes the lock. The default time limit is 60 seconds. [inferred] |
| `close` | `terminal.sh close [--hook] [--owner PANE]` | `clear-history`, then `kill-pane` (split) or `kill-server` on the private socket. Deletes `$D`. Silent when nothing is open, and it exits 0. The default owner is `$TMUX_PANE` of the calling process, as `agent-state.sh` does. The hook calls `close --hook` and passes no `--owner`. With `--hook` the verb prints nothing and exits 0 in every case, also outside tmux and also with no companion. [inferred] |
| `list` | `terminal.sh list` | Prints one line for each open companion on this machine: owner key, mode, pane, and the state `alive`, `gone` or `foreign`. A key of another tmux server gives `foreign`. [inferred] |
| `check-line` | `terminal.sh check-line [--patterns FILE] -- <line>` | A hidden verb for the tests. It applies the pattern list, rule 2 and rule 3 of section 6 to one line of text. [inferred] `--patterns FILE` uses FILE in place of the shipped list and in place of the tmux option, so a test can isolate the filter. [inferred] It exits 0 on a credential prompt, and 1 on no credential prompt. It does not call tmux, so it also works outside tmux. [inferred] |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | The verb completed. For `run`, read `exit=<rc>` for the result of the command. |
| 1 | The time limit ended. The run continues in the pane. Use `wait --run N` or `read`. |
| 2 | The script cannot operate: not inside tmux, a bad argument, or tmux is missing. |
| 3 | A credential prompt is in the pane. The user must answer it in the pane. |
| 4 | No companion is open for this owner. `close` never gives this code. [inferred] |
| 5 | Busy: a run is not complete, or the pane is not at the prompt. [inferred] Use `wait`, `send` or `read`. |

### One run at a time

`run` makes the lock directory `$D/busy` with `mkdir`. When the lock is present and the
last run has no `<n>.rc`, `run` fails with exit code 5. `run` removes the lock when it
reads the result. When `run` ends on its time limit, the lock stays. The next `wait --run N`
or `read` that finds `<n>.rc` removes it.

Before it sends, `run` also requires that the pane is at the prompt. The test has three steps. [inferred] It takes the cursor line with the capture in section 6. [inferred] It removes the trailing spaces. [inferred] It tests that the result ends with `clux$`, with `case "$t" in *'clux$') ;; *) not at the prompt ;; esac`. [inferred] The test is a suffix test, and not a full-line comparison, because a command whose output has no final newline leaves the prompt on the same row as the output, for example `hiclux$ `. [inferred] `printf`, `echo -n`, a progress meter and `cat` of a file with no final newline all give such a row. [inferred] The suffix test still refuses `clux$ ls`, a line that the user typed, and `Password:`, a prompt of a program. [inferred] The test removes the trailing spaces first, because `capture-pane` without `-J` removes the trailing spaces and `-J` keeps them. [inferred] This is the same test that `wait --idle` uses, and `open` uses it too. [inferred] When the pane is not at the prompt,
`run` exits 5 with the message `the pane is not at the prompt: use wait --idle, send or read`.
This rule stops `run` from typing into a program that `send` started, and into a line that the
user typed. [inferred]

## 6. Credential prompts

- The pattern list is in `plugins/clux/config/credential-patterns.txt`, one extended regex on each line, case-insensitive. Comments start with `#`. The first list is:
  `passw(or)?d`, `pass ?phrase`, `passcode`, `\bpin\b`, `\botp\b`, `one-time`, `verification code`, `2fa`, `mfa`, `\btoken\b`, `secret`, `private key`, `enter .*key`, `sudo\]`, `authenticat(e|ion)[^a-z]*$`, `security code`, `api key`, `access key`, `credential`, `yubikey`, `touch id`, `enter .*code`. [inferred] `passw(or)?d` also matches `Passwd:`. `pass ?phrase` also matches `Enter pass phrase for server.pem:`. `\btoken\b` matches `Token (will be hidden):`, and rule 2 keeps `token: null` out. `access key` matches `AWS Access Key ID [None]:`. [inferred]
- The script removes comments and blank lines from both pattern files with the rule in the manifest header (`deploy-manifest.txt:12-13`): `grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'`. It gives the result to `grep -E -i -f`. A blank pattern makes GNU grep match every line, so the script must remove it. [inferred]
- The script ignores a user pattern file that is absent, or that it cannot read. It prints no message. It reads the option `@clux-terminal-patterns` from the user's server (`$TMUX`), never from the private socket. [inferred]
- The check reads the cursor line, and not the last non-empty line. [inferred] The script takes the cursor row with `cy=$(tmux display-message -p -t "$pane" '#{cursor_y}')`, then reads the line with `tmux capture-pane -p -J -t "$pane" -S 0 -E "$cy" | tail -n 1`. [inferred] The row index of `#{cursor_y}` counts each screen row, but `-J` joins the rows of one wrapped line. Thus the script must cut the capture at `$cy` and take the last line. [inferred] That line holds the full prompt text, also when the prompt is longer than the pane width. [inferred] `run`, `wait`, `send` and `read` all use this same capture. [inferred]
- The echo line `$ <command>` needs no rule of its own. While a command runs, the cursor is on the row below the echo line. [inferred]
- A match counts as a credential prompt only when these three rules are also true. [inferred] A false match is not harmless: it marks the run secret and discards the output. [inferred]
  1. The cursor is on the line. The capture above gives that line, so the script makes no other test. [inferred] A program that waits for input keeps the cursor on the prompt line. An output line that scrolled has a new line after it. [inferred]
  2. The line ends with a prompt terminator: `:`, `?` or `]`, with spaces after it or with none. [inferred] The script removes the trailing spaces with `t=$(printf '%s' "$l" | sed 's/[[:space:]]*$//')`, then tests `case "$t" in *:|*\?|*\]) ;; *) no match ;; esac`. [inferred] Do not write the test as `[[ "$l" =~ [:?\]][[:space:]]*$ ]]`. That form matches nothing in bash 3.2. [inferred]
  3. The line does not end with a yes/no choice. [inferred] Section 2 decides that Claude answers plain prompts, so a yes/no question is not a credential prompt, also when the text holds a keyword. [inferred] After the trailing spaces are removed the script tests `case "$t" in *'[y/N]'|*'[Y/n]'|*'[y/n]'|*'(y/n)'|*'(yes/no)'|*'[y/N]:'|*'[Y/n]:'|*'(y/n)?'|*'(yes/no)?') no match ;; esac`. [inferred] These exclusions are in the same file as the pattern list, marked as exclusions. [inferred] The user can add more exclusions there. [inferred]
- `wait --run n` does not do the credential check when run `n` already has a `<n>.secret` marker. [inferred] It waits until `<n>.rc` and `<n>.done` are present, or until its time limit, and then prints only `exit=<rc>`. [inferred] Thus Claude can wait while the user types the credential in the pane. [inferred] `run` keeps the check, because `run` is the call that marks the run secret. [inferred]
- `run` and `wait` do the check in each poll step while the run is not complete. On a match, they stop and exit with code 3. They print: `credential prompt in the companion pane: the user must answer it there`. They do not print the screen. In each poll step they first test `<n>.rc` and `<n>.done`. They do the credential check only when the run is not complete. Thus a command that completes with a matching cursor line keeps its output. [inferred]
- When a run had a credential match, the script marks it as secret (`<n>.secret`). When the run completes, `run` and `wait --run` return only `exit=<rc>` and delete `<n>.out`. The output after a password prompt can contain a token.
- `--secret` on `run` has the same result from the start.
- `read` refuses (exit code 3) when the check matches.
- `wait --pattern` refuses (exit code 3) under the same secret-run rule as `read`, because a pattern answer can give a secret one character at a time. [inferred]
- A secret run leaves the secret text on the screen. `read` and `wait --pattern` could then give that text to Claude. [inferred] Thus the next plain `run` clears the screen and the history before it sends `__clux_run <n>`. [inferred] It does these five steps in this order: [inferred]
  1. The lock test and the prompt test of section 5. [inferred] This step comes first, so the clear line never goes into a program that `send` started. [inferred]
  2. Send `__clux_clear` and Enter. [inferred]
  3. Wait for the prompt test, with a limit of 5 seconds. [inferred]
  4. Run `tmux clear-history -t <pane>`. [inferred]
  5. Send `__clux_run <n>` and Enter. [inferred]
- The script does not send the key `C-l` to clear the screen. [inferred] In bash 3.2 in a tmux pane that key goes into the readline buffer as the literal text `^L`. [inferred] The screen keeps the secret, and the next line `__clux_run <n>` comes after the `^L`, so the run never starts. [inferred]
- `clear-history` comes last, because tmux copies the visible screen into the history when a program clears the screen. [inferred] A `clear-history` before the screen clear leaves the secret in the history, and `read` gives it back through `capture-pane -S -50`. [inferred]
- `read` and `wait --pattern` stay refused until that plain run has started. [inferred] The pane shows the secret until that moment, as the decision in section 2 permits. [inferred]
- The skill body tells Claude: on exit code 3, tell the user to type in the pane, then use `wait --run N`. Never type into a credential prompt.
- The user can add patterns in a file set by `@clux-terminal-patterns` (a tmux option). The shipped list always applies.

## 7. Session end

- `hooks.json` gets a third command in `SessionEnd`: `${CLAUDE_PLUGIN_ROOT}/scripts/terminal.sh close --hook`. This is the only hook form. The hook passes no `--owner`. [inferred]
- In hook mode the script reads and discards stdin, writes nothing to stdout or stderr, and always exits 0. This follows the rule in the header of `agent-state.sh`. A detached `claude agents` session runs the hook with no `TMUX` and no `TMUX_PANE`. The hook then does nothing and exits 0. [inferred]
- `SessionEnd` also occurs on `/clear`, because `/clear` ends one session and starts a new one. `close --hook` closes the companion on every reason, `clear` included. One companion belongs to one session id, and the private directory holds output of the old session. The skill tells Claude to warn the user before `/clear`. [inferred]
- `SessionEnd` does not always occur (for example, when the terminal is killed). Thus `open` also runs the reaper: it deletes the private directory of each owner pane that is gone from the server, and closes its companion pane.
- The owner key has three fields, and the key validator of the state store (`_clux_valid_server_key`, `path.sh:79-84`) refuses a name with two dashes. [inferred] Thus the reaper must split the directory name first: server key is `${base%-*}`, owner pane is `${base##*-}`, and server pid is `${base%%-*}`. [inferred] It gives only the server part to `_clux_valid_server_key`, and then applies the two rules below. [inferred] A reaper that gives the full name to the validator skips every companion directory, and it does no work and prints no error. [inferred]
- The reaper does nothing when `tmux list-panes -a` gives an empty listing. [inferred] It returns at once, as the state store does (`path.sh:136-137`). [inferred] This guard is load-bearing: a missing server or a failed `list-panes` call gives an empty listing, and without the guard the reaper treats every owner pane as gone and closes every live companion. [inferred]
- The reaper and `list` use the two rules of the state store (`path.sh:184-199`), because `list-panes` answers only for the current server. For a directory with the key of this server, the owner pane is gone when `list-panes -a` does not show it. For a directory with a foreign server key, the directory is gone only when `kill -0` on the server pid in the key fails. The reaper kills only companion panes on this server, and private sockets under gone directories. It never touches a live foreign companion. [inferred]

## 8. Skill

`plugins/clux/skills/terminal/SKILL.md`, written with `superpowers:writing-skills`, in ASD-STE100.
The body carries Snippet S1 from `configuring-tmux/SKILL.md`, which resolves `PLUGIN_ROOT` in three tiers, and it tells Claude to call `$PLUGIN_ROOT/scripts/terminal.sh`. [inferred] The skill needs this snippet because the harness sets `CLAUDE_PLUGIN_ROOT` for a hook process always, but for a command or subagent Bash call only sometimes. [inferred] The hook form in section 7 uses `${CLAUDE_PLUGIN_ROOT}` directly, because the harness always sets it for a hook. [inferred]
The body tells Claude:

- when to use `run` and when to use `send` + `read`;
- how to read each exit code;
- to never type into a credential prompt;
- to use `--secret` when the output can contain a secret;
- to pass the command to `run` as one single-quoted string, because the script joins the words after `--` with one space; [inferred]
- to read `run=<n>` from the first line, and to use `wait --run <n>` after exit code 1 or exit code 3; [inferred]
- to use `send` for a command that starts a background process; [inferred]
- to set the Bash tool `timeout` parameter to more than S seconds each time it gives `--timeout S` with S above 100; [inferred]
- that `read` gives exit code 3 after a secret run, until the next plain `run` completes; [inferred]
- to warn the user before `/clear`, because `/clear` closes the companion; [inferred]
- that other skills opt in by name (`clux:terminal`) and depend on clux.

## 9. Repository changes

- `plugins/clux/scripts/terminal.sh` (new). It runs from `CLAUDE_PLUGIN_ROOT` and is not deployed. Thus add it to the not-deployed list in `test/deploy-manifest.bats` and to the note in the manifest header. Do not add it to `deploy-manifest.txt`. Rename the list `SETUP_ONLY` to `NOT_DEPLOYED`, because terminal.sh runs at Claude time and not at setup time. Re-word the comment in `test/deploy-manifest.bats` and the note in `deploy-manifest.txt` to "runs from the plugin tree, never from ~/.config/clux/scripts". [inferred]
- `plugins/clux/config/credential-patterns.txt` (new).
- `plugins/clux/skills/terminal/SKILL.md` (new).
- `plugins/clux/hooks/hooks.json`: the `SessionEnd` line.
- `plugins/clux/.claude-plugin/plugin.json`: version 3.9.0.
- `CHANGELOG.md`: a `[3.9.0]` section in the voice of the file.
- `CONTRIBUTING.md`: the new files in the plugin tree. Add these three lines: `scripts/terminal.sh`, `config/credential-patterns.txt` and `skills/terminal/SKILL.md`. `test/docs-tree.bats` compares every `scripts/*.sh` with this tree, so the line for terminal.sh is necessary. [inferred]
- `/clux:validate` (`commands/validate.md`): check the new `SessionEnd` command. Grep for the exact string `terminal.sh close --hook`. [inferred]

## 10. Tests

- `test/terminal.bats`: argument parsing, the refusal outside tmux, exit codes, and the credential-pattern match. Use the tmux stub where a real server is not necessary. The committed stub prints nothing, so `resolve_agent_server_key` gives an empty key. Thus terminal.bats covers only argument parsing, exit 2 outside tmux, the pattern filter, the credential match on a text fixture, and the `umask 077` word inside the process substitution of the wrapper. Every verb that needs a key runs in terminal-e2e.bats on the real server, or with a stub that answers `display-message` with `1234-1700000000` (the pattern in `e2e-agent-lifecycle.bats:19-40`). [inferred]
- `test/terminal.bats` also covers the credential rules. These lines must NOT match: `Do you want to save the token? [y/N]`, `Overwrite secret? [y/N]:`, `Are you sure you want to continue connecting (yes/no/[fingerprint])?`, `$ op read op://v/i/password`, `Authenticated successfully`, `Authentication failed`, `token: null`, `client_secret: x`, `MFA enabled: false`, `Press enter to continue, any key`, `Logged in to github.com as user (Token: gho_****)`. These lines MUST match: `Password:`, `Enter passphrase for key '/id_ed25519':`, `Enter code:`, `Enter your security code?`, `[sudo] password for user:`, `Token (will be hidden):`, `Enter pass phrase for server.pem:`, `Passwd:`, `AWS Access Key ID [None]:`. [inferred] `check-line --patterns FILE` with a file that holds one blank line and one comment line gives exit 1 for `Password:`. [inferred] The same verb with a file that holds `passw(or)?d` gives exit 0 for `Password:`. [inferred] The test gives each line to `terminal.sh check-line`, which needs no pane. [inferred] Rule 1 of section 6 (the cursor line) has cover only in `terminal-e2e.bats` test 8. [inferred] Rule 3 (the yes/no exclusion) has cover in the MUST NOT list. [inferred] One more unit case gives the reaper a directory with the name `<pid>-<start>-<pane>`, and shows that the reaper reads the server key from the first two fields. [inferred] That case needs a stub that answers `display-message` with `1234-1700000000` and `list-panes` with `1234-1700000000 %0`, because the reaper returns at once on an empty listing. [inferred] The case makes two directories, `1234-1700000000-0` (the reaper keeps it) and `1234-1700000000-9` (the reaper removes it). [inferred]
- `test/terminal-e2e.bats`: a real throwaway server, `tmux -S "$BATS_TEST_TMPDIR/sock"`, with a fake `TMUX` and `TMUX_PANE`. Use the pattern in `test/render-clux-conf.bats`. Cases:
  1. `open` makes a pane; a second `open` re-uses it.
  2. `run -- echo hi` prints `hi` and `exit=0`; `run -- false` prints `exit=1`. A run with a large output (`run -- 'seq 1 30000'`) followed by `run -- 'echo hi'` must also exit 0, because the pane must be back at the prompt. [inferred]
  3. `run -- 'cd /tmp'` then `run -- 'pwd'` prints `/tmp` (the shell state stays). [inferred]
  4. `run -- 'export X=1'` then `run -- 'echo $X'` prints `1`. The command is in single quotes, so the bats shell does not expand `$X`. [inferred]
  5. The output file is gone after `run`; the modes of `$D` and the files are 0700 and 0600. A file that a command makes in the pane keeps the mode of the user's umask, and not 0600, because the pane shell sets no umask. [inferred] The case makes a file with `touch` in the pane and reads its mode with `stat -f %Lp` (macOS) or `stat -c %a` (Linux). [inferred]
  6. `run --timeout 1 -- 'sleep 5'` exits 1; `wait --timeout 10 --run N` then exits 0. [inferred]
  7. A second `run` while the first is not complete exits 5.
  8. `run -- 'read -s -p "Password: " p'` exits 3 and prints no screen text; `read` exits 3. Then `wait --timeout 5 --run N` exits 1 (the time limit), and not 3. [inferred] Then `tmux send-keys` types a line, and `wait --run N` exits 0 and prints only `exit=0`. [inferred]
  9. `run --secret -- echo token` prints only `exit=0`. After it, `wait --pattern token` exits 3. [inferred]
  10. `send` + `wait --pattern` + `read` work with a small interactive command.
  11. `close` removes the pane and `$D`; `close --hook` with no companion exits 0 with no output.
  12. The reaper removes the directory of a gone owner pane. It keeps the directory of a live foreign server key. [inferred]
  13. Outside tmux (`TMUX` not set), every verb except `close --hook` and `check-line` exits 2. `close --hook` exits 0 with no output. [inferred]
  14. `run -- 'echo token: abc'` prints `token: abc` and `exit=0`, because the completion test comes before the credential check. [inferred]
  15. `run -- 'sleep 3 & echo started'` prints `started` with the incomplete-output note, exits 0, and leaves no lock. [inferred]
  16. After the pane is killed, `open` makes a new companion and `run -- 'echo hi'` works. [inferred]
  17. `run -- 'exit'` exits 2 and the pane stays. `run -- 'echo a; exit'` gets through the first-word test, prints `a`, and the pane stays, because `rc.bash` refuses the word. [inferred]
  18. `run -- 'printf hi'` prints `hi` and `exit=0`. The next `run -- 'echo after'` also exits 0, because the prompt test is a suffix test. [inferred]
  19. After `run --secret -- echo token` and then `run -- true`, `read` exits 0 and its output does not hold `token`. [inferred] `tmux capture-pane -p -S -50` also holds no `token` after `run -- true`. [inferred]
  20. `run -- 'for n in 7 8; do echo $n; done'` prints `7`, `8` and `exit=0`, and the next `run -- 'echo hi'` exits 0. [inferred] `run -- 'D=oops; echo hi'` prints `hi` and `exit=0`. [inferred] `run -- 'return'` exits 2. [inferred]
  21. `send --enter -- 'read -s -p "Password: " p'` then `wait --timeout 5 --idle` exits 3. [inferred]
- `bats test/` must pass in full.

## 11. Out of scope

- A nested attach, or a new window that attaches to the private socket for the user.
- A general rule that sends every Bash command to the companion.
- More than one companion for each Claude Code session.

## Refinement Status

Refinement: ESCALATE round 5 (max rounds reached; round 5 fixes are not yet re-checked by a critic)
