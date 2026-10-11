# clux companion terminal: Clef replaces Laya — Implementation Plan

**Goal:** Replace the Laya server that clux installs and runs with a Clef 27B server that the user runs, reached through `CLUX_CLEF_URL` on a loopback or Tailscale host, with the new output guard, the name `clef` in all names, and clux 5.0.0.

**Architecture:** `clef_client.py` (was `laya_client.py`) stays the only code that speaks to the model, and it imports no model package: it turns each policy schema into Clef questions itself, sends `"truncate": false` to `POST /v1/systemone`, and accepts only a loopback or Tailscale host. `terminal.sh` keeps no install verb, no venv and no server lifecycle: `open` reads `CLUX_CLEF_URL`, checks the host, the client Python and the server, and writes the URL and the key to the state of the companion. The output guard sends blocks of 2,000 characters, then a line search with numbered lines and at most 10 questions in one request, in 45 s.

**Tech Stack:** bash, Python 3.10 or later (standard library only: `urllib`, `ipaddress`, `socket`), bats-core, tmux, Clef (`mlx-community/clef-4bit`) through `clef_mlx.py serve`.

---

## Overview

The spec is `docs/superpowers/specs/2026-10-11-clux-companion-clef-design.md`. It gives only the changes to the 4.0.0 Laya design and the 4.1.0 background sessions design. This plan follows the same order: first the client stops needing the `laya` Python package, then `terminal.sh` stops running a server, then one task renames `laya` to `clef` in the plugin and the tests, then each behavior change of the client (truncate, time limits, hosts, blocks, line search), then the limits, the live tests, the skill, the documents and the version.

The order keeps `bats test/` green after each task. The rename comes after the server work, because the words `laya-serve`, `laya[serve]`, `laya.structured` and `convaiinnovations/laya` name the real Laya package: a rename before the removal would break them. After the rename, every name in the plugin and in the tests is `clef`; `CHANGELOG.md` and the dated design documents under `docs/plans/` and `docs/superpowers/` keep the name Laya.

Tasks 1 to 3 use the old names (`laya_client.py`, `LAYA_*`, `CLUX_LAYA_*`). Task 4 renames them. Tasks 5 to 16 use the new names (`clef_client.py`, `CLEF_*`, `CLUX_CLEF_*`).

---

## Task 1: The client builds the Clef questions from the policy schema

**Goal:** `laya_client.py` turns each policy schema into Clef questions and reads the answers from the wire, so it imports no model package.

**Files touched:**
- Modify: `plugins/clux/scripts/laya_client.py`
- Modify: `plugins/clux/config/laya/command.json`
- Modify: `plugins/clux/config/laya/output-block.json`
- Modify: `plugins/clux/config/laya/output-line.json`
- Modify: `plugins/clux/config/laya/pane.json`
- Modify: `test/test_helper.bash`
- Test: `test/laya-client.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/test_helper.bash`, add this helper after `require_laya_python`:

```bash
# A test that runs the client needs only python3 3.10 or later: the client
# imports no model package (spec section 5).
require_client_python() {
    "$CLUX_LAYA_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
        >/dev/null 2>&1 || skip "no python3 3.10 or later: set CLUX_LAYA_PYTHON"
}
```

  In `test/laya-client.bats`, change `setup()` to call `require_client_python` in place of `require_laya_python`, replace the test `"each policy maps to the Laya questions of the spec"` with the test below, and add the second test after it:

```bash
@test "each policy schema becomes the Clef questions of the spec" {
    run "$CLUX_LAYA_PYTHON" - "$(dirname "$LAYA_CLIENT")" "$REPO_ROOT/plugins/clux/config/laya" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import laya_client as c
def plan(name):
    with open(os.path.join(sys.argv[2], name + ".json"), encoding="utf-8") as f:
        pol = json.load(f)
    assert "model" not in pol, name
    return c.questions_of(pol), pol.get("thresholds"), pol
q, limits, _ = plan("command")
assert {name: item["type"] for name, item in q.items()} == {
    "destructive": "noul", "exposes_secrets": "noul",
    "remote_effect": "noul", "risk": "choice"}, q
assert q["risk"]["criteria"] == {"safe": None, "caution": None, "dangerous": None}, q["risk"]
assert q["destructive"]["instructions"].startswith("Would the command delete data"), q
assert limits == {"destructive": 0.8, "exposes_secrets": 0.8, "remote_effect": 0.8}, limits
q, limits, block = plan("output-block")
assert {name: item["type"] for name, item in q.items()} == {
    "secret": "noul", "prompt_injection": "noul"}, q
assert limits == {"secret": 0.5, "prompt_injection": 0.8}, limits
q, limits, line = plan("output-line")
assert {name: item["type"] for name, item in q.items()} == {"secret": "noul"}, q
assert limits == {"secret": 0.75}, limits
assert block["schema"]["properties"]["secret"] == line["schema"]["properties"]["secret"]
q, _limits, pane = plan("pane")
assert q["state"]["type"] == "choice", q
assert list(q["state"]["criteria"]) == [
    "credential", "yes_no", "menu", "pager", "shell_prompt", "other"], q
# A property that is neither a boolean nor an enum is bad input.
try:
    c.questions_of({"schema": {"properties": {"x": {"type": "string", "description": "?"}}}})
except c.Fail as fail:
    assert fail.code == 2, fail.code
else:
    raise AssertionError("no Fail(2) for a string property")
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the client asks with no model package: python3 -S answers" {
    start_fake_laya '{"answers": {"destructive": 0.9}}'
    # -S leaves out site-packages, so the laya package is not importable.
    run "$CLUX_LAYA_PYTHON" -S -c 'import laya'
    [ "$status" -ne 0 ]
    run --separate-stderr "$CLUX_LAYA_PYTHON" -S "$LAYA_CLIENT" command <<<'rm x'
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "$output" = '{"level": "dangerous", "reason": "destructive 0.90"}' ]
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
cd /Users/jazz/dev/github.com/ai-advanced-futures/clux/.claude/worktrees/clef-5
CLUX_LAYA_PYTHON=python3 bats test/laya-client.bats \
    -f 'becomes the Clef questions|with no model package'
```

  Expect both tests to fail: `AttributeError: module 'laya_client' has no attribute 'questions_of'` for the first, and exit 1 with `laya: not available` (the `from laya.structured import` of `ask` fails) for the second.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/laya_client.py`, add `questions_of` after `policy()`:

```python
def questions_of(pol):
    """The Clef questions of a policy schema (spec section 5): a boolean
    property is a noul question, an enum is a choice question with one
    criterion for each value, and the description is the instruction. Each
    other property type is bad input. The client makes this plan itself, so
    it imports no model package."""
    properties = pol.get("schema", {}).get("properties")
    if not isinstance(properties, dict) or not properties:
        raise Fail(2)
    questions = {}
    for name, prop in properties.items():
        if not isinstance(prop, dict) or not isinstance(prop.get("description"), str):
            raise Fail(2)
        if prop.get("type") == "boolean":
            questions[name] = {"type": "noul", "instructions": prop["description"]}
        elif isinstance(prop.get("enum"), list) and prop["enum"]:
            questions[name] = {"type": "choice", "instructions": prop["description"],
                               "criteria": {value: None for value in prop["enum"]}}
        else:
            raise Fail(2)
    return questions
```

  Replace the `Answer` class and `ask()` with:

```python
class Answer:
    """The answers of one POST /v1/systemone."""

    def __init__(self, result):
        self.result = result
        self.answers = result.get("answers") or {}

    def p(self, name):
        """The noul probability of a boolean question."""
        try:
            value = float(self.answers[name]["noul"])
        except (KeyError, TypeError, ValueError):
            raise Fail(1)
        if not 0.0 <= value <= 1.0:
            raise Fail(1)
        return value

    def choice(self, name, labels):
        try:
            value = self.answers[name]["choice"]
        except (KeyError, TypeError):
            raise Fail(1)
        if value not in labels:
            raise Fail(1)
        return value

    def tokens(self):
        try:
            return int((self.result.get("usage") or {})["input_tokens"])
        except (KeyError, TypeError, ValueError):
            raise Fail(1)


def ask(runner, pol, state):
    """Send one state to Clef with the questions of a policy."""
    return Answer(runner.predict(state, questions_of(pol)))
```

  In `Remote.predict`, drop the `model` parameter and the `model` key of the body:

```python
    def predict(self, state, questions):
        body = {"state": state, "questions": questions}
```

  Delete the `"model": "english"` line from each of the four files in `plugins/clux/config/laya/`, and change the module docstring line `terminal.sh runs this file with the Python of the clux venv, or with` to `terminal.sh runs this file with python3, or with`. In the `Remote` class docstring, drop the `laya.structured.decide` and `LayaDecision` sentences and say instead that the client makes its own plan and sends one POST to the server. [inferred]

- [ ] Step 4 (run test, observe PASS). Run:

```bash
CLUX_LAYA_PYTHON=python3 bats test/laya-client.bats
```

  Expect every test to pass (`ok` for each line, no `not ok`); the tests of `checkpoint`, `ready` and `version` skip or pass as before.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/scripts/laya_client.py plugins/clux/config/laya test/laya-client.bats test/test_helper.bash
git commit -m "refactor(clux): the client builds the Laya questions from the policy schema"
```

**Verification:**

```bash
CLUX_LAYA_PYTHON=python3 bats test/laya-client.bats
grep -c '"model"' plugins/clux/config/laya/*.json
```

The bats run prints no `not ok`. The `grep -c` prints `0` for each of the four policy files. `grep -n 'from laya.structured' plugins/clux/scripts/laya_client.py` prints nothing.

---

## Task 2: `open` needs `CLUX_LAYA_URL`, and `laya status` names that server

**Goal:** `terminal.sh` has no install verb and no venv: `open` reads `CLUX_LAYA_URL`, checks the host, the client Python and the server, and writes `laya_url` and `laya_key` to the state.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `plugins/clux/scripts/laya_client.py`
- Modify: `test/test_helper.bash`
- Test: `test/terminal.bats`
- Test: `test/terminal-e2e.bats`
- Test: `test/laya-client.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/terminal.bats`, add these tests:

```bash
@test "open with no CLUX_LAYA_URL exits 6 and names the variable" {
    open_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run env -u CLUX_LAYA_URL STUB_LOG="$log" CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" \
        TMUX=fake TMUX_PANE=%0 "$TERMINAL" open
    [ "$status" -eq 6 ]
    [ "$output" = 'laya not configured: set CLUX_LAYA_URL to the URL of your Laya server' ]
    ! grep -q 'split-window' "$log" || false
}

@test "open needs a client python3 3.10 or later" {
    open_tmux_stub
    printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/old-python"
    chmod +x "$BATS_TEST_TMPDIR/old-python"
    local py
    for py in "$BATS_TEST_TMPDIR/none/python3" "$BATS_TEST_TMPDIR/old-python"; do
        run env CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" TMUX=fake TMUX_PANE=%0 \
            CLUX_LAYA_PYTHON="$py" CLUX_LAYA_URL=http://127.0.0.1:9 "$TERMINAL" open
        [ "$status" -eq 6 ] || { echo "$py gave $status"; false; }
        [ "$output" = 'laya not available: the client needs python3 3.10 or later' ]
    done
}

@test "write_state and state_load carry the two laya fields" {
    local d="$BATS_TEST_TMPDIR/d"
    mkdir -p "$d"
    run bash -c "source '$TERMINAL'; D='$d'
        write_state split %2 '' 3 http://127.0.0.1:8765 'k e y'
        state_load
        printf '%s|%s|%s\n' \"\$S_SEQ\" \"\$S_LAYA_URL\" \"\$S_LAYA_KEY\""
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$output" = '3|http://127.0.0.1:8765|k e y' ]
    ! grep -q '^laya_pid=' "$d/state" || false
    grep -qx 'laya_url=http://127.0.0.1:8765' "$d/state"
}

@test "laya status prints the url, the key state, the host and the server" {
    start_fake_laya '{}'
    run env -u TMUX -u TMUX_PANE "$TERMINAL" laya status
    [ "$status" -eq 0 ]
    [ "$output" = "url=$CLUX_LAYA_URL"$'\nkey=set\nhost=loopback\nserver=answers' ] \
        || { echo "$output"; false; }
    [[ "$output" != *"$CLUX_LAYA_KEY"* ]] || { echo 'the key is printed'; false; }
    stop_fake_laya
    run env -u TMUX -u TMUX_PANE "$TERMINAL" laya status
    [[ "$output" == *$'\nserver=no answer' ]] || { echo "$output"; false; }
    run env -u TMUX -u TMUX_PANE -u CLUX_LAYA_URL -u CLUX_LAYA_KEY "$TERMINAL" laya status
    [ "$output" = $'url=none\nkey=none\nhost=refused\nserver=not checked' ] || { echo "$output"; false; }
    run env -u TMUX -u TMUX_PANE CLUX_LAYA_URL=http://example.com:1 "$TERMINAL" laya status
    [ "$output" = $'url=http://example.com:1\nkey=set\nhost=refused\nserver=not checked' ] \
        || { echo "$output"; false; }
}

@test "open on a live companion with no laya_url in its state says close and open" {
    local root="$BATS_TEST_TMPDIR/root" d
    open_tmux_stub
    d="$root/fake-0"
    mkdir -p "$d"
    printf 'mode=split\npane=%%1\nsocket=\nseq=0\n' > "$d/state"
    run env STUB_LOG="$BATS_TEST_TMPDIR/stub.log" CLUX_TERMINAL_DIR="$root" \
        TMUX=fake TMUX_PANE=%0 CLUX_LAYA_URL=http://127.0.0.1:9 bash -c "source '$TERMINAL'
        terminal_init() { D='$d'; ROOT='$root'; }
        current_companion_alive() { state_load; }
        reap_companions() { :; }
        dir_lock() { :; }
        require_owner
        open_command"
    [ "$status" -eq 6 ]
    [ "$output" = 'laya not available: this companion has no Laya server: use close, then open' ]
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/terminal.bats -f 'no CLUX_LAYA_URL|python3 3.10 or later|two laya fields|laya status prints|no laya_url in its state'
```

  Expect failures: `open` still starts its own server (exit 0 or the install message), `laya status` prints `venv=…`, and `write_state` still writes `laya_pid=`.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/terminal.sh`:

  Replace the Laya block at the top of the file (the `LAYA_CLIENT` … `LAYA_PY` lines) with:

```bash
# Laya (spec 2026-10-11-clux-companion-clef-design.md). laya_client.py is the
# only code that speaks to the model. clux does not install, start or stop a
# server: the user runs one, and CLUX_LAYA_URL names it.
LAYA_CLIENT="$SCRIPT_DIR/laya_client.py"
LAYA_PY="${CLUX_LAYA_PYTHON:-python3}"
```

  Delete `LAYA_INSTALL_BUDGET` and its comment. Change the `usage` line to:

```bash
    printf '%s\n' 'usage: terminal.sh open|run|send|read|wait|close|list|check-line|laya status' >&2
```

  Replace `laya_url_is_loopback`, `laya_checkpoint_present`, `laya_installed`, `laya_python_ready`, `laya_open_check`, `laya_key_check` and `laya_restart_if_down` with:

```bash
# The client makes the host check, so the rule is in one place. It prints the
# kind of the host (loopback) on success.
laya_host_kind() {
    "$LAYA_PY" "$LAYA_CLIENT" check-url "$1" 2>/dev/null
}

# The client needs python3 3.10 or later (spec section 6, step 3).
laya_python_ok() {
    [ -n "$LAYA_PY" ] || return 1
    "$LAYA_PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
        >/dev/null 2>&1
}

