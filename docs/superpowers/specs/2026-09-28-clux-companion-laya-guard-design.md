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
- The English checkpoint reads at most 512 tokens. It cuts the text after 512 tokens with no error. The answer gives the real count in `usage.input_tokens`. That count is the sum over the question rows: one row for each question, each with the question text and the state, each cut at 512 (`agent.py`). Measured: one state with the two output-block questions gives 83 = 46 + 37.
- Laya can only detect. It cannot remove or change text.
- Measured risk results: `rm -rf ~/dev` destructive 0.85; `git push --force origin main` 0.79; `curl … | sudo bash` 0.94; `ls -la ~/dev` 0.33 and `caution` (a false positive).

### Measured secret detection (2026-09-28, question: "Does the text contain a password, API key, token, private key or other credential?")

| Input | Result |
|---|---|
| One `ls -la` line | about 30 tokens. 20 lines are 512 tokens: the text is cut. |
| 20 `ls -la` lines + an AWS key at the end | 0.877, the same as with no key. The key was cut off. |
| 8 or 12 `ls -la` lines, key first or last | 1.0 |
| 8 or 12 `ls -la` lines, no key | 0.90 (block false positive) |
| 12 `git log --stat` lines, no key / key last | 0.001 / 0.70 |
| 20 `git log --stat` lines, no key | 1.0 (block false positive) |
| 7 secret lines alone (AWS, `ghp_`, `password:`, URL with password, `xoxb-`, PEM start, PEM body) | 0.79 to 1.00 |
| 40 clean lines alone (`ls -la`, `git log`) | 3 above 0.75: two `ls -la` lines (0.84, 0.85) and `commit <sha>` (1.00) |
| `hunter2` alone / after the line `Password:` | 0.18 / 0.97 |

Conclusions for section 8:

- Blocks must be sized by the real token count, not by a character estimate.
- The block check finds secrets well, but it flags many clean blocks. It decides only which lines get the line check. It is not a filter that makes Laya calls fewer in the usual case.
- The line threshold is 0.75, because 0.8 misses a URL with a password (0.79).
- The line check needs the line above as context.

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
| `config/laya/secret-values.txt` (new) | Regular expressions for secret values. An extra layer of the output guard (section 8). |
| `config/laya/not-secret.txt` (new) | Regular expressions for line shapes that are never secret (section 15). |

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
- A user copy in `$XDG_CONFIG_HOME/clux/laya/<name>.json` replaces the shipped file of the same name. This is a replace rule, not the add rule that `credential-patterns.txt` uses in 3.9.0. [inferred] The three `.txt` files (`safe-commands.txt`, `secret-values.txt`, `not-secret.txt`) have no user copy. [inferred] Only the shipped `.txt` files apply. [inferred]

## 5. The client

`laya_client.py` runs with the Python of the clux venv. When `CLUX_LAYA_PYTHON` is set, `terminal.sh` runs the client with that Python instead. [inferred] The venv path (overridable by `XDG_DATA_HOME`) is otherwise used only to start `laya-serve` and for the "installed" checks in `open` and `laya status`. [inferred] It never writes terminal text to stderr or to a log. Its stderr has only fixed error messages.

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
- At most 16 requests run at one time (a thread pool). This agrees with the server limit `LAYA_MAX_CONCURRENT`. After a 503 the client tries one time more. It waits for the `Retry-After` time of the server (1 s from `laya-serve`), and never more than 1 s.
- The `output` subcommand has a total time limit of 15 s. When the limit ends, the client exits 1. This 15 s limit is a placeholder. [inferred] Section 8 gives the full time budget and the 120 s bound it must fit. [inferred]

## 6. Laya server lifecycle

### With `CLUX_LAYA_URL`

- clux tests that the host is a loopback host. If not, `open` refuses with exit code 6.
- clux calls `health`. If it fails, `open` refuses with exit code 6.
- clux never starts or stops this server. `CLUX_LAYA_KEY` can hold its API key.
- After the pane is made, `open` writes `laya_url` to `state`. [inferred] It writes `laya_key` too, when `CLUX_LAYA_KEY` is set. [inferred] It does not write `laya_pid`, so `close` knows the server is external. [inferred]

