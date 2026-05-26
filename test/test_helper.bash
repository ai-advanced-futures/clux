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

# install_stubs — copy committed stubs into a per-test dir and prepend to PATH.
install_stubs() {
    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    cp -r "$BATS_TEST_DIRNAME/stubs/"* "$BATS_TEST_TMPDIR/stubs/"
    export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
}

setup() {
    install_stubs
    export QUEUE_FILE="$BATS_TEST_TMPDIR/queue"
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export CLUX_NOTIFY_FILE="$QUEUE_FILE"   # agent path resolves via resolve_notify_file() -> CLUX_NOTIFY_FILE (tier 1)
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}
