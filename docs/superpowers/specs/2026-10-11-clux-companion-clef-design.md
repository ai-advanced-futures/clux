# clux companion terminal: Clef replaces Laya — design

Date: 2026-10-11. Status: written for user review. Target version: 5.0.0 (major: the companion needs a Clef server that the user runs, and clux does not install or start a model now).

Base designs: `2026-09-28-clux-companion-laya-guard-design.md` (4.0.0) and `2026-09-30-clux-companion-background-sessions-design.md` (4.1.0). This document gives only the changes to those designs. Where this document does not name a part, that part stays as it is, with the name `laya` changed to `clef` (section 10).

## 1. Goal

The user wants better decisions from the command gate, the output guard and the pane state. Speed is less important.

In 5.0.0 the Cloudflare model Clef (27B) makes the decisions in place of Laya. The plugin does not run the model:

1. **The user runs one Clef server** on the Mac Studio (`mac-studio`, `100.117.159.16` on the user's tailnet).
2. **Each companion connects to that server** through the URL in `CLUX_CLEF_URL`, on each Mac and Linux VM of the user, over the tailnet. The Mac Studio uses the same URL, or a loopback URL.
3. **clux does not install, start or stop a model server.** The install verb, the venv, the server start, the API key that clux makes, and the server stops of `close`, the watchdog and the reaper go away.

## 2. What Clef is

These facts come from the model cards, the code of `clef_mlx.py`, and tests on this machine (Apple M4 Max, 128 GB, 2026-10-11).

- Clef (`Cloudflare/clef`, Apache-2.0) is a decision model. It does not write text. It reads a state and typed questions, and it gives a probability for each allowed answer of each question, in one forward pass. The base model is Qwen 3.8 27B. Clef-Flash is the 9B form.
- The question types are the same as for Laya: `noul`, `choice` and `score`. The request (`POST /v1/systemone`) and the answer have the same form as for `laya-serve`. A `noul` answer is `{"type": "noul", "noul": <p>}`. A `choice` answer has `choice`, `confidence` and `probabilities`.
- Clef reads at most 16,384 tokens for one request. All questions go in that one request.
- `mlx-community/clef-4bit` is Clef for Apple Silicon (MLX, 4 bits, 16.3 GB download). It runs only with its loader `clef_mlx.py`, which is Python code in the model repository. The tested revision is `b973b6f405d02f8e9b83208c7e82ddf43a742eb6`. Packages: `mlx-vlm>=0.7.4,<0.8` and `huggingface_hub`.
- `clef_mlx.py serve` is an HTTP server with `GET /health` and `POST /v1/systemone`. It runs one request at a time (a lock); other requests wait. It has no API key check and no 503. With `"truncate": false` in the request, a state that is too long gives 413 and `maximum context length exceeded`. Without it, the server cuts the state with no error. `--host` sets the address that it listens on (default `127.0.0.1`).
- llama.cpp also runs Clef (`llama-server`, GGUF, support merged on 2026-10-03). It has `--api-key`. A state that is too long gives 500, not 413. It was about 10% slower than MLX here.

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
- **Model.** Clef 27B (`mlx-community/clef-4bit`), on MLX, on the Mac Studio. There is no Laya fallback.
- **Who runs it.** The user runs the server. The plugin does not run a model.
- **Where.** All Macs and Linux VMs of the user use that one server over the tailnet. The URL comes from an environment variable.
- **Guard time.** The output guard can use 45 s (section 8).
- **Names.** `laya` becomes `clef` in all names. The version is 5.0.0.

### Assumed, not confirmed

- `CLUX_CLEF_KEY` is optional. `clef_mlx.py serve` has no key check, so with that server the user sets no key. When the user puts a server with a key in front (for example `llama-server --api-key`, or a proxy), clux sends the key as `Authorization: Bearer <key>`.
- clux accepts only a loopback host or a Tailscale host (section 5). It refuses each other host, so terminal text does not go out of the tailnet.
- The thresholds and the time limits are set for Clef 27B on MLX on an M4 Max. Another model or a slower machine works, but more output stays `not_examined` in the guard limit.
- How the user starts the server and keeps it running (for example a launchd agent on the Mac Studio) is not part of clux. `docs/reference.md` gives one example command.
- 4.x state (`laya_*` fields, the `laya` venv) is not carried over. `close` and `open` again is the path. The 4.x venv `~/.local/share/clux/laya` stays on disk; `docs/reference.md` tells the user that it can be deleted.

## 4. Parts

| Part | Purpose |
|---|---|
| `scripts/clef_client.py` (was `laya_client.py`) | The only code that speaks to Clef. It imports no model package and runs with any Python 3.10 or later. It turns the policy schema into questions itself (section 5). The helpers `checkpoint`, `ready`, `port`, `version` and `pip-install` go away. |
| `scripts/terminal.sh` | Reads `CLUX_CLEF_URL` (section 6). All code that installs, starts, checks or stops a Laya server goes away. The verb `laya` becomes `clef`, with only `status`. |
| `config/clef/*.json`, `*.txt` (was `config/laya/`) | The four policies and the two pattern files. The `model` field goes away. The thresholds stay (section 8). |

## 5. The client

`clef_client.py` keeps the subcommands `health`, `command`, `output`, `pane`, `check-url`, `after-cursor` and `scrub`, the exit codes and the rules of the base design. These parts change:

- **No model package.** The client turns each policy schema into questions: a `boolean` property becomes `noul`, an `enum` becomes `choice` (each value is its own criterion), and the `description` is the instruction. Another property type is bad input (exit 2). The client reads `answers[<name>].noul` and `answers[<name>].choice`. A missing or bad value gives exit 1.
- **No cut by the server.** Each request has `"truncate": false`. A 413 gives exit 3 (`clef: too long to examine`). The `CUT_TOKENS` rule, `ROW_MARGIN` and the split of a cut block go away: Clef reads 16,384 tokens, and it tells the client when a state is too long. A server that gives another code for a long state (for example 500 from `llama-server`) makes the client exit 1, so the verb fails closed.
- **Time.** The request limit is 15 s (was 5 s), because a request can wait for a request of another companion (section 7), and the request goes over the network. The retry after 503 stays, because a proxy can give 503. The gate limit is a fixed 15 s (was 11 s), its own constant and not `2 * REQUEST_LIMIT + RETRY_DELAY`, and a retry after 503 runs only in the time that is left in those 15 s.
- **One request at a time.** The client sends one request at a time (`MAX_PARALLEL = 1`), for the block check and for the line search. [inferred]
- **Hosts.** The URL must use `http` and have no user part. The host must be one of these:
  - a loopback host (`127.0.0.1`, `localhost`, `::1`);
  - a Tailscale IPv4 address (`100.64.0.0/10`) or IPv6 address (`fd7a:115c:a1e0::/48`);
  - a name that ends in `.ts.net` and that resolves only to Tailscale addresses. The client resolves the name one time for each process and connects to the address that it checked, so a second lookup cannot give another address. The host of the request URL becomes that address, and the `Host` header holds the name, so the lookup function is on the connect path. [inferred] The client does the lookup in one function of `clef_client.py`, and no environment variable or option changes it. [inferred]
  
  Each other host gives exit 1 and `clef: the host of CLUX_CLEF_URL is not a loopback or Tailscale host`. The traffic on the tailnet is encrypted by Tailscale (WireGuard). A redirect is still refused.
- **Key.** When `CLUX_CLEF_KEY` is set, each request sends it, also `health`, because clux does not own the port now. A 401 or 403 gives exit 4, as in the base design; a 401 or 403 from `health` gives the `refused CLUX_CLEF_KEY` message of section 6, step 4.
- **Names.** Messages start with `clef:`, for example `clef: not available`.

## 6. The server

clux does not start or stop a server. The rules of the base design for an external server (`CLUX_LAYA_URL`, section 6, "With `CLUX_LAYA_URL`") are now the only rules:

1. `open` reads `CLUX_CLEF_URL`. When it is not set, `open` exits 6 with `clef not configured: set CLUX_CLEF_URL to the URL of your Clef server`.
2. `open` checks the host (section 5). A bad host gives exit 6.
3. `open` checks that the client Python is 3.10 or later. It uses `python3`, or `CLUX_CLEF_PYTHON` when that is set. Else it exits 6 with `clef not available: the client needs python3 3.10 or later`.
4. `open` calls `health`, then sends one pane request, so that a bad key or a server that is not Clef fails at `open`. This request runs before the pane opens, so it carries a fixed one-word state and not the pane. [inferred] An empty state is not allowed for this check, because `pane` sends no request for it. [inferred] The request adds about 0.6 s to `open` (section 2). [inferred] A failure gives exit 6 with `clef not available: the server at CLUX_CLEF_URL does not answer` (or `refused CLUX_CLEF_KEY`).
5. `open` writes `clef_url` and, when it is set, `clef_key` to the `state` of the companion. The later verbs read them from `state`, as in the base design. `open` on a live companion makes steps 1 to 4 again and writes the current `CLUX_CLEF_URL` to `state`, which replaces an older `clef_url`; a state with no `clef_url` (a 4.x companion) still gets the message "this companion has no Clef server: use close, then open". [inferred]

When the server stops during a session (the Mac Studio sleeps, or the user stops the server), each check fails, the verb exits 6 with `clef not available`, and no output goes to Claude. `open` is not necessary after the server is back: the next verb tries again.

These parts of the base designs go away: `laya install`, the venv, the install marker, the checkpoint check, the free port, the random key, `laya_start_server`, the check that the process listens on the port, the warm-up loop, `laya_pid`, the server stop in `close` and `close --hook`, the server stop of the reaper and of the watchdog (background sessions design), and the restart of a dead server in `open`.

### The server on the Mac Studio

`docs/reference.md` gives the user this example (not run by clux):

```bash
hf download mlx-community/clef-4bit --revision b973b6f405d02f8e9b83208c7e82ddf43a742eb6 --local-dir ~/models/clef-4bit
python ~/models/clef-4bit/clef_mlx.py serve --model ~/models/clef-4bit --host 100.117.159.16 --port 8765 --no-truncate --quiet
```

On each machine: `export CLUX_CLEF_URL=http://mac-studio.<tailnet>.ts.net:8765` (or `http://100.117.159.16:8765`). The reference names these points:

- `clef_mlx.py serve` has no key check. Each device on the tailnet that the Tailscale ACL lets reach the port can send requests. It cannot read the requests of other devices. The user limits the port with the ACL.
- `clef_mlx.py` is code from the model repository. The user reads it before the first run.
- With `--host 100.117.159.16`, a process on the Mac Studio uses the same tailnet URL, not `127.0.0.1`.

## 7. Command gate and pane state

The rules of the base design stay. The time limits change: the gate and the pane probe each use the request limit of 15 s.

All companions of all machines share one server, and the server runs one request at a time. A request can wait for one guard request of another companion (at most about 8 s: a line search of 10 lines in a block of 2,000 characters). The request limit covers this wait when one other companion works. The server lock does not keep an order, so with three or more busy companions a request can wait longer and fail with exit 6. This is a known limit; the next verb tries again.

## 8. Output guard

The guard keeps its inputs, its results, its markers, `secret-values.txt`, `not-secret.txt`, the PEM rule and its order (the newest lines first). The steps change:

1. **Blocks.** Blocks of whole lines, at most 2,000 characters, made from the last line up. A line longer than 2,000 characters is cut into pieces that share 100 characters.
2. **Block check.** One request for each block with `output-block.json`, one block at a time. A block with `prompt_injection` above 0.8 is held as one unit, as in the base design.
3. **Line search.** For a block with `secret` above 0.5, the client asks which lines hold the secret, with `output-line.json`. The state is the full block, each line with its number (`<n>: <line>`). Each request has one `noul` question for at most 10 lines (`Does line <n> contain a password, API key, token, private key or other credential?`), so that one request takes at most about 8 s and a request of another companion does not wait too long (section 7). A block of 30 lines needs 3 requests. The question for line `<n>` is named `line<n>`; `<n>` counts from 1 in the block, and the client maps it back to the output line. The text of the question is the `description` of the `secret` property in `output-line.json`, with "the text" changed to "line `<n>`". [inferred] A line above 0.75 is held. The pair rule of the base design goes away: the block gives each line its context. The lines that `secret-values.txt` holds get no question. A block that is a piece of a long line gets no line search: the full line is held (base design, step 7).
4. **No time for the line search.** The client estimates the cost of the line search from the measured rate of this guard: the number of line-search requests (`ceil(<lines> / 10)`) times the time of the block check of this block, plus 0.35 s for each line question. When the time left is less than that, the full block is held as `[held by clef: secret, <k> lines]`. A block is never held as `not_examined` after its block check gave `secret`. When a line-search request of such a block gets no answer (the request limit, two 503 answers, or the end of the guard limit), the full block is held in the same way. [inferred]

### Time

The guard limit is 45 s (`CLEF_GUARD_LIMIT`, was 15 s). The guard gets at most the last 16,384 bytes (`CLEF_GUARD_BYTES`, was 32,768), so that a usual output fits in the limit: clean output needs about 2.5 ms for each character, so 16,384 bytes take about 40 s. The note becomes `output cut: the last 16384 bytes, from the first full line`.

The time budget of `run` (base design and `test/terminal.bats`): the gate (15 s), the prompt wait (2 s), the clear (5 s), the run limit (64 s), the last pane probe (15 s), the report grace (1 s), one late tick (1 s) and the guard (45 s) are 148 s. This is more than the 120 s default of the Bash tool. The skill tells Claude to set the Bash tool `timeout` to 180000 ms for each `run` and `wait`, and to (S + 116) × 1000 ms or more for `--timeout S` above 64. The test checks that the sum stays 10 s under 180 s.

## 9. Status

`terminal.sh clef status` prints `url=<CLUX_CLEF_URL or none>`, `key=set|none`, `host=loopback|tailscale|refused`, and `server=answers|no answer|not checked`. It sends one `health` request (with the key, when it is set) when the URL is set and the host is allowed. It does not print the key.

## 10. Names

| 4.x | 5.0.0 |
|---|---|
| `laya_client.py` | `clef_client.py` |
| `config/laya/` | `config/clef/` |
| `terminal.sh laya install` / `status` | `terminal.sh clef status` (no install) |
| `CLUX_LAYA_URL`, `CLUX_LAYA_KEY`, `CLUX_LAYA_PYTHON`, `CLUX_LAYA_LIVE` | `CLUX_CLEF_URL`, `CLUX_CLEF_KEY`, `CLUX_CLEF_PYTHON`, `CLUX_CLEF_LIVE` |
| `LAYA_GUARD_LIMIT`, `LAYA_GUARD_BYTES` | `CLEF_GUARD_LIMIT`, `CLEF_GUARD_BYTES` |
| `[held by laya: …]`, `laya: held <k> lines`, `laya: dangerous (…)`, `laya: caution (…)` | `[held by clef: …]`, `clef: held <k> lines`, `clef: dangerous (…)`, `clef: caution (…)` |
| `laya not installed` | `clef not configured` |
| `laya not available` | `clef not available` |
| `test/fixtures/fake-laya.py`, `laya-wire/`, `capture-laya-wire.sh` | `fake-clef.py`, `clef-wire/`, `capture-clef-wire.sh` |
| `test/laya-*.bats` | `test/clef-*.bats` |

The `CHANGELOG.md` history and the dated design documents keep the name Laya.

`README.md`, `docs/reference.md` and `CONTRIBUTING.md` get new text, not only the rename: the install text becomes the `CLUX_CLEF_URL` setup of section 6. `docs/reference.md` holds the server command; `README.md` links to it. [inferred]

## 11. Skill

`skills/terminal/SKILL.md` changes:

- The companion needs a Clef server. On exit 6 with `clef not configured`, Claude tells the user to set `CLUX_CLEF_URL` (and `CLUX_CLEF_KEY` when the server has a key) in the environment of Claude Code, and to start Claude Code again. Claude does not try to start a model.
- On exit 6 with `clef not available`, Claude tells the user that the Clef server does not answer, and names the URL from `terminal.sh clef status`.
- The Bash tool `timeout` for `run` and `wait` (section 8).
- `[held by clef: secret, <k> lines]` is a held block. Claude runs the command again with less output (`| grep`, `| tail`), not with a way to read the held text.

## 12. Tests

- `test/fixtures/fake-clef.py` answers in the wire form captured from `clef_mlx.py serve` with the real model (`capture-clef-wire.sh`): `noul`, `choice`, `/health` and 413. A fake 401 comes from the base design captures.
- `test/clef-client.bats`: the base design tests, without the cut tests, and with these new tests: the schema to questions conversion for each policy; `"truncate": false` in each request; the line search holds only the line above 0.75 and sends at most 10 questions in one request; no time for the line search holds the full block; the host rule (loopback, `100.64.0.0/10`, `fd7a:115c:a1e0::/48`, a `.ts.net` name that resolves to a Tailscale address, and refusals for other hosts, for a `.ts.net` name that resolves to another address, and for a user part); the key is sent only when it is set. The two `.ts.net` cases run through a Python wrapper in the test that imports `clef_client`, replaces the lookup function, and calls the client; they do not skip off the tailnet. [inferred]
- `test/terminal.bats`: `open` with no `CLUX_CLEF_URL` exits 6 with `clef not configured`; the time budget against 180 s; `clef status` does not print the key. The tests of the removed parts (install, server start, server stop) go away.
- `test/terminal-e2e.bats`: the base design cases with the fake server through `CLUX_CLEF_URL`, without the server-stop case.
- `test/clef-live.bats` (`CLUX_CLEF_LIVE=1` and `CLUX_CLEF_URL` set, not in CI): the 26 commands, the 30 real blocks and the secret cases of section 2 against the real server, and the guard time of 16,384 bytes under `CLEF_GUARD_LIMIT`.
- The skip gate of `test/test_helper.bash` (`import laya`) and the venv default of `CLUX_CLEF_PYTHON` go away; the tests use `python3`. [inferred]
- `bats test/` must pass in full.

## 13. Out of scope

- A model that clux installs, starts or stops.
- A key check in front of `clef_mlx.py`.
- llama.cpp as a tested server.
- More than one request at one time on the server.
- A migration of 4.x companions (`close`, then `open`).
