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

# The Python that runs clef_client.py in the tests: any python3 3.10 or
# later (spec section 5). 5.0.0 has no venv.
export CLUX_CLEF_PYTHON="${CLUX_CLEF_PYTHON:-python3}"
FAKE_CLEF="$REPO_ROOT/test/fixtures/fake-clef.py"
CLEF_CLIENT="$SCRIPTS_DIR/clef_client.py"
export FAKE_CLEF CLEF_CLIENT

# client ARGS... — run clef_client.py with the test Python. The one spelling
# of the client launch for every test file.
client() { "$CLUX_CLEF_PYTHON" "$CLEF_CLIENT" "$@"; }

# clef_home — the per-test HOME and XDG_CONFIG_HOME of a test that runs the
# client. setup() of this file does the same for the other test files.
clef_home() {
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
}

# install_stubs — copy committed stubs into a per-test dir and prepend to PATH.
install_stubs() {
    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    cp -r "$BATS_TEST_DIRNAME/stubs/"* "$BATS_TEST_TMPDIR/stubs/"
    export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
}

# A test that runs the client needs only python3 3.10 or later: the client
# imports no model package (spec section 5). It asks clef_python_ok of
# terminal.sh, so the version floor stays in one place.
require_client_python() {
    bash -c "source '$SCRIPTS_DIR/terminal.sh'; clef_python_ok" \
        || skip "no python3 3.10 or later: set CLUX_CLEF_PYTHON"
}

# start_fake_clef [ANSWERS_JSON] — start fake-clef.py on a free loopback port.
# Exports CLUX_CLEF_URL, CLUX_CLEF_KEY, FAKE_CLEF_ANSWERS and FAKE_CLEF_LOG.
start_fake_clef() {
    local json="${1:-}" port_file="$BATS_TEST_TMPDIR/fake-clef.port" i=0
    [ -n "$json" ] || json='{}'
    export FAKE_CLEF_ANSWERS="$BATS_TEST_TMPDIR/fake-clef.json"
    export FAKE_CLEF_LOG="$BATS_TEST_TMPDIR/fake-clef.log"
    export CLUX_FAKE_CLEF_ANSWERS="$FAKE_CLEF_ANSWERS"
    printf '%s\n' "$json" > "$FAKE_CLEF_ANSWERS"
    rm -f "$port_file"
    CLUX_FAKE_CLEF_LOG="$FAKE_CLEF_LOG" CLUX_FAKE_CLEF_PORT_FILE="$port_file" \
        CLEF_HOST=127.0.0.1 CLEF_PORT=0 CLEF_API_KEY=fake-key \
        python3 "$FAKE_CLEF" </dev/null >/dev/null 2>&1 3>&- &
    FAKE_CLEF_PID=$!
    while [ ! -s "$port_file" ] && [ "$i" -lt 100 ]; do sleep .05; i=$((i + 1)); done
    [ -s "$port_file" ] || return 1
    export CLUX_CLEF_URL="http://127.0.0.1:$(cat "$port_file")"
    export CLUX_CLEF_KEY=fake-key
}

# set_fake_clef ANSWERS_JSON — change the answers of the running fake.
set_fake_clef() {
    printf '%s\n' "$1" > "$FAKE_CLEF_ANSWERS"
}

stop_fake_clef() {
    [ -z "${FAKE_CLEF_PID:-}" ] || kill "$FAKE_CLEF_PID" 2>/dev/null || true
    FAKE_CLEF_PID=
}

# fake_clef_states QUESTION — print the state of each request that asked
# QUESTION, in order, one JSON string for each line. For a state that is a
# JSON object, print its "line" field.
fake_clef_states() {
    [ -f "${FAKE_CLEF_LOG:-}" ] || return 0
    python3 - "$FAKE_CLEF_LOG" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as log:
    for raw in log:
        request = json.loads(raw)
        if sys.argv[2] in request["questions"]:
            state = request["state"]
            print(json.dumps(state["line"] if isinstance(state, dict) else state))
PY
}

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

# write_filter_rules DIR RULE... — the filter file of the repo at DIR
# (scripts/notify-filter.sh), one line for each RULE.
write_filter_rules() {
    local dir="$1"; shift
    mkdir -p "$dir/.claude"
    printf '%s\n' "$@" > "$dir/.claude/clux-filters.local"
}

# hold_lock PATH — a live process that holds the flock lock of PATH, as a verb
# of terminal.sh does (LOCK_HELPER). It sets HOLD_PID when the lock is held.
# stop_holders stops each holder (the teardown does it too). A holder that
# is stopped leaves its file, as a verb that was killed does.
HOLD_PID=
hold_lock() {
    local ready="$BATS_TEST_TMPDIR/hold.$RANDOM" i=0
    perl -e 'use Fcntl qw(:flock O_RDWR O_CREAT);
        sysopen(my $f, $ARGV[0], O_RDWR | O_CREAT, 0600) or die;
        flock($f, LOCK_EX) or die;
        open(my $r, ">", $ARGV[1]) or die; close $r;
        sleep 600' "$1" "$ready" < /dev/null > /dev/null 2>&1 3>&- &
    HOLD_PID=$!
    printf '%s\n' "$HOLD_PID" >> "$BATS_TEST_TMPDIR/holders"
    while [ ! -e "$ready" ] && [ "$i" -lt 50 ]; do sleep .1; i=$((i + 1)); done
    [ -e "$ready" ] || { echo "hold_lock: no lock on $1"; return 1; }
}

stop_holders() {
    local pid
    [ -f "$BATS_TEST_TMPDIR/holders" ] || return 0
    while read -r pid; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done < "$BATS_TEST_TMPDIR/holders"
    rm -f "$BATS_TEST_TMPDIR/holders"
}

# The shared setup and teardown. A file with its own setup() or teardown()
# calls these first, so a change here reaches every file.
setup() { clux_setup; }
teardown() { clux_teardown; }

clux_setup() {
    install_stubs
    # A run from a Claude Code Bash call gets the session of that call. Each
    # test selects its owner: a pane (TMUX and TMUX_PANE) or a session that
    # the test sets.
    unset CLAUDE_CODE_SESSION_ID CLUX_SESSION_ID CLAUDE_PID
    export QUEUE_FILE="$BATS_TEST_TMPDIR/queue"
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export CLUX_NOTIFY_FILE="$QUEUE_FILE"   # agent path resolves via resolve_notify_file() -> CLUX_NOTIFY_FILE (tier 1)
}

clux_teardown() {
    stop_fake_clef
    stop_holders
    rm -rf "$BATS_TEST_TMPDIR"
}
