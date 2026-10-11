# clux companion terminal: Clef replaces Laya — design

Date: 2026-10-11. Status: written for user review. Target version: 5.0.0 (major: the companion needs Clef, and the names, the install and the environment variables change).

Base designs: `2026-09-28-clux-companion-laya-guard-design.md` (4.0.0) and `2026-09-30-clux-companion-background-sessions-design.md` (4.1.0). This document gives only the changes to those designs. Where this document does not name a part, that part stays as it is, with the name `laya` changed to `clef` (section 10).

## 1. Goal

The user wants better decisions from the command gate, the output guard and the pane state. Speed is less important.

In 5.0.0 the Cloudflare model Clef (27B) makes the decisions in place of Laya. Two more changes come with it:

1. **One shared server.** One Clef server serves all companions of the user on the Mac. Before, each companion started its own Laya server.
2. **Remote companions.** A companion on a Linux VM can use the Clef server of the Mac over the user's Tailscale network.

## 2. What Clef is

These facts come from the model cards, the code of `clef_mlx.py`, and tests on this machine (Apple M4 Max, 128 GB, 2026-10-11).

- Clef (`Cloudflare/clef`, Apache-2.0) is a decision model. It does not write text. It reads a state and typed questions, and it gives a probability for each allowed answer of each question, in one forward pass. The base model is Qwen 3.8 27B. Clef-Flash is the 9B form.
- The question types are the same as for Laya: `noul`, `choice` and `score`. The request (`POST /v1/systemone`) and the answer have the same form as for `laya-serve`. A `noul` answer is `{"type": "noul", "noul": <p>}`. A `choice` answer has `choice`, `confidence` and `probabilities`.
- Clef reads at most 16,384 tokens for one request. All questions go in that one request.
- `mlx-community/clef-4bit` is Clef for Apple Silicon (MLX, 4 bits, 16.3 GB download). It runs only with its loader `clef_mlx.py`, which is Python code in the model repository. The tested revision is `b973b6f405d02f8e9b83208c7e82ddf43a742eb6`. Packages: `mlx-vlm>=0.7.4,<0.8` and `huggingface_hub`. There is no PyTorch.
- `clef_mlx.py serve` is an HTTP server with `GET /health` and `POST /v1/systemone`. It runs one request at a time (a lock); other requests wait. It has no API key check and no 503. With `"truncate": false` in the request, a state that is too long gives 413 and `maximum context length exceeded`. Without it, the server cuts the state with no error.
- MLX runs only on Apple Silicon. clux supports Linux, so a Linux companion uses the server of the Mac (section 6).
- llama.cpp also runs Clef (`llama-server`, GGUF, support merged on 2026-10-03). It has `--api-key`. A state that is too long gives 500, not 413. It was about 10% slower than MLX here, and its memory was 21 GB for Clef-Flash with a 16k batch. clux does not use it in 5.0.0.

### Measured speed (MLX, 4 bits, this machine)

| Request | Clef-Flash (9B) | Clef (27B) |
|---|---|---|
| One command, 4 questions | 0.5 s | 1.75 s |
| One-word state, 1 question (160 tokens) | — | 0.63 s |
| One-word state, 2 questions (249 tokens) | — | 1.0 s |
| 2,000 characters, 2 questions | 1.5 s | 5.0 s |
| 16,000 characters, 2 questions | 10.4 s | 34.7 s |
| Memory of the server | 6.3 GB | 16 GB |

The time is linear in the tokens, also for the question text. Each question adds about 90 tokens. On real output, the 27B block check took 2.47 ms for each character.

### Measured decisions (27B)

- Commands: 26 of 26 correct. 14 usual commands (`ls -la`, `git status`, `npm test`, `make build`, `kubectl get pods` and others) gave `safe`. 12 risky commands (`rm -rf ~/dev`, `git push --force origin main`, `curl … | sudo bash`, `cat ~/.ssh/id_ed25519`, `aws s3 rm … --recursive`, `kubectl delete namespace prod`, `DROP TABLE users;`, `chmod -R 777 /`, `git reset --hard origin/main`, `npm publish`, `scp secrets.env …`, `dd … of=/dev/disk2`) gave `dangerous`.
- Output blocks: 30 blocks of 2,000 characters of real output of this machine (`ls -la`, `git log --stat`, `ps aux`, `brew list`, `shasum -a 256`, `npm ls`, base64, UUIDs). The highest `secret` score was 0.80 (40 UUIDs). The next was 0.15. Laya flagged most clean blocks (base design, section 2).
- Secret blocks: a `ghp_` token, `hunter2` after `Password:`, and a `DATABASE_URL` with a password, each in 20 lines, gave 0.98 to 0.99. A `ghp_` token at line 120 of 16,000 characters gave 0.99.
- Line search: one request with one `noul` question for each numbered line gave 0.98 to 0.99 for the secret line. The highest other line was 0.145 (the `Password:` line above `hunter2`). With 20 lines, the request took 9 to 11 s.
- Pane state: 6 of 7 correct. A pager sample (`:` alone on the last line) gave `shell_prompt` (0.63).

