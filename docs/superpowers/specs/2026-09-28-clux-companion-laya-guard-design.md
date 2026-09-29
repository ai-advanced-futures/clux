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
- **Risk levels.** Each command goes to Laya: there is no safe list (section 7). A `caution` command runs, and Claude gets a note. A `dangerous` command runs only after the user types `y` in the pane.
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
- There is no user copy of a policy or of the two `.txt` files (`secret-values.txt`, `not-secret.txt`). Only the shipped files apply. A command in the companion runs as the user and can write the files of the user, so a copy in `$XDG_CONFIG_HOME/clux/laya/` with a threshold of 2 would turn off the gate or the guard.

## 5. The client

`laya_client.py` runs with the Python of the clux venv. When `CLUX_LAYA_PYTHON` is set, `terminal.sh` runs the client with that Python instead. [inferred] The venv path (overridable by `XDG_DATA_HOME`) is otherwise used only to start `laya-serve` and for the "installed" checks in `open` and `laya status`. [inferred] It never writes terminal text to stderr or to a log. Its stderr has only fixed error messages.

Input: the URL comes from the environment variable `CLUX_LAYA_URL`, and the key from `CLUX_LAYA_KEY`. `terminal.sh` sets both.

| Subcommand | stdin | stdout |
|---|---|---|
| `health` | nothing | `{"ok": true}`, or exit 1 |
| `command` | the command text | `{"level": "safe"\|"caution"\|"dangerous", "reason": "destructive 0.85"}`, or exit 3 when Laya cut the text (see "Cut text" in section 7) |
| `output` | the text | `{"text": "<text with held lines replaced>", "held": [{"kind": "secret", "lines": 2}, …]}` |
| `pane` | the cursor line and the 4 lines above it (exit 3 when Laya cut the text, section 9) | `{"state": "credential"\|"yes_no"\|"menu"\|"pager"\|"shell_prompt"\|"other"}` |

Exit codes of the client: 0 on a decision; 1 when Laya is not available or gives a bad answer; 2 on bad input; 3 when Laya would cut the text; 4 when the server refuses the API key (401 or 403). `terminal.sh` treats all codes other than 0 as "Laya not available", and `open` names the key for code 4.

### Limits

- Each request has a time limit of 5 s.
- At most 16 requests run at one time (a thread pool). This agrees with the server limit `LAYA_MAX_CONCURRENT`. After a 503 the client tries one time more. It waits for the `Retry-After` time of the server (1 s from `laya-serve`), and never more than 1 s.
- The `output` subcommand has a total time limit of 15 s. When the limit ends, the client exits 1. This 15 s limit is a placeholder. [inferred] Section 8 gives the full time budget and the 120 s bound it must fit. [inferred]

## 6. Laya server lifecycle

### With `CLUX_LAYA_URL`

- clux tests that the host is a loopback host. If not, `open` refuses with exit code 6. [inferred] First `open` tests that the client Python (the venv, or `CLUX_LAYA_PYTHON`) can import `laya.structured`; if not, it exits 6 with `laya not installed: run terminal.sh laya install`, also for a server that the user starts. [inferred] terminal.sh uses the check of the client (`laya_client.py check-url`), so the two cannot disagree (for example on `HTTP://`).
- clux calls `health`. If it fails, `open` refuses with exit code 6. `/health` of `laya-serve` does not check the API key, so `open` then sends one pane request. When the server refuses the key, `open` exits 6 with `laya not available: the server at CLUX_LAYA_URL refused CLUX_LAYA_KEY: set the key of that server`. `open` on a live companion with an external server makes the same two checks.
- clux never starts or stops this server. `CLUX_LAYA_KEY` can hold its API key.
- After the pane is made, `open` writes `laya_url` to `state`. [inferred] It writes `laya_key` too, when `CLUX_LAYA_KEY` is set. [inferred] It does not write `laya_pid`, so `close` knows the server is external. [inferred]

### Without `CLUX_LAYA_URL`

`open` does these steps:

1. It finds the venv. If there is no venv, it refuses with exit code 6 and the message `laya not installed: run terminal.sh laya install`. Here "no venv" means the marker file that install step 2 below writes is absent, even when the venv directory exists. [inferred] It also checks that the English checkpoint is in the Hugging Face cache. [inferred] When the checkpoint is missing, it refuses in the same way. [inferred] The check is one call from the venv Python to `huggingface_hub.try_to_load_from_cache` with `repo_id="convaiinnovations/laya"` and `filename="model.safetensors"` — the top-level checkpoint file in the snapshot, not `multilingual/model.safetensors` or `typed-decisions/model.safetensors` (checked on this machine, 2026-09-28). [inferred] Because the check is a `huggingface_hub` call, it resolves the cache root the way that library does: `HF_HUB_CACHE` when set, otherwise `$HF_HOME/hub`, otherwise the default `~/.cache/huggingface/hub`. [inferred] `install` step 2 and `laya status` use this same check, so "installed" in one place always agrees with the other two. [inferred]
2. It makes `$D`. [inferred]
3. It selects a free port on `127.0.0.1` and makes a random API key (32 bytes from `/dev/urandom`, in hex).
4. It starts `laya-serve` in the background with: `LAYA_HOST=127.0.0.1`, `LAYA_PORT=<port>`, `LAYA_API_KEY=<key>`, `LAYA_LOG_LEVEL=warning`, `LAYA_MODELS=english`, `HF_HUB_OFFLINE=1`, `USE_TF=0`. stdout and stderr go to `$D/laya.log` (0600).
   [inferred] When health answers, the process that `open` started must listen on the port (`lsof`, else `ss`). Another local process can take the free port before `laya-serve` does, and it would get the key and the terminal text. When the check fails, `open` stops as if the server did not start. With neither tool, clux cannot make this check.
