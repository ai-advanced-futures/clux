# clux companion terminal: the Laya guard — design

Date: 2026-09-28. Status: written for user review. Target version: 4.0.0 (major: the companion does not operate without Laya).

Base design: `2026-09-26-clux-companion-terminal-design.md` (3.9.0). This document gives only the changes to that design.

## 1. Goal

The companion (`plugins/clux/scripts/terminal.sh`) sends commands from Claude to a tmux pane and gives the results back to Claude.
In 3.9.0, regular expressions make all decisions about the content of the pane.

In 4.0.0 a local Laya model makes these decisions:

1. **Command gate.** Before a command runs, Laya finds its risk.
2. **Output guard.** Before Claude reads output or screen text, Laya finds secrets and prompt injection. clux holds back the lines with secrets and the blocks with injection.
3. **Pane state.** Laya finds the type of prompt on the cursor line (credential, yes/no, menu, pager, shell prompt).

All decisions occur on this machine. The text that Laya examines does not go into the input of Claude Code before the decision is complete.
Claude gets only the result of the decision and the text that the decision lets through.

## 2. What Laya is

These facts come from the laya-local session and from tests on this machine (2026-09-28).

- Laya (`convaiinnovations/laya` on Hugging Face, Apache-2.0) is a local encoder model. It does not write text. It gives probabilities for typed questions about a "state" (text or JSON).
- There are three question types: `noul` (the probability of "true"), `choice` (one label from a list), and `score` (a level on a scale).
- Package: `laya` 0.3.21 on PyPI, Python 3.10 or later. It runs on PyTorch (Apple MPS, CUDA or CPU).
- `laya-serve` is an HTTP server. The endpoints are `GET /health` and `POST /v1/systemone`. There is no batch endpoint.
- Server settings are environment variables: `LAYA_HOST`, `LAYA_PORT`, `LAYA_DEVICE`, `LAYA_MODELS`, `LAYA_API_KEY`, `LAYA_MAX_CONCURRENT` (default 16; more requests at one time get 503), `LAYA_LOG_LEVEL` (default `info`).
- SDK: `laya.LayaDecision(json_schema, base_url=..., api_key=..., return_details=True).invoke(state)` sends one request to the server and gives a `DecisionResult` with the probabilities. The import does not load torch. Measured: 0.12 s for the full process (Python start, import, one request).
- Speed on MPS after the first call: one question about 22–26 ms over HTTP; four questions about 38 ms; an input of about 500 tokens about 160 ms. The first call after a start is about 1.4 s. The load of three checkpoints is about 17 s.
- The English checkpoint reads at most 512 tokens.
- Laya can only detect. It cannot remove or change text.
- Measured risk results: `rm -rf ~/dev` destructive 0.85; `git push --force origin main` 0.79; `curl … | sudo bash` 0.94; `ls -la ~/dev` 0.33 and `caution` (a false positive).

## 3. Decisions

These decisions come from the user (2026-09-28).

- **Scope.** All three uses (section 1) with equal priority.
- **Local only.** All decisions occur on this machine. Nothing that Laya examines goes to Claude before the decision.
- **Where.** Only the companion (`run`, `send`, `read`, `wait`). There is no hook on the Bash tool. Skills continue to opt in.
- **Hard requirement.** When Laya is not available, the companion fails. There is no fallback to the regular expressions only.
- **Start.** clux can install and start Laya locally, after the user confirms.
- **Lifetime.** `open` starts one Laya server for the companion. `close` and the `SessionEnd` hook stop it.
- **External server.** When `CLUX_LAYA_URL` is set, clux uses that server and does not start or stop a server.
- **Risk levels.** Commands on the safe list do not go to Laya. A `caution` command runs, and Claude gets a note. A `dangerous` command runs only after the user types `y` in the pane.
- **Output guard.** clux splits the output into blocks and sends each block to Laya. clux then examines each line of a flagged block, and holds back only the lines that contain secrets.
- **Client.** A small Python client that uses the laya SDK.

### Assumed, not confirmed