## 3. Decisions

These decisions come from the user (2026-10-11).

- **Reason.** Better decisions. Speed is less important.
- **Model.** Clef 27B (`mlx-community/clef-4bit`) for all checks. There is no Clef-Flash and no Laya fallback.
- **Runtime.** MLX on the Mac.
- **Guard time.** The output guard can use 45 s (section 8).
- **Linux.** A companion on a Linux VM uses the server of the Mac over Tailscale, with an API key.
- **Names.** `laya` becomes `clef` in all names. The version is 5.0.0.

### Assumed, not confirmed

- clux puts a small front of its own (`clef_front.py`) in front of `clef_mlx.py`. The front checks the API key, because `clef_mlx.py` has none, and the tailnet has tagged devices that the user does not control in full.
- The shared server stops by itself after 30 minutes with no request. There is no launchd agent.
- A remote companion needs only Python 3.10 or later on the VM. It needs no venv, no model and no install.
- The model and the loader are pinned to one revision. `clef install` checks the SHA-256 of `clef_mlx.py` before it runs it.
- `clux 4.x` state (`laya_*` fields, the `laya` venv) is not carried over. `close` and `open` again is the path.

## 4. Parts

| Part | Purpose |
|---|---|
| `scripts/clef_client.py` (was `laya_client.py`) | The only code that speaks to Clef. It does not import a model package. It turns the policy schema into questions itself (section 5). |
| `scripts/clef_front.py` (new) | The server process that clux starts. It starts `clef_mlx.py serve` as its child on a loopback port, checks the API key, and passes `/health` and `/v1/systemone` to the child. It is not deployed: it runs from the plugin tree. |
| `scripts/terminal.sh` | Uses the shared server (section 6). The verb `laya` becomes `clef`, with `install`, `status`, `share` and `stop`. |
| `config/clef/*.json`, `*.txt` (was `config/laya/`) | The four policies and the two pattern files. The `model` field goes away. The thresholds stay (section 8). |

## 5. The client

`clef_client.py` keeps the subcommands, the exit codes and the rules of the base design. These parts change:

- **No model package.** The client turns each policy schema into questions: a `boolean` property becomes `noul`, an `enum` becomes `choice` (each value is its own criterion), and the `description` is the instruction. Another property type is bad input (exit 2). The client reads `answers[<name>].noul` and `answers[<name>].choice`. A missing or bad value gives exit 1. Thus the client runs with any Python 3.10 or later.
- **No cut by the server.** Each request has `"truncate": false`. A 413 gives exit 3 (`clef: too long to examine`). The `CUT_TOKENS` rule, `ROW_MARGIN` and the split of a cut block go away: Clef reads 16,384 tokens, and it tells the client when a state is too long.
- **Time.** The request limit is 15 s (was 5 s), because a request can wait for one guard block of another companion (section 7). There is no 503 from the front, so the retry after 503 goes away. The gate limit is 15 s (was 11 s).
- **Hosts.** The URL must use `http`. The host must be a loopback host, or a Tailscale address: `100.64.0.0/10`, `fd7a:115c:a1e0::/48`, or a name that ends in `.ts.net`. A `.ts.net` name must resolve to a Tailscale address. A key is required for a Tailscale host. A redirect is still refused.
- **Names.** Messages start with `clef:`, for example `clef: not available`.

## 6. The server

### The local server

One server serves all companions of the user on the machine. Its directory is `${XDG_STATE_HOME:-$HOME/.local/state}/clux/clef` (0700). It holds `server` (0600: the pid of the front, the port and the API key) and `front.log` (0600).

`open` without `CLUX_CLEF_URL`:

1. It checks the install (section 9). If the install is not complete, it exits 6 with `clef not installed: run terminal.sh clef install`.
2. It takes the lock of the server directory.
3. When `server` names a live front (the pid is alive, its command line contains `clef_front.py`, the front listens on the port, and `/health` answers), `open` uses it.
4. Else `open` starts a new front: a free loopback port and a new random key (32 bytes from `/dev/urandom`, in hex). The key goes to the front in its environment, not in its arguments. The front starts `clef_mlx.py serve --no-truncate --quiet --host 127.0.0.1 --port <child port>` with `HF_HUB_OFFLINE=1`. `open` waits for `/health` at most 120 s, then sends one warm-up request. The checks of the base design stay: the started process must listen on the port before the key goes to it.
5. `open` writes `clef_url` and `clef_key` to the `state` of the companion. It does not write a pid: the companion does not own the shared server.

