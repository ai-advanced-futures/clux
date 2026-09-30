# shellcheck shell=bash
# test_helper.bash — shared setup/teardown + install_stubs helper

# Capture the real jq path BEFORE PATH is modified, so the jq stub can
# delegate to it without resolving to itself.
REAL_JQ="$(command -v jq)"
export REAL_JQ

# Path constants — exported so subshells launched via `run bash -c` can see them.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/plugins/clux/scripts"
HOOKS_DIR="$REPO_ROOT/plugins/clux/hooks"
NOTIFY_HOOK="$HOOKS_DIR/notify-tmux.sh"
export REPO_ROOT SCRIPTS_DIR HOOKS_DIR NOTIFY_HOOK

# The Python that runs laya_client.py in the tests (spec section 13). It is
# read here, when the file loads, because setup() moves HOME to a temp
# directory. The default is the venv of `terminal.sh laya install`.
export CLUX_LAYA_PYTHON="${CLUX_LAYA_PYTHON:-${XDG_DATA_HOME:-$HOME/.local/share}/clux/laya/bin/python3}"
FAKE_LAYA="$REPO_ROOT/test/fixtures/fake-laya.py"
LAYA_CLIENT="$SCRIPTS_DIR/laya_client.py"
export FAKE_LAYA LAYA_CLIENT

# install_stubs — copy committed stubs into a per-test dir and prepend to PATH.
install_stubs() {
    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    cp -r "$BATS_TEST_DIRNAME/stubs/"* "$BATS_TEST_TMPDIR/stubs/"
    export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
}

# A test that runs the client skips when CLUX_LAYA_PYTHON cannot import laya.
require_laya_python() {
    "$CLUX_LAYA_PYTHON" -c 'import laya' >/dev/null 2>&1 \
        || skip "no Python that can import laya: set CLUX_LAYA_PYTHON"
}

# start_fake_laya [ANSWERS_JSON] — start fake-laya.py on a free loopback port.
# Exports CLUX_LAYA_URL, CLUX_LAYA_KEY, FAKE_LAYA_ANSWERS and FAKE_LAYA_LOG.
start_fake_laya() {
    local json="${1:-}" port_file="$BATS_TEST_TMPDIR/fake-laya.port" i=0
    [ -n "$json" ] || json='{}'
    export FAKE_LAYA_ANSWERS="$BATS_TEST_TMPDIR/fake-laya.json"
    export FAKE_LAYA_LOG="$BATS_TEST_TMPDIR/fake-laya.log"
    export CLUX_FAKE_LAYA_ANSWERS="$FAKE_LAYA_ANSWERS"
    printf '%s\n' "$json" > "$FAKE_LAYA_ANSWERS"
    rm -f "$port_file"
    CLUX_FAKE_LAYA_LOG="$FAKE_LAYA_LOG" CLUX_FAKE_LAYA_PORT_FILE="$port_file" \
        LAYA_HOST=127.0.0.1 LAYA_PORT=0 LAYA_API_KEY=fake-key \
        python3 "$FAKE_LAYA" </dev/null >/dev/null 2>&1 3>&- &
    FAKE_LAYA_PID=$!
    while [ ! -s "$port_file" ] && [ "$i" -lt 100 ]; do sleep .05; i=$((i + 1)); done
    [ -s "$port_file" ] || return 1
    export CLUX_LAYA_URL="http://127.0.0.1:$(cat "$port_file")"
    export CLUX_LAYA_KEY=fake-key
}

# set_fake_laya ANSWERS_JSON — change the answers of the running fake.
set_fake_laya() {
    printf '%s\n' "$1" > "$FAKE_LAYA_ANSWERS"
}

stop_fake_laya() {
    [ -z "${FAKE_LAYA_PID:-}" ] || kill "$FAKE_LAYA_PID" 2>/dev/null || true
    FAKE_LAYA_PID=
}