- "For flagged blocks review locally" means: the client sends each line of a flagged block to Laya and holds back only the flagged lines. The user does not examine the lines in the pane.
- Prompt injection holds back the full flagged block, not single lines, because injection text usually covers more than one line.
- `CLUX_LAYA_URL` must name a loopback host (`127.0.0.1`, `localhost` or `::1`). clux refuses all other hosts.
- The version is 4.0.0, because the companion does not operate without Laya.
- The install is a separate verb (`terminal.sh laya install`). Claude runs it with the normal Bash permission prompt, so the user sees the full command and confirms it there.
- The venv is `~/.local/share/clux/laya` (`$XDG_DATA_HOME/clux/laya` when that variable is set). It is not in the plugin cache, because a plugin update deletes the cache.
- The regular-expression credential check of 3.9.0 stays as an extra layer. It can only add a hold. It cannot remove a hold that Laya sets.

## 4. Parts

| Part | Purpose |
|---|---|
| `scripts/laya_client.py` (new) | The only code that speaks to Laya. Subcommands: `health`, `command`, `output`, `pane`. Input on stdin. One JSON result on stdout. |
| `scripts/terminal.sh` | Calls the client at each decision point. Fails closed on each client error. Starts and stops the server. New verb `laya`. |
| `config/laya/command.json` (new) | Policy for the command gate. |
| `config/laya/output-block.json` (new) | Policy for a block of output. |
| `config/laya/output-line.json` (new) | Policy for one line of a flagged block. |
| `config/laya/pane.json` (new) | Policy for the prompt type on the cursor line. |
| `config/laya/safe-commands.txt` (new) | The safe list: first words that do not go to Laya. |

### Policy file format

Each policy file is one JSON object:

```json
{
  "schema": { "type": "object", "properties": { "…": {} } },
  "model": "english",
  "thresholds": { "…": 0.8 }
}
```

- `schema` goes to `LayaDecision` unchanged. `enum` becomes `choice`, `boolean` becomes `noul`, and an integer with limits becomes `score`. The `description` of each property is the question.
- `thresholds` are read only by the client.
- Claude does not edit these files. The skill tells Claude not to edit them.
- A user copy in `$XDG_CONFIG_HOME/clux/laya/<name>.json` replaces the shipped file of the same name. This follows the user-pattern rule for `credential-patterns.txt`.

## 5. The client

`laya_client.py` runs with the Python of the clux venv. It never writes terminal text to stderr or to a log. Its stderr has only fixed error messages.

Input: the URL comes from the environment variable `CLUX_LAYA_URL`, and the key from `CLUX_LAYA_KEY`. `terminal.sh` sets both.

| Subcommand | stdin | stdout |
|---|---|---|
| `health` | nothing | `{"ok": true}`, or exit 1 |
| `command` | the command text | `{"level": "safe"\|"caution"\|"dangerous", "reason": "destructive 0.85"}` |
| `output` | the text | `{"text": "<text with held lines replaced>", "held": [{"kind": "secret", "lines": 2}, …]}` |
| `pane` | the cursor line and the 4 lines above it | `{"state": "credential"\|"yes_no"\|"menu"\|"pager"\|"shell_prompt"\|"other"}` |

Exit codes of the client: 0 on a decision; 1 when Laya is not available or gives a bad answer; 2 on bad input. `terminal.sh` treats all codes other than 0 as "Laya not available".

### Limits

- Each request has a time limit of 5 s.
- At most 16 requests run at one time (a thread pool). This agrees with the server limit `LAYA_MAX_CONCURRENT`. After a 503 the client tries one time more, after 0.2 s.
- The `output` subcommand has a total time limit of 15 s. When the limit ends, the client exits 1.

## 6. Laya server lifecycle

### With `CLUX_LAYA_URL`

- clux tests that the host is a loopback host. If not, `open` refuses with exit code 6.
- clux calls `health`. If it fails, `open` refuses with exit code 6.
- clux never starts or stops this server. `CLUX_LAYA_KEY` can hold its API key.

### Without `CLUX_LAYA_URL`

`open` does these steps before it makes the pane:

1. It finds the venv. If there is no venv, it refuses with exit code 6 and the message `laya not installed: run terminal.sh laya install`.
2. It selects a free port on `127.0.0.1` and makes a random API key (32 bytes from `/dev/urandom`, in hex).
3. It starts `laya-serve` in the background with: `LAYA_HOST=127.0.0.1`, `LAYA_PORT=<port>`, `LAYA_API_KEY=<key>`, `LAYA_LOG_LEVEL=warning`, `LAYA_MODELS=english`, `HF_HUB_OFFLINE=1`, `USE_TF=0`. stdout and stderr go to `$D/laya.log` (0600).
4. It writes `laya_pid`, `laya_port` and `laya_key` to `state` (the file is 0600).
5. It calls `health` each 0.5 s for at most 60 s. Then it sends one warm-up request, because the first call takes about 1.4 s.
6. If a step fails, `open` stops the server, deletes `$D`, and exits 6. The pane is not made.

Each Claude Code session has its own server. Each server uses about 1–2 GB of memory.

### Stop

- `close` and `close --hook` stop the server with `kill <laya_pid>`, then `kill -9` after 3 s. They delete `$D/laya.log` with `$D`.
- clux stops only a process whose pid is in `state` and whose command line contains `laya-serve`. This prevents a kill of a new process that has the same pid.
- The reaper (3.9.0) also stops the server of an owner pane that is gone.

### When the server stops during a session

Each verb that needs Laya calls the client. When the client exits 1, the verb fails with exit code 6 and the message `laya not available: close and open the companion`. clux does not restart the server itself.

### Install

`terminal.sh laya install` does these steps. It is the only step that uses the network.

1. It finds `python3` version 3.10 or later. If there is none, it exits 2.
2. It makes the venv and runs `pip install laya==0.3.21`.
3. It downloads the English checkpoint to the Hugging Face cache with one call to the model.
4. It prints the venv path and the disk space used.

`terminal.sh laya status` prints the venv path, the installed version, and the state of the server of this companion.

## 7. Command gate

The gate applies to `run`, and to each `send` that ends a line at the shell prompt: `send --enter` and `send --key Enter` (also `C-m` and `C-j`).
For `send`, the gate examines the full input line: the text after `clux$ ` on the cursor line, plus the new text. Thus a command that Claude types in parts gets the same check as a command in one part.

### Safe list

A command skips Laya only when all of these are true:

- Its first word is on `config/laya/safe-commands.txt` (for example `ls`, `pwd`, `cat`, `head`, `tail`, `wc`, `echo`, `git status`, `git log`, `git diff`).
- It is one simple command. It contains none of these: `;` `|` `&` `<` `>` `$` `` ` `` `(` `)` newline.
- It does not start with `sudo`, `env`, `xargs`, `eval`, `command` or `builtin`.

Thus `ls -la` skips Laya, and `ls $(rm -rf x)` goes to Laya.

### Levels

The client sends the command to Laya with `config/laya/command.json`. The schema asks:

- `destructive` (boolean): would the command delete data, overwrite files, or change the system in a way that is hard to undo?
- `exposes_secrets` (boolean): would the command show or send secrets or credentials?
- `remote_effect` (boolean): would the command change a remote system (push, deploy, publish, send data out)?
- `risk` (enum `safe`, `caution`, `dangerous`).

The client gives `dangerous` when one boolean is above its threshold (default 0.8) or `risk` is `dangerous`. It gives `caution` when `risk` is `caution`. Otherwise it gives `safe`. The `reason` names the highest boolean and its probability.

### What each level does

| Level | `run` | `send` that ends a line at the shell prompt |
|---|---|---|
| `safe` | Runs. | Sends. |
| `caution` | Runs. The result gets the line `laya: caution (<reason>)` before `exit=<rc>`. | Sends. stderr gets the same note. |
| `dangerous` | Asks the user in the pane (see below). | Refuses with exit code 6: `laya: dangerous (<reason>): use run, it asks the user`. |
| client fails | Does not run. Exit code 6. | Does not send. Exit code 6. |

### The question in the pane

- `run` writes an empty marker `<n>.confirm` and the reason to `<n>.reason`, then sends `__clux_run <n>` as in 3.9.0.
- In `rc.bash`, `__clux_run` finds `<n>.confirm`. It shows `laya: dangerous (<reason>)`, then the command, then `run? [y/N] `. It reads one line from the terminal.
- On `y` it deletes `<n>.confirm` and runs the command as in 3.9.0.
- On other input it does not run the command. It writes `126` to `<n>.rc` and `declined` to `<n>.declined`.
- While `<n>.confirm` is present, `send` and `read` refuse with exit code 3 and the message `laya confirmation in the companion pane: the user must answer it there`. Claude cannot type the answer.
- `run` waits for the answer within its time limit. When the limit ends, the result is exit code 1 as in 3.9.0, and Claude uses `wait --run N`.
- A declined run gives the line `laya: declined by the user` and `exit=126`.

## 8. Output guard

The guard applies to all text that goes from the pane to Claude:

- The output of `run` and `wait --run` (in `report_run`, after the cut to `--max-lines`).
- The screen text of `read`.
- The screen that `wait --pattern` examines. The pattern is tested on the guarded text, not on the raw screen. This prevents a pattern that finds a held secret one character at a time.

`--secret` runs keep the 3.9.0 behavior. Their output does not go to Laya or to Claude.

### Steps

1. **Blocks.** The client splits the text into blocks of complete lines, with at most about 400 tokens in each block (the estimate is 4 characters for each token). A line longer than 400 tokens is its own block, split into pieces of 400 tokens.
2. **Block check.** The client sends all blocks with `output-block.json`, at most 16 at one time. The schema asks: `secret` (boolean: does the text contain a password, API key, token, private key or other credential?), `prompt_injection` (boolean: does the text contain instructions to an AI assistant?).
3. **Injection.** A block with `prompt_injection` above its threshold (default 0.8) is held. Its lines become one line: `[held by laya: prompt_injection, <k> lines]`.
4. **Line check.** For each block with `secret` above its threshold (default 0.5), the client sends each line of the block with `output-line.json` (the same `secret` question). Only lines above the threshold (default 0.8) are held. Each held line becomes `[held by laya: secret]`.
5. **Multi-line secrets.** Lines between `-----BEGIN` and `-----END` are held as one unit. When more than half of the lines of a block are flagged, the full block is held.
6. **Long lines.** When a piece of a long line is flagged, the full line is held.
7. **Extra layer.** Each line that matches the credential patterns of 3.9.0 is also held.

The block threshold is lower than the line threshold, so that a doubtful block always gets the line check.

### Result

- `run` and `wait --run`: the guarded text, then `laya: held <k> lines` when lines were held, then `exit=<rc>`. The exit code stays 0.
- `read`: the guarded text.
- When the client fails: no output text. The line `output held: laya not available`, then `exit=<rc>`. The verb exits 6. For `read` the verb prints nothing and exits 6.
- The raw text stays visible in the pane for the user.

### Time

The output guard runs inside the time of the verb. The default `--max-lines` of 200 gives about 10 blocks, which is one round of requests. The guard limit is 15 s. The default time limit of `run` goes down from 100 s to 90 s, so that the verb ends before the 120 s limit of the Bash tool.

## 9. Pane state

`credential_on_cursor` becomes `pane_state`. It gives one of `credential`, `yes_no`, `menu`, `pager`, `shell_prompt`, `other`.

- The client gets the cursor line and the 4 lines above it (the prompt `Enter value:` alone is not clear).
- The pane-state input does not go to Claude, so this text needs no output guard.
- The result is `credential` when Laya gives `credential` or the 3.9.0 regular expressions find a credential prompt.
- The test `line_at_prompt` (the suffix `clux$`) stays a plain string test. It does not use Laya, because it is the marker of the clux shell and not a decision about content.
- The wait loops call `pane_state` each fifth tick (each 1 s), as in 3.9.0.
- When the client fails in a wait loop, the verb exits 6.

`credential` gives exit code 3, as in 3.9.0. The other states are for the skill and for later use. `wait --idle` prints `pane=<state>` when it ends on its time limit, so Claude knows why the pane is not at the prompt.

## 10. Exit codes

The 3.9.0 codes stay. One code is new.

| Code | Meaning |
|---|---|
| 3 | A credential prompt or a Laya confirmation is in the pane. The user must answer it in the pane. |
| 6 | Laya: not installed, not available, refused (`dangerous` on `send`), or output held because Laya did not answer. |

## 11. Skill

`skills/terminal/SKILL.md` gets these changes:

- The companion needs Laya. On exit 6 with `laya not installed`, Claude tells the user and asks to run `terminal.sh laya install`. Claude does not run it before the user agrees.
- On exit 3 with `laya confirmation`, Claude tells the user to answer in the pane, then uses `wait --run N`.
- `[held by laya: …]` lines are not errors. Claude does not try to read the held text by other ways (for example with `cat` of the same file, or with `grep` for the value).
- Claude does not edit the files in `config/laya/`.

## 12. Repository changes

- `plugins/clux/scripts/laya_client.py` (new). It is not deployed. Add it to the not-deployed list in `test/deploy-manifest.bats` and to the note in the manifest header.
- `plugins/clux/config/laya/*.json` and `safe-commands.txt` (new). They are read from `CLAUDE_PLUGIN_ROOT` and are not deployed.
- `plugins/clux/scripts/terminal.sh`: sections 6 to 10.
- `plugins/clux/skills/terminal/SKILL.md`: section 11.
- `plugins/clux/.claude-plugin/plugin.json`: version 4.0.0.
- `CHANGELOG.md`: a `[4.0.0]` section. It names the breaking change: the companion needs Laya.
- `CONTRIBUTING.md`: the new files in the plugin tree.
- `README.md`: the Laya requirement and `terminal.sh laya install`.

## 13. Tests

- **Fake server.** `test/fixtures/fake-laya.py` is a small HTTP server with the two endpoints. It gives fixed answers from a JSON file that each test writes. Thus CI does not need the model.
- `test/laya-client.bats`:
  1. `command`: the safe list, the simple-command rule (`ls -la` skips, `ls $(rm -rf x)` does not), the three levels, the thresholds.
  2. `output`: one secret line in a block of 20 is held and the other 19 stay; an injection block is held in full; a PEM block is held as one unit; a block with more than half of its lines flagged is held in full; a long line is held in full.
  3. `pane`: the six states; the regex layer adds `credential` when Laya gives `other`.
  4. The fake server gives 503, then 200: the client tries one time more and gives the result.
  5. No server, a time-out, bad JSON: the client exits 1 and prints no input text to stdout or stderr.
  6. Terminal text never goes to stderr (a test sends a unique marker and greps stderr).
- `test/terminal.bats`: `CLUX_LAYA_URL` with a host that is not loopback gives exit 6; `open` with no venv gives exit 6 and the install message.
- `test/terminal-e2e.bats` (with the fake server through `CLUX_LAYA_URL`):
  1. A `dangerous` `run`: the pane shows the question; `send` and `read` exit 3; `tmux send-keys y Enter` lets the run complete; `n` gives `exit=126` and `laya: declined by the user`.
  2. A `caution` `run` prints the note before `exit=<rc>`.
  3. `run -- 'printf "a\nAKIA…\nb\n"'` prints `a`, `[held by laya: secret]`, `b`.
  4. `read` and `wait --pattern` use the guarded text.
  5. The fake server stops during a session: the next `run` exits 6 and the command does not run.
  6. `close` stops the server that `open` started (test with a fake `laya-serve` in the venv path) and deletes `laya.log`.
  7. All 3.9.0 e2e cases still pass with the fake server set to "all safe".
- `test/laya-live.bats` (opt-in, `CLUX_LAYA_LIVE=1`): the real model on a list of commands and outputs, to find threshold drift. It is not part of CI.
- `bats test/` must pass in full.

## 14. Out of scope

- A hook on the Bash tool (for commands that do not use the companion).
- One Laya server that all sessions share, or a launchd agent.
- Laya servers that are not on this machine.
- Removal of secrets inside a line (a part of a line). Laya cannot find the position of a secret. The full line is held.
- A restart of the Laya server during a session.