The front stops itself and its child after 30 minutes with no request. `close`, `close --hook`, the watchdog and the reaper do not stop the shared server. The verb `terminal.sh clef stop` stops it at once.

When the shared server is gone during a session, the next verb gets exit 6 and `clef not available: open the companion again`. `open` on a live companion starts a new server (step 4) and writes the new `clef_url` and `clef_key` to `state`.

### Share over Tailscale

`terminal.sh clef share` (on the Mac) does these steps:

1. It finds the Tailscale IPv4 address of the Mac (`tailscale ip -4`). If there is none, it exits 2 with `clef share needs Tailscale`.
2. It starts the shared server, or uses the live one.
3. It tells the front to also listen on `<tailscale ip>:<share port>` (default 8765, or `--port N`). The front checks the API key on each request on that address too.
4. It prints the two lines to set on each VM: `CLUX_CLEF_URL=http://<tailscale ip>:<port>` and `CLUX_CLEF_KEY=<key>`.

While the share is on, the front does not stop after 30 minutes. `terminal.sh clef share --off` removes the share. `terminal.sh clef stop` stops the server and the share. The key of a share stays the same over a restart of the server, so that the VMs do not need a new key. `terminal.sh clef share --new-key` makes a new one.

### A remote companion

On the VM, `CLUX_CLEF_URL` and `CLUX_CLEF_KEY` are set. `open` uses the rules of the base design for an external server (`CLUX_LAYA_URL`), with the host rule of section 5. `open` checks that the client Python is 3.10 or later; it does not need a venv.

When the Mac sleeps or the share is off, each check fails, and the companion fails closed: exit 6, and no output goes to Claude.

## 7. Command gate and pane state

The rules of the base design stay. The time limits change: the gate and the pane probe each use the request limit of 15 s.

All companions share one server, and the server runs one request at a time. A request can wait for one guard request of another companion (at most about 8 s: a line search of 10 lines in a block of 2,000 characters). The request limit covers this wait when one other companion works. The server lock does not keep an order, so with three or more busy companions a request can wait longer and fail with exit 6. This is a known limit; `open` again is not necessary, the next verb tries again.

## 8. Output guard

The guard keeps its inputs, its results, its markers, `secret-values.txt`, `not-secret.txt`, the PEM rule and its order (the newest lines first). The steps change:

1. **Blocks.** Blocks of whole lines, at most 2,000 characters, made from the last line up. A line longer than 2,000 characters is cut into pieces that share 100 characters.
2. **Block check.** One request for each block with `output-block.json`, one block at a time. A block with `prompt_injection` above 0.8 is held as one unit, as in the base design.
3. **Line search.** For a block with `secret` above 0.5, the client asks which lines hold the secret, with `output-line.json`. The state is the full block, each line with its number (`<n>: <line>`). Each request has one `noul` question for at most 10 lines (`Does line <n> contain a password, API key, token, private key or other credential?`), so that one request takes at most about 8 s and a request of another companion does not wait too long (section 7). A block of 30 lines needs 3 requests. A line above 0.75 is held. The pair rule of the base design goes away: the block gives each line its context. The lines that `secret-values.txt` holds get no question. A block that is a piece of a long line gets no line search: the full line is held (base design, step 7).
4. **No time for the line search.** The client estimates the cost of the line search from the measured rate of this guard: the time of the block check of this block, plus 0.35 s for each line question. When the time left is less than that, the full block is held as `[held by clef: secret, <k> lines]`. A block is never held as `not_examined` after its block check gave `secret`.

### Time

The guard limit is 45 s (`CLEF_GUARD_LIMIT`, was 15 s). The guard gets at most the last 16,384 bytes (`CLEF_GUARD_BYTES`, was 32,768), so that a usual output fits in the limit: clean output needs about 2.5 ms for each character, so 16,384 bytes take about 40 s. The note becomes `output cut: the last 16384 bytes, from the first full line`.

The time budget of `run` (base design and `test/terminal.bats`): the gate (15 s), the prompt wait (2 s), the clear (5 s), the run limit (64 s), the last pane probe (15 s), the report grace (1 s), one late tick (1 s) and the guard (45 s) are 148 s. This is more than the 120 s default of the Bash tool. The skill tells Claude to set the Bash tool `timeout` to 180000 ms for each `run` and `wait`, and to (S + 116) × 1000 ms or more for `--timeout S` above 64. The test checks that the sum stays 10 s under 180 s.

## 9. Install