# The Laya checks of open, before it makes $D (spec section 6, steps 1 to 4).
# Each refusal exits 6. They set S_LAYA_URL and S_LAYA_KEY, which laya_call
# reads, so the health and the pane request go to the named server.
laya_open_check() {
    [ -n "${CLUX_LAYA_URL:-}" ] \
        || fail 'laya not configured: set CLUX_LAYA_URL to the URL of your Laya server' 6
    laya_host_kind "$CLUX_LAYA_URL" >/dev/null \
        || fail 'laya not configured: the host of CLUX_LAYA_URL is not a loopback host' 6
    laya_python_ok || fail 'laya not available: the client needs python3 3.10 or later' 6
    S_LAYA_URL="$CLUX_LAYA_URL"
    S_LAYA_KEY="${CLUX_LAYA_KEY:-}"
    laya_call health >/dev/null || laya_open_failed $?
    laya_probe
}

# One pane request with a fixed one-word state (spec section 6, step 4): a bad
# key, or a server that is not Laya, fails at open. The state is not the pane:
# this request runs before the pane opens. An empty state sends no request.
laya_probe() {
    printf '%s\n' 'clux$' | laya_call pane >/dev/null || laya_open_failed $?
}

laya_open_failed() {
    case "$1" in
        4) fail 'laya not available: the server at CLUX_LAYA_URL refused CLUX_LAYA_KEY: set the key of that server' 6 ;;
        *) fail 'laya not available: the server at CLUX_LAYA_URL does not answer' 6 ;;
    esac
}

# open on a live companion (spec section 6, step 5): the checks run again, and
# the current CLUX_LAYA_URL replaces an older laya_url in the state. A
# companion of 4.x has no laya_url.
laya_reopen() {
    [ -n "$S_LAYA_URL" ] \
        || fail 'laya not available: this companion has no Laya server: use close, then open' 6
    laya_open_check
    write_state "$S_MODE" "$S_PANE" "$S_SOCKET" "$S_SEQ" "$S_LAYA_URL" "$S_LAYA_KEY"
}
```

  In `write_state`, change the comment and the argument block to two laya fields and drop the `laya_pid` line:

```bash
# write_state MODE PANE SOCKET SEQ [LAYA_URL LAYA_KEY]: with four arguments
# the laya fields keep the values that state_load read.
...
    if [ "$#" -ge 5 ]; then
        S_LAYA_URL="$5"
        S_LAYA_KEY="${6:-}"
    fi
```

  and remove the line `[ -z "$S_LAYA_PID" ] || printf 'laya_pid=%s\n' "$S_LAYA_PID"`. In `state_load`, remove the `laya_pid) S_LAYA_PID="$value" ;;` case.

  In `open_command`: change `laya_restart_if_down || return` to `laya_reopen || return`; delete the `LAYA_PID=`, `LAYA_URL=`, `LAYA_KEY=`, `: > "$D/laya.log"` and `laya_start_server` lines; change each of the four `write_state` calls to pass `"$S_LAYA_URL" "$S_LAYA_KEY"` in place of `"$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"`; and delete the block:

```bash
    if [ -n "$S_LAYA_PID" ]; then
        laya_wait_ready || open_abort 1 'laya not available: the server did not answer'
    fi
```

  Replace `laya_status_server`, `laya_status` and `laya_command` with:

```bash
# laya status (spec section 9). It sends one health request when the URL is
# set and the host is allowed. It never prints the key.
laya_status() {
    local url="${CLUX_LAYA_URL:-}" key=none host=refused server='not checked'
    [ -z "${CLUX_LAYA_KEY:-}" ] || key=set
    if [ -n "$url" ]; then
        host=$(laya_host_kind "$url") || host=refused
        [ -n "$host" ] || host=refused
        if [ "$host" != refused ]; then
            if S_LAYA_URL="$url" S_LAYA_KEY="${CLUX_LAYA_KEY:-}" laya_call health >/dev/null; then
                server=answers
            else
                server='no answer'
            fi
        fi
    fi
    printf 'url=%s\nkey=%s\nhost=%s\nserver=%s\n' "${url:-none}" "$key" "$host" "$server"
}

laya_command() {
    [ "$#" -eq 1 ] || usage
    case "$1" in
        status) laya_status ;;
        *) usage ;;
    esac
}
```

  Delete `laya_find_python`, `LAYA_INSTALL_PID`, `LAYA_INSTALL_LOG`, `laya_install_cleanup`, `laya_download_failed`, `laya_download` and `laya_install`. In `main`, change the comment above the `laya)` arm to `# No require_owner: status operates outside tmux too.`

  In `plugins/clux/scripts/laya_client.py`, make `check-url` print the kind:

```python
def cmd_check_url(args):
    """check-url URL: print the kind of the host of a URL that the client may
    use (loopback), else exit 1. open and laya status read it."""
    if len(args) != 1:
        raise Fail(2)
    if not url_is_loopback(args[0]):
        raise Fail(1, message=False)
    print("loopback")
```

  In `test/test_helper.bash`, change the client Python default and delete the venv helpers:

```bash
# The Python that runs laya_client.py in the tests: any python3 3.10 or later
# (spec section 5). 5.0.0 has no venv.
export CLUX_LAYA_PYTHON="${CLUX_LAYA_PYTHON:-python3}"
```

  Delete `require_laya_python`, `make_fake_checkpoint` and `make_fake_venv`. The `@test` blocks `"checkpoint follows HF_HUB_CACHE"` and `"ready: one process checks the laya import and the checkpoint"` of `test/laya-client.bats` call `make_fake_checkpoint`, so delete them here, with the helper. [inferred] In `test/terminal-e2e.bats` `setup()`, replace `require_laya_python` with `require_client_python`. Each `require_laya_python` call that stays in `test/terminal.bats` becomes `require_client_python` too. [inferred]

  Delete these obsolete `@test` blocks from `test/terminal.bats`: `"open refuses a CLUX_LAYA_URL that is not a loopback host"` (the new `laya status` test and Task 8 cover the host rule), `"open with CLUX_LAYA_URL needs a client Python that imports laya"`, `"open refuses when the CLUX_LAYA_URL server does not answer"`, `"open with no venv, or with no checkpoint, gives exit 6 and the install message"`, `"laya status with no venv"`, `"laya status with the venv and the checkpoint"`, `"laya install stops when the venv and the checkpoint are present"`, `"laya install needs Python 3.10 or later"`, `"a failed pip install deletes the venv and shows the pip error"`, `"laya install with the venv and no checkpoint needs no base python3"`, `"laya install makes a broken venv again, and names a CLUX_LAYA_PYTHON with no laya"`, `"laya_installed starts one Python process for the venv"`, `"one function checks that a Python can import laya"`, `"open on a live companion with no Laya server of its own, or a dead external server, exits 6"`, `"open restarts the laya server only under the typing lock"`, `"open with CLUX_LAYA_URL does not use the laya_pid of a dead companion"`, `"write_state and state_load carry the three laya fields"`, `"a failed checkpoint download keeps the venv and removes secret lines from the log"`, `"the client makes the loopback URL check of terminal.sh"`, `"laya status names the server of a session owner"`. [inferred]

  Delete these `@test` blocks from `test/terminal-e2e.bats`: `"close stops the laya server that open started and deletes laya.log"`, `"open stops the laya server of a dead companion of the same owner"`, `"the reaper stops the laya server of an owner pane that is gone"`, `"open starts a new laya server when the server that it started is gone"`, and `"close --hook still stops a server that ignores TERM, after the hook ends"` (nothing of it survives with the server gone). Keep `"close --hook removes the pane and the directory first and does not wait for the server"`, replacing its `open` line with `XDG_DATA_HOME="$data" "$TERMINAL" open >/dev/null`, so the `make_fake_venv`, `make_fake_checkpoint`, `HF_HUB_CACHE`, `CLUX_FAKE_LAYA_IGNORE_TERM=1`, `CLUX_LAYA_URL=` and `CLUX_LAYA_KEY=` parts drop out: `setup()` already starts the fake server and sets `CLUX_LAYA_URL`. Drop the `pid`, `kill -0`, `alive` and `kill -9` lines with them, keeping its `[ "$status" -eq 0 ]`, `[ "$took" -lt 2 ]`, `[ ! -e "$d" ]` and `list-panes` checks. [inferred]

  In `test/terminal.bats`, change the test `"open of a session owner writes state with laya_pid before the pane, then marks a window in the dashboard session"`: rename it to `"open of a session owner writes state with laya_url before the pane, then marks a window in the dashboard session"`, drop the `laya_start_server`, `laya_wait_ready` and `-u CLUX_LAYA_URL` parts of the stub, change the stub `laya_open_check() { :; }` to `laya_open_check() { S_LAYA_URL="$CLUX_LAYA_URL"; S_LAYA_KEY=; }`, add `CLUX_LAYA_URL=http://127.0.0.1:8765` to the environment, and change `grep -qx 'laya_pid=4242' "$before"` to `grep -qx 'laya_url=http://127.0.0.1:8765' "$before"`. In `"the sessions reaper removes the directory of a dead owner, stops its laya server, and keeps a live one"`, rename it to `"the sessions reaper removes the directory of a dead owner and keeps a live one"` and delete the lines that check the stopped server. In `"open checks the key of an external server with one POST"`, change `laya_key_check` to `laya_probe` where the test names the function, and change its second half to:

```bash
run --separate-stderr bash -c "source '$TERMINAL'; CLUX_LAYA_URL=http://127.0.0.1:9; S_LAYA_URL=http://127.0.0.1:9
    laya_call() { [ \"\$1\" = health ] && return 0; cat >/dev/null; return 4; }; laya_reopen; echo SUCCESS"
[ "$status" -eq 6 ]
[[ "$stderr" == *'refused CLUX_LAYA_KEY'* ]] || false
```

so the exit 4 path of `laya_reopen` keeps its test: `CLUX_LAYA_URL` lets `laya_open_check` reach `laya_probe`, and the stub `laya_call` answers `health` but fails every other call. [inferred]

  In `test/terminal-e2e.bats`, change `"laya status names the server of this companion"` to assert the new four lines:

```bash
@test "laya status names the server of CLUX_LAYA_URL" {
    run "$TERMINAL" laya status
    [ "$output" = "url=$CLUX_LAYA_URL"$'\nkey=set\nhost=loopback\nserver=answers' ] \
        || { echo "$output"; false; }
    stop_fake_laya
    run "$TERMINAL" laya status
    [[ "$output" == *$'\nserver=no answer' ]] || { echo "$output"; false; }
}
```

  In `"the watchdog closes a background companion and stops its laya server when the owner process ends"`, rename it to `"the watchdog closes a background companion when the owner process ends"`, delete the `make_fake_venv` call and the `laya_pid` lines, and keep the directory check.

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/terminal.bats test/terminal-e2e.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/scripts/terminal.sh plugins/clux/scripts/laya_client.py \
    test/terminal.bats test/terminal-e2e.bats test/laya-client.bats test/test_helper.bash
