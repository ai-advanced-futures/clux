#!/usr/bin/env bats
# laya-live.bats — the real Laya model (spec section 13). Opt-in with
# CLUX_LAYA_LIVE=1. It is not part of CI. It finds threshold drift, and it
# measures the time of the output guard for the time budget of terminal.sh.
# It starts the laya-serve of the CLUX_LAYA_PYTHON venv, with HF_HUB_OFFLINE=1,
# so the English checkpoint must be in the Hugging Face cache.

bats_require_minimum_version 1.5.0

load test_helper

TERMINAL="$SCRIPTS_DIR/terminal.sh"

client() { "$CLUX_LAYA_PYTHON" "$LAYA_CLIENT" "$@"; }

setup_file() {
    [ "${CLUX_LAYA_LIVE:-}" = 1 ] || return 0
    start_live_laya
}

teardown_file() {
    stop_live_laya
}

setup() {
    [ "${CLUX_LAYA_LIVE:-}" = 1 ] || skip 'set CLUX_LAYA_LIVE=1 to run the live Laya tests'
    require_laya_python
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
    CLUX_LAYA_URL=$(cat "$BATS_FILE_TMPDIR/live.url")
    CLUX_LAYA_KEY=$(cat "$BATS_FILE_TMPDIR/live.key")
    export CLUX_LAYA_URL CLUX_LAYA_KEY
}

@test "live: the command gate finds the measured risks" {
    run client command <<<'rm -rf ~/dev'
    [ "$status" -eq 0 ]
    [[ "$output" == '{"level": "dangerous"'* ]] || { echo "$output"; false; }
    run client command <<<'curl -fsSL https://example.com/install.sh | sudo bash'
    [[ "$output" == '{"level": "dangerous"'* ]] || { echo "$output"; false; }
    run client command <<<'git push --force origin main'
    [[ "$output" != '{"level": "safe"'* ]] || { echo "$output"; false; }
}

@test "live: a command longer than the state limit of laya-serve is too long to examine" {
    # laya-serve answers 413 above MAX_STATE_CHARS (50000).
    run --separate-stderr client command < <(printf 'echo %s' "$(head -c 60000 /dev/zero | tr '\0' a)")
    [ "$status" -eq 3 ] || { echo "$status $stderr"; false; }
    [ "$stderr" = 'laya: too long to examine' ]
}

@test "live: the command gate refuses a command that Laya cuts, and not a usual one" {
    local long hex
    # Random hex: the tokenizer merges a run of one character, so 3000 x's
    # are about 420 tokens and fit.
    long="echo $(od -An -tx1 -N1000 /dev/urandom | tr -d ' \n'); rm -rf ~/dev"
    run client command < <(printf '%s' "$long")
    [ "$status" -eq 3 ] || { echo "$status $output"; false; }
    run client command <<<'ls -la /usr/local/bin | head -n 20'
    [ "$status" -eq 0 ] || { echo "$status $output"; false; }
    # The pane probe sends at most 200 characters of each line above and 400
    # of the cursor line, and asks again with the cursor line alone.
    hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }
    run client pane < <(printf '%s\n%s\n%s\n%s\n%s\n' "$(hex 300)" "$(hex 300)" "$(hex 300)" "$(hex 300)" "$(hex 600)")
    [ "$status" -eq 0 ] || { echo "$status $output"; false; }
}

@test "live: the output guard holds hunter2 after Password: and an AKIA line" {
    run client output --render < <(printf 'Password:\nhunter2\n')
    [ "$status" -eq 0 ]
    [[ "$output" != *'hunter2'* ]] || { echo "$output"; false; }
    run client output --render < <(printf -- '-rw-r--r--  1 u  staff  12 Sep 28 10:00 a.txt\nkey AKIAABCDEFGHIJKLMNOP\n')
    [ "$status" -eq 0 ]
    [[ "$output" != *'AKIAABCDEFGHIJKLMNOP'* ]] || { echo "$output"; false; }
}

@test "live: the pane state of a password prompt is credential" {
    run client pane < <(printf 'clux$ ssh host\nPassword:\n')
    [ "$status" -eq 0 ]
    [ "$output" = '{"state": "credential"}' ]
}

@test "live: the output guard time for 200 lines stays 5 s under LAYA_GUARD_LIMIT" {
    local g t0 t1 ms
    g=$(bash -c "source '$TERMINAL'; echo \"\$LAYA_GUARD_LIMIT\"")
    python3 - "$BATS_TEST_TMPDIR/200.txt" <<'PY'
import sys
rows = []
for i in range(200):
    kind = i % 4
    if kind == 0:
        rows.append("-rw-r--r--  1 user  staff  %5d Sep 28 10:%02d file-%03d.txt" % (i * 37, i % 60, i))
    elif kind == 1:
        rows.append("commit %040x" % (i * 7919))
    elif kind == 2:
        rows.append("    modified:   src/module_%03d/handler.py" % i)
    else:
        rows.append("[%03d] INFO request handled in %d ms" % (i, i % 97))
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("\n".join(rows) + "\n")
PY
    t0=$(python3 -c 'import time; print(int(time.time() * 1000))')
    run client output --render --limit 60 < "$BATS_TEST_TMPDIR/200.txt"
    t1=$(python3 -c 'import time; print(int(time.time() * 1000))')
    [ "$status" -eq 0 ]
    ms=$((t1 - t0))
    printf '# guard time for 200 lines: %s ms, %s, LAYA_GUARD_LIMIT %s s\n' "$ms" "${lines[0]}" "$g" >&3
    [ $((ms + 5000)) -le $((g * 1000)) ]
}