# fake_laya_states QUESTION — print the state of each request that asked
# QUESTION, in order, one JSON string for each line. For a state that is a
# JSON object, print its "line" field.
fake_laya_states() {
    [ -f "${FAKE_LAYA_LOG:-}" ] || return 0
    python3 - "$FAKE_LAYA_LOG" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as log:
    for raw in log:
        request = json.loads(raw)
        if sys.argv[2] in request["questions"]:
            state = request["state"]
            print(json.dumps(state["line"] if isinstance(state, dict) else state))
PY
}

# make_fake_checkpoint DIR — a Hugging Face cache in DIR that holds the English
# checkpoint file of convaiinnovations/laya. Use it with HF_HUB_CACHE=DIR.
make_fake_checkpoint() {
    local repo="$1/models--convaiinnovations--laya" rev=0123456789abcdef0123456789abcdef01234567
    mkdir -p "$repo/refs" "$repo/snapshots/$rev"
    printf '%s' "$rev" > "$repo/refs/main"
    : > "$repo/snapshots/$rev/model.safetensors"
}

# make_fake_venv DIR — a venv shape for terminal.sh: bin/python3 runs
# CLUX_LAYA_PYTHON, bin/laya-serve is fake-laya.py, and the install marker is
# present.
make_fake_venv() {
    mkdir -p "$1/bin"
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$CLUX_LAYA_PYTHON" > "$1/bin/python3"
    chmod +x "$1/bin/python3"
    ln -s "$FAKE_LAYA" "$1/bin/laya-serve"
    : > "$1/.clux-installed"
}

# start_live_laya — start the real laya-serve of the CLUX_LAYA_PYTHON venv on
# a free loopback port, for one bats file (test/laya-live.bats). The URL, the
# key and the pid go to BATS_FILE_TMPDIR. It waits at most 120 s for health.
start_live_laya() {
    local bin="${CLUX_LAYA_PYTHON%/*}/laya-serve" port key i=0
    [ -x "$bin" ] || { echo "no laya-serve next to $CLUX_LAYA_PYTHON" >&2; return 1; }
    port=$("$CLUX_LAYA_PYTHON" "$LAYA_CLIENT" port) || return 1
    key=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    LAYA_HOST=127.0.0.1 LAYA_PORT="$port" LAYA_API_KEY="$key" LAYA_LOG_LEVEL=warning \
        LAYA_MODELS=english HF_HUB_OFFLINE=1 USE_TF=0 \
        "$bin" > "$BATS_FILE_TMPDIR/live.log" 2>&1 < /dev/null 3>&- &
    printf '%s\n' "$!" > "$BATS_FILE_TMPDIR/live.pid"
    printf 'http://127.0.0.1:%s\n' "$port" > "$BATS_FILE_TMPDIR/live.url"
    printf '%s\n' "$key" > "$BATS_FILE_TMPDIR/live.key"
    until CLUX_LAYA_URL="http://127.0.0.1:$port" CLUX_LAYA_KEY="$key" \
            "$CLUX_LAYA_PYTHON" "$LAYA_CLIENT" health >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -lt 240 ] || { echo 'laya-serve did not answer in 120 s' >&2; return 1; }
        sleep .5
    done
}

stop_live_laya() {
    local pid
    pid=$(cat "$BATS_FILE_TMPDIR/live.pid" 2>/dev/null) || return 0
    kill "$pid" 2>/dev/null || true
}

setup() {
    install_stubs
    # A run from a Claude Code Bash call gets the session of that call. Each
    # test selects its owner: a pane (TMUX and TMUX_PANE) or a session that
    # the test sets.
    unset CLAUDE_CODE_SESSION_ID CLUX_SESSION_ID CLAUDE_PID
    export QUEUE_FILE="$BATS_TEST_TMPDIR/queue"
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export CLUX_NOTIFY_FILE="$QUEUE_FILE"   # agent path resolves via resolve_notify_file() -> CLUX_NOTIFY_FILE (tier 1)
}

teardown() {
    stop_fake_laya
    rm -rf "$BATS_TEST_TMPDIR"
}