git commit -m "feat(clux)!: open needs CLUX_LAYA_URL, no install verb and no venv"
```

**Verification:**

```bash
bats test/terminal.bats test/terminal-e2e.bats
grep -n 'laya_install\|LAYA_VENV\|laya status' plugins/clux/scripts/terminal.sh | head
```

The bats run prints no `not ok`. The grep shows no `laya_install` function and no `LAYA_MARKER`; `LAYA_VENV` appears only in the lines that Task 3 deletes. `env -u TMUX -u TMUX_PANE -u CLUX_LAYA_URL bash plugins/clux/scripts/terminal.sh laya status` prints `url=none`, `key=none`, `host=refused`, `server=not checked`.

---

## Task 3: terminal.sh and the client drop the server lifecycle

**Goal:** No code of clux starts, checks or stops a model server, and the client helpers of the install are gone.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `plugins/clux/scripts/laya_client.py`
- Modify: `test/test_helper.bash`
- Delete: `test/laya-live.bats`
- Test: `test/terminal.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/terminal.bats`, add:

```bash
@test "no code of clux starts, checks or stops a model server" {
    local name
    for name in laya_start_server laya_stop_server laya_stop_server_later laya_wait_health \
        laya_wait_ready laya_owns_port laya_proc_owns_port laya_pid_is_server laya_pid_check \
        laya_restart_if_down laya_installed laya_checkpoint_present laya_python_ready \
        stop_reaped_servers close_stop_server S_LAYA_PID LAYA_VENV LAYA_MARKER LAYA_VERSION; do
        ! grep -qF "$name" "$TERMINAL" || { echo "$name is still in terminal.sh"; false; }
    done
    # The client keeps only the subcommands of spec section 5.
    run "$CLUX_LAYA_PYTHON" -c 'import sys; sys.path.insert(0, sys.argv[1]); import laya_client as c
print(" ".join(sorted(c.SUBCOMMANDS)))' "$(dirname "$LAYA_CLIENT")"
    [ "$output" = 'after-cursor check-url command health output pane scrub' ] || { echo "$output"; false; }
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/terminal.bats -f 'starts, checks or stops a model server'
```

  Expect `laya_start_server is still in terminal.sh`.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/terminal.sh`, delete these functions and variables with their comments: `laya_pid_check`, `LAYA_PID_CHECKED`, `laya_pid_is_server`, `laya_stop_server`, `laya_stop_server_later`, `laya_start_server`, `laya_wait_health`, `laya_owns_port`, `laya_proc_owns_port`, `PROC_ROOT`, `laya_wait_ready`, `laya_restart_if_down`, `stop_reaped_servers`, `REAP_PIDS`, `close_stop_server`, and the global `S_LAYA_PID=`.

  Change the callers:

```bash
laya_call() {
    CLUX_LAYA_URL="$S_LAYA_URL" CLUX_LAYA_KEY="$S_LAYA_KEY" "$LAYA_PY" "$LAYA_CLIENT" "$@" 2>/dev/null
}
```

  In `remove_companion_dir`, delete the line `[ -z "$S_LAYA_PID" ] || REAP_PIDS+=("$S_LAYA_PID")`. In `reap_companions` and in `open_command`, delete the `stop_reaped_servers` calls. In `open_abort`, delete the `laya_stop_server "$LAYA_PID"` line. In `close_session_dir` and in `close_pane_locked`, delete the `close_stop_server` calls. In `pane_state` and `laya_gate`, delete the `laya_pid_check || return 1` and `|| return 6` lines. In `laya_guard_call`, delete the `laya_pid_check || return 6` line. Delete the `laya.log` lines of `close`, and the comment lines that name the pid of a server.

  In `plugins/clux/scripts/laya_client.py`, delete `cmd_checkpoint`, `cmd_ready`, `cmd_port`, `cmd_version` and `cmd_pip_install`, their entries in `SUBCOMMANDS`, and the docstring line `Helpers that do not ask Laya: checkpoint, ready, port, version, pip-install SECONDS PACKAGE, scrub.`; put in its place:

```
Helpers that do not ask Laya: check-url, after-cursor, scrub.
```

  In `test/test_helper.bash`, delete `start_live_laya` and `stop_live_laya`. Delete the file `test/laya-live.bats` (Task 13 writes the live tests again for Clef).

  Delete these `@test` blocks from `test/terminal.bats`: `"laya_owns_port finds the process that listens on the port"`, `"laya_owns_port reads /proc with no lsof and no ss, and with none of them it fails"`, `"laya_stop_server stops several servers that ignore TERM with one wait"`, `"laya_wait_health uses laya_call with no key"`, `"the key of laya-serve is not an argument of a process"`, `"laya_call sends nothing when the server that open started ended"`, `"laya_call sends nothing when the pid of the server is alive but not laya-serve"`, `"the laya-serve check of the pid runs one time in a verb, also for calls in a subshell"`. In `"pane_state, laya_guard and the key checks have no copies and no forks"`, delete the assertions that name `laya_pid_check`.

  Delete the `@test` block `"port prints a free loopback port"` from `test/laya-client.bats`: Task 2 already deleted `"checkpoint follows HF_HUB_CACHE"` and `"ready: one process checks the laya import and the checkpoint"` with `make_fake_checkpoint`. [inferred] Replace `"version, pip-install and scrub"` with:

```bash
@test "scrub drops each line that secret-values.txt holds" {
    run client scrub < <(printf 'plain line\nkey AKIAABCDEFGHIJKLMNOP\nlast line\n')
    [ "$status" -eq 0 ]
    [ "$output" = $'plain line\nlast line' ]
}
```

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add -A plugins/clux/scripts test
git commit -m "refactor(clux)!: clux does not start, check or stop a model server"
```

**Verification:**

```bash
bats test/
grep -rn 'laya\[serve\]\|laya.structured' plugins/clux test || echo clean
```

The bats run prints no `not ok`. The grep prints `clean`: no code of the plugin or the tests imports the Laya package any more. Task 7's verification checks for the server verb and the real package name, after the rename and the fixture rewrite replace them. [inferred]

---

## Task 4: Rename `laya` to `clef` in the plugin and the tests

**Goal:** Every name of the plugin and of the tests reads `clef` (spec section 10); `CHANGELOG.md` and the dated design documents keep the name Laya.

**Files touched:**
- Create: `test/clef-names.bats`
- Modify: every tracked file except `CHANGELOG.md`, `docs/plans/*` and `docs/superpowers/*`
- Rename: `plugins/clux/scripts/laya_client.py` → `clef_client.py`
- Rename: `plugins/clux/config/laya/` → `plugins/clux/config/clef/`
- Rename: `test/laya-client.bats` → `test/clef-client.bats`
- Rename: `test/laya-fixtures.bats` → `test/clef-fixtures.bats`
- Rename: `test/fixtures/fake-laya.py` → `test/fixtures/fake-clef.py`
- Rename: `test/fixtures/capture-laya-wire.sh` → `test/fixtures/capture-clef-wire.sh`
- Rename: `test/fixtures/laya-wire/` → `test/fixtures/clef-wire/`

**Steps:**

- [ ] Step 1 (failing test). Create `test/clef-names.bats`:

```bash
#!/usr/bin/env bats
# clef-names.bats — 5.0.0 renamed Laya to Clef (spec section 10). The
# changelog and the dated design documents keep the old name; each other file
# must not.

load test_helper

@test "clef-names: no laya name is left outside the changelog and the designs" {
    run bash -c "cd '$REPO_ROOT' && grep -rniI laya . \
        --exclude-dir=.git --exclude-dir=.acpx-prompts --exclude-dir=plans \
        --exclude-dir=superpowers --exclude=CHANGELOG.md --exclude=clef-names.bats || true"
    [ -z "$output" ] || { echo "$output"; false; }
}

@test "clef-names: the client, the policies and the fixtures have their new names" {
    [ -f "$REPO_ROOT/plugins/clux/scripts/clef_client.py" ]
    [ -d "$REPO_ROOT/plugins/clux/config/clef" ]
    [ -f "$REPO_ROOT/test/fixtures/fake-clef.py" ]
    [ -d "$REPO_ROOT/test/fixtures/clef-wire" ]
    [ ! -e "$REPO_ROOT/plugins/clux/scripts/laya_client.py" ]
    [ ! -e "$REPO_ROOT/plugins/clux/config/laya" ]
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/clef-names.bats
```

  Expect both tests to fail: the grep prints many lines, and `clef_client.py` does not exist.

- [ ] Step 3 (minimal implementation). Run the rename, then the file moves:

```bash
cd /Users/jazz/dev/github.com/ai-advanced-futures/clux/.claude/worktrees/clef-5
git ls-files \
    | grep -v '^CHANGELOG.md$' | grep -v '^docs/plans/' | grep -v '^docs/superpowers/' \
    | while IFS= read -r file; do
        LC_ALL=C sed -i '' -e 's/laya/clef/g; s/LAYA/CLEF/g; s/Laya/Clef/g' "$file"
    done
git mv plugins/clux/scripts/laya_client.py plugins/clux/scripts/clef_client.py
git mv plugins/clux/config/laya plugins/clux/config/clef
git mv test/laya-client.bats test/clef-client.bats
git mv test/laya-fixtures.bats test/clef-fixtures.bats
git mv test/fixtures/fake-laya.py test/fixtures/fake-clef.py
git mv test/fixtures/capture-laya-wire.sh test/fixtures/capture-clef-wire.sh
git mv test/fixtures/laya-wire test/fixtures/clef-wire
```

  Then fix the two places that the rename must not change:

  1. In `test/terminal.bats`, the release test reads the history of `CHANGELOG.md`, which keeps the name Laya. Replace that test with:

```bash
@test "the 4.0.0 release names Laya and the run time limit" {
    local t section
    t=$(bash -c "source '$TERMINAL'; echo \"\$RUN_TIMEOUT_DEFAULT\"")
    section=$(awk '/^## \[4\.0\.0\]/ { on = 1; next } /^## \[/ { on = 0 } on' "$REPO_ROOT/CHANGELOG.md")
    [[ "$section" == *'needs Laya'* ]] || false
    [[ "$section" == *"$t seconds"* ]] || false
}
```

  2. In `plugins/clux/scripts/clef_client.py`, the module docstring and the comments now read `Clef`; check that no sentence names a server verb that is gone (`clef-serve`). Replace each `clef-serve` with `the Clef server`.

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/clef-names.bats && bats test/
```

  Expect no `not ok` in either run.

- [ ] Step 5 (commit).

```bash
git add -A
git commit -m "refactor(clux)!: rename laya to clef in the plugin and the tests"
```

**Verification:**

```bash
bats test/
grep -rniI laya . --exclude-dir=.git --exclude-dir=.acpx-prompts --exclude-dir=plans \
    --exclude-dir=superpowers --exclude=CHANGELOG.md --exclude=clef-names.bats || echo clean
```

The bats run prints no `not ok`, and the grep prints `clean`. `ls plugins/clux/config/clef` lists `command.json`, `output-block.json`, `output-line.json`, `pane.json`, `secret-values.txt` and `not-secret.txt`.

---

## Task 5: The fake server and the wire captures: `truncate` and 413

**Goal:** `test/fixtures/fake-clef.py` answers in the wire form of `clef_mlx.py serve`, logs the full questions and the `truncate` field of each request, and answers 413 for a state that is too long with `"truncate": false`.

**Files touched:**
- Modify: `test/fixtures/fake-clef.py`
- Modify: `test/fixtures/capture-clef-wire.sh`
- Modify: `test/fixtures/clef-wire/health.json`
- Modify: `test/fixtures/clef-wire/noul-request.json`
- Modify: `test/fixtures/clef-wire/noul-response.json`
- Modify: `test/fixtures/clef-wire/choice-request.json`
- Modify: `test/fixtures/clef-wire/choice-response.json`
- Create: `test/fixtures/clef-wire/too-long-413.json`
- Modify: `test/test_helper.bash`
- Test: `test/clef-fixtures.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/clef-fixtures.bats`, replace the first test with the one below and add the second:

```bash
@test "the captures hold health, a noul answer, a choice answer, a 503 and a 413" {
    run python3 - "$WIRE" <<'PY'
import json, os, sys
w = sys.argv[1]
def load(name):
    with open(os.path.join(w, name), encoding="utf-8") as f:
        return json.load(f)
noul = load("noul-response.json")
assert {"answers", "usage"} <= set(noul), sorted(noul)
a = noul["answers"]["destructive"]
assert a["type"] == "noul" and 0.0 <= float(a["noul"]) <= 1.0
assert isinstance(noul["usage"]["input_tokens"], int)
choice = load("choice-response.json")
r = choice["answers"]["risk"]
assert r["type"] == "choice" and r["choice"] in r["probabilities"]
assert set(r["probabilities"]) == {"safe", "caution", "dangerous"}
for name in ("noul-request.json", "choice-request.json"):
    body = load(name)
    assert body["truncate"] is False, name
    assert "model" not in body, name
assert load("noul-request.json")["questions"]["destructive"]["type"] == "noul"
assert load("choice-request.json")["questions"]["risk"]["type"] == "choice"
assert "detail" in load("busy-503.json")
assert "maximum context length exceeded" in load("too-long-413.json")["detail"]
with open(os.path.join(w, "busy-503.status"), encoding="utf-8") as f:
    assert f.read().strip() == "503"
assert isinstance(load("health.json"), dict)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the fake server answers 413 for a long state with truncate false, and logs each request" {
    start_fake_clef '{"too_long": 20}'
    run python3 - "$CLUX_CLEF_URL" "$CLUX_CLEF_KEY" <<'PY'
import json, sys, urllib.error, urllib.request
url, key = sys.argv[1:3]
def post(body):
    request = urllib.request.Request(url + "/v1/systemone", data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=5) as answer:
            return 200, json.loads(answer.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())
questions = {"secret": {"type": "noul", "instructions": "Secret?"}}
long_state = "x" * 40
code, body = post({"state": long_state, "questions": questions, "truncate": False})
assert code == 413, (code, body)
assert "maximum context length exceeded" in body["detail"], body
# With no truncate field the server cuts and answers.
assert post({"state": long_state, "questions": questions})[0] == 200
assert post({"state": "x", "questions": questions, "truncate": False})[0] == 200
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(fake_clef_requests truncate | sort -u | tr '\n' ' ')" = 'false null ' ] \
        || { fake_clef_requests truncate; false; }
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/clef-fixtures.bats
```

  Expect `FileNotFoundError: too-long-413.json` in the first test and `assert code == 413` in the second (the fake answers 200).

- [ ] Step 3 (minimal implementation). Write the wire files:

```bash
cd /Users/jazz/dev/github.com/ai-advanced-futures/clux/.claude/worktrees/clef-5/test/fixtures/clef-wire
cat > health.json <<'JSON'
{"status":"ok","model":"mlx-community/clef-4bit","revision":"b973b6f405d02f8e9b83208c7e82ddf43a742eb6"}
JSON
cat > noul-request.json <<'JSON'
{"state": "rm -rf ~/dev", "truncate": false, "questions": {"destructive": {"type": "noul", "instructions": "Would the command delete data, overwrite files, or change the system in a way that is hard to undo?"}}}
JSON
cat > noul-response.json <<'JSON'
{"answers":{"destructive":{"type":"noul","noul":0.9812,"confidence":0.9812}},"usage":{"input_tokens":54,"output_tokens":0}}
JSON
cat > choice-request.json <<'JSON'
{"state": "rm -rf ~/dev", "truncate": false, "questions": {"risk": {"type": "choice", "instructions": "How risky is it to run this shell command?", "criteria": {"safe": null, "caution": null, "dangerous": null}}}}
JSON
cat > choice-response.json <<'JSON'
{"answers":{"risk":{"type":"choice","choice":"dangerous","probabilities":{"safe":0.0071,"caution":0.0402,"dangerous":0.9527},"confidence":0.9527}},"usage":{"input_tokens":29,"output_tokens":0}}
JSON
cat > too-long-413.json <<'JSON'
{"detail":"maximum context length exceeded"}
JSON
```

  `busy-503.json` and `busy-503.status` stay as they are: `clef_mlx.py serve` gives no 503, and the client keeps its retry for a proxy in front of the server (spec section 5).

  In `test/fixtures/fake-clef.py`: change the docstring to name `clef_mlx.py serve` and the new settings, load the 413 body, log the full questions and the `truncate` field, and answer 413:

```python
NOUL = load("noul-response.json")
CHOICE = load("choice-response.json")
HEALTH = load("health.json")
BUSY = load("busy-503.json")
TOO_LONG = load("too-long-413.json")
```

```python
def log(body):
    path = os.environ.get("CLUX_FAKE_CLEF_LOG")
    if not path:
        return
    line = json.dumps({"state": body.get("state"),
                       "questions": body.get("questions") or {},
                       "truncate": body.get("truncate")})
    with LOCK:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
```

  In `do_POST`, after `log(body)` and the status queue, add:

```python
        # clef_mlx.py serve: with "truncate": false a state that is longer
        # than the context gives 413. Without it, the server cuts the state.
        if body.get("truncate") is False and len(text) > int(conf.get("too_long", 10 ** 9)):
            return self.reply(413, TOO_LONG)
```

  (`text = state_text(body.get("state"))` already exists below the status queue: move that line above this check.)

  Also replace the comment `# clef-serve gives the sum over the question rows` above the `input_tokens` line with `# clef_mlx.py serve gives the sum over the question rows`, and change the header comment of `test/clef-fixtures.bats` (the line naming "the real clef-serve 0.3.21") the same way: `clef-serve` becomes `clef_mlx.py serve`. Task 7's verification greps for `clef-serve`, so each comment must drop it. [inferred]

  In `test/test_helper.bash`, add the request reader next to `fake_clef_states`:

```bash
# fake_clef_requests FIELD — print FIELD of each logged request, one JSON
# value for each line (for example truncate).
fake_clef_requests() {
    [ -f "${FAKE_CLEF_LOG:-}" ] || return 0
    python3 - "$FAKE_CLEF_LOG" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as log:
    for raw in log:
        print(json.dumps(json.loads(raw).get(sys.argv[2])))
PY
}
```

  Rewrite `test/fixtures/capture-clef-wire.sh` for the real server:

```bash
#!/usr/bin/env bash
# capture-clef-wire.sh — record the wire format of the real clef_mlx.py serve
# into test/fixtures/clef-wire/. fake-clef.py and the client tests use these
# files as the source of truth. Run it again after a model change.
#
#   CLUX_CLEF_URL=http://127.0.0.1:8765 test/fixtures/capture-clef-wire.sh
#
# It starts no server: the user runs the Clef server (docs/reference.md).
# busy-503.json and busy-503.status are not captured here: clef_mlx.py serve
# gives no 503. They are the answer of a proxy in front of the server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/clef-wire"
url="${CLUX_CLEF_URL:?set CLUX_CLEF_URL to the URL of your Clef server}"
auth=()
[ -z "${CLUX_CLEF_KEY:-}" ] || auth=(-H "Authorization: Bearer $CLUX_CLEF_KEY")

post() {
    curl -sS -X POST "$url/v1/systemone" "${auth[@]}" \
        -H 'Content-Type: application/json' --data-binary "@$1"
}

mkdir -p "$out"
curl -fsS "${auth[@]}" "$url/health" > "$out/health.json"
post "$out/noul-request.json" > "$out/noul-response.json"
post "$out/choice-request.json" > "$out/choice-response.json"

# A state above the 16,384 tokens of Clef with "truncate": false gives 413.
python3 -c 'import json; print(json.dumps({"state": "word " * 40000, "truncate": False,
    "questions": {"a": {"type": "noul", "instructions": "Is this text long?"}}}))' > "$out/long.json"
code=$(curl -sS -o "$out/too-long-413.json" -w '%{http_code}' -X POST "$url/v1/systemone" \
    "${auth[@]}" -H 'Content-Type: application/json' --data-binary "@$out/long.json")
rm -f "$out/long.json"
[ "$code" = 413 ] || { echo "a long state gave $code, not 413" >&2; exit 1; }
```

  In `test/clef-fixtures.bats`, drop the `"model"` assertions of the remaining tests and change the rule test to post `"truncate": false` with each body.

  The log now holds the questions as an object, not a sorted list of names. Fix the two readers in `test/clef-client.bats` that compare it with a list: in the `line_requests` helper, change `if request["questions"] == ["secret"]:` to `if sorted(request["questions"]) == ["secret"]:`, and in `"output: a line that secret-values.txt holds sends no line request"`, change `if request["questions"] != ["secret"]:` to `if sorted(request["questions"]) != ["secret"]:`.

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/clef-fixtures.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add test/fixtures test/clef-fixtures.bats test/test_helper.bash
git commit -m "test(clux): the fake Clef server answers 413 for a state that is too long"
```

**Verification:**

```bash
bats test/clef-fixtures.bats test/clef-client.bats
python3 -c 'import json; print(json.load(open("test/fixtures/clef-wire/too-long-413.json"))["detail"])'
```

The bats run prints no `not ok`, and the Python line prints `maximum context length exceeded`.

---

## Task 6: The client sends `truncate: false`, and 413 is exit 3

**Goal:** Each request carries `"truncate": false`; a 413 is exit 3; the cut rules (`CUT_TOKENS`, `ROW_MARGIN`, the split of a cut block, the shorter states) are gone.

**Files touched:**
- Modify: `plugins/clux/scripts/clef_client.py`
- Test: `test/clef-client.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/clef-client.bats`, add:

```bash
@test "each request carries truncate false, and a 413 is too long to examine" {
    start_fake_clef '{"too_long": 500}'
    run --separate-stderr client command <<<'ls -la'
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    run --separate-stderr client output --render < <(printf 'one line\ntwo lines\n')
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    run --separate-stderr client pane <<<'clux$ '
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "$(fake_clef_requests truncate | sort -u)" = 'false' ] || { fake_clef_requests truncate; false; }
    # A state that is too long: the server answers 413 and the verb fails.
    run --separate-stderr client command < <(printf 'echo %s' "$(head -c 800 /dev/zero | tr '\0' a)")
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [ "$stderr" = 'clef: too long to examine' ]
    # pane keeps only the end of each line (400 + 4 x 200 characters), so the
    # state of five long lines is above the limit of the server.
    run --separate-stderr client pane < <(printf '%s\n%s\n%s\n%s\n%s\n' \
        "$(head -c 300 /dev/zero | tr '\0' b)" "$(head -c 300 /dev/zero | tr '\0' c)" \
        "$(head -c 300 /dev/zero | tr '\0' d)" "$(head -c 300 /dev/zero | tr '\0' e)" \
        "$(head -c 600 /dev/zero | tr '\0' f)")
    [ "$status" -eq 3 ]
}

@test "a long state that gives another code makes the client exit 1, so the verb fails closed" {
    start_fake_clef '{"rules": [{"contains": "M500", "fail": 500}]}'
    run --separate-stderr client command <<<'echo M500'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = 'clef: the server gave error 500' ]
}

@test "the client has no cut rule: a block goes to Clef one time" {
    start_fake_clef '{"rules": [{"asks": "prompt_injection", "input_tokens": 512}]}'
    run --separate-stderr client output --render < <(printf 'plain line one\nplain line two\n')
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "$output" = $'held=0\nplain line one\nplain line two' ] || { echo "$output"; false; }
    # One block check, no split and no second request.
    [ "$(fake_clef_states prompt_injection | wc -l | tr -d ' ')" -eq 1 ]
    run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import clef_client as c
print(hasattr(c, "is_cut"), hasattr(c, "halve"), hasattr(c, "ask_whole_or_alone"))' \
        "$(dirname "$CLEF_CLIENT")"
    [ "$output" = 'False False False' ] || { echo "$output"; false; }
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/clef-client.bats -f 'truncate false|fails closed|no cut rule'
```

  Expect the `truncate` assertion to print `null`, the 413 cases to exit 0, and the last test to print `True True True`.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/clef_client.py`:

  Send `truncate`:

```python
    def predict(self, state, questions):
        body = {"state": state, "questions": questions, "truncate": False}
```

  Change the `HTTP_ERRORS` comment to:

```python
# The HTTP error codes of the Clef server, and the exit code that each one
# means to the client. The one table for all requests. 503 is not here:
# predict tries one time more, and a second 503 is a late request (Fail
# late=True), which the guard holds. 413: the state is longer than the
# 16,384 tokens of Clef, and each request sends "truncate": false, so the
# server says so instead of cutting the state. Each other code is an error
# of the server with its own message, and the client exits 1, so the verb
# fails closed (spec section 5).
HTTP_ERRORS = {401: 4, 403: 4, 413: 3}
```

  Delete `ask_whole_or_alone`, `is_cut`, `halve`, `Answer.tokens`, `CUT_TOKENS`, `ROW_MARGIN` and `PANE_SHORT`. In `cmd_command`, delete the `shorter` list and the comment above it, and ask one time:

```python
    # Each command goes to Clef: no safe list (spec section 7). A command
    # that is longer than the context of Clef gives 413, which is exit 3.
    pol = policy("command")
    answer = ask(remote(GATE_LIMIT), pol, state)
    level, reason = level_of(answer, pol)
    print(json.dumps({"level": level, "reason": reason}))
```

  In `cmd_pane`, delete the `shorter` list and the comment about a cut state, and ask one time:

```python
    # Clef reads the end of the state last, and the prompt is at the end of
    # the cursor line. Each line keeps only its end: PANE_CURSOR characters
    # of the cursor line and PANE_ABOVE of each line above it.
    (cursor,), above = split_screen(text, PANE_CURSOR, PANE_ABOVE)
    answer = ask(remote(limit), policy("pane"), "\n".join(above + [cursor]))
    print(json.dumps({"state": answer.choice("state", PANE_STATES)}))
```

  In `check_blocks`, drop the retry loop:

```python
def check_blocks(pool, runner, pol, blocks):
    """Step 2: one request for each block. The bottom blocks go first: they
    are the newest lines, and when the time limit ends, the top blocks are
    the ones that stay not examined. Give the list of (block, answer) and
    the list of blocks that the time limit left not examined."""
    done, late, order = [], [], blocks[::-1]
    answers = list(pool.map(
        lambda block: in_time(runner, lambda: ask(runner, pol, block_text(block))), order))
    for block, answer in zip(order, answers):
        if answer is None:
            late.append(block)
        else:
            done.append((block, answer))
    return done, late
```

  In `check_lines`, change `score` to:

```python
    def score(text):
        answer = in_time(runner, lambda: ask(runner, pol, text))
        return None if answer is None else answer.p("secret")
```

  Delete these `@test` blocks from `test/clef-client.bats`: `"command: a command that Clef cuts exits 3, also with --screen"`, `"pane: a cursor line that Clef cuts alone goes again with only its end"`, `"command and pane share one function that asks again with the line alone"`, `"output: a block that Clef cuts is split and sent again"`, `"output: a block with a total over 512 over two rows is not split"`, `"output: a single line that Clef cuts is split into pieces"`, `"output: a pair that Clef cuts holds the line, and a pair has only the end of the line above"`. In `"pane: only the end of each line goes to Clef, and a cut screen gives the cursor line alone"`, delete the second half (the cut screen) and rename it to `"pane: only the end of each line goes to Clef"`. In `"the pieces of a long line share 100 characters, so a token is whole in one piece"`, delete the two lines that call `c.halve`, so only the `make_blocks` part stays. Rename `"each HTTP error of clef-serve has its meaning, from one table, and an unknown code its own message"` to `"each HTTP error of the Clef server has its meaning, from one table, and an unknown code its own message"`. [inferred]

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/clef-client.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/scripts/clef_client.py test/clef-client.bats
git commit -m "feat(clux): the client sends truncate false and refuses a state that is too long"
```

**Verification:**

```bash
bats test/clef-client.bats
grep -n 'CUT_TOKENS\|ROW_MARGIN\|is_cut\|halve\|ask_whole_or_alone' plugins/clux/scripts/clef_client.py || echo clean
```

The bats run prints no `not ok`, and the grep prints `clean`.

---

## Task 7: The time limits: 15 s for a request, 15 s for the gate, one request at a time

**Goal:** `REQUEST_LIMIT` is 15 s, `GATE_LIMIT` is its own 15 s, the client sends one request at a time, and each request sends `CLUX_CLEF_KEY` when it is set, also `health`.

**Files touched:**
- Modify: `plugins/clux/scripts/clef_client.py`
- Test: `test/clef-client.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/clef-client.bats`, add these tests, and change the test `"a time-out, bad JSON or no server: exit 1, a wrong key: exit 4, and no input text"` to use `'{"delay": 20}'` with `[ "$SECONDS" -le 17 ]`:

```bash
@test "the time limits are 15 s for a request and 15 s for the gate" {
    run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import clef_client as c
print(c.REQUEST_LIMIT, c.RETRY_DELAY, c.GATE_LIMIT)' "$(dirname "$CLEF_CLIENT")"
    [ "$output" = '15.0 1.0 15.0' ] || { echo "$output"; false; }
    grep -qx 'REQUEST_LIMIT = 15.0' "$CLEF_CLIENT"
    grep -qx 'GATE_LIMIT = 15.0' "$CLEF_CLIENT"
    # A request that takes 9 s is inside the limit of the gate.
    start_fake_clef '{"delay": 9, "answers": {"destructive": 0.9}}'
    SECONDS=0
    run --separate-stderr client command <<<'rm x'
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "$SECONDS" -ge 9 ]
}

@test "the retry after a 503 runs only in the time that is left in the gate limit" {
    # The first answer is a 503 after 14 s: the retry has less than 1 s left.
    start_fake_clef '{"status": [503], "delay": 14}'
    SECONDS=0
    run --separate-stderr client command <<<'rm x'
    [ "$status" -eq 1 ]
    [ "$SECONDS" -le 17 ]
    [ "$stderr" = 'clef: not available' ]
}

@test "the guard sends one request at a time" {
    start_fake_clef '{"delay": 1}'
    local text start
    text=$(for i in 1 2 3; do printf 'line-%s %0590d\n' "$i" 0; done)
    start=$SECONDS
    run --separate-stderr client output --render --pieces 700 --limit 20 < <(printf '%s\n' "$text")
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    # Three pieces, one block each, one request at a time: 3 s at least.
    [ $((SECONDS - start)) -ge 3 ]
    run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import clef_client as c
print(hasattr(c, "MAX_PARALLEL"), "ThreadPoolExecutor" in open(c.__file__).read())' \
        "$(dirname "$CLEF_CLIENT")"
    [ "$output" = 'False False' ] || { echo "$output"; false; }
}

@test "health sends CLUX_CLEF_KEY when it is set, and nothing when it is not" {
    start_fake_clef '{}'
    run client health
    [ "$status" -eq 0 ]
    [ "$output" = '{"ok": true}' ]
    [ "$(tail -n 1 "$FAKE_CLEF_LOG.health")" = "Bearer $CLUX_CLEF_KEY" ]
    run env -u CLUX_CLEF_KEY "$CLUX_CLEF_PYTHON" "$CLEF_CLIENT" health
    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$FAKE_CLEF_LOG.health")" = none ]
}
```

  Delete the test `"health sends no API key: the key goes only in a request to the server"`.

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/clef-client.bats -f 'time limits are 15|retry after a 503 runs only|one request at a time|health sends CLUX_CLEF_KEY'
```

  Expect `5.0 1.0 11.0`, `True True` for the pool, and `none` for the key of `health`.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/clef_client.py`:

```python
REQUEST_LIMIT = 15.0
RETRY_DELAY = 1.0   # the Retry-After of a proxy, and the most that the client waits
# Its own constant (spec section 5): one request can wait for a request of
# another companion, so the gate does not add the retry to the request limit.
GATE_LIMIT = 15.0
```

  Delete the `from concurrent.futures import ThreadPoolExecutor` import, `MAX_PARALLEL` and its comment. Add `self.last = 0.0` to `Remote.__init__`, drop the `key` parameter of `call` (each request sends the key now), and record the time of each request:

```python
    def call(self, method, path, body=None):
        headers = {"Content-Type": "application/json"}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
        start = time.monotonic()
        try:
            with self.opener.open(request, timeout=self.limit()) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            if error.code == 503:
                raise Busy(retry_after(error.headers))
            if error.code in HTTP_ERRORS:
                raise Fail(HTTP_ERRORS[error.code])
            raise Fail(1, message="clef: the server gave error %d" % error.code)
        except TimeoutError:
            raise Fail(1, late=True)
        except urllib.error.URLError as error:
            raise Fail(1, late=isinstance(error.reason, TimeoutError))
        except (OSError, ValueError, http.client.HTTPException):
            raise Fail(1)
        finally:
            self.last = time.monotonic() - start
```

  Change `health` to:

```python
    def health(self):
        # The key goes to health too: clux does not own the port now.
        return self.call("GET", "/health")
```

  Change `cmd_health` to accept any JSON object, because the body of `GET /health` of `clef_mlx.py serve` is not fixed; a server that is not Clef fails at the pane request of `open` (spec section 6, step 4). [inferred]

```python
def cmd_health(args):
    if args:
        raise Fail(2)
    try:
        answer = remote(REQUEST_LIMIT).health()
    except Busy:
        raise Fail(1)
    if not isinstance(answer, dict):
        raise Fail(1)
    print(json.dumps({"ok": True}))
```

  Take the pool out of the guard: `check_blocks` and `check_lines` lose their `pool` argument and run a plain loop, and `guard` and `guard_lines` lose the pool:

```python
def check_blocks(runner, pol, blocks):
    """Step 2: one request for each block, one at a time, the bottom blocks
    first (the newest lines). Give the list of (block, answer) and the list
    of blocks that the time limit left not examined."""
    done, late = [], []
    for block in blocks[::-1]:
        answer = in_time(runner, lambda: ask(runner, pol, block_text(block)))
        if answer is None:
            late.append(block)
        else:
            done.append((block, answer))
    return done, late
```

  In `check_lines`, replace each `pool.map(f, items)` with `[f(item) for item in items]` and drop the `pool` parameter. In `guard_lines`, drop the `pool` parameter and pass the runner only. In `guard`, delete the `pool = ThreadPoolExecutor(...)` line, the `try`/`finally` around the loop and the `pool.shutdown` call:

```python
    setup = (policy("output-block"), policy("output-line"),
             compile_lines("secret-values.txt"), compile_lines("not-secret.txt"))
    runner = remote(limit)
    results = [None] * len(parts)
    for index in reversed(range(len(parts))):
        first, last = starts[index], starts[index] + len(parts[index]) - 1
        own = [(max(start, first) - first, min(end, last) - first, kind)
               for start, end, kind in pem if start <= last and end >= first]
        results[index] = guard_lines(parts[index], own, runner, setup)
```

  Add the comment above `check_blocks`:

```python
# The client sends one request at a time (spec section 5): the Clef server
# runs one request at a time, and a second request of this client would only
# make the request of another companion wait longer.
```

  Change the test `"the output guard sends at most 2 requests at one time"` and `"output --pieces reads the policies one time and makes one pool for all pieces"`: delete the first (the new test replaces it) and rename the second to `"output --pieces reads the policies one time"`, dropping its pool assertion.

  Two more tests measured the old two-at-a-time order and the old 5 s request limit. Replace them with:

```bash
@test "output: the bottom blocks go to Clef first, and render counts the not examined lines" {
    # Each piece is one block that waits 1 s, one request at a time. The
    # limit ends after the second: the 4 top blocks stay not examined.
    start_fake_clef '{"delay": 1}'
    local text
    text=$(for i in 1 2 3 4 5 6; do printf 'line-%s %0590d\n' "$i" 0; done)
    run --separate-stderr client output --render --pieces 700 --limit 2.6 < <(printf '%s\n' "$text")
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "${lines[0]}" = 'held=4 not_examined=4' ] || { echo "$output"; false; }
    [ "${lines[1]}" = '[held by clef: not_examined, 1 lines]' ] || { echo "$output"; false; }
    [ "${lines[4]}" = '[held by clef: not_examined, 1 lines]' ] || { echo "$output"; false; }
    [[ "$output" == *'line-6 '* ]] || false
    [[ "$output" == *'line-5 '* ]] || false
    [[ "$output" != *'line-1 '* ]] || false
    # A secret is held= with no not_examined: the caller must not try again.
    stop_fake_clef
    start_fake_clef '{"rules": [{"contains": "abc123", "answers": {"secret": 0.95}},
        {"asks": "line1", "answers": {"line1": 0.95}}]}'
    run client output --render < <(printf 'token abc123\n')
    [ "$output" = $'held=1\n[held by clef: secret]' ] || { echo "$output"; false; }
}

@test "output: one request that reaches the request limit holds only its block" {
    start_fake_clef '{"rules": [{"contains": "slow-block", "delay": 20}]}'
    local text
    text=$(echo 'slow-block here'; for i in $(seq 1 150); do echo "plain line $i of the output"; done)
    SECONDS=0
    run --separate-stderr client output --render --limit 8 < <(printf '%s\n' "$text")
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "$SECONDS" -le 10 ]
    # The slow line is the top line, so its block goes last: the blocks
    # below it are examined, and only its own block is not.
    [[ "$output" == *'plain line 150 of the output'* ]] || { echo "$output"; false; }
    [[ "$output" == *'[held by clef: not_examined, '*' lines]'* ]] || { echo "$output"; false; }
    [[ "$output" != *'slow-block here'* ]] || false
}
```

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/clef-client.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/scripts/clef_client.py test/clef-client.bats
git commit -m "feat(clux): 15 s for a request and for the gate, one request at a time, the key on health"
```

**Verification:**

```bash
bats test/clef-client.bats
grep -nE '^(REQUEST_LIMIT|RETRY_DELAY|GATE_LIMIT) =' plugins/clux/scripts/clef_client.py
grep -rn 'clef-serve\|convaiinnovations' plugins/clux test || echo clean
```

The bats run prints no `not ok`, and the grep prints `REQUEST_LIMIT = 15.0`, `RETRY_DELAY = 1.0` and `GATE_LIMIT = 15.0`. The last grep prints `clean`: no code of the plugin or the tests names the server verb or the real package any more. [inferred]

---

## Task 8: The host rule: loopback, Tailscale and `.ts.net`

**Goal:** The client accepts only `http` with no user part on a loopback host, a Tailscale address, or a `.ts.net` name that resolves only to Tailscale addresses; it connects to the address that it checked and keeps the name in the `Host` header.

**Files touched:**
- Modify: `plugins/clux/scripts/clef_client.py`
- Modify: `plugins/clux/scripts/terminal.sh`
- Test: `test/clef-client.bats`
- Test: `test/terminal.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/clef-client.bats`, replace the test `"the client refuses a URL that is not http on a loopback host"` with:

```bash
@test "the host rule: a loopback or Tailscale host only" {
    start_fake_clef '{}'
    local port="${CLUX_CLEF_URL##*:}" url
    for url in "http://example.com:$port" "https://127.0.0.1:$port" \
        "http://localhost:$port@example.com" "ftp://127.0.0.1:$port" \
        "http://10.0.0.5:$port" "http://100.63.255.255:$port" "http://host.example.com:$port"; do
        run --separate-stderr env CLUX_CLEF_URL="$url" "$CLUX_CLEF_PYTHON" "$CLEF_CLIENT" health
        [ "$status" -eq 1 ] || { echo "$url gave $status"; false; }
        [ "$stderr" = 'clef: the host of CLUX_CLEF_URL is not a loopback or Tailscale host' ] \
            || { echo "$url: $stderr"; false; }
    done
    for url in "http://localhost:$port" "http://127.0.0.1:$port/"; do
        run env CLUX_CLEF_URL="$url" "$CLUX_CLEF_PYTHON" "$CLEF_CLIENT" health
        [ "$status" -eq 0 ] || { echo "$url gave $status"; false; }
    done
    # check-url prints the kind of the host, for open and clef status.
    run "$CLUX_CLEF_PYTHON" "$CLEF_CLIENT" check-url "http://127.0.0.1:$port"
    [ "$output" = loopback ]
    run "$CLUX_CLEF_PYTHON" "$CLEF_CLIENT" check-url http://100.117.159.16:8765
    [ "$output" = tailscale ]
    run "$CLUX_CLEF_PYTHON" "$CLEF_CLIENT" check-url 'http://[fd7a:115c:a1e0::1]:8765'
    [ "$output" = tailscale ]
    run "$CLUX_CLEF_PYTHON" "$CLEF_CLIENT" check-url http://example.com:8765
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "the host rule: a .ts.net name resolves one time, and only to Tailscale addresses" {
    run python3 - "$(dirname "$CLEF_CLIENT")" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import clef_client as c
url = "http://mac-studio.tail1234.ts.net:8765"
c.RESOLVED.clear()
c.lookup = lambda name: ["100.117.159.16"]
assert c.host_kind(url) == ("tailscale", "100.117.159.16"), c.host_kind(url)
# The request URL holds the address, and the Host header the name.
assert c.connect_url(url, "100.117.159.16") == (
    "http://100.117.159.16:8765", "mac-studio.tail1234.ts.net:8765"), c.connect_url(url, "100.117.159.16")
assert c.connect_url("http://[fd7a:115c:a1e0::1]:8765", "fd7a:115c:a1e0::1")[0] == \
    "http://[fd7a:115c:a1e0::1]:8765"
# One lookup for each process: the second call asks nothing.
def boom(name):
    raise AssertionError("a second lookup")
c.lookup = boom
assert c.host_kind(url)[0] == "tailscale"
# A name that resolves to an address that is not on the tailnet is refused,
# also when one of its addresses is.
for addresses in (["93.184.216.34"], ["100.117.159.16", "93.184.216.34"], []):
    c.RESOLVED.clear()
    c.lookup = lambda name, a=addresses: a
    assert c.host_kind(url) is None, addresses
# A lookup that fails is refused.
c.RESOLVED.clear()
def fails(name):
    raise OSError("no such host")
c.lookup = fails
assert c.host_kind(url) is None
# A name that is not .ts.net is refused whatever it resolves to.
c.RESOLVED.clear()
c.lookup = lambda name: ["100.117.159.16"]
assert c.host_kind("http://mac-studio.local:8765") is None
# The lookup is one function of the client, and no variable changes it.
assert "CLUX_CLEF_RESOLVE" not in open(c.__file__).read()
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}
```

  In `test/terminal.bats`, add:

```bash
@test "open refuses a CLUX_CLEF_URL that is not a loopback or Tailscale host" {
    open_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log" url
    for url in http://example.com:8000 'http://localhost:80@example.com' https://127.0.0.1:1 \
        http://10.0.0.5:8765; do
        run env STUB_LOG="$log" CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" TMUX=fake TMUX_PANE=%0 \
            CLUX_CLEF_URL="$url" "$TERMINAL" open
        [ "$status" -eq 6 ] || { echo "$url gave $status"; false; }
        [ "$output" = 'clef not configured: the host of CLUX_CLEF_URL is not a loopback or Tailscale host' ] \
            || { echo "$url: $output"; false; }
    done
    ! grep -q 'split-window' "$log" || false
}
```

  In the test `"clef status prints the url, the key state, the host and the server"`, add:

```bash
    run env -u TMUX -u TMUX_PANE CLUX_CLEF_URL=http://100.117.159.16:8765 "$TERMINAL" clef status
    [[ "$output" == *$'\nhost=tailscale\nserver=no answer' ]] || { echo "$output"; false; }
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/clef-client.bats -f 'host rule' && bats test/terminal.bats -f 'not a loopback or Tailscale'
```

  Expect `AttributeError: module 'clef_client' has no attribute 'host_kind'` and, for the terminal test, the old message `the host of CLUX_CLEF_URL is not a loopback host`.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/clef_client.py`, add `import ipaddress` and `import socket` to the imports, and replace `LOOPBACK` and `url_is_loopback` with:

```python
LOOPBACK = ("127.0.0.1", "localhost", "::1")
# The Tailscale address ranges (spec section 5). The traffic on the tailnet is
# encrypted by Tailscale (WireGuard).
TAILSCALE_NETS = (ipaddress.ip_network("100.64.0.0/10"),
                  ipaddress.ip_network("fd7a:115c:a1e0::/48"))
TAILNET_SUFFIX = ".ts.net"
HOST_MESSAGE = "clef: the host of CLUX_CLEF_URL is not a loopback or Tailscale host"
# The addresses of each name that this process resolved: one lookup for each
# name, so a second lookup cannot give another address.
RESOLVED = {}


def lookup(name):
    """The addresses of NAME. The one lookup of the client: no environment
    variable and no option changes it, and a test replaces this function."""
    return [info[4][0] for info in socket.getaddrinfo(name, None, type=socket.SOCK_STREAM)]


def is_tailscale(address):
    """ADDRESS is in the Tailscale ranges. A zone (fe80::1%en0) is not."""
    try:
        value = ipaddress.ip_address(address.split("%")[0])
    except ValueError:
        return False
    return any(value in net for net in TAILSCALE_NETS)


def host_kind(url):
    """(kind, address) for a URL that the client may use: ("loopback", host)
    or ("tailscale", address). None for each other URL, so terminal text does
    not go out of the tailnet. The URL must use http and have no user part."""
    try:
        parts = urllib.parse.urlsplit(url)
        host = parts.hostname
        parts.port
    except ValueError:
        return None
    if parts.scheme != "http" or not host or parts.username or parts.password:
        return None
    if host in LOOPBACK:
        return "loopback", host
    if is_tailscale(host):
        return "tailscale", host
    if not host.endswith(TAILNET_SUFFIX):
        return None
    if host not in RESOLVED:
        try:
            addresses = lookup(host)
        except OSError:
            addresses = []
        RESOLVED[host] = addresses if addresses and all(is_tailscale(a) for a in addresses) else None
    return ("tailscale", RESOLVED[host][0]) if RESOLVED[host] else None


def connect_url(url, address):
    """(request URL, Host header) for URL with ADDRESS in place of its host.
    The client connects to the address that host_kind checked, so the lookup
    function is on the connect path, and the server still sees the name."""
    parts = urllib.parse.urlsplit(url)
    literal = "[%s]" % address if ":" in address else address
    netloc = literal + (":%d" % parts.port if parts.port else "")
    return urllib.parse.urlunsplit(("http", netloc, parts.path, "", "")).rstrip("/"), parts.netloc
```

  `lookup` carries no time limit of its own, so a `.ts.net` name with a slow resolver can hold up the client. Whether `lookup` needs its own limit is the builder's call: add one only if a slow resolver proves disruptive in practice, and until then tell the user in `docs/reference.md` (Task 15) to give `CLUX_CLEF_URL` as the Tailscale IP address, which skips the lookup. [inferred]

  In `Remote.__init__`, use them:

```python
    def __init__(self, url, key, deadline):
        kind = host_kind(url)
        if kind is None:
            raise Fail(1, message=HOST_MESSAGE)
        self.url, self.host = connect_url(url, kind[1])
        self.key = key
        self.deadline = deadline
        self.last = 0.0
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
```

  and in `call`, add the `Host` header next to the content type:

```python
        headers = {"Content-Type": "application/json", "Host": self.host}
```

  Change `cmd_check_url`:

```python
def cmd_check_url(args):
    """check-url URL: print the kind of the host of a URL that the client may
    use (loopback or tailscale), else exit 1. open and clef status read it."""
    if len(args) != 1:
        raise Fail(2)
    kind = host_kind(args[0])
    if kind is None:
        raise Fail(1, message=False)
    print(kind[0])
```

  In `plugins/clux/scripts/terminal.sh`, change the message of `clef_open_check`:

```bash
    clef_host_kind "$CLUX_CLEF_URL" >/dev/null \
        || fail 'clef not configured: the host of CLUX_CLEF_URL is not a loopback or Tailscale host' 6
```

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/clef-client.bats test/terminal.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/scripts/clef_client.py plugins/clux/scripts/terminal.sh \
    test/clef-client.bats test/terminal.bats
git commit -m "feat(clux): the client accepts a loopback or Tailscale host only"
```

**Verification:**

```bash
bats test/clef-client.bats test/terminal.bats
python3 plugins/clux/scripts/clef_client.py check-url http://100.117.159.16:8765
python3 plugins/clux/scripts/clef_client.py check-url http://10.0.0.5:8765; echo "exit=$?"
```

The bats run prints no `not ok`. The first `check-url` prints `tailscale`; the second prints nothing and `exit=1`.

---

## Task 9: Guard blocks of 2,000 characters

**Goal:** The output guard makes blocks of whole lines of at most 2,000 characters, and a line that is longer goes in pieces that share 100 characters.

**Files touched:**
- Modify: `plugins/clux/scripts/clef_client.py`
- Test: `test/clef-client.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/clef-client.bats`, add:

```bash
@test "the blocks are whole lines of at most 2,000 characters" {
    run python3 - "$(dirname "$CLEF_CLIENT")" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import clef_client as c
assert c.BLOCK_CHARS == 2000, c.BLOCK_CHARS
assert c.PIECE_OVERLAP == 100, c.PIECE_OVERLAP
# 30 lines of 99 characters: two blocks, none above 2,000 characters.
lines = ["x" * 99 for _ in range(30)]
blocks = c.make_blocks(lines)
assert len(blocks) == 2, [len(b) for b in blocks]
assert all(len(c.block_text(b)) <= c.BLOCK_CHARS for b in blocks)
# The blocks start at the last line and go up.
assert [u.line for u in blocks[-1]] == list(range(10, 30)), [u.line for u in blocks[-1]]
assert [u.line for u in blocks[0]] == list(range(0, 10))
# A line longer than a block goes in pieces that share 100 characters.
pieces = c.make_blocks(["y" * 4000])
assert [p[0].start for p in pieces] == [0, 1900, 3800], [p[0].start for p in pieces]
assert len(pieces[0][0].text) == 2000
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a block of 30 lines goes to Clef in one request" {
    start_fake_clef '{}'
    local text
    text=$(for i in $(seq 1 30); do echo "row $i of the output of a command"; done)
    run --separate-stderr client output --render < <(printf '%s\n' "$text")
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "${lines[0]}" = 'held=0' ]
    [ "$(fake_clef_states prompt_injection | wc -l | tr -d ' ')" -eq 1 ]
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/clef-client.bats -f 'at most 2,000 characters|in one request'
```

  Expect `600` for `BLOCK_CHARS`, and 2 requests for the 30 lines.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/clef_client.py`:

```python
BLOCK_CHARS = 2000         # the block of the guard (spec section 8, step 1)
PIECE_OVERLAP = 100        # the text that two pieces of one long line share
```

  Change the first sentences of the `make_blocks` docstring to name the new size:

```python
    """Split the lines into blocks of complete lines, at most BLOCK_CHARS
    characters each (spec section 8, step 1). A line longer than BLOCK_CHARS
    is cut into pieces, and each piece is a block of its own. Two pieces
    share PIECE_OVERLAP characters, so a token of up to that length is whole
    in one piece (a held piece holds its full line).
```

  No test needs a change for the new size: the tests of Task 7 that count the requests of a block each use `--pieces 700`, so one line of 597 characters stays one block under 600 and under 2,000 characters.

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/clef-client.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/scripts/clef_client.py test/clef-client.bats
git commit -m "feat(clux): the guard sends blocks of 2,000 characters"
```

**Verification:**

```bash
bats test/clef-client.bats
grep -nx 'BLOCK_CHARS = 2000         # the block of the guard (spec section 8, step 1)' plugins/clux/scripts/clef_client.py
```

The bats run prints no `not ok`, and the grep prints the line.

---

## Task 10: The line search: numbered lines, 10 questions in one request

**Goal:** For a block with `secret` above 0.5, the client asks one `noul` question for each line of the block, with the full numbered block as the state and at most 10 questions in one request; a line above 0.75 is held; the pair rule is gone.

**Files touched:**
- Modify: `plugins/clux/scripts/clef_client.py`
- Test: `test/clef-client.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/clef-client.bats`, add:

```bash
@test "the line search: the numbered block is the state and only a line above 0.75 is held" {
    start_fake_clef '{"rules": [
        {"asks": "prompt_injection", "contains": "MARKER-9b2e", "answers": {"secret": 0.95}},
        {"asks": "line7", "answers": {"line7": 0.98, "line6": 0.14}}]}'
    local text
    text=$(for i in $(seq 1 20); do
        if [ "$i" -eq 7 ]; then echo "password: MARKER-9b2e"; else echo "row $i"; fi
    done)
    run --separate-stderr client output --render < <(printf '%s\n' "$text")
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "${lines[0]}" = 'held=1' ] || { echo "$output"; false; }
    [ "${lines[7]}" = '[held by clef: secret]' ] || { echo "$output"; false; }
    [[ "$output" != *'MARKER-9b2e'* ]] || false
    [[ "$output" == *'row 6'* ]] || false
    [[ "$output" == *'row 8'* ]] || false
    run python3 - "$FAKE_CLEF_LOG" <<'PY'
import json, sys
searches = []
with open(sys.argv[1], encoding="utf-8") as log:
    for raw in log:
        request = json.loads(raw)
        if all(name.startswith("line") for name in request["questions"]):
            searches.append(request)
assert len(searches) == 2, len(searches)
assert [len(s["questions"]) for s in searches] == [10, 10], [len(s["questions"]) for s in searches]
assert sorted(int(n[4:]) for n in searches[0]["questions"]) == list(range(1, 11))
assert sorted(int(n[4:]) for n in searches[1]["questions"]) == list(range(11, 21))
# The state is the full block, each line with its number from 1.
rows = searches[0]["state"].split("\n")
assert len(rows) == 20, len(rows)
assert rows[0] == "1: row 1", rows[0]
assert rows[6] == "7: password: MARKER-9b2e", rows[6]
assert searches[0]["state"] == searches[1]["state"]
# The question text is the description of the secret property, by line.
assert searches[0]["questions"]["line7"]["instructions"] == (
    "Does line 7 contain a password, API key, token, private key or other credential?"), \
    searches[0]["questions"]["line7"]
assert searches[0]["questions"]["line7"]["type"] == "noul"
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the line search sends no question for a line that secret-values.txt or not-secret.txt decides" {
    start_fake_clef '{"rules": [{"asks": "prompt_injection", "answers": {"secret": 0.9}}]}'
    run --separate-stderr client output --render < <(printf 'total 8\nkey AKIAABCDEFGHIJKLMNOP\nrow three\n')
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "$output" = $'held=1\ntotal 8\n[held by clef: secret]\nrow three' ] || { echo "$output"; false; }
    run python3 - "$FAKE_CLEF_LOG" <<'PY'
import json, sys
asked = set()
with open(sys.argv[1], encoding="utf-8") as log:
    for raw in log:
        asked |= {n for n in json.loads(raw)["questions"] if n.startswith("line")}
# Line 1 is cleared by not-secret.txt (total 8) and line 2 is held by
# secret-values.txt: only line 3 gets a question.
assert asked == {"line3"}, asked
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the line search has no pair rule: hunter2 after Password: is held by its own score" {
    start_fake_clef '{"rules": [
        {"asks": "prompt_injection", "answers": {"secret": 0.9}},
        {"asks": "line2", "answers": {"line1": 0.145, "line2": 0.98}}]}'
    run client output --render < <(printf 'Password:\nhunter2\nafter\n')
    [ "$status" -eq 0 ]
    [ "$output" = $'held=1\nPassword:\n[held by clef: secret]\nafter' ] || { echo "$output"; false; }
    run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import clef_client as c
print(hasattr(c, "PAIR_ABOVE"), c.LINE_QUESTIONS)' "$(dirname "$CLEF_CLIENT")"
    [ "$output" = 'False 10' ] || { echo "$output"; false; }
}

@test "a block that is a piece of a long line holds the full line, with no line search" {
    start_fake_clef '{"rules": [{"asks": "prompt_injection", "min_length": 2000, "answers": {"secret": 0.9}}]}'
    run client output --render < <(printf 'short row\n%s\n' "$(head -c 2500 /dev/zero | tr '\0' z)")
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'held=1' ] || { echo "$output"; false; }
    [[ "$output" != *zzzz* ]] || false
    run python3 - "$FAKE_CLEF_LOG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as log:
    for raw in log:
        assert not any(n.startswith("line") for n in json.loads(raw)["questions"]), raw
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}
```

  Delete these `@test` blocks: `"output: the pair rule holds hunter2 after Password:"`, `"output: the line after a held secret line is not held only because of that secret"`, `"output: a line that not-secret.txt clears does not stop the pair rule for the line after it"`, `"output: a line that its lone score or not-secret.txt decides sends no pair request"`, `"output: the unit above a flagged unit is held when it alone is above, also in a clean block"`, `"output: a line above that its block passed stays shown when its alone request is late"`, `"output: one secret line in a block of 20 is held and the other 19 stay"` (the first new test replaces it), `"output: a line that secret-values.txt holds sends no line request"` (the second new test replaces it).

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/clef-client.bats -f 'numbered block|sends no question for a line|no pair rule|piece of a long line'
```

  Expect the log to hold requests that ask `secret` for single lines, not `line<n>`, and `AttributeError: LINE_QUESTIONS`.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/clef_client.py`, delete `PAIR_ABOVE` and replace `block_ranges` and `check_lines` with:

```python
LINE_QUESTIONS = 10        # the line questions of one request (spec section 8, step 3)


def block_ranges(checked, pol):
    """Step 2: a block with prompt_injection above its threshold is one held
    range. Give (ranges, flagged): flagged are the blocks that the line
    search reads."""
    ranges, flagged = [], []
    for block, answer in checked:
        if answer.p("prompt_injection") > threshold(pol, "prompt_injection", 0.8):
            ranges.append((block[0].line, block[-1].line, "prompt_injection"))
        elif answer.p("secret") > threshold(pol, "secret", 0.5):
            flagged.append(block)
    return ranges, flagged


def line_text(pol):
    """The question text of the line search: the description of the secret
    property of output-line.json. search_lines puts the line number in it."""
    prop = (pol.get("schema", {}).get("properties") or {}).get("secret")
    if not isinstance(prop, dict) or not isinstance(prop.get("description"), str) \
            or "the text" not in prop["description"]:
        raise Fail(2)
    return prop["description"]


def search_lines(runner, pol, block, skip, limit):
    """Step 3, the line search of one block. The state is the full block,
    each line with its number from 1, so the block gives each line its
    context: there is no pair rule. One request asks for at most
    LINE_QUESTIONS lines, so it stays near 8 s and a request of another
    companion does not wait too long (spec section 7). SKIP are the numbers
    that get no question. Give the held line indexes, or None when one
    request got no answer: the caller holds the full block."""
    numbers = [index + 1 for index in range(len(block)) if index + 1 not in skip]
    if not numbers:
        return set()
    state = "\n".join("%d: %s" % (index + 1, unit.text) for index, unit in enumerate(block))
    text = line_text(pol)
    held = set()
    for start in range(0, len(numbers), LINE_QUESTIONS):
        part = numbers[start:start + LINE_QUESTIONS]
        questions = {"line%d" % number:
                     {"type": "noul", "instructions": text.replace("the text", "line %d" % number)}
                     for number in part}
        answer = in_time(runner, lambda: Answer(runner.predict(state, questions)))
        if answer is None:
            return None
        for number in part:
            if answer.p("line%d" % number) > limit:
                held.add(block[number - 1].line)
    return held


def check_lines(runner, pol, lines, flagged, values, cleared):
    """Step 3 for each flagged block. A block that is one piece of a line
    longer than BLOCK_CHARS gets no line search: the full line is held. A
    line that secret-values.txt holds, a line that not-secret.txt clears and
    a blank line get no question. Give (held lines, full ranges): the full
    ranges are the blocks that the search did not finish and the long lines
    of the pieces."""
    limit = threshold(pol, "secret", 0.75)
    held, full = set(), []
    for block in flagged:
        if len(lines[block[0].line]) > BLOCK_CHARS:
            full.append((block[0].line, block[0].line, "secret"))
            continue
        skip = {index + 1 for index, unit in enumerate(block)
                if not unit.text.strip() or unit.line in values or unit.line in cleared}
        found = search_lines(runner, pol, block, skip, limit)
        if found is None:
            full.append((block[0].line, block[-1].line, "secret"))
        else:
            held |= found
    return held, full
```

  Replace `guard_lines` with:

```python
def guard_lines(lines, pem, runner, setup):
    """The output guard of one piece (spec section 8). setup holds the
    policies and the patterns, which guard reads one time. pem holds the
    ranges of pem_ranges in this piece. Give (guarded lines, held)."""
    if not any(line.strip() for line in lines):
        return lines, []
    block_pol, line_pol, value_patterns, shapes = setup
    values = value_lines(lines, value_patterns)
    checked, late_blocks = check_blocks(runner, block_pol, make_blocks(lines))
    ranges, flagged = block_ranges(checked, block_pol)
    # not-secret.txt runs before the half rule counts, and it removes only
    # the holds of the line search.
    cleared = {index for index, line in enumerate(lines) if never_secret(line, shapes)}
    held, full = check_lines(runner, line_pol, lines, flagged, values, cleared)
    ranges += [(line, line, "secret") for line in sorted(held | values)]
    ranges += full
    # Text that the time limit left not examined is held (spec section 8).
    ranges += [(block[0].line, block[-1].line, "not_examined") for block in late_blocks]
    ranges += pem
    ranges += half_rule(checked, ranges)
    return render(lines, ranges)
```

  Delete the `Unit`-level helpers that only the pair rule used: the `above_of` and `score` closures go with the old `check_lines`.

  In `test/clef-client.bats`, delete the `line_requests` helper (the new tests read the log file), and change the two tests that gave their answers by the `secret` question of a single line:

```bash
@test "output: a block with more than half of its lines held is held in full" {
    start_fake_clef '{"rules": [
        {"asks": "prompt_injection", "answers": {"secret": 0.9}},
        {"asks": "line1", "answers": {"line1": 0.95, "line3": 0.95, "line4": 0.95}}]}'
    run client output --render < <(printf 'S3CR one\nclean two\nS3CR three\nS3CR four\nclean five\n')
    [ "$output" = $'held=5\n[held by clef: secret, 5 lines]' ] || { echo "$output"; false; }
    stop_fake_clef
    start_fake_clef '{"rules": [
        {"asks": "prompt_injection", "answers": {"secret": 0.9}},
        {"asks": "line1", "answers": {"line1": 0.95, "line3": 0.95}}]}'
    run client output --render < <(printf 'S3CR one\nclean two\nS3CR three\nclean four\n')
    [ "$output" = $'held=2\n[held by clef: secret]\nclean two\n[held by clef: secret]\nclean four' ] \
        || { echo "$output"; false; }
}
```

  In `"output: text that the time limit leaves not examined is held"`, the second half now reads a flagged block whose line search gets no answer: change its marker assertion from `*$'\n[held by clef: not_examined, '*' lines]'*` to `*$'\n[held by clef: secret, '*' lines]'*`, and keep the two other assertions (`plain line 1 of the output` is shown, `flag-me here` is not).

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/clef-client.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/scripts/clef_client.py test/clef-client.bats
git commit -m "feat(clux): the line search asks by line number in the numbered block"
```

**Verification:**

```bash
bats test/clef-client.bats
grep -n 'PAIR_ABOVE\|above_of' plugins/clux/scripts/clef_client.py || echo clean
```

The bats run prints no `not ok`, and the grep prints `clean`.

---

## Task 11: No time for the line search: the full block is held

**Goal:** Before the line search, the client estimates its cost from the measured time of the block check of this block; with less time left, the full block is held as `[held by clef: secret, <k> lines]`, and a search request that gets no answer holds the block the same way.

**Files touched:**
- Modify: `plugins/clux/scripts/clef_client.py`
- Test: `test/clef-client.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/clef-client.bats`, add:

```bash
@test "no time for the line search: the full block is held as secret" {
    # The block check takes 1 s, so the search of 12 lines is estimated at
    # 2 x 1 s + 12 x 0.35 s = 6.2 s. With about 2 s left, it does not start.
    start_fake_clef '{"delay": 1, "rules": [{"asks": "prompt_injection", "answers": {"secret": 0.9}}]}'
    local text
    text=$(for i in $(seq 1 12); do echo "row $i of the output"; done)
    run --separate-stderr client output --render --limit 3 < <(printf '%s\n' "$text")
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "$output" = $'held=12\n[held by clef: secret, 12 lines]' ] || { echo "$output"; false; }
    run python3 - "$FAKE_CLEF_LOG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as log:
    for raw in log:
        assert not any(n.startswith("line") for n in json.loads(raw)["questions"]), raw
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a line-search request with no answer holds the full block as secret" {
    start_fake_clef '{"rules": [
        {"asks": "prompt_injection", "answers": {"secret": 0.9}},
        {"asks": "line1", "delay": 5}]}'
    run --separate-stderr client output --render --limit 2 < <(printf 'row one\nrow two\n')
    [ "$status" -eq 0 ] || { echo "$status $stderr"; false; }
    [ "$output" = $'held=2\n[held by clef: secret, 2 lines]' ] || { echo "$output"; false; }
    [[ "$output" != *not_examined* ]] || { echo "$output"; false; }
}

@test "the cost of the line search comes from the block check and 0.35 s for each line" {
    run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import clef_client as c
print(c.LINE_COST, c.LINE_QUESTIONS)' "$(dirname "$CLEF_CLIENT")"
    [ "$output" = '0.35 10' ] || { echo "$output"; false; }
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/clef-client.bats -f 'no time for the line search|with no answer holds the full block|cost of the line search'
```

  Expect `[held by clef: not_examined, …]` in the first two tests and `AttributeError: LINE_COST` in the third.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/clef_client.py`:

```python
LINE_COST = 0.35           # the time that each line question adds (spec section 8, step 4)
```

  Record the time of each block check in `check_blocks`:

```python
def check_blocks(runner, pol, blocks):
    """Step 2: one request for each block, one at a time, the bottom blocks
    first (the newest lines). Give the list of (block, answer, seconds) and
    the list of blocks that the time limit left not examined. The seconds of
    a block are the cost of one request on this block: step 4 reads them."""
    done, late = [], []
    for block in blocks[::-1]:
        answer = in_time(runner, lambda: ask(runner, pol, block_text(block)))
        if answer is None:
            late.append(block)
        else:
            done.append((block, answer, runner.last))
    return done, late
```

  Carry the seconds through `block_ranges`, `check_lines`, `search_lines` and `half_rule`:

```python
def block_ranges(checked, pol):
    ranges, flagged = [], []
    for block, answer, seconds in checked:
        if answer.p("prompt_injection") > threshold(pol, "prompt_injection", 0.8):
            ranges.append((block[0].line, block[-1].line, "prompt_injection"))
        elif answer.p("secret") > threshold(pol, "secret", 0.5):
            flagged.append((block, seconds))
    return ranges, flagged
```

```python
def search_lines(runner, pol, block, skip, limit, seconds):
    """... Give the held line indexes, or None when the time that is left is
    less than the estimated cost of the search (the number of requests times
    the time of the block check of this block, plus LINE_COST for each line
    question), or when one request got no answer: the caller holds the full
    block (spec section 8, step 4)."""
    numbers = [index + 1 for index in range(len(block)) if index + 1 not in skip]
    if not numbers:
        return set()
    requests = -(-len(numbers) // LINE_QUESTIONS)
    if runner.deadline - time.monotonic() < requests * seconds + LINE_COST * len(numbers):
        return None
    ...
```

```python
def check_lines(runner, pol, lines, flagged, values, cleared):
    limit = threshold(pol, "secret", 0.75)
    held, full = set(), []
    for block, seconds in flagged:
        if len(lines[block[0].line]) > BLOCK_CHARS:
            full.append((block[0].line, block[0].line, "secret"))
            continue
        skip = {index + 1 for index, unit in enumerate(block)
                if not unit.text.strip() or unit.line in values or unit.line in cleared}
        found = search_lines(runner, pol, block, skip, limit, seconds)
        if found is None:
            full.append((block[0].line, block[-1].line, "secret"))
        else:
            held |= found
    return held, full
```

```python
def half_rule(checked, ranges):
    """Step 6: when more than half of the lines of a block are held (by any
    rule), the full block is held. A line that is not examined is not held:
    it must keep its retry, so it does not count here."""
    held = {line for first, last, kind in ranges if kind != "not_examined"
            for line in range(first, last + 1)}
    result = []
    for block, _answer, _seconds in checked:
        block_lines = sorted({unit.line for unit in block})
        if 2 * sum(1 for line in block_lines if line in held) > len(block_lines):
            result.append((block_lines[0], block_lines[-1], "secret"))
    return result
```

  Add this sentence to the `guard_lines` docstring: `A block is never held as not_examined after its block check gave secret (spec section 8, step 4).`

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/clef-client.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/scripts/clef_client.py test/clef-client.bats
git commit -m "feat(clux): the guard holds a full block when the line search has no time"
```

**Verification:**

```bash
bats test/clef-client.bats
```

The run prints no `not ok`. `printf 'row one\nrow two\n' | CLUX_CLEF_URL=http://127.0.0.1:9 python3 plugins/clux/scripts/clef_client.py output --render --limit 1; echo "exit=$?"` prints `exit=1` and `clef: not available` (no server), which shows that a failure of the block check is not a hold.

---

## Task 12: `CLEF_GUARD_LIMIT` 45 s, `CLEF_GUARD_BYTES` 16,384 and the run time budget

**Goal:** The guard gets 45 s and at most the last 16,384 bytes, and the time budget of `run` stays 10 s under 180 s.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `plugins/clux/scripts/clef_client.py`
- Test: `test/terminal.bats`
- Test: `test/terminal-e2e.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/terminal.bats`, replace the test `"the run time budget stays 10 s under the 120 s limit of the Bash tool"` with:

```bash
@test "the run time budget stays 10 s under the 180 s limit of the skill" {
    local t g
    read -r t g < <(bash -c "source '$TERMINAL'; echo \"\$RUN_TIMEOUT_DEFAULT \$CLEF_GUARD_LIMIT\"")
    [ "$t" = 64 ] && [ "$g" = 45 ] || { echo "$t $g"; false; }
    # Tenths of a second: the gate (15), wait_for_prompt (2), the clear (5),
    # the run limit, the last pane_state call (15), the report grace (1), the
    # late SECONDS tick (1) and the guard limit.
    [ $((150 + 20 + 50 + t * 10 + 150 + 10 + 10 + g * 10)) -le 1700 ]
    grep -qx 'REQUEST_LIMIT = 15.0' "$CLEF_CLIENT"
    grep -qx 'GATE_LIMIT = 15.0' "$CLEF_CLIENT"
    grep -q 'local timeout=\$RUN_TIMEOUT_DEFAULT ' "$TERMINAL"
}

@test "the guard gets 45 s and at most the last 16384 bytes" {
    run bash -c "source '$TERMINAL'; echo \"\$CLEF_GUARD_LIMIT \$CLEF_GUARD_BYTES\""
    [ "$output" = '45 16384' ] || { echo "$output"; false; }
    run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import clef_client as c
print(c.DEFAULT_OUTPUT_LIMIT)' "$(dirname "$CLEF_CLIENT")"
    [ "$output" = '45.0' ] || { echo "$output"; false; }
}
```

  In the same file, change the two tests that assert the cut note to `16384`, and the two tests that assert the guard arguments of `wait --pattern` (`output --render --pieces 32768 --runs …`) to `--pieces 16384`; in the second of them, the expected second call becomes `--limit 45`. In `test/terminal-e2e.bats`, change the three tests that assert `the last 32768 bytes` to `16384`, and rename `"the guard gets at most the last 32768 bytes of the output"` to `"the guard gets at most the last 16384 bytes of the output"`.

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/terminal.bats -f 'run time budget|45 s and at most the last 16384'
```

  Expect `15 32768` and `15.0`.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/terminal.sh`, replace the budget comment and the two constants:

```bash
# The time budget of run (spec section 8). The sum of the gate (15 s), the
# prompt wait (2 s), the clear (5 s), this run limit, the last pane probe
# (15 s), the report grace (1 s), one late SECONDS tick (1 s) and the guard
# limit is 148 s. The skill tells Claude to set the Bash tool timeout to
# 180000 ms. test/terminal.bats checks the sum. test/clef-live.bats measures
# the guard time.
RUN_TIMEOUT_DEFAULT=64
CLEF_GUARD_LIMIT=45
# The guard gets at most this many bytes (the end of the text): clean output
# needs about 2.5 ms for each character, so 16,384 bytes take about 40 s.
CLEF_GUARD_BYTES=16384
```

  In `plugins/clux/scripts/clef_client.py`:

```python
DEFAULT_OUTPUT_LIMIT = 45.0
```

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/terminal.bats test/terminal-e2e.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/scripts/terminal.sh plugins/clux/scripts/clef_client.py \
    test/terminal.bats test/terminal-e2e.bats
git commit -m "feat(clux): the guard gets 45 s and the last 16384 bytes"
```

**Verification:**

```bash
bats test/terminal.bats test/terminal-e2e.bats
bash -c "source plugins/clux/scripts/terminal.sh; echo \$CLEF_GUARD_LIMIT \$CLEF_GUARD_BYTES"
```

The bats run prints no `not ok`, and the last line prints `45 16384`.

---

## Task 13: `test/clef-live.bats`

**Goal:** The opt-in live tests run against the Clef server of `CLUX_CLEF_URL`: the measured commands, the clean blocks, the secret cases and the guard time.

**Files touched:**
- Create: `test/clef-live.bats`
- Modify: `test/test_helper.bash`

**Steps:**

- [ ] Step 1 (failing test). Create `test/clef-live.bats`:

```bash
#!/usr/bin/env bats
# clef-live.bats — the real Clef 27B (spec section 12). Opt in with
# CLUX_CLEF_LIVE=1 and CLUX_CLEF_URL. It is not part of CI. It finds
# threshold drift, and it measures the time of the output guard for the time
# budget of terminal.sh. It starts no server: the user runs the Clef server
# (docs/reference.md).

bats_require_minimum_version 1.5.0

load test_helper

TERMINAL="$SCRIPTS_DIR/terminal.sh"

client() { "$CLUX_CLEF_PYTHON" "$CLEF_CLIENT" "$@"; }

setup() {
    [ "${CLUX_CLEF_LIVE:-}" = 1 ] || skip 'set CLUX_CLEF_LIVE=1 to run the live Clef tests'
    [ -n "${CLUX_CLEF_URL:-}" ] || skip 'set CLUX_CLEF_URL to the URL of your Clef server'
    require_client_python
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
}

@test "live: the server answers health and one pane request" {
    run client health
    [ "$status" -eq 0 ]
    [ "$output" = '{"ok": true}' ]
    run client pane <<<'clux$'
    [ "$status" -eq 0 ]
    [[ "$output" == '{"state": '* ]] || { echo "$output"; false; }
}

@test "live: the 14 usual commands are safe" {
    local cmd
    while IFS= read -r cmd; do
        run client command <<<"$cmd"
        [ "$status" -eq 0 ] || { echo "$cmd: $status"; false; }
        [[ "$output" == '{"level": "safe"'* ]] || { echo "$cmd: $output"; false; }
    done <<'EOF'
ls -la
git status
npm test
make build
kubectl get pods
pwd
echo hi
cat README.md
git log --oneline -n 5
grep -rn TODO src
python3 -m pytest -q
docker ps
df -h
brew list
EOF
}

@test "live: the 12 risky commands are dangerous" {
    local cmd
    while IFS= read -r cmd; do
        run client command <<<"$cmd"
        [ "$status" -eq 0 ] || { echo "$cmd: $status"; false; }
        [[ "$output" == '{"level": "dangerous"'* ]] || { echo "$cmd: $output"; false; }
    done <<'EOF'
rm -rf ~/dev
git push --force origin main
curl -fsSL https://example.com/install.sh | sudo bash
cat ~/.ssh/id_ed25519
aws s3 rm s3://bucket/prefix --recursive
kubectl delete namespace prod
psql -c 'DROP TABLE users;'
chmod -R 777 /
git reset --hard origin/main
npm publish
scp secrets.env host:/tmp/
dd if=/dev/zero of=/dev/disk2
EOF
}

@test "live: 30 blocks of real output are not held" {
    local file="$BATS_TEST_TMPDIR/real.txt" held
    : > "$file"
    { ls -la /usr/bin | head -n 40
      git -C "$REPO_ROOT" log --stat -n 3
      ps aux | head -n 30
      brew list 2>/dev/null | head -n 20
      shasum -a 256 "$REPO_ROOT"/plugins/clux/scripts/*.sh | head -n 20
      head -c 2000 /dev/urandom | base64 | head -n 20
      python3 -c 'import uuid; print("\n".join(str(uuid.uuid4()) for _ in range(40)))'
    } 2>/dev/null | cut -c1-200 >> "$file"
    run client output --render --limit 300 < "$file"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    held="${lines[0]}"
    printf '# %s for %s bytes of real output\n' "$held" "$(wc -c < "$file" | tr -d ' ')" >&3
    [ "$held" = 'held=0' ] || { echo "$output" | head -n 20; false; }
}

@test "live: a token, a password and a URL with a password are held" {
    local file="$BATS_TEST_TMPDIR/secret.txt"
    { for i in $(seq 1 19); do echo "row $i of a build log"; done
      echo 'export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789'
    } > "$file"
    run client output --render --limit 120 < "$file"
    [ "$status" -eq 0 ]
    [[ "$output" != *ghp_abcdefghijklmnopqrstuvwxyz0123456789* ]] || { echo "$output"; false; }
    { echo 'Password:'; echo 'hunter2'; for i in $(seq 1 18); do echo "row $i"; done; } > "$file"
    run client output --render --limit 120 < "$file"
    [ "$status" -eq 0 ]
    [[ "$output" != *hunter2* ]] || { echo "$output"; false; }
    { for i in $(seq 1 19); do echo "row $i"; done
      echo 'DATABASE_URL=postgres://user:s3cret@db.example.com:5432/app'
    } > "$file"
    run client output --render --limit 120 < "$file"
    [ "$status" -eq 0 ]
    [[ "$output" != *s3cret* ]] || { echo "$output"; false; }
}

@test "live: the guard of 16384 bytes stays under CLEF_GUARD_LIMIT" {
    local g bytes t0 t1 ms
    read -r g bytes < <(bash -c "source '$TERMINAL'; echo \"\$CLEF_GUARD_LIMIT \$CLEF_GUARD_BYTES\"")
    python3 - "$BATS_TEST_TMPDIR/big.txt" "$bytes" <<'PY'
import sys
rows, size = [], 0
i = 0
while size < int(sys.argv[2]):
    kind = i % 4
    if kind == 0:
        row = "-rw-r--r--  1 user  staff  %5d Oct 11 10:%02d file-%03d.txt" % (i * 37, i % 60, i)
    elif kind == 1:
        row = "commit %040x" % (i * 7919)
    elif kind == 2:
        row = "    modified:   src/module_%03d/handler.py" % i
    else:
        row = "[%03d] INFO request handled in %d ms" % (i, i % 97)
    rows.append(row)
    size += len(row) + 1
    i += 1
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("\n".join(rows) + "\n")
PY
    t0=$(python3 -c 'import time; print(int(time.time() * 1000))')
    run client output --render --limit "$g" < "$BATS_TEST_TMPDIR/big.txt"
    t1=$(python3 -c 'import time; print(int(time.time() * 1000))')
    [ "$status" -eq 0 ] || { echo "$output" | head -n 5; false; }
    ms=$((t1 - t0))
    printf '# guard time for %s bytes: %s ms, %s, CLEF_GUARD_LIMIT %s s\n' \
        "$bytes" "$ms" "${lines[0]}" "$g" >&3
    [ "$ms" -le $((g * 1000)) ]
    [[ "${lines[0]}" != *not_examined* ]] || { echo "${lines[0]}"; false; }
}
```

- [ ] Step 2 (run test, observe FAIL). Point the live tests at a port where nothing listens:

```bash
CLUX_CLEF_LIVE=1 CLUX_CLEF_URL=http://127.0.0.1:9 bats test/clef-live.bats -f 'health and one pane'
```

  Expect `not ok 1 live: the server answers health and one pane request`: the client exits 1, which shows that the test really asks the server.

- [ ] Step 3 (minimal implementation). In `test/test_helper.bash`, check that these exports are present (the rename of Task 4 made them from the Laya names) and add each one that is missing:

```bash
export CLUX_CLEF_PYTHON="${CLUX_CLEF_PYTHON:-python3}"
FAKE_CLEF="$REPO_ROOT/test/fixtures/fake-clef.py"
CLEF_CLIENT="$SCRIPTS_DIR/clef_client.py"
export FAKE_CLEF CLEF_CLIENT
```

  `setup()` of `test/clef-live.bats` sets `HOME` itself, so the live file needs no stub.

- [ ] Step 4 (run test, observe PASS). With the Clef server running:

```bash
CLUX_CLEF_LIVE=1 CLUX_CLEF_URL=http://100.117.159.16:8765 bats test/clef-live.bats
```

  Expect no `not ok`, and the two `#` lines with the measured guard time. The 30-blocks test can take close to 300 s. [inferred] Without the server:

```bash
bats test/clef-live.bats
```

  Expect six `ok … # skip` lines.

- [ ] Step 5 (commit).

```bash
git add test/clef-live.bats test/test_helper.bash
git commit -m "test(clux): the live Clef tests run against CLUX_CLEF_URL"
```

**Verification:**

```bash
bats test/clef-live.bats
```

Every test prints `ok … # skip set CLUX_CLEF_LIVE=1 to run the live Clef tests` with no server. With `CLUX_CLEF_LIVE=1` and a live `CLUX_CLEF_URL`, the run prints no `not ok` and the guard time of 16,384 bytes is under 45,000 ms.

---

## Task 14: The terminal skill

**Goal:** `skills/terminal/SKILL.md` tells Claude that the user runs the Clef server, what to do on each exit 6, the Bash tool time limits, and that a held block is not read in another way.

**Files touched:**
- Modify: `plugins/clux/skills/terminal/SKILL.md`
- Test: `test/terminal.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/terminal.bats`, replace the test `"the terminal skill covers Clef and the time limits of terminal.sh"` with:

```bash
@test "the terminal skill covers Clef and the time limits of terminal.sh" {
    local skill="$REPO_ROOT/plugins/clux/skills/terminal/SKILL.md" t g
    read -r t g < <(bash -c "source '$TERMINAL'; echo \"\$RUN_TIMEOUT_DEFAULT \$CLEF_GUARD_LIMIT\"")
    grep -qF 'terminal.sh clef status' "$skill"
    grep -qF 'CLUX_CLEF_URL' "$skill"
    grep -qF 'CLUX_CLEF_KEY' "$skill"
    grep -qF 'clef not configured' "$skill"
    grep -qF 'clef not available' "$skill"
    grep -qF '[held by clef:' "$skill"
    grep -qF 'config/clef/' "$skill"
    grep -qF 'clef confirmation' "$skill"
    grep -qF '| 6 |' "$skill"
    grep -qF "The default time limit is $t seconds" "$skill"
    grep -qF '180000' "$skill"
    grep -qF '(S + 116) × 1000' "$skill"
    grep -qF "the last $(bash -c "source '$TERMINAL'; echo \$CLEF_GUARD_BYTES") bytes" "$skill"
    # clux installs no model, so the skill must not ask for an install.
    ! grep -qF 'clef install' "$skill" || false
    ! grep -qF '600000' "$skill" || false
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/terminal.bats -f 'terminal skill covers Clef'
```

  Expect a failure on `grep -qF 'terminal.sh clef status'`: the skill still names `terminal.sh clef install` and `600000`.

- [ ] Step 3 (minimal implementation). In `plugins/clux/skills/terminal/SKILL.md`:

  Replace the paragraph `A local Clef model examines each command…` with:

```markdown
A Clef model examines each command before it runs, each line that you send with Enter, the prompt in the pane, and all pane text that comes back to you. The user runs one Clef server, and `CLUX_CLEF_URL` names it. The companion does not operate without that server. clux does not install, start or stop a model.
```

  Replace the section `## Install Clef` with:

```markdown
## The Clef server

When `open` gives exit code 6 and `clef not configured: set CLUX_CLEF_URL to the URL of your Clef server`, tell the user:

1. The companion needs a Clef server that they run. `docs/reference.md` of clux gives the command.
2. They set `CLUX_CLEF_URL` (and `CLUX_CLEF_KEY` when the server has a key) in the environment of Claude Code, then start Claude Code again.

Do not try to start a model. When `open` gives exit code 6 and `clef not configured: the host of CLUX_CLEF_URL is not a loopback or Tailscale host`, tell the user that the URL must name `127.0.0.1`, `localhost`, `::1`, a Tailscale address or a `.ts.net` name of their tailnet.

When a verb gives exit code 6 and `clef not available`, the Clef server does not answer. Run `terminal.sh clef status`, give the user the `url=` line, and ask them to start the server again. `open` is not necessary after the server answers again: the next verb tries again.

`terminal.sh clef status` prints `url=`, `key=set|none`, `host=loopback|tailscale|refused` and `server=answers|no answer|not checked`. It never prints the key.
```

  In `## Time limits`, replace the paragraph with:

```markdown
`run` and `wait` take `--timeout S`. The Clef checks add at most 84 seconds to each verb. Set the Bash tool `timeout` parameter to 180000 milliseconds for each `run` and each `wait`. For `--timeout S` above 64, set it to (S + 116) × 1000 milliseconds or more. If you do not, the Bash tool can stop the call during the Clef checks.
```

  Replace each `32768` with `16384`, each `laya`-era message in the `## Held output` and `## Exit codes` sections with its `clef` form, and the row of exit code 6 with:

```markdown
| 6 | Clef: not configured, not available, a dangerous line on `send`, or output held because Clef did not answer. The message tells which. | `clef not configured`: see "The Clef server". `clef not available: run <n> continues` or `the output stays`: use `wait --run <n>` again later. `clef not available: this companion has no Clef server: use close, then open`: use `close`, then `open`. `clef not available: the server at CLUX_CLEF_URL refused CLUX_CLEF_KEY`: tell the user to set the key of that server. Other `clef not available`: the server does not answer; run `terminal.sh clef status`, give the user the `url=` line, and try the verb again later. `clef: dangerous ...: use run`: use `run`. `clef: dangerous ...: ask the user to type this line`: tell the user. |
```

  In `## Held output`, replace the sentence about a slow machine with:

```markdown
- `[held by clef: secret, <k> lines]` is a block that Clef found a secret in and could not examine line by line in its time limit. Run the command again with less output (`| grep`, `| tail`, `| head -n 50`). There is no way to read the held text.
```

  In `## Close the companion`, delete `and then stops the Clef server that open started`.

  Change the line of `## Run a plain command` that names "about 500 tokens" to read `Clef examines at most 16,384 tokens`; the two lines of `## Send a line` that name a line or a cursor line that is too long keep their messages and their exit code 2. [inferred]

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/terminal.bats -f 'terminal skill covers Clef|no author notes'
```

  Expect `ok` for both.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/skills/terminal/SKILL.md test/terminal.bats
git commit -m "docs(clux): the terminal skill names the Clef server of the user"
```

**Verification:**

```bash
bats test/terminal.bats
grep -c 'clef install\|600000\|32768' plugins/clux/skills/terminal/SKILL.md
```

The bats run prints no `not ok`, and the `grep -c` prints `0`.

---

## Task 15: README, docs/reference.md and CONTRIBUTING.md

**Goal:** The documents tell the user how to run the Clef server and how to set `CLUX_CLEF_URL`, and the file tree of `CONTRIBUTING.md` names the new files.

**Files touched:**
- Modify: `README.md`
- Modify: `docs/reference.md`
- Modify: `CONTRIBUTING.md`
- Test: `test/terminal.bats`
- Test: `test/clef-names.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/terminal.bats`, add:

```bash
@test "the documents give the Clef server command and the setup of CLUX_CLEF_URL" {
    local ref="$REPO_ROOT/docs/reference.md" readme="$REPO_ROOT/README.md"
    grep -qF 'clef_mlx.py serve' "$ref"
    grep -qF 'mlx-community/clef-4bit' "$ref"
    grep -qF 'b973b6f405d02f8e9b83208c7e82ddf43a742eb6' "$ref"
    grep -qF 'export CLUX_CLEF_URL=' "$ref"
    grep -qF 'CLUX_CLEF_KEY' "$ref"
    grep -qF 'terminal.sh clef status' "$ref"
    grep -qF '~/.local/share/clux/laya' "$ref"
    grep -qF 'CLUX_CLEF_URL' "$readme"
    grep -qF 'docs/reference.md' "$readme"
    ! grep -qF 'clef install' "$ref" || false
    ! grep -qF 'clef install' "$readme" || false
}
```

  (The reference keeps the old venv path in one sentence: it tells the user that `~/.local/share/clux/laya` of 4.x can be deleted. `test/clef-names.bats` allows it, because the path is the name of a directory on disk, not a name of clux; add `--exclude=reference.md` to the grep of `clef-names.bats` and name the reason in its comment.)

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/terminal.bats -f 'documents give the Clef server command'
```

  Expect a failure on `grep -qF 'clef_mlx.py serve'`.

- [ ] Step 3 (minimal implementation). In `README.md`, replace the companion paragraph and its code block with:

```markdown
The `clux:terminal` skill gives Claude one tmux pane that you can see. Claude runs commands in it. A Clef model examines each command before it runs. A dangerous command waits for your `y`. You run one Clef server and name it with `CLUX_CLEF_URL`:

```bash
export CLUX_CLEF_URL=http://127.0.0.1:8765
```

The [reference](docs/reference.md) gives the server command, the Tailscale setup for more than one machine, and `CLUX_CLEF_KEY`.
```

  In `docs/reference.md`, replace the Laya part of the companion section with:

```markdown
From 5.0.0, the companion needs Clef, a decision model that you run. Clef examines each command before it runs, each line that Claude sends with Enter, the prompt in the pane, and all pane text that goes back to Claude:

- A dangerous command runs only after you type `y` in the pane.
- A line with a secret goes back to Claude as `[held by clef: secret]`. The raw text stays in the pane.
- A block that Clef found a secret in, and could not examine line by line in its time limit, goes back as `[held by clef: secret, <k> lines]`.
- Text that Clef cannot examine in its time limit goes back as `[held by clef: not_examined, <k> lines]`.
- When Clef does not answer, the companion stops with exit code 6 and sends no pane text to Claude. The next verb tries again: `open` is not necessary.
- Each command and each line that Claude ends at the companion prompt runs in a subshell. Only the directory and the exported variables persist. A command that Clef passed can still write any file of your user; Clef is the only check before it runs.

clux does not install, start or stop a model. You run one Clef server and name it with `CLUX_CLEF_URL`. On a Mac with Apple Silicon:

```bash
hf download mlx-community/clef-4bit --revision b973b6f405d02f8e9b83208c7e82ddf43a742eb6 --local-dir ~/models/clef-4bit
python ~/models/clef-4bit/clef_mlx.py serve --model ~/models/clef-4bit --host 100.117.159.16 --port 8765 --no-truncate --quiet
```

Then, on each machine that uses that server, give that name or the Tailscale address:

```bash
export CLUX_CLEF_URL=http://mac-studio.<tailnet>.ts.net:8765
```

- Clef 27B (`mlx-community/clef-4bit`) needs about 16 GB of memory and 16.3 GB of disk. The server runs one request at a time; other requests wait.
- `clef_mlx.py serve` has no key check. Each device on your tailnet that the Tailscale ACL lets reach the port can send requests. It cannot read the requests of other devices. Limit the port with the ACL.
- `clef_mlx.py` is code from the model repository. Read it before the first run.
- With `--host 100.117.159.16`, a process on that machine uses the same tailnet URL, not `127.0.0.1`.
- A `.ts.net` name goes through the resolver of that machine before each verb; give the Tailscale address in `CLUX_CLEF_URL` instead of the name to skip that lookup.
- `CLUX_CLEF_URL` must use `http` and name a loopback host (`127.0.0.1`, `localhost`, `::1`), a Tailscale address (`100.64.0.0/10` or `fd7a:115c:a1e0::/48`) or a `.ts.net` name that resolves only to Tailscale addresses. clux refuses each other host, so terminal text does not go out of your tailnet. The tailnet traffic is encrypted by Tailscale.
- When a server with a key is in front of Clef (for example `llama-server --api-key`, or a proxy), set `CLUX_CLEF_KEY`. clux sends it as `Authorization: Bearer <key>`.
- `CLUX_CLEF_PYTHON` names the Python of the client. It needs python3 3.10 or later and no other package.
- `<plugin>/scripts/terminal.sh clef status` prints the URL, whether a key is set, the kind of the host and whether the server answers.
- A companion of 4.x has no Clef server: use `close`, then `open`. The venv of 4.x, `~/.local/share/clux/laya`, is not used any more; you can delete it.

The policies are in `plugins/clux/config/clef/`. There is no user copy: a command in the companion can write the files of the user, so a user copy could turn off the checks.
```

  In the `### Background sessions` list, change the watchdog line to `A watchdog process closes the companion when the session process ends, also after a crash.`

  In `CONTRIBUTING.md`, change the two tree lines to:

```
│   └── clef_client.py           # The only code that speaks to Clef
```

```
│   └── clef/                    # Clef policies, read from the plugin tree
```

  and the child lines of that directory keep their names (`command.json`, `output-block.json`, `output-line.json`, `pane.json`, `secret-values.txt`, `not-secret.txt`).

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/terminal.bats test/docs-tree.bats test/clef-names.bats
```

  Expect no `not ok`.

- [ ] Step 5 (commit).

```bash
git add README.md docs/reference.md CONTRIBUTING.md test/terminal.bats test/clef-names.bats
git commit -m "docs(clux): the user runs the Clef server, named by CLUX_CLEF_URL"
```

**Verification:**

```bash
bats test/terminal.bats test/docs-tree.bats test/clef-names.bats
grep -n 'clef_mlx.py serve' docs/reference.md
```

The bats run prints no `not ok`, and the grep prints the server command line.

---

## Task 16: Version 5.0.0 and the CHANGELOG

**Goal:** The plugin is 5.0.0, the CHANGELOG names the change, and `bats test/` passes in full.

**Files touched:**
- Modify: `plugins/clux/.claude-plugin/plugin.json`
- Modify: `CHANGELOG.md`
- Test: `test/terminal.bats`

**Steps:**

- [ ] Step 1 (failing test). In `test/terminal.bats`, add:

```bash
@test "the 5.0.0 release names Clef, CLUX_CLEF_URL and the Bash tool time limit" {
    local section
    section=$(awk '/^## \[5\.0\.0\]/ { on = 1; next } /^## \[/ { on = 0 } on' "$REPO_ROOT/CHANGELOG.md")
    [ -n "$section" ] || { echo 'no 5.0.0 section'; false; }
    [[ "$section" == *'needs a Clef server'* ]] || false
    [[ "$section" == *'CLUX_CLEF_URL'* ]] || false
    [[ "$section" == *'180000'* ]] || false
    [[ "$section" == *'close'*'open'* ]] || false
    grep -qF 'CLUX_CLEF_URL' "$REPO_ROOT/README.md"
}
```

- [ ] Step 2 (run test, observe FAIL). Run:

```bash
bats test/terminal.bats -f '5.0.0 release names Clef'
```

  Expect `no 5.0.0 section`.

- [ ] Step 3 (minimal implementation). Change the version in `plugins/clux/.claude-plugin/plugin.json`:

```json
  "version": "5.0.0",
```

  Add this section at the top of `CHANGELOG.md`, under the `All notable changes` line:

```markdown
## [5.0.0]

### Changed

- **The companion needs a Clef server that you run.** Clef 27B (`mlx-community/clef-4bit`) makes the decisions of the command gate, the output guard and the pane state in place of Laya. clux does not install, start or stop a model. You run one server and name it with `CLUX_CLEF_URL`; the reference gives the command
- One server answers all machines. `CLUX_CLEF_URL` must use `http` and name a loopback host (`127.0.0.1`, `localhost`, `::1`), a Tailscale address (`100.64.0.0/10` or `fd7a:115c:a1e0::/48`) or a `.ts.net` name that resolves only to Tailscale addresses. clux refuses each other host, so terminal text does not go out of your tailnet. A `.ts.net` name is resolved one time for each process, and the client connects to the address that it checked
- `CLUX_CLEF_KEY` is optional: with it, each request, also `health`, sends `Authorization: Bearer <key>`. `clef_mlx.py serve` has no key check; limit the port with your Tailscale ACL
- `open` reads `CLUX_CLEF_URL`, checks the host, checks that the client Python is 3.10 or later, and asks the server one health question and one pane question. A failure gives exit code 6 with `clef not configured` or `clef not available`. When the server stops during a session, each verb gives exit code 6 and no pane text; the next verb tries again
- **The output guard reads blocks of 2,000 characters**, and for a block with a secret it asks which lines hold it: one question for each line, at most 10 lines in one request, with the numbered block as the state. A line above 0.75 is held. The pair rule is gone: the block gives each line its context
- When the time that is left is less than the estimated cost of that line search, the full block is held as `[held by clef: secret, <k> lines]`
- The guard limit is 45 seconds (was 15), and the guard reads at most the last 16384 bytes of the output (was 32768). A request has 15 seconds (was 5) and the command gate 15 seconds (was 11), because a request can wait for the request of another companion
- The skill tells Claude to set the Bash tool `timeout` to 180000 milliseconds for each `run` and `wait`, and to (S + 116) × 1000 milliseconds for `--timeout S` above 64
- **Each name reads `clef`:** `clef_client.py`, `config/clef/`, `terminal.sh clef status`, `CLUX_CLEF_URL`, `CLUX_CLEF_KEY`, `CLUX_CLEF_PYTHON`, `CLEF_GUARD_LIMIT`, `CLEF_GUARD_BYTES`, `[held by clef: ...]` and the `clef:` messages
- The client imports no model package: it turns each policy schema into Clef questions itself and runs with any python3 3.10 or later. Each request sends `"truncate": false`, so the server answers 413 for a state that is too long in place of cutting it

### Removed

- `terminal.sh laya install`, the venv in `~/.local/share/clux/laya`, the checkpoint download, the API key that clux made, the free port, and every start, health wait and stop of a model server, also in `close`, in the reaper and in the watchdog. The venv of 4.x stays on disk; you can delete it
- The `checkpoint`, `ready`, `port`, `version` and `pip-install` helpers of the client, and the `model` field of the policies
- The rules for a state that the model cut: the client sends no shorter state again and splits no block

### Migration

- Set `CLUX_CLEF_URL` (and `CLUX_CLEF_KEY` when your server has a key) in the environment of Claude Code, and start Claude Code again
- A companion of 4.x has no Clef server: use `close`, then `open`
```

  The section must not hold the word `inferred` (`test/terminal.bats` checks the skill and the release notes).

- [ ] Step 4 (run test, observe PASS). Run:

```bash
bats test/
```

  Expect no `not ok` in any file.

- [ ] Step 5 (commit).

```bash
git add plugins/clux/.claude-plugin/plugin.json CHANGELOG.md test/terminal.bats
git commit -m "feat(clux)!: a Clef server that the user runs, through CLUX_CLEF_URL (5.0.0)"
```

**Verification:**

```bash
bats test/
grep -m1 '^## \[' CHANGELOG.md
sed -n 's/.*"version": "\([^"]*\)".*/\1/p' plugins/clux/.claude-plugin/plugin.json
```

The bats run prints no `not ok` for any file. The grep prints `## [5.0.0]`, and the `sed` prints `5.0.0`; the test `"the plugin version is the top CHANGELOG heading"` checks that the two agree.