### Without `CLUX_LAYA_URL`

`open` does these steps:

1. It finds the venv. If there is no venv, it refuses with exit code 6 and the message `laya not installed: run terminal.sh laya install`. Here "no venv" means the marker file that install step 2 below writes is absent, even when the venv directory exists. [inferred] It also checks that the English checkpoint is in the Hugging Face cache. [inferred] When the checkpoint is missing, it refuses in the same way. [inferred] The check is one call from the venv Python to `huggingface_hub.try_to_load_from_cache` with `repo_id="convaiinnovations/laya"` and `filename="model.safetensors"` — the top-level checkpoint file in the snapshot, not `multilingual/model.safetensors` or `typed-decisions/model.safetensors` (checked on this machine, 2026-09-28). [inferred] Because the check is a `huggingface_hub` call, it resolves the cache root the way that library does: `HF_HUB_CACHE` when set, otherwise `$HF_HOME/hub`, otherwise the default `~/.cache/huggingface/hub`. [inferred] `install` step 2 and `laya status` use this same check, so "installed" in one place always agrees with the other two. [inferred]
2. It makes `$D`. [inferred]
3. It selects a free port on `127.0.0.1` and makes a random API key (32 bytes from `/dev/urandom`, in hex).
4. It starts `laya-serve` in the background with: `LAYA_HOST=127.0.0.1`, `LAYA_PORT=<port>`, `LAYA_API_KEY=<key>`, `LAYA_LOG_LEVEL=warning`, `LAYA_MODELS=english`, `HF_HUB_OFFLINE=1`, `USE_TF=0`. stdout and stderr go to `$D/laya.log` (0600).
5. It makes the pane. [inferred]
6. It writes `laya_pid`, `laya_url` and `laya_key` to `state` in one call, together with the pane, mode, socket and seq fields (the file is 0600). [inferred] `laya_url` is `http://127.0.0.1:<port>`. [inferred] `write_state` and `state_load` carry these three fields on every rewrite and every read. [inferred]
7. It calls `health` each 0.5 s for at most 60 s. Then it sends one warm-up request, because the first call takes about 1.4 s.
8. If a step fails after the pane exists, `open` stops the server, closes the pane, and deletes `$D`, then exits 6. [inferred] If a step fails before the pane exists, `open` stops the server when it started one, and deletes `$D`, then exits 6. [inferred]

Each Claude Code session has its own server. Each server uses about 1–2 GB of memory.

### Stop

- `close` and `close --hook` stop the server with `kill <laya_pid>`, then `kill -9` after 3 s. They delete `$D/laya.log` with `$D`.
- clux stops only a process whose pid is in `state` and whose command line contains `laya-serve`. This prevents a kill of a new process that has the same pid.
- The reaper (3.9.0) also stops the server of an owner pane that is gone.

### Who owns the server

When `laya_pid` is in `state`, `open` started the server, and `close` stops it. When `laya_pid` is not in `state`, the server is external (`CLUX_LAYA_URL`), and clux does not stop it. The later verbs read the URL and the key from `state`, not from the environment, so that all verbs of one companion use the same server.

### When the server stops during a session

Each verb that needs Laya calls the client. When the client exits 1, the verb fails with exit code 6 and the message `laya not available: close and open the companion`. clux does not restart the server itself.

### Install

`terminal.sh laya install` does these steps. It is the only step that uses the network. It does not call `require_tmux`. [inferred] `terminal.sh laya status` does not call `require_tmux` either. [inferred]