5. It makes the pane. [inferred]
6. It writes `laya_pid`, `laya_url` and `laya_key` to `state` in one call, together with the pane, mode, socket and seq fields (the file is 0600). [inferred] `laya_url` is `http://127.0.0.1:<port>`. [inferred] `write_state` and `state_load` carry these three fields on every rewrite and every read. [inferred]
7. It calls `health` each 0.5 s for at most 60 s. Then it sends a warm-up request, because the first call takes about 1.4 s. [inferred] The warm-up tries again until the same 60 s end, because on a cold machine the first request can take more than the 5 s request limit. `open` and `laya install` use one start function (with the log path and `HF_HUB_OFFLINE` as parameters) and one health-wait function.
8. If a step fails after the pane exists, `open` stops the server, closes the pane, and deletes `$D`, then exits 6. [inferred] If a step fails before the pane exists, `open` stops the server when it started one, and deletes `$D`, then exits 6. [inferred]

Each Claude Code session has its own server. Each server uses about 1–2 GB of memory.

### Stop

- `close` and `close --hook` first clear the pane history, remove the pane and delete `$D` (with `laya.log` and the key). [inferred] Then they stop the server with `kill <laya_pid>`, then `kill -9` after 3 s. [inferred] `close --hook` does this in a separate process that ignores `HUP` and `TERM` and that the hook does not wait for, because the `SessionEnd` hook has little time and the pid in `$D` is gone.
- clux stops only a process whose pid is in `state` and whose command line contains `laya-serve`. This prevents a kill of a new process that has the same pid.
- The reaper (3.9.0) also stops the server of an owner pane that is gone. [inferred] `open` also stops the server of a dead companion of the same owner (the companion pane closed) before it removes that `$D`. [inferred] It sends `kill` to all such servers first and waits one time (at most 3 s) for all of them, so `open` does not wait 3 s for each one.

### Who owns the server

When `laya_pid` is in `state`, `open` started the server, and `close` stops it. When `laya_pid` is not in `state`, the server is external (`CLUX_LAYA_URL`), and clux does not stop it. The later verbs read the URL and the key from `state`, not from the environment, so that all verbs of one companion use the same server.

### When the server stops during a session

Each verb that needs Laya calls the client. When the client exits 1, the verb fails with exit code 6 and the message `laya not available: close and open the companion`. The verbs do not restart the server. `open` on a live companion does: when `state` has `laya_pid` and `health` fails, `open` stops that process (only when its command line contains `laya-serve`), takes the typing lock and reads `state` again (so no `run` writes `seq` at the same time, and a second `open` does not start a second server), starts a new server with the steps 3, 4 and 7 above, and writes the new `laya_pid`, `laya_url` and `laya_key` to `state` before the warm-up (the client reads the URL and the key from `state`). When the start fails, `open` exits 6 with `laya not available: the server did not start` or `laya not available: the server did not answer`. Thus `open` again is enough. A server that the user started (`CLUX_LAYA_URL`, no `laya_pid`) is not changed: when it does not answer, `open` exits 6 with `laya not available: the server at CLUX_LAYA_URL does not answer`. A companion with no `laya_url` in `state` (clux 3.x opened it, with an old `rc.bash`) gets exit 6 and `laya not available: this companion has no Laya server: use close, then open`.

### Install

`terminal.sh laya install` does these steps. It is the only step that uses the network. [inferred] When the venv and the checkpoint are present, it prints `laya <version> is already installed` first, before it looks for a base `python3` 3.10 or later. It looks for a base `python3` only when the install marker of the venv is absent, so a venv with no checkpoint goes to step 3 with no base `python3`. It does not call `require_tmux`. [inferred] `terminal.sh laya status` does not call `require_tmux` either. [inferred]