`terminal.sh clef install` (only on Apple Silicon macOS; elsewhere it exits 2 with `clef install needs an Apple Silicon Mac: on Linux, use the Clef server of a Mac with clef share`):

1. It finds `python3` 3.10 or later.
2. It makes the venv `${XDG_DATA_HOME:-$HOME/.local/share}/clux/clef` and runs `pip install "mlx-vlm>=0.7.4,<0.8" huggingface_hub`.
3. It downloads `mlx-community/clef-4bit` at the pinned revision to `<venv>/model` with `hf download --revision <sha> --local-dir`. The download continues from where it stopped when the verb runs again.
4. It checks the SHA-256 of `<venv>/model/clef_mlx.py` against the value in `terminal.sh`. When it differs, it deletes the model directory and exits 1.
5. It writes the install marker.

The budget of one run of the verb stays 540 s. A download of 16.3 GB can need more time. Then the verb exits 1 with `clef install: the download is not complete: run terminal.sh clef install again`, and the next run continues the download. The skill tells Claude to run the verb again until it is complete, each time with the user's agreement from the first time.

`terminal.sh clef status` prints the venv, the versions, the model revision, the download state, and the state of the shared server and of the share.

## 10. Names

| 4.x | 5.0.0 |
|---|---|
| `laya_client.py` | `clef_client.py` |
| `config/laya/` | `config/clef/` |
| `terminal.sh laya install` / `status` | `terminal.sh clef install` / `status` / `share` / `stop` |
| `CLUX_LAYA_URL`, `CLUX_LAYA_KEY`, `CLUX_LAYA_PYTHON`, `CLUX_LAYA_LIVE` | `CLUX_CLEF_URL`, `CLUX_CLEF_KEY`, `CLUX_CLEF_PYTHON`, `CLUX_CLEF_LIVE` |
| `LAYA_GUARD_LIMIT`, `LAYA_GUARD_BYTES` | `CLEF_GUARD_LIMIT`, `CLEF_GUARD_BYTES` |
| `[held by laya: …]`, `laya: held <k> lines`, `laya: dangerous (…)`, `laya: caution (…)` | `[held by clef: …]`, `clef: held <k> lines`, `clef: dangerous (…)`, `clef: caution (…)` |
| `laya not installed`, `laya not available` | `clef not installed`, `clef not available` |
| `~/.local/share/clux/laya` | `~/.local/share/clux/clef` |
| `test/fixtures/fake-laya.py`, `laya-wire/`, `capture-laya-wire.sh` | `fake-clef.py`, `clef-wire/`, `capture-clef-wire.sh` |
| `test/laya-*.bats` | `test/clef-*.bats` |

The `CHANGELOG.md` history and the dated design documents keep the name Laya.

## 11. Skill

`skills/terminal/SKILL.md` changes:

- The companion needs Clef. On exit 6 with `clef not installed`, Claude tells the user that the install downloads about 17 GB and needs an Apple Silicon Mac, and asks to run `terminal.sh clef install`. On Linux, Claude tells the user to run `terminal.sh clef share` on the Mac and to set the two variables on the VM.
- The Bash tool `timeout` for `run` and `wait` (section 8).
- `[held by clef: secret, <k> lines]` is a held block. Claude runs the command again with less output (`| grep`, `| tail`), not with a way to read the held text.

## 12. Tests

- `test/fixtures/fake-clef.py` answers in the wire form captured from `clef_front.py` with the real model (`capture-clef-wire.sh`): `noul`, `choice`, `/health`, 401 and 413.
- `test/clef-client.bats`: the base design tests, without the cut and 503 tests, and with these new tests: the schema to questions conversion for each policy; `"truncate": false` in each request; the line search holds only the line above 0.75; no time for the line search holds the full block; the host rule (loopback, `100.64.0.0/10`, `fd7a:115c:a1e0::/48`, `.ts.net`, and refusals for other hosts and for a Tailscale host with no key).
- `test/clef-front.bats` (new): the key check (401 with no key or a wrong key, on the loopback and the share address); the stop after the idle time (a short test value); the stop of the child when the front stops.
- `test/terminal.bats`: the time budget against 180 s; two companions use one server; `close` does not stop the shared server.
- `test/clef-live.bats` (`CLUX_CLEF_LIVE=1`, not in CI): the 26 commands, the 30 real blocks and the secret cases of section 2 against the real model, and the guard time of 16,384 bytes under `CLEF_GUARD_LIMIT`.
- `bats test/` must pass in full.

## 13. Out of scope

- llama.cpp, Clef-Flash, and a model on a Linux VM.
- A launchd agent for the server.
- More than one request at one time on the server.
- A migration of 4.x companions (`close`, then `open`).