1. It finds `python3` version 3.10 or later. If there is none, it exits 2.
2. When the venv already exists and the English checkpoint is already in the Hugging Face cache (the check named in step 1 of "Without `CLUX_LAYA_URL`" above), it prints the installed version and exits 0. [inferred] It does not reinstall. [inferred] When the venv exists but the checkpoint is missing, it skips venv creation and pip, and goes to step 3. [inferred] Otherwise it makes the venv and runs `pip install laya==0.3.21` inside the same 540 s budget as step 3. The `timeout` command is not in the macOS base system, so step 2 does not use it. [inferred] The venv Python starts `pip install laya==0.3.21` with `subprocess.run(..., timeout=<seconds-left>)`. [inferred] `<seconds-left>` is what remains of the 540 s after step 1. [inferred] The helper exits 124 when the time ends, and with the `pip` exit code otherwise. [inferred] When `pip install` fails or the budget ends during `pip install`, it deletes the partial venv, prints the `pip` error (or the time-out), and exits 1. [inferred] When `pip install` succeeds, it writes a marker file inside the venv. [inferred] "The venv exists" in this step, in `open` step 1 (Without `CLUX_LAYA_URL`), and in `laya status` means this marker file is present, not only that the venv directory exists, so a verb end during `pip install` (for example the Bash tool's own `timeout` at 600000 ms) leaves a venv the next run treats as not yet installed, and step 2 runs again instead of going straight to step 3 with a broken venv. [inferred]
3. It downloads the English checkpoint to the Hugging Face cache with one call to the model. This call starts `laya-serve` on a free loopback port with the same environment as `open` step 4, but without `HF_HUB_OFFLINE=1`, and with `laya-serve` stdout and stderr sent to a temp file instead of `$D/laya.log` (no companion `$D` exists yet during install). [inferred] The whole install verb has a total time budget of 540 s, measured from the start of step 1, so that steps 1 and 2 (venv creation and `pip install laya==0.3.21` with PyTorch) leave time for step 3 inside the 600000 ms Bash tool `timeout` of section 11. [inferred] It polls `health` every 0.5 s for the time left in that 540 s budget, then stops that server. [inferred] When the 540 s budget is already used up at the start of step 3 (for example after a `pip install` that used the full budget), step 3 does not start `laya-serve` at all; it goes straight to the failure path below. [inferred] A trap on the install verb stops the install `laya-serve` and deletes the temp file if the Bash tool ends the verb at its `timeout`. [inferred] The download fails when the 540 s budget ends, or when the `laya-serve` process exits before `health` succeeds. [inferred] When the download fails, it prints the failure and the last part of the temp file with any line that matches `secret-values.txt` removed, deletes the temp file, stops the server if it is still running, and exits 1. [inferred] The venv stays, so a retry skips venv creation and pip in step 2, and reaches step 3 again. [inferred]
4. It prints the venv path and the disk space used.

`terminal.sh laya status` prints the venv path, the installed version, and the state of the server of this companion. It uses the same checkpoint-cache check as `open` step 1 to report whether the checkpoint is present. [inferred]

## 7. Command gate

The gate applies to `run` and to each `send`: text with or without `--enter`, and each `--key` except the interrupt keys below. A key goes to the gate because `bind` can make any key end a line. The line is the cursor line plus the new text, so text sent in pieces is examined as one line. This is true in all pane states, not only at the `clux$` prompt. Thus a command typed into `ssh`, `python`, `psql` or another program in the pane also gets the check. `send -- 'text'` refuses with exit code 2 when `text` contains `\n` or `\r`. [inferred] This stops a literal newline from ending a line and skipping the gate. [inferred]

An interrupt key (`send --key C-c`, `C-d`, `C-z`, `C-\` or `Escape`) does not end a line and cannot type a value. It does not go through the Laya pane check, so Claude can stop a command in the pane when Laya is not available. A Laya confirmation in the pane still refuses it with exit code 3.

Text that `send` types with no `--enter` must show on the cursor line within 1 s. When it does not (for example after `stty -echo`), the next gate cannot examine it. Then `send` writes the marker `hidden` and exits 3 with `text that the pane does not show is on the line: send --key C-c first`. While the marker exists, each `send` and `run` refuses with exit code 3. Only `send --key C-c` removes it, because C-c discards the line. [inferred] A `bind` that makes a key type hidden text is outside this check; the gate examines the `bind` command itself.

For `send`, the state that goes to Laya is:

- `line`: the full input line. At the `clux$` prompt this is the text after `clux$ ` on the cursor line, plus the new text. Thus a command that Claude types in parts gets the same check as a command in one part. In other states (a continuation line, a heredoc, a program prompt) there is no `clux$`, and `line` is the cursor line plus the new text.
- `screen`: the 4 lines above the cursor line, so that Laya knows the program (for example `mysql>` or a `[y/N]` question).

The safe list applies only at the `clux$` prompt.

### Safe list

A command skips Laya only when all of these are true:

- The command's first words equal one full line of `config/laya/safe-commands.txt`, word for word (for example `ls`, `pwd`, `cat`, `head`, `tail`, `wc`, `echo`, `git status`, `git log`, `git diff`). [inferred] `git` alone does not match the `git status` line. [inferred] `git push --force` matches no line. [inferred]
- No word after the matched line starts with `--`. A long option can write a file (`git diff --output=<file>`), so `git log --output=<file>` and `ls --color` go to Laya. Short options (`ls -la`, `git log -3`) do not end the match.
- It is one simple command. It contains none of these: `;` `|` `&` `<` `>` `$` `` ` `` `(` `)` newline.
Thus `ls -la` skips Laya, and `ls $(rm -rf x)` goes to Laya.

The pane shell runs `shopt -u expand_aliases`, so an alias cannot change what a safe-list word runs. `run` writes `<n>.safe` for a safe-list command. For such a run, `__clux_run` checks the first word with `type -t`. When it is not a program or a builtin (for example a function of the same name), the run prints `refused: the first word is an alias or a function in the companion shell` and exits 126. [inferred] The safe list trusts `PATH`; a command that changes `PATH` goes to Laya.

### Levels

The client sends the command to Laya with `config/laya/command.json`. The schema asks:

- `destructive` (boolean): would the command delete data, overwrite files, or change the system in a way that is hard to undo?
- `exposes_secrets` (boolean): would the command show or send secrets or credentials?
- `remote_effect` (boolean): would the command change a remote system (push, deploy, publish, send data out)?
- `risk` (enum `safe`, `caution`, `dangerous`).

The client gives `dangerous` when one boolean is above its threshold (default 0.8) or `risk` is `dangerous`. It gives `caution` when `risk` is `caution`. Otherwise it gives `safe`. The `reason` names the highest boolean and its probability.

### What each level does

| Level | `run` | `send` that ends a line |
|---|---|---|
| `safe` | Runs. | Sends. |
| `caution` | Runs. The result gets the line `laya: caution (<reason>)` before `exit=<rc>`. | Sends. stderr gets the same note. |
| `dangerous` | Asks the user in the pane (see below). | Refuses with exit code 6: `laya: dangerous (<reason>): use run, it asks the user`. |
| client fails | Does not run. Exit code 6. | Does not send. Exit code 6. |

### The question in the pane

- `run` writes an empty marker `<n>.confirm` and the reason to `<n>.reason`, then sends `__clux_run <n>` as in 3.9.0.
- In `rc.bash`, `__clux_run` finds `<n>.confirm`. It shows `laya: dangerous (<reason>)`, then the command, then `run? [y/N] `. It reads one line from the terminal.
- Each `<n>.cmd` runs one time. `__clux_run` refuses a run that has no `<n>.cmd` or that has an `<n>.rc`, and it deletes `<n>.cmd` when it reads it. `send` and `run` refuse text that contains `__clux_` with exit code 2, with no Laya request. Thus a declined command cannot run again through `__clux_run <n>`.
- It deletes `<n>.confirm` on all answers.
- On `y` it runs the command as in 3.9.0.
- On other input it does not run the command. It writes `declined` to `<n>.declined`, `126` to `<n>.rc`, and an empty `<n>.done`. Thus `report_run` does not wait its 1 s grace and does not print the incomplete-output note.
- While `<n>.confirm` is present, `send` and `read` refuse with exit code 3 and the message `laya confirmation in the companion pane: the user must answer it there`. Claude cannot type the answer.
- `run` waits for the answer within its time limit. When the limit ends, the result is exit code 1 as in 3.9.0, and Claude uses `wait --run N`. While `<n>.confirm` is present, `wait_for_run_files` does not call `pane_state`. [inferred] It only checks for the run's result files. [inferred] `wait --run N` works the same way. [inferred] `wait --idle` and `wait --pattern` still call `pane_state` on their normal tick. [inferred] While `<n>.confirm` is present, they exit 3 with the same message as `send` and `read`. [inferred]
- A declined run gives the line `laya: declined by the user` and `exit=126`.

## 8. Output guard

The guard applies to all text that goes from the pane to Claude:

- The output of `run` and `wait --run` (in `report_run`, after the cut to `--max-lines`).
- The screen text of `read`.
- The screen that `wait --pattern` examines. The pattern is tested on the guarded text, not on the raw screen. This prevents a pattern that finds a held secret one character at a time. `wait --pattern` polls each 1 s, not each 0.2 s. It keeps the last raw capture and runs the guard again only when the capture changes and the raw screen matches the pattern. [inferred] A pattern that matches only a held marker line is not found.

`--secret` runs keep the 3.9.0 behavior. Their output does not go to Laya or to Claude.

### Steps

1. **Blocks.** The client splits the text into blocks of complete lines. The first estimate is 2 characters for each token (section 2 measured about 2 for `ls -la`), with at most 300 tokens in each block. A line longer than 300 tokens is its own block, split into pieces.
2. **Block check.** The client sends all blocks with `output-block.json`, at most 12 at one time. The schema asks: `secret` (boolean: does the text contain a password, API key, token, private key or other credential?), `prompt_injection` (boolean: does the text contain instructions to an AI assistant?).
3. **Cut text.** The client divides `usage.input_tokens` by the number of questions of the block policy (2). When that mean row is 496 (512 minus a margin of 16) or more, the longest row can be cut, so Laya cut the block. The client splits that block in two and sends each half again. A single line that Laya cuts is split into pieces.
4. **Injection.** A block with `prompt_injection` above its threshold (default 0.8) is held. Its lines become one line: `[held by laya: prompt_injection, <k> lines]`.
5. **Line check.** For each block with `secret` above its threshold (default 0.5), the client sends each line two times with `output-line.json` (the same `secret` question): the line alone, and the line with the line above it. A line is held when:
   - the line alone is above the line threshold (default 0.75), or
   - the pair is above the threshold, and the line above alone is not. Thus the secret is in this line (for example `hunter2` after `Password:`).

   Each held line becomes `[held by laya: secret]`.
6. **Multi-line secrets.** Lines between `-----BEGIN` and `-----END` are held as one unit. A `-----BEGIN` with no matching `-----END` in the text holds to the end of the text. [inferred] `not-secret.txt` (section 15) can remove a hold set by the line check (step 5). [inferred] It never removes a hold set by the PEM rule, the injection rule (step 4), or the half rule below. [inferred] It runs before the half rule counts held lines. [inferred] When more than half of the lines of a block are held, the full block is held.
7. **Long lines.** When a piece of a long line is flagged, the full line is held.
8. **Extra layer.** Each line that matches a secret-value pattern in `config/laya/secret-values.txt` (new) is also held. Examples: `AKIA[0-9A-Z]{16}`, `gh[pousr]_[A-Za-z0-9]{36}`, `xox[abpr]-`, `-----BEGIN [A-Z ]*PRIVATE KEY-----`. The 3.9.0 file `credential-patterns.txt` finds credential prompts, not values, so the guard does not use it. `secret-values.txt` and `not-secret.txt` use Python `re` syntax. [inferred] Only `credential-patterns.txt` stays ERE, read by bash. [inferred]

The block threshold is lower than the line threshold, so that a doubtful block always gets the line check. Section 2 shows that most blocks of usual output go to the line check. Thus the usual cost is about 2 line requests for each line, plus the block requests. 200 lines give about 450 requests. This is an estimate: the plan must measure the real time with 16 requests at one time on MPS, before it sets the guard limit.

### Known false positives

Section 2 found that some clean lines score above 0.75: `commit <sha>` lines and some `ls -la` lines. `config/laya/not-secret.txt` removes these holds (section 15).

### Result

- `run` and `wait --run`: the guarded text, then `laya: held <k> lines` when lines were held, then `exit=<rc>`. The exit code stays 0.
- `read`: the guarded text.
- When the client fails: no output text. The line `output held: laya not available: use wait --run <n> again`, then `exit=<rc>`. The verb exits 6. `<n>.out` stays until the next `run`, so `wait --run <n>` gives the output when Laya answers again. For `read` the verb prints nothing and exits 6.
- The guard gets at most the last 32768 bytes (`LAYA_GUARD_BYTES`), after the cut to `--max-lines`. Then the verb prints `output cut: the last 32768 bytes`. Thus one very long line does not use the full guard limit. A cut can start inside a PEM key: an `-----END` line with no `-----BEGIN` above it holds from the first line.
- The raw text stays visible in the pane for the user.

### Time

The output guard runs inside the time of the verb. The guard limit is 15 s. When the limit ends, all output is held (as when the client fails). The default time limit of `run` goes down from 100 s to 90 s, so that the verb ends before the 120 s limit of the Bash tool. The 15 s guard limit and the 90 s `run` limit are placeholders. [inferred] The plan must set both from a measured time budget. [inferred] That budget must add the gate (5 s, or 11 s with the 503 retry), `wait_for_prompt` (2 s), the clear (5 s), the report grace (1 s), and the guard limit. [inferred] The sum must stay under the 120 s limit of the Bash tool. [inferred] A normal 200-line output that exceeds the guard limit is held in full, the same as a client failure. [inferred]

## 9. Pane state

`credential_on_cursor` becomes `pane_state`. It gives one of `credential`, `yes_no`, `menu`, `pager`, `shell_prompt`, `other`.

- The client gets the cursor line and the 4 lines above it (the prompt `Enter value:` alone is not clear).
- The pane-state input does not go to Claude, so this text needs no output guard.
- The result is `credential` when Laya gives `credential` or the 3.9.0 regular expressions find a credential prompt. terminal.sh applies this rule. [inferred] It calls the existing `line_is_credential` (3.9.0 bash, unchanged) on the cursor line. [inferred] It ORs that result with the client's `state`. [inferred] The client does not read `credential-patterns.txt`. [inferred]
- The test `line_at_prompt` (the suffix `clux$`) stays a plain string test. It does not use Laya, because it is the marker of the clux shell and not a decision about content.
- The wait loops call `pane_state` each fifth tick (each 1 s), as in 3.9.0. `pane_state` keeps the last capture and its answer. When the capture did not change, it sends no request.
- When the client fails in a wait loop, the loop applies `line_is_credential` to the cursor line and continues. After 3 failed probes in a row, the verb exits 6. Thus one slow answer or one 503 does not stop the wait while the command continues.
- The output guard sends at most 12 requests at one time, under `LAYA_MAX_CONCURRENT` (16), so a pane probe gets a server slot while a guard runs.
- [inferred] The capture keeps a blank cursor line. The cursor line is then empty, not the line above it.

`credential` gives exit code 3, as in 3.9.0. The other states are for the skill and for later use. `wait --idle` prints `pane=<state>` when it ends on its time limit, so Claude knows why the pane is not at the prompt.

## 10. Exit codes

The 3.9.0 codes stay. One code is new.

| Code | Meaning |
|---|---|
| 3 | A credential prompt or a Laya confirmation is in the pane. The user must answer it in the pane. |
| 6 | Laya: not installed, not available, refused (`dangerous` on `send`), or output held because Laya did not answer. The message on stderr tells which. The skill uses the message text to select the next step. |

## 11. Skill

`skills/terminal/SKILL.md` gets these changes:

- The companion needs Laya. On exit 6 with `laya not installed`, Claude tells the user and asks to run `terminal.sh laya install`. Claude does not run it before the user agrees. When the user agrees, Claude runs it with a Bash tool `timeout` of 600000 ms, because the install (pip of `laya` with PyTorch, plus the checkpoint download) can exceed the 120 s Bash tool default. [inferred] This timeout leaves margin over the 540 s total install budget of section 6, so the Bash tool's own limit does not cut the install verb short of its own failure path. [inferred]
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

- **Fake server.** `test/fixtures/fake-laya.py` is a small HTTP server with the two endpoints. It gives fixed answers from a JSON file that each test writes. Thus CI does not need the model. `test_helper` sets `CLUX_LAYA_PYTHON` to the venv Python. [inferred] The default path is `~/.local/share/clux/laya/bin/python3`. [inferred] A bats file that calls the client skips its tests when that Python cannot import `laya`. [inferred] The plan captures one real request and response from `laya-serve` 0.3.21 for a `noul` property, a `choice` property, `/health`, and a 503, into `test/fixtures/`. [inferred] `fake-laya.py` and the client tests use these captures as the source of truth for the wire format. [inferred]
- `test/laya-client.bats`:
  1. `command`: the safe list, the simple-command rule (`ls -la` skips, `ls $(rm -rf x)` does not), the three levels, the thresholds.
  2. `output`: one secret line in a block of 20 is held and the other 19 stay; an injection block is held in full; a PEM block is held as one unit; a block with more than half of its lines flagged is held in full; a long line is held in full.
  3. `pane`: the six states.
  4. The fake server gives 503, then 200: the client tries one time more and gives the result.
  5. No server, a time-out, bad JSON: the client exits 1 and prints no input text to stdout or stderr.
  6. Terminal text never goes to stderr (a test sends a unique marker and greps stderr).
  7. A block that the fake server answers with `input_tokens` 512 for each row is split and sent again. A block with 300 for each row (600 in total) is not split. The fake server gives the sum over the rows, as `laya-serve` does.
  8. The pair rule: `hunter2` after `Password:` is held; the line after a held secret line is not held only because of that secret.
  9. `secret-values.txt` holds an `AKIA…` line when the fake server gives 0 for it.
- `test/terminal.bats`: `CLUX_LAYA_URL` with a host that is not loopback gives exit 6; `open` with no venv gives exit 6 and the install message; the regex layer adds `credential` when the client answer is `other` and `line_is_credential` matches. [inferred]
- `test/terminal-e2e.bats` (with the fake server through `CLUX_LAYA_URL`):
  1. A `dangerous` `run`: the pane shows the question; `send` and `read` exit 3; `tmux send-keys y Enter` lets the run complete; `n` gives `exit=126` and `laya: declined by the user`, and after it `send` and `read` work again.
  1a. `send -- 'rm -rf '` then `send --enter -- '/tmp/x'` is checked as one line and refused with exit 6. `send --enter` inside `python3` in the pane is also checked.
  2. A `caution` `run` prints the note before `exit=<rc>`.
  3. `run -- 'printf "a\nAKIA…\nb\n"'` prints `a`, `[held by laya: secret]`, `b`.
  4. `read` and `wait --pattern` use the guarded text.
  5. The fake server stops during a session: the next `run` exits 6 and the command does not run.
  6. `close` stops the server that `open` started (test with a fake `laya-serve` in the venv path) and deletes `laya.log`. This case unsets `CLUX_LAYA_URL`, because `open` does not start a server when that variable is set; `CLUX_LAYA_PYTHON` still names a real Python that can import `laya`, for the client calls. [inferred]
  7. All 3.9.0 e2e cases still pass with the fake server set to "all safe".
- `test/laya-live.bats` (opt-in, `CLUX_LAYA_LIVE=1`): the real model on a list of commands and outputs, to find threshold drift. It is not part of CI.
- `bats test/` must pass in full.

## 14. Out of scope

- A hook on the Bash tool (for commands that do not use the companion).
- One Laya server that all sessions share, or a launchd agent.
- Laya servers that are not on this machine.
- Removal of secrets inside a line (a part of a line). Laya cannot find the position of a secret. The full line is held.
- A restart of the Laya server during a session.

## 15. Decisions made after review

The user started the implementation on 2026-09-28 with no change to the recommendations. Thus:

1. **False positives in the output guard: option (b).** `config/laya/not-secret.txt` (new) holds regular expressions for line shapes that are never secret (for example `^commit [0-9a-f]{40}$` and `ls -l` lines). An anchored pattern matches the full line shape (for example an anchored `ls -l` pattern that allows an `HH:MM` time and a trailing `@`). [inferred] A match by an anchored pattern removes a hold with no character check. [inferred] A match by any other pattern removes a hold only when the line has no `=`, `:` or `@`. A match never removes a hold from `secret-values.txt`. This is the one exception to the rule "regular expressions can only add a hold".
2. **`send` in all pane states,** as section 7 says.
3. **Version 4.0.0.**