1. It finds `python3` version 3.10 or later. If there is none, it exits 2.
2. When the venv already exists and the English checkpoint is already in the Hugging Face cache (the check named in step 1 of "Without `CLUX_LAYA_URL`" above), it prints the installed version and exits 0. [inferred] It does not reinstall. [inferred] When the venv exists but the checkpoint is missing, it skips venv creation and pip, and goes to step 3. [inferred] Otherwise it makes the venv and runs `pip install laya==0.3.21` inside the same 540 s budget as step 3. The `timeout` command is not in the macOS base system, so step 2 does not use it. [inferred] The venv Python starts `pip install laya==0.3.21` with `subprocess.run(..., timeout=<seconds-left>)`. [inferred] `<seconds-left>` is what remains of the 540 s after step 1. [inferred] The helper exits 124 when the time ends, and with the `pip` exit code otherwise. [inferred] When `pip install` fails or the budget ends during `pip install`, it deletes the partial venv, prints the `pip` error (or the time-out), and exits 1. [inferred] When `pip install` succeeds, it writes a marker file inside the venv. [inferred] "The venv exists" in this step, in `open` step 1 (Without `CLUX_LAYA_URL`), and in `laya status` means this marker file is present, not only that the venv directory exists, so a verb end during `pip install` (for example the Bash tool's own `timeout` at 600000 ms) leaves a venv the next run treats as not yet installed, and step 2 runs again instead of going straight to step 3 with a broken venv. [inferred]
3. It downloads the English checkpoint to the Hugging Face cache with one call to the model. This call starts `laya-serve` on a free loopback port with the same environment as `open` step 4, but without `HF_HUB_OFFLINE=1`, and with `laya-serve` stdout and stderr sent to a temp file instead of `$D/laya.log` (no companion `$D` exists yet during install). [inferred] The whole install verb has a total time budget of 540 s, measured from the start of step 1, so that steps 1 and 2 (venv creation and `pip install laya==0.3.21` with PyTorch) leave time for step 3 inside the 600000 ms Bash tool `timeout` of section 11. [inferred] It polls `health` every 0.5 s for the time left in that 540 s budget, then stops that server. [inferred] When the 540 s budget is already used up at the start of step 3 (for example after a `pip install` that used the full budget), step 3 does not start `laya-serve` at all; it goes straight to the failure path below. [inferred] A trap on the install verb stops the install `laya-serve` and deletes the temp file if the Bash tool ends the verb at its `timeout`. [inferred] The download fails when the 540 s budget ends, or when the `laya-serve` process exits before `health` succeeds. [inferred] When the download fails, it prints the failure and the last part of the temp file with any line that matches `secret-values.txt` removed, deletes the temp file, stops the server if it is still running, and exits 1. [inferred] The venv stays, so a retry skips venv creation and pip in step 2, and reaches step 3 again. [inferred]
4. It prints the venv path and the disk space used.

A venv can be present with its marker but not work, for example after an upgrade of the base Python. `install` tests that the venv Python can import `laya.structured`. When it cannot, `install` removes the marker, so step 2 makes the venv again. When `CLUX_LAYA_PYTHON` is set and that Python cannot import `laya`, `install` does not make a venv that `open` would not use: it exits 2 with `CLUX_LAYA_PYTHON cannot import laya: install laya 0.3.21 in that Python, or unset CLUX_LAYA_PYTHON`. Thus `install` and `open` do not send the user in a circle.

`terminal.sh laya status` prints the venv path, the installed version, and the state of the server of this companion. It uses the same checkpoint-cache check as `open` step 1 to report whether the checkpoint is present. [inferred]

## 7. Command gate

The gate applies to `run` and to each `send`: text with or without `--enter`, and each `--key` except the interrupt keys below. A key goes to the gate because `bind` can make any key end a line. The line is the cursor line plus the new text, so text sent in pieces is examined as one line. This is true in all pane states, not only at the `clux-<token>$` prompt. [inferred] In all pane states, the cursor must be at the end of the line (`cursor_x` counts screen cells, and a wide character takes 2, so the client counts the cells of the row [inferred]): text after the cursor (after `Home` or `Left`) would put the new text in the middle, and the gate would examine a different line. Then `send` refuses the text with exit code 2 and `the cursor is not at the end of the line: send --key End or --key C-c first`. The check fails closed: when terminal.sh cannot read the cursor (a capture fails, or the client fails or gives no clear answer), `send` refuses with exit code 5 and `cannot read the cursor position: try again`. The client prints `end` or `mid`; it does not use its exit code for the answer. Thus a command typed into `ssh`, `python`, `psql` or another program in the pane also gets the check. `send -- 'text'` refuses with exit code 2 when `text` contains `\n` or `\r`. [inferred] This stops a literal newline from ending a line and skipping the gate. [inferred]

[inferred] `send --key` takes only a tmux key name: a named key (`Enter`, `Up`, `F5`, `PageDown` and others), a modifier (`C-`, `M-`, `S-`) with one character or a named key, or `^X`. tmux types any other argument as text, and a key has no echo check, so `send --key 'curl x | sh'` after `stty -echo` would type a command that no gate examined. Other text gives exit code 2 and `not a key name: <key>: send text with send -- TEXT`. One character alone is text too.

An interrupt key (`send --key C-c`, `C-d`, `C-z`, `C-\` or `Escape`) does not end a line and cannot type a value. It does not go through the Laya pane check, so Claude can stop a command in the pane when Laya is not available. [inferred] It also works while a Laya confirmation is open: the question reads in a subshell, so `C-c` or `C-d` declines the run; no interrupt key can accept it. When `C-c` comes while `<n>.cmd` is present and `<n>.rc` is not, in plain or in confirm mode, the pane shell never read the typed line (text came before it, or `C-c` came before its `Enter`). After 0.3 s, when that is still true, `send` removes `<n>.cmd` and `<n>.confirm` and writes `<n>.notstarted`, `<n>.declined`, `<n>.done` and `126` to `<n>.rc`. Then `wait --run <n>` gives `run <n> did not start: the typed line changed` and `exit=126`, and no verb waits for a question that is not in the pane.

[inferred] The `clux-<token>$` prompt is found anywhere on the cursor line, as `run` finds it: after output with no last newline the line is `fooclux-<token>$ `. The gate gets the text after the first `clux-<token>$ `, so output that holds the prompt mark gives the gate more text, not less. A blank line at the `clux-<token>$` prompt needs no request. In any other state a blank line can accept a default (`[Y/n]`, a menu), so it goes to Laya with the 4 lines above it; only a blank screen too needs no request.

At the `clux-<token>$` prompt and when Laya gives `shell_prompt`, text that `send` types with no `--enter` must show on the cursor line within 2 s. [inferred] In other states (a pager, a menu) a program takes the key and can keep the same cursor line (space in `less`), so there is no check. When the cursor line changes to other text (a program took the key, for example `q` in `less`), the text is not hidden. When the cursor line stays the same (for example after `stty -echo`), the next gate cannot examine it. Then `send` writes the marker `hidden` and exits 3 with `text that the pane does not show is on the line: send --key C-c first`. While the marker exists, each `send` and `run` refuses with exit code 3. Only `send --key C-c` removes it, because C-c discards the line. [inferred] A `bind` that makes a key type hidden text is outside this check; the gate examines the `bind` command itself.

For `send`, the state that goes to Laya is:

- `line`: the full input line. At the `clux-<token>$` prompt this is the text after `clux-<token>$ ` on the cursor line, plus the new text. Thus a command that Claude types in parts gets the same check as a command in one part. In other states (a continuation line, a heredoc, a program prompt) there is no prompt mark, and `line` is the cursor line plus the new text.
- `screen`: the 4 lines above the cursor line, so that Laya knows the program (for example `mysql>` or a `[y/N]` question). Each screen line keeps only its last 200 characters, as in the pane check. When Laya cuts the line and the screen, the line goes again with an empty screen, so a long screen does not stop a short line. When Laya cuts the line alone, the verb refuses (see Cut text).

### One verb types at a time

`send` and `run` take the typing lock before they read the cursor line, and keep it until they typed. The lock is a symbolic link `$D/typing` to the pid of the verb (`ln -s` makes it or fails, in one step). A lock whose pid is not alive is taken over: the verb moves the link away with `mv` (only one verb gets it), checks that it is still the dead holder, then makes its own link. When a live verb holds it, the verb exits 5 with `another send or run is typing in the pane: try again`. Without the lock, two `send` verbs at one time read the same cursor line, Laya examines each piece alone, and the two pieces make one line that no gate examined. The interrupt keys take no lock. `run` releases the lock when it typed `__clux_run`, not when the command ends. `run` takes the typing lock before the busy lock, so only one `run` at a time decides on the busy lock. After the typing lock, `send` and `run` read the state file again: a run that another verb started before the lock has a new `seq`, and the busy takeover, the number of the new run and the check for an open question (`<seq>.confirm`) must use it.

### The line that the gate examined

The gate can take some seconds. In that time a program can change the cursor line (for example `ssh` shows `Password:`). Thus `send` reads the cursor line again after the gate, just before it types. When the line is not the line that the gate examined, or the capture fails, `send` types nothing and exits 5 with `the line changed while Laya examined it: read, then send again`. [inferred] A program that draws the line again and again (a spinner) gives this refusal each time. [inferred] A short time stays between the second read and the typing; the lock does not close it, because a program in the pane is not a verb.

`run` makes the same check after the gate: the cursor line must be the empty `clux-<token>$` prompt. When the user typed text in the pane while Laya examined the command, or the capture fails, `run` frees the busy lock, types nothing and exits 5 with `the pane is not at an empty prompt: use read, then run again`. `run` then types `C-e` and `C-u` before `__clux_run` (and before `__clux_clear`), so text that comes between this check and the typing is removed and does not join the typed line. `C-u` removes only the text to the left of the cursor, so `C-e` goes to the end of the line first. `rc.bash` sets the emacs keys and binds `C-e` and `C-u`, so a vi mode or other keys in `~/.inputrc` do not change this.

### Cut text

Laya reads at most 512 tokens for each question. When the text is longer, Laya examines only a part of it, and a command such as `echo <400 x's>; rm -rf ~` gets the score of the `echo`. The client divides `usage.input_tokens` by the number of questions of the policy. When that mean is 496 (512 minus a margin of 16) or more, Laya cut the text, and the client exits 3. `send` then exits 2 with `laya: the line is too long to examine: make it shorter`, and `run` exits 2 with `laya: the command is too long to examine: make it shorter`. Nothing is typed.

### What runs in the pane shell

The rule: no line from Claude runs in the pane shell itself. Only these touch the pane shell: the functions of `rc.bash`, the keys that edit the line (below), and the working directory and the exported variables that `__clux_carry` takes back from a subshell. Each line that Claude ends at the `clux-<token>$` prompt runs in a subshell, the same as `run`.

- **A line that `send` ends.** At the `clux-<token>$` prompt, when `send` ends a line (`--enter`, or a key that ends a line), terminal.sh does not send `Enter` to the typed text. After the gate, it writes the line (the cursor line with the known prompt removed) to `$D/line.cmd`, then types `C-e`, `C-u`, the literal `__clux_line <sum>` and `Enter`. Thus text to the right of the cursor (after `Home`) does not join the typed line. `<sum>` is the first 32 hex characters of the SHA-256 of the line that Laya examined. `__clux_line` reads `line.cmd` and deletes it, refuses a missing file or a missing sum (`refused: no line is waiting`) and a different sum (`refused: the line changed after Laya examined it`), shows `$ <line>`, then runs the line in a subshell with the same EXIT trap and keep file as `run` (`__clux_sub`). A blank line gets a plain `Enter`. Thus a `send` line has the same limits as a `run` command: `cd` and `export` persist; a function, an alias, a trap, an option or a variable that is not exported does not. A background job that the line starts keeps running, but it is a job of the subshell, so `fg`, `bg` and `jobs` in a later line do not see it.
- **Keys at the `clux-<token>$` prompt.** Only `Enter` (also `C-m`, `C-j`, `^M`, `^J`), which goes through `__clux_line`, and the keys that edit the line are permitted: `Left`, `Right`, `Home`, `End`, `Up`, `Down`, `BSpace`, `DC`, `Delete`, `Tab`, `Space`, `C-a`, `C-b`, `C-e`, `C-f`, `C-h`, `C-k`, `C-u`, `C-w`, `C-l` and their `^` forms. Another key gives exit code 2 and `at the clux prompt, only Enter and keys that edit the line work: <key>: use send --enter or run`. `Escape` gives exit code 2 and `at the clux prompt, Escape is not permitted: use send --key C-c`, because `Escape` starts a readline key sequence (`M-` keys). The other interrupt keys still work there.
- **The functions of `rc.bash` are read-only** (`readonly -f`), so a line cannot make a new `__clux_run`, `__clux_line` or `__clux_carry`, also with quotes that split the name (`e""val "__clu""x_run"...`), which the word rule cannot find. `__clux_load` ends with `set +o posix`, and `POSIXLY_CORRECT` is in the deny list, so POSIX mode does not stay.

### No safe list

Each command goes to Laya, also `ls` and `echo`. An earlier design let some first words skip Laya, and the pane shell checked that the first word was the program that terminal.sh found. That check cannot be trusted: a command that ran earlier can make a function with the name of any builtin that the check uses (`builtin`, `type`, `command`, `hash`), and bash permits a function named `/bin/ls`. The pane shell still runs `shopt -u expand_aliases`, so it runs the text that Laya examined.

A command can change the shell for the commands after it. A word rule cannot find all such commands (`eval`, quotes, `source`, `trap`, `bind -x` and more). Thus the design is structural:

- **`run` runs each command in a subshell.** `__clux_run` runs `( eval "$cmd" )`. In the subshell, `exit`, `exec` and `logout` are the builtins again, so `cd dir || exit 1` stops the command; `run` does not refuse these words. The subshell writes the keep file after the command, and an EXIT trap writes it after `exit`; the exit code stays. The DEBUG, ERR and RETURN traps of the command do not run in that step. A command that sets its own EXIT trap and then ends with `exit` writes no keep file: then the output ends with `clux: the directory and the exported variables did not come back: the command set an EXIT trap and ended with exit`. A function, an alias, a trap, a `shopt` or `set` option, or a variable that is not exported goes away when the command ends. Only two things come back to the pane shell: the working directory, and the exported variables. The subshell writes them to `$D/<n>.keep` (`PWD`, then `name=value` records, with NUL bytes between them, then an end record). It reads the names of `compgen -e` one line at a time with no word split, so an `IFS` that the command left changes nothing. The pane shell reads this file with no `eval`, and uses it only when the end record is present. It does not take a name that is not a valid name, or that is in the deny list (`__clux*`, `BASH*`, `ENV`, `PROMPT_COMMAND`, `PS0`-`PS4`, `IFS`, `SHELLOPTS`, `CDPATH`, `GLOBIGNORE`, `HISTFILE`, `HISTCMD`, `TMOUT`, `IGNOREEOF`, `SHLVL`, `PWD`, `OLDPWD`, `LD_*`, `DYLD_*`, `_`). It unsets an exported name that the command removed. Thus `cd`, `export` and `source` of a file that exports variables work with `run` as before. A variable that is set but not exported does not persist to the next `run`.
- **`send` at a nested shell prompt** (not the `clux-<token>$` prompt: for example a nested `bash` or `zsh`, or `ssh`, `mosh`, `docker exec` or `kubectl exec`, where the shell is on the other side) gives the client `--shell`. At the `clux-<token>$` prompt the line runs in a subshell (above), so there are no shell rules there. The process in the pane decides, not the Laya class of the prompt: a shell with a prompt such as `➜ ` can get `other`. The shell rules do not apply only when `#{pane_current_command}` is a known program that is not a shell (`python*`, `ipython*`, `psql`, `mysql`, `sqlite3`, `redis-cli`, `mongosh`, `node`, `irb`, `ghci`, `lua*`, `vim`, `nano`, `emacs`, `less`, `man`, `top` and others). Any other process, and a name that tmux cannot give, gets the rules: they only refuse more. Then the client gives `dangerous` with the reason `can change the shell for later commands` when the line has a word that can change the shell (`eval`, `source`, `.`, `trap`, `bind`, `enable`, `alias`, `unalias`, `typeset`, `declare`, `export`, `readonly`, `set`, `shopt`, `unset`, `function`, `builtin`, `command`, `hash`, `exec`, `read`, `mapfile`, `readarray`, `exit`, `logout`, `printf -v`, `()`), an assignment to an array item (`a[1]=`), an assignment to a shell variable (`PATH`, `PROMPT_COMMAND`, `BASH*`, `ENV`, `PS0`-`PS4`, `IFS`, `SHELLOPTS`, `POSIXLY_CORRECT`, `CDPATH`, `GLOBIGNORE`, `HISTFILE`, `HISTCMD`, `TMOUT`, `IGNOREEOF`, `SHLVL`, `PWD`, `OLDPWD`, `LD_*`, `DYLD_*`), or `<<`. The rule looks at the full line, also inside quotes. It is not complete: quotes can split a word (`e""val`), and the rule cannot find that. Its list of names holds each name that `__clux_carry` does not carry back (a test keeps the two lists equal). The client runs no shell of its own (no `bash -n`). The user must know that in a nested shell only this rule and the gate of each line apply.
- **The continuation prompt.** `rc.bash` sets `PS2` to `clux-<token>> `. When the cursor line shows it, the pane shell waits for the rest of a command that `send` did not examine as one line. Then `send` refuses text and keys (not the interrupt keys) with exit code 5 and `the pane shell waits for the rest of a command: send --key C-c, then send the full command on one line`.

The limit that remains: an exported variable that `run` or a `send` line sets persists, for example `export PATH=/tmp/x:$PATH`, and a later command then does a different thing than its text shows. Laya examines each command with no memory of the commands before it. In a nested shell that Laya does not see as `shell_prompt`, only the gate of each line applies. These limits are disclosed in the skill.

The pane shell sets `ignoreeof` and `IGNOREEOF=1000000`. `C-d` is an interrupt key and skips the gate, so without this a `send --key C-d` at an empty prompt would end the pane shell. `IGNOREEOF` and `TMOUT` (`0`) are read-only, so `IGNOREEOF=0` or `TMOUT=1` cannot end the pane shell. bash still lets `set +o ignoreeof` remove `IGNOREEOF`; at the `clux-<token>$` prompt each line runs in a subshell, and in a nested shell the word rule refuses `set`.

In a pager or a menu (the last `pane_state`), the keys `Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`, `PgUp`, `PageDown`, `PgDn`, `NPage` and `PPage` with no modifier go to the pane with no command request: there they only move. `Space` is not one: it selects in a menu. At a shell prompt these keys still go to the gate.

`check_pane` refuses when the capture of the pane fails two times (0.2 s apart): with no cursor line, the gate cannot examine the line. The exit code is 4 when the pane is gone, else 5 with `cannot read the companion pane: try again`. For the end-of-line check, a row of printable ASCII needs no client: its length is its cell count.

### The limit of the private directory

The pane shell runs as the same user as terminal.sh, so no file of the companion is out of its reach. The gate protects the pane before a command runs. A command that ran can change the pane shell, `rc.bash` or the state file, and a later gate cannot undo that. Thus clux does not keep trust in files that the pane shell can write: the typed line carries the sum and the mode, `rc.bash` gets the private directory as a read-only value (not the exported `CLUX_TERMINAL_D`), and the client refuses a Laya URL that is not on a loopback host.

This limit is out of scope, and it is disclosed: a command that Laya passed can write any file of the same user, also `$D/state` (for example `laya_url` to a different loopback port), the files in `config/laya/` and the plugin code. clux does not defend against a command after Laya passed it. The gate is the only defense: each command reaches a file only after Laya examined it.

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
| `dangerous` | Asks the user in the pane (see below). | Refuses with exit code 6. At the `clux-<token>$` prompt: `laya: dangerous (<reason>): use run, it asks the user`. In other pane states (a program, `ssh`, a nested shell): `laya: dangerous (<reason>): ask the user to type this line in the pane`, because `run` types at the clux prompt only. |
| client fails | Does not run. Exit code 6. | Does not send. Exit code 6. |

### The question in the pane

- `run` refuses a command with a control character (a newline, a tab, an escape) with exit code 2, before Laya: such a character can hide a part of the command in the question.
- `run` writes the command to `<n>.cmd`, an empty marker `<n>.confirm` and the reason to `<n>.reason`, then types `__clux_run <n> <sum> confirm`. `<sum>` is the first 32 hex characters of the SHA-256 of the command that Laya examined.
- The typed line, not a file, tells the pane shell what the gate decided: the mode is `plain` or `confirm`. `__clux_run` refuses any other mode (exit 126). The files in the private directory are only data. `__clux_run` makes the sum of `<n>.cmd` again and refuses a different sum (`refused: the command changed after Laya examined it`, exit 126). Thus a change of `<n>.cmd` after the gate, or a deleted `<n>.confirm`, does not skip the gate or the question.
- For `confirm`, `__clux_run` shows `laya: dangerous (<reason>)`, then the command, then `run? [y/N] `. Control characters in the reason and in the command show as `?`. It reads one line from the terminal.
- Each `<n>.cmd` runs one time. `__clux_run` refuses a run that has no `<n>.cmd` or that has an `<n>.rc`, and it deletes `<n>.cmd` when it reads it. `send` and `run` refuse text that contains `__clux_` with exit code 2, with no Laya request. Thus a declined command cannot run again through `__clux_run <n>`.
- It deletes `<n>.confirm` on all answers. A run that it refuses before the question (the run has an `<n>.rc`), a plain run, and a refused mode delete `<n>.confirm` too, so no verb waits for a question that is not in the pane. `__clux_run` refuses a run number that is not a number.
- On `y` it runs the command as in 3.9.0.
- On other input it does not run the command. It writes `declined` to `<n>.declined`, `126` to `<n>.rc`, and an empty `<n>.done`. Thus `report_run` does not wait its 1 s grace and does not print the incomplete-output note.
- While `<n>.confirm` is present, `send` and `read` refuse with exit code 3 and the message `laya confirmation in the companion pane: the user must answer it there`. Claude cannot type the answer.
- `run` waits for the answer within its time limit. When the limit ends, the result is exit code 1 as in 3.9.0, and Claude uses `wait --run N`. While `<n>.confirm` is present, `wait_for_run_files` does not call `pane_state`. [inferred] It only checks for the run's result files. [inferred] `wait --run N` works the same way. [inferred] `wait --idle` and `wait --pattern` still call `pane_state` on their normal tick. [inferred] While `<n>.confirm` is present, they exit 3 with the same message as `send` and `read`. [inferred]
- A declined run gives the line `laya: declined by the user` and `exit=126`.

## 8. Output guard

The guard applies to all text that goes from the pane to Claude:

- The output of `run` and `wait --run` (in `report_run`, after the cut to `--max-lines`).
- The screen text of `read`.
- The screen that `wait --pattern` examines. The pattern is tested on the guarded text, not on the raw screen. This prevents a pattern that finds a held secret one character at a time. `wait --pattern` polls each 1 s, not each 0.2 s. It keeps the last raw capture. When the capture changes, only the lines that no earlier guard of this wait examined go to the guard (the set of examined lines holds each line one time), each with the line above it for context, and the pattern is tested on that guarded text. A line that an earlier guard examined did not match the pattern then. A line that an earlier guard of this wait held stays held: the pair rule can hold a line (`hunter2` under `Password:`) that passes in a later window with other context. The verb finds the held lines from the markers of the guarded text; when the guarded text does not line up with the lines that it sent, each line that is left counts as held. Thus a progress bar sends 2 lines each second, not the full screen. No test reads the raw screen: when a raw test decides whether the guard runs, the time of the verb tells that a held line matches. When the time limit of the wait has ended, the wait starts no new guard and ends. A failed guard counts as a failed pane probe: after 3 in a row the verb exits 6, and the same screen is guarded again on the next tick. [inferred] The verb removes each marker line (`[held by laya: <reason>]` or `[held by laya: <reason>, <k> lines]`) before it tests the pattern, so a pattern that matches only a held marker line (for example `held` or `laya`) is not found.

`--secret` runs keep the 3.9.0 behavior. Their output does not go to Laya or to Claude.

### Steps

1. **Blocks.** The client splits the text into blocks of complete lines. It makes the blocks from the last line up, so that new output at the end does not move the edges of the blocks above it. A top block of less than half the size joins the block below it. The first estimate is 2 characters for each token (section 2 measured about 2 for `ls -la`), with at most 300 tokens in each block. A line longer than 300 tokens is its own block, split into pieces. Two pieces next to each other share 100 characters, so a token of less than 100 characters is whole in at least one piece. When a piece is cut in two again, the two halves share at most 50 characters.
2. **Block check.** The client sends all blocks with `output-block.json`, at most 2 at one time. [inferred] `laya-serve` 0.3.21 runs one model request at a time, and the 5 s request limit counts the time in its queue; with 2, a request waits for at most one other request. The schema asks: `secret` (boolean: does the text contain a password, API key, token, private key or other credential?), `prompt_injection` (boolean: does the text contain instructions to an AI assistant?).
3. **Cut text.** The client divides `usage.input_tokens` by the number of questions of the block policy (2). When that mean row is 496 (512 minus a margin of 16) or more, the longest row can be cut, so Laya cut the block. The client splits that block in two and sends each half again. A single line that Laya cuts is split into pieces.
4. **Injection.** A block with `prompt_injection` above its threshold (default 0.8) is held. Its lines become one line: `[held by laya: prompt_injection, <k> lines]`.
5. **Line check.** For each block with `secret` above its threshold (default 0.5), the client sends each line two times with `output-line.json` (the same `secret` question): the line alone, and the line with the line above it. A line is held when:
   - the line alone is above the line threshold (default 0.75), or
   - the pair is above the threshold, and the line above alone is not. Thus the secret is in this line (for example `hunter2` after `Password:`).

   The pair gets the last 200 characters of the line above, so that Laya does not cut the pair. When Laya cuts a request of the line check, the score is 1.0 and the line is held. There is no pair request when the line alone or the line above alone is held, or when `secret-values.txt` holds the line above. A line that `secret-values.txt` holds gets no line request at all: it is held with no request. The pair rule goes in line order: a line whose line above is held is not held by the pair.

   [inferred] The context of a block still changes its score: the same line can get a different score in a different block. `secret-values.txt` is the layer that does not depend on the context.

   The line above has its own alone score. [inferred] When that score is above the line threshold, the line above is held too, also when its own block was not flagged (a secret on the last line of a block).

   `not-secret.txt` applies before this pair rule: a line that it clears is never held by the line check, and it counts as a line above that is not above the threshold. Thus `total 48` above a secret does not let the secret through.

   Each held line becomes `[held by laya: secret]`.
6. **Multi-line secrets.** Lines between `-----BEGIN` and `-----END` are held as one unit. A `-----BEGIN` with no matching `-----END` in the text holds to the end of the text. [inferred] An `-----END` line with no `-----BEGIN` above it holds from the first line only when the text is cut (the client gets `--cut`: `report_run` cut lines to `--max-lines`, the guard cut bytes, or the text is a screen of `read` or `wait --pattern`), and only when the line is the end of a private key (`-----END <words> PRIVATE KEY-----`, also `PRIVATE KEY BLOCK`). An `-----END CERTIFICATE-----` or `-----END OF REPORT-----` line holds nothing. `not-secret.txt` (section 15) can remove a hold set by the line check (step 5). [inferred] It never removes a hold set by the PEM rule, the injection rule (step 4), or the half rule below. [inferred] It runs before the half rule counts held lines. [inferred] When more than half of the lines of a block are held, the full block is held.
7. **Long lines.** When a piece of a long line is flagged, the full line is held.
8. **Extra layer.** Each line that matches a secret-value pattern in `config/laya/secret-values.txt` (new) is also held. Examples: `AKIA[0-9A-Z]{16}`, `gh[pousr]_[A-Za-z0-9]{36}`, `xox[abpr]-`, `-----BEGIN [A-Z ]*PRIVATE KEY-----`. The 3.9.0 file `credential-patterns.txt` finds credential prompts, not values, so the guard does not use it. `secret-values.txt` and `not-secret.txt` use Python `re` syntax. [inferred] Only `credential-patterns.txt` stays ERE, read by bash. [inferred]

The block threshold is lower than the line threshold, so that a doubtful block always gets the line check. Section 2 shows that most blocks of usual output go to the line check. Thus the usual cost is about 2 line requests for each line, plus the block requests. 200 lines give about 450 requests. This is an estimate: the plan must measure the real time with 16 requests at one time on MPS, before it sets the guard limit.

### Known false positives

Section 2 found that some clean lines score above 0.75: `commit <sha>` lines and some `ls -la` lines. `config/laya/not-secret.txt` removes these holds (section 15).

### Result

- `run` and `wait --run`: the guarded text, then `laya: held <k> lines` when lines were held, then `exit=<rc>`. The exit code stays 0.
- `read`: the guarded text.
- When the client fails: no output text. The line `output held: laya not available: use wait --run <n> again`, then `exit=<rc>`. On stderr: `laya not available: the output stays; use wait --run <n> when Laya answers`. The verb exits 6. `<n>.out` stays, and the run keeps the lock (the marker `<n>.held`), so `wait --run <n>` gives the output when Laya answers again. [inferred] Until then a new `run` exits 5 with `the output of run <n> is held: use wait --run <n> first`, so no new run deletes the output. [inferred] `wait --run` on an older run does not free the lock of the last run. [inferred] When the guard fails each time (for example a large file of secrets), `wait --run <n> --discard` deletes the held output with no text, prints `output discarded: laya did not examine it` and `exit=<rc>`, and frees the lock. With no held output it exits 2. For `read` the verb prints nothing and exits 6.
- The guard gets at most the last 32768 bytes (`LAYA_GUARD_BYTES`), after the cut to `--max-lines`. Then the verb prints `output cut: the last 32768 bytes`. Thus one very long line does not use the full guard limit. A cut can start inside a PEM key: then an `-----END ... PRIVATE KEY-----` line with no `-----BEGIN` above it holds from the first line (step 6). [inferred] The guard removes NUL bytes before the text goes to Laya, and it counts the size in a file, not in a bash string, so binary output gives no bash warning and the cut note stays correct. The file is new for each guard (`mktemp`), and `tail`, `wc` and `tr` run with `LC_ALL=C`, so they count bytes and do not stop on bytes that are not UTF-8.
- The raw text stays visible in the pane for the user.

### Time

The output guard runs inside the time of the verb. The guard limit is 15 s (`LAYA_GUARD_LIMIT`), and the default time limit of `run` is 64 s, so that the verb ends before the 120 s limit of the Bash tool with the gate, `wait_for_prompt`, the clear and the report grace.

Measured on this machine (2026-09-28) for 32768 bytes of output: on the CPU a typical output takes 12.3 s and a hard output (lines of `export VAR=<hex>`, where most blocks go to the line check) takes 59 s; on MPS, 3.4 s and 16.2 s.

The guard does not hold all output when the limit ends. The client stops a request when less than 0.05 s of the limit stays. A request that reaches the 5 s request limit before that (a queue on the server, for example a `read` while a `run` guard works) holds only its own text as not examined; the guard goes on. A request that fails in another way (no server) stops the guard. A block that got no answer in time, and a line of a flagged block that got no line answer in time, is held as `[held by laya: not_examined, <k> lines]`. The other lines stay as the guard decided, and the verb exits 0. Thus text that Laya did not examine never goes to Claude, and a slow machine gives a part of the output, not exit 6. For the hard output above on MPS, the guard ends in 15.1 s with exit 0 and 75 lines not examined. When lines are held as `not_examined`, a smaller `--max-lines` or a `read` of a part of the output gives a text that Laya can examine in time. When two marker kinds join, the order is `prompt_injection`, then `not_examined`, then `secret`.

### The busy lock and the readers

The busy lock is the directory `$D/busy`. `busy/owner` holds `pending` while `run` asks the gate, then the number of the run. `busy/pid` holds the pid of the `run` verb until it typed `__clux_run`. When the verb is gone before that (the Bash tool stopped it during the gate), a later `run` takes the lock. `release_run <n>` frees the lock only when the owner is empty or is `<n>`, so a `wait --run` of an older run, or a reader that ends late, does not free the lock of a newer run. While `report_run` gives the output of run `<n>`, the symbolic link `$D/<n>.reading` names the pid of the verb. The EXIT trap of the verb removes it with the typing lock. While that reader is alive, `run` does not take over the lock of the completed run, and `release_if_done` and `remove_stale_output` keep the lock and `<n>.out`, so no new run deletes the output that a reader reads. Only one verb reads the output of a run at a time: `pid_link` makes the link, and a second reader exits 5 with `another verb reads the output of run <n> now: try again` and does not change the output. A link whose pid is dead is taken over. The typing lock uses the same `pid_link`.

## 9. Pane state

`credential_on_cursor` becomes `pane_state`. It gives one of `credential`, `yes_no`, `menu`, `pager`, `shell_prompt`, `other`.

- The client gets the cursor line and the 4 lines above it (the prompt `Enter value:` alone is not clear). It sends the last 400 characters of the cursor line and the last 200 characters of each line above. When Laya cuts that text, it asks again with the cursor line alone. When Laya cuts that too, the client exits 3, and the probe fails as when Laya does not answer.
- The pane-state input does not go to Claude, so this text needs no output guard.
- The result is `credential` when Laya gives `credential` or the 3.9.0 regular expressions find a credential prompt. terminal.sh applies this rule. [inferred] It calls the existing `line_is_credential` (3.9.0 bash, unchanged) on the cursor line. [inferred] It ORs that result with the client's `state`. [inferred] The client does not read `credential-patterns.txt`. [inferred]
- The prompt is `clux-<token>$ `. `open` makes the token from 4 random bytes and writes it to `rc.bash` and to the state file. The test `line_at_prompt` (the suffix `clux-<token>$`) stays a plain string test. It does not use Laya, because it is the marker of the clux shell and not a decision about content. Output that shows `clux$ ` is not the prompt, because it does not have the token. `prompt_input`, `wait_for_prompt` and `wait_for_clear` use the same mark. A companion that an older clux opened has no token, and its mark stays `clux$`.
- The wait loops call `pane_state` each fifth tick (each 1 s), as in 3.9.0. `pane_state` keeps the window that it sends (the last 5 lines) and its answer. When the window did not change, it sends no request, also when rows above the window change.
- When the client fails in a wait loop (`wait --run`, `wait --idle`, `wait --pattern` and `run`), the loop applies `line_is_credential` to the cursor line and continues. After 3 failed probes in a row, the verb exits 6. [inferred] For `run` and `wait --run` the message is `laya not available: run <n> continues in the pane; use wait --run <n> again`, because the command still runs. Thus one slow answer or one 503 does not stop the wait while the command continues.
- The output guard sends at most 2 requests at one time (see section 8), so a pane probe waits for at most 2 requests.
- [inferred] The capture keeps a blank cursor line. The cursor line is then empty, not the line above it. The client removes only the last newline, so the blank line stays the last line that Laya gets.

`credential` gives exit code 3, as in 3.9.0. The other states are for the skill and for later use. `wait --idle` prints `pane=<state>` when it ends on its time limit, so Claude knows why the pane is not at the prompt.

## 10. Exit codes

The 3.9.0 codes stay. One code is new.

| Code | Meaning |
|---|---|
| 2 | Also, as in 3.9.0 for bad arguments: `run` with a blank command (`run needs a command`), a command that the client refuses as bad input (`laya: bad input`), a line or a command that Laya cannot examine in full (`too long to examine`), and at the `clux-<token>$` prompt `Escape` or a key that does not edit the line (section 7). |
| 5 | Also, as in 3.9.0 for a busy companion: another `send` or `run` holds the typing lock, the cursor line changed while Laya examined it, terminal.sh cannot read the cursor position, or the pane shell waits for the rest of a command (section 7). Another verb reads the output of the same run (section 8). |
| 3 | A credential prompt or a Laya confirmation is in the pane. The user must answer it in the pane. Also: text that the pane did not show is on the line (`send --key C-c` removes it). |
| 6 | Laya: not installed, not available, refused (`dangerous` on `send`), or output held because Laya did not answer. The message on stderr tells which. The skill uses the message text to select the next step. |

## 11. Skill

`skills/terminal/SKILL.md` gets these changes:

- The companion needs Laya. On exit 6 with `laya not installed`, Claude tells the user and asks to run `terminal.sh laya install`. Claude does not run it before the user agrees. When the user agrees, Claude runs it with a Bash tool `timeout` of 600000 ms, because the install (pip of `laya` with PyTorch, plus the checkpoint download) can exceed the 120 s Bash tool default. [inferred] This timeout leaves margin over the 540 s total install budget of section 6, so the Bash tool's own limit does not cut the install verb short of its own failure path. [inferred]
- On exit 3 with `laya confirmation`, Claude tells the user to answer in the pane, then uses `wait --run N`.
- `[held by laya: …]` lines are not errors. Claude does not try to read the held text by other ways (for example with `cat` of the same file, or with `grep` for the value).
- Claude does not edit the files in `config/laya/`.

## 12. Repository changes

- `plugins/clux/scripts/laya_client.py` (new). It is not deployed. Add it to the not-deployed list in `test/deploy-manifest.bats` and to the note in the manifest header.
- `plugins/clux/config/laya/*.json` and the two `.txt` files (new). They are read from `CLAUDE_PLUGIN_ROOT` and are not deployed.
- `plugins/clux/scripts/terminal.sh`: sections 6 to 10.
- `plugins/clux/skills/terminal/SKILL.md`: section 11.
- `plugins/clux/.claude-plugin/plugin.json`: version 4.0.0.
- `CHANGELOG.md`: a `[4.0.0]` section. It names the breaking change: the companion needs Laya.
- `CONTRIBUTING.md`: the new files in the plugin tree.
- `README.md`: the Laya requirement and `terminal.sh laya install`.

## 13. Tests

- **Fake server.** `test/fixtures/fake-laya.py` is a small HTTP server with the two endpoints. It gives fixed answers from a JSON file that each test writes. Thus CI does not need the model. `test_helper` sets `CLUX_LAYA_PYTHON` to the venv Python. [inferred] The default path is `~/.local/share/clux/laya/bin/python3`. [inferred] A bats file that calls the client skips its tests when that Python cannot import `laya`. [inferred] The plan captures one real request and response from `laya-serve` 0.3.21 for a `noul` property, a `choice` property, `/health`, and a 503, into `test/fixtures/`. [inferred] `fake-laya.py` and the client tests use these captures as the source of truth for the wire format. [inferred]
- `test/laya-client.bats`:
  1. `command`: each command goes to Laya (also `ls` and `echo`), the three levels, the thresholds, and exit 3 for a cut command.
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
