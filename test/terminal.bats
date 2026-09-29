#!/usr/bin/env bats

load test_helper

TERMINAL="$SCRIPTS_DIR/terminal.sh"

@test "check-line accepts credential prompts and rejects ordinary output" {
    local line
    while IFS= read -r line; do
        run "$TERMINAL" check-line -- "$line"
        [ "$status" -eq 0 ] || { echo "expected credential prompt: $line"; false; }
    done <<'EOF'
Password:
Enter passphrase for key '/id_ed25519':
Enter code:
Enter your security code?
[sudo] password for user:
Token (will be hidden):
Enter pass phrase for server.pem:
Passwd:
AWS Access Key ID [None]:
EOF

    while IFS= read -r line; do
        run "$TERMINAL" check-line -- "$line"
        [ "$status" -eq 1 ] || { echo "expected ordinary line: $line"; false; }
    done <<'EOF'
Do you want to save the token? [y/N]
Overwrite secret? [y/N]:
Are you sure you want to continue connecting (yes/no/[fingerprint])?
$ op read op://v/i/password
Authenticated successfully
Authentication failed
token: null
client_secret: x
MFA enabled: false
Press enter to continue, any key
Logged in to github.com as user (Token: gho_****)
EOF
}

@test "check-line removes comments and blank patterns" {
    local patterns="$BATS_TEST_TMPDIR/patterns"
    printf '\n# no active patterns\n' > "$patterns"
    run "$TERMINAL" check-line --patterns "$patterns" -- 'Password:'
    [ "$status" -eq 1 ]

    printf 'passw(or)?d\n' > "$patterns"
    run "$TERMINAL" check-line --patterns "$patterns" -- 'Password:'
    [ "$status" -eq 0 ]
}

@test "check-line never calls tmux" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run env STUB_LOG="$log" "$TERMINAL" check-line -- 'ordinary output'
    [ "$status" -eq 1 ]
    [ ! -s "$log" ]
}

@test "tmux verbs refuse outside tmux while hook close is silent" {
    local args
    for args in 'open' 'run -- true' 'send -- x' 'read' 'wait --idle' 'close' 'list'; do
        run env -u TMUX -u TMUX_PANE bash -c "'$TERMINAL' $args"
        [ "$status" -eq 2 ] || { echo "$args returned $status"; false; }
        [[ "$output" == *'inside tmux'* ]] || false
    done

    run env -u TMUX -u TMUX_PANE bash -c "printf hook-input | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "malformed verb arguments exit 2" {
    local args
    # --bogus stands for any unknown flag: it is the *) usage arm of that verb's
    # own parser. Naming a plausible-but-absent flag here read as if the flag
    # existed and was handled.
    for args in 'open --size wrong' 'open --size' 'run --timeout x -- true' 'run --timeout' 'run --bogus' \
        'send --key' 'read --lines 0' 'read --lines' 'wait --timeout x --idle' 'wait' 'wait --idle --pattern x' \
        'close --bogus' 'bogus' 'laya' 'laya bogus' 'laya status extra'; do
        run env TMUX=fake TMUX_PANE=%0 bash -c "'$TERMINAL' $args"
        [ "$status" -eq 2 ] || { echo "$args returned $status"; false; }
    done
}

@test "the wrapper sets umask 077 only inside the process substitution" {
    grep -q '> >(umask 077; tee ' "$TERMINAL"
    run sed -n '/^write_rc_file()/,/^EOF/p' "$TERMINAL"
    [[ "$output" == *'__clux_run()'* ]] || false
    ! printf '%s\n' "$output" | grep -q '^umask' || false
}

# The reaper splits <pid>-<start>-<pane>: only the first two fields go to the
# server-key validator. A socket-mode state with no socket must never turn
# into a kill-pane on the user's server.
@test "the reaper reads the server key from the first two fields" {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    display-message) echo 1234-1700000000 ;;
    list-panes) echo %0 ;;
esac
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    local root="$BATS_TEST_TMPDIR/root" log="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$root/1234-1700000000-0" "$root/1234-1700000000-9"
    printf 'mode=socket\npane=%%0\nsocket=\nseq=0\n' > "$root/1234-1700000000-9/state"
    # A foreign server that is gone: its split pane id means nothing here.
    mkdir -p "$root/999999999-1-4"
    printf 'mode=split\npane=%%0\nsocket=\nseq=0\n' > "$root/999999999-1-4/state"
    run env STUB_LOG="$log" CLUX_TERMINAL_DIR="$root" TMUX=fake TMUX_PANE=%0 bash -c \
        "source '$TERMINAL'; terminal_init; reap_companions"
    [ "$status" -eq 0 ]
    [ -d "$root/1234-1700000000-0" ]
    [ ! -e "$root/1234-1700000000-9" ]
    [ ! -e "$root/999999999-1-4" ]
    ! grep -q 'kill-pane' "$log" || false
}

@test "the terminal skill carries Snippet S1 unchanged" {
    local skills="$REPO_ROOT/plugins/clux/skills"
    s1() { sed -n '/^# Tier 1: the harness/,/^echo "MANIFEST=/p' "$1"; }
    [ -n "$(s1 "$skills/configuring-tmux/SKILL.md")" ]
    [ "$(s1 "$skills/terminal/SKILL.md")" = "$(s1 "$skills/configuring-tmux/SKILL.md")" ]
}

@test "close --owner is parsed" {
    run env -u TMUX -u TMUX_PANE "$TERMINAL" close --owner
    [ "$status" -eq 2 ]
    run env TMUX=fake TMUX_PANE=%0 CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/none" "$TERMINAL" close --owner %5
    [ "$status" -eq 0 ]
}

@test "run --max-lines needs a positive integer" {
    run env TMUX=fake TMUX_PANE=%0 "$TERMINAL" run --max-lines 0 -- true
    [ "$status" -eq 2 ]
    run env TMUX=fake TMUX_PANE=%0 "$TERMINAL" wait --max-lines x --run 1
    [ "$status" -eq 2 ]
}

# A tmux stub for open: one server key, one pane, version 3.4.
open_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    -V) echo 'tmux 3.4' ;;
    display-message) echo 1234-1700000000 ;;
    list-panes) echo %0 ;;
esac
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "open refuses a CLUX_LAYA_URL that is not a loopback host" {
    open_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log" url
    for url in http://example.com:8000 'http://localhost:80@example.com' https://127.0.0.1:1; do
        run env STUB_LOG="$log" CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" TMUX=fake TMUX_PANE=%0 \
            CLUX_LAYA_URL="$url" "$TERMINAL" open
        [ "$status" -eq 6 ] || { echo "$url gave $status"; false; }
        [ "$output" = 'CLUX_LAYA_URL must name a loopback host: 127.0.0.1, localhost or ::1' ]
    done
    ! grep -q 'split-window' "$log" || false
}

@test "open with CLUX_LAYA_URL needs a client Python that imports laya" {
    open_tmux_stub
    local py
    # A Python with no laya package.
    printf '#!/bin/sh\nexec python3 -S -I -c "import sys; sys.exit(1)" "$@"\n' > "$BATS_TEST_TMPDIR/nolaya"
    chmod +x "$BATS_TEST_TMPDIR/nolaya"
    for py in "$BATS_TEST_TMPDIR/none/python3" "$BATS_TEST_TMPDIR/nolaya"; do
        run env CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" TMUX=fake TMUX_PANE=%0 \
            CLUX_LAYA_PYTHON="$py" CLUX_LAYA_URL=http://127.0.0.1:9 "$TERMINAL" open
        [ "$status" -eq 6 ] || { echo "$py gave $status"; false; }
        [ "$output" = 'laya not installed: run terminal.sh laya install' ]
    done
}

@test "open refuses when the CLUX_LAYA_URL server does not answer" {
    open_tmux_stub
    run env CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" TMUX=fake TMUX_PANE=%0 \
        CLUX_LAYA_URL=http://127.0.0.1:9 "$TERMINAL" open
    [ "$status" -eq 6 ]
    [ "$output" = 'laya not available at CLUX_LAYA_URL' ]
}

@test "open with no venv, or with no checkpoint, gives exit 6 and the install message" {
    open_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run env -u CLUX_LAYA_URL STUB_LOG="$log" XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
        CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" TMUX=fake TMUX_PANE=%0 "$TERMINAL" open
    [ "$status" -eq 6 ]
    [ "$output" = 'laya not installed: run terminal.sh laya install' ]
    ! grep -q 'split-window' "$log" || false
    require_laya_python
    make_fake_venv "$BATS_TEST_TMPDIR/data/clux/laya"
    run env -u CLUX_LAYA_URL XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" \
        CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" TMUX=fake TMUX_PANE=%0 "$TERMINAL" open
    [ "$status" -eq 6 ]
    [ "$output" = 'laya not installed: run terminal.sh laya install' ]
}

@test "write_state and state_load carry the three laya fields" {
    run bash -c "source '$TERMINAL'
        D='$BATS_TEST_TMPDIR'
        write_state split %1 '' 3 4242 http://127.0.0.1:5 k1
        S_LAYA_PID=; S_LAYA_URL=; S_LAYA_KEY=
        state_load
        echo \"\$S_SEQ \$S_LAYA_PID \$S_LAYA_URL \$S_LAYA_KEY\"
        write_state split %1 '' 4
        state_load
        echo \"\$S_SEQ \$S_LAYA_PID \$S_LAYA_URL \$S_LAYA_KEY\"
        write_state split %1 '' 5 '' '' ''
        cat \"\$D/state\""
    [ "$status" -eq 0 ]
    [ "$output" = $'3 4242 http://127.0.0.1:5 k1\n4 4242 http://127.0.0.1:5 k1\nmode=split\npane=%1\nsocket=\nseq=5' ]
}

@test "pane_state: the regex layer adds credential, and a client failure gives 6" {
    require_laya_python
    start_fake_laya '{"answers": {"state": "other"}}'
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *cursor_y*) echo 4 ;;
    capture-pane*) printf 'one\ntwo\nthree\nfour\n%s\n' "$CLUX_TEST_LINE" ;;
esac
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    probe() {
        CLUX_TEST_LINE="$1" bash -c "source '$TERMINAL'
            S_MODE=split; S_PANE=%1; S_LAYA_URL='$CLUX_LAYA_URL'; S_LAYA_KEY='$CLUX_LAYA_KEY'
            pane_state; echo \"\$? \$PANE_STATE\""
    }
    [ "$(probe 'Password:')" = '0 credential' ]
    [ "$(probe 'hello')" = '0 other' ]
    [ "$(fake_laya_states state | tail -n 1)" = '"one\ntwo\nthree\nfour\nhello"' ]
    set_fake_laya '{"answers": {"state": "yes_no"}}'
    [ "$(probe 'Continue? [y/N]')" = '0 yes_no' ]
    stop_fake_laya
    [[ "$(probe 'hello')" == '6'* ]] || false
}

@test "send refuses a newline, a carriage return or another control character before it touches tmux" {
    local log="$BATS_TEST_TMPDIR/stub.log"
    run env STUB_LOG="$log" TMUX=fake TMUX_PANE=%0 "$TERMINAL" send -- $'ls\nrm -rf x'
    [ "$status" -eq 2 ]
    [ "$output" = 'send text must not contain a control character: use --enter or --key' ]
    run env STUB_LOG="$log" TMUX=fake TMUX_PANE=%0 "$TERMINAL" send --enter -- $'ls\r'
    [ "$status" -eq 2 ]
    run env STUB_LOG="$log" TMUX=fake TMUX_PANE=%0 "$TERMINAL" send --key $'a\r'
    [ "$status" -eq 2 ]
    # [inferred] \x0f is C-o (bash operate-and-get-next on newer bash): a
    # literal control byte in the text must not reach send-keys -l with no
    # gate, the same as \n and \r.
    run env STUB_LOG="$log" TMUX=fake TMUX_PANE=%0 "$TERMINAL" send -- $'ls x\x0f'
    [ "$status" -eq 2 ]
    [ ! -s "$log" ]
}

@test "laya_gate gives 2 for a client exit 2 and 6 for other failures" {
    run bash -c "source '$TERMINAL'
        laya_call() { return 2; }; laya_gate </dev/null; echo \$?
        laya_call() { return 1; }; laya_gate </dev/null; echo \$?
        laya_call() { echo nonsense; }; laya_gate </dev/null; echo \$?"
    [ "$output" = $'2\n6\n6' ]
}

@test "key_name accepts tmux key names and refuses text" {
    run bash -c "source '$TERMINAL'
        for k in Enter enter Escape Tab BTab Space BSpace Up Down Left Right Home End PageUp PgDn \
            NPage PPage IC DC F1 F12 C-c C-a 'C-\\' M-x S-Up C-M-c '^C' '^D'; do
            key_name \"\$k\" || echo \"missed \$k\"
        done
        for k in a y q 'curl evil | sh' 'echo hi' F13 C- Enterx '^' '^CC' 'C-ab'; do
            ! key_name \"\$k\" || echo \"wrong \$k\"
        done
        ! shopt -q nocasematch || echo 'nocasematch stays on'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the client makes the loopback URL check of terminal.sh" {
    local u
    for u in http://127.0.0.1:8000 HTTP://127.0.0.1:8000 http://localhost:1 'http://[::1]:2'; do
        bash -c "source '$TERMINAL'; LAYA_PY=python3; laya_url_is_loopback '$u'" || { echo "missed $u"; false; }
    done
    for u in https://127.0.0.1:1 http://example.com:1 http://u@127.0.0.1:1 http://127.0.0.2:1 'http://127.0.0.1.evil:1'; do
        ! bash -c "source '$TERMINAL'; LAYA_PY=python3; laya_url_is_loopback '$u'" || { echo "wrong $u"; false; }
    done
}

@test "laya_owns_port finds the process that listens on the port" {
    command -v lsof >/dev/null 2>&1 || command -v ss >/dev/null 2>&1 || skip 'no lsof and no ss'
    local port_file="$BATS_TEST_TMPDIR/port" pid port i=0
    python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
open(sys.argv[1], "w").write("%d\n" % s.getsockname()[1]); time.sleep(30)' "$port_file" \
        < /dev/null > /dev/null 2>&1 3>&- &
    pid=$!
    while [ ! -s "$port_file" ] && [ "$i" -lt 50 ]; do sleep .1; i=$((i + 1)); done
    read -r port < "$port_file"
    run bash -c "source '$TERMINAL'; laya_owns_port $pid $port"
    local own=$status
    run bash -c "source '$TERMINAL'; laya_owns_port $$ $port"
    local other=$status
    kill "$pid"
    [ "$own" -eq 0 ]
    [ "$other" -ne 0 ]
}

@test "laya_stop_server stops several servers that ignore TERM with one wait" {
    local bin="$BATS_TEST_TMPDIR/bin" a b start
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\ntrap "" TERM\nwhile :; do sleep .2; done\n' > "$bin/laya-serve"
    chmod +x "$bin/laya-serve"
    # One level deeper, so a killed server is not a zombie of this shell.
    a=$( ("$bin/laya-serve" < /dev/null > /dev/null 2>&1 3>&- & echo $!) )
    b=$( ("$bin/laya-serve" < /dev/null > /dev/null 2>&1 3>&- & echo $!) )
    sleep .3
    start=$SECONDS
    # The real ps: the stub ps of this file finds no process.
    PATH="/bin:/usr/bin:$PATH" bash -c "source '$TERMINAL'; laya_stop_server $a $b"
    local took=$((SECONDS - start)) alive=0
    kill -0 "$a" 2>/dev/null && alive=1
    kill -0 "$b" 2>/dev/null && alive=1
    kill -9 "$a" "$b" 2>/dev/null || true
    [ "$alive" -eq 0 ]
    [ "$took" -lt 5 ]
}

@test "interrupt_key finds only the keys that skip the Laya pane check" {
    run bash -c "source '$TERMINAL'
        for k in C-c c-C C-d C-z 'C-\\' '^C' '^d' Escape escape; do
            interrupt_key \"\$k\" || echo \"missed \$k\"
        done
        for k in Enter C-m C-a C-u Up Tab M-c C-M-c c; do
            ! interrupt_key \"\$k\" || echo \"wrong \$k\"
        done"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the run time budget stays 10 s under the 120 s limit of the Bash tool" {
    local t g
    read -r t g < <(bash -c "source '$TERMINAL'; echo \"\$RUN_TIMEOUT_DEFAULT \$LAYA_GUARD_LIMIT\"")
    [ -n "$t" ] && [ -n "$g" ]
    # Tenths of a second: the gate with its retry, wait_for_prompt, the clear,
    # the run limit, the last pane_state call, the report grace, the late
    # SECONDS tick and the guard limit.
    [ $((110 + 20 + 50 + t * 10 + 110 + 10 + 10 + g * 10)) -le 1100 ]
    grep -q '^REQUEST_LIMIT = 5.0$' "$LAYA_CLIENT"
    grep -q '^RETRY_DELAY = 1.0 ' "$LAYA_CLIENT"
    grep -q 'local timeout=\$RUN_TIMEOUT_DEFAULT ' "$TERMINAL"
}

@test "laya status with no venv" {
    run env -u TMUX -u TMUX_PANE XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" "$TERMINAL" laya status
    [ "$status" -eq 0 ]
    [ "$output" = "venv=$BATS_TEST_TMPDIR/data/clux/laya"$'\nversion=none\ncheckpoint=missing\nserver=none' ]
}

@test "laya status with the venv and the checkpoint" {
    require_laya_python
    make_fake_venv "$BATS_TEST_TMPDIR/data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    run env -u TMUX -u TMUX_PANE XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" \
        "$TERMINAL" laya status
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nversion='[0-9]*$'\ncheckpoint=present\nserver=none' ]] || false
}

@test "laya install stops when the venv and the checkpoint are present" {
    require_laya_python
    make_fake_venv "$BATS_TEST_TMPDIR/data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    run env -u TMUX -u TMUX_PANE XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" \
        "$TERMINAL" laya install
    [ "$status" -eq 0 ]
    [[ "$output" == 'laya '*' is already installed'* ]] || false
    # An installed venv needs no python3 3.10 on PATH.
    run env -u TMUX -u TMUX_PANE PATH="$BATS_TEST_TMPDIR/nopython:/bin:/usr/sbin:/sbin" \
        XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" \
        /bin/bash -c "PATH=\$PATH; exec '$(command -v bash)' '$TERMINAL' laya install"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == 'laya '*' is already installed'* ]] || false
}

@test "laya install needs Python 3.10 or later" {
    local name
    for name in python3.12 python3.13 python3.11 python3.10 python3; do
        printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/stubs/$name"
        chmod +x "$BATS_TEST_TMPDIR/stubs/$name"
    done
    run env -u TMUX -u TMUX_PANE XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" "$TERMINAL" laya install
    [ "$status" -eq 2 ]
    [ "$output" = 'laya install needs python3 3.10 or later' ]
    [ ! -e "$BATS_TEST_TMPDIR/data/clux/laya" ]
}

@test "a failed pip install deletes the venv and shows the pip error" {
    cat > "$BATS_TEST_TMPDIR/stubs/python3.12" <<'STUB'
#!/usr/bin/env bash
# The version check passes. "-m venv DIR" makes a venv whose python3 fails
# as pip does.
case "$1" in
    -m)
        mkdir -p "$3/bin"
        printf '#!/usr/bin/env bash\necho "stub pip: no matching distribution" >&2\nexit 1\n' > "$3/bin/python3"
        chmod +x "$3/bin/python3"
        ;;
esac
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/python3.12"
    run env -u TMUX -u TMUX_PANE XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" "$TERMINAL" laya install
    [ "$status" -eq 1 ]
    [[ "$output" == *'stub pip: no matching distribution'* ]] || false
    [[ "$output" == *'laya install: pip install failed'* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/data/clux/laya" ]
}

@test "a failed checkpoint download keeps the venv and removes secret lines from the log" {
    require_laya_python
    local venv="$BATS_TEST_TMPDIR/data/clux/laya" tmp="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$tmp"
    make_fake_venv "$venv"
    rm "$venv/bin/laya-serve"
    printf '#!/usr/bin/env bash\necho "token AKIAABCDEFGHIJKLMNOP"\necho boom\nexit 1\n' > "$venv/bin/laya-serve"
    chmod +x "$venv/bin/laya-serve"
    run env -u TMUX -u TMUX_PANE TMPDIR="$tmp" XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
        HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" "$TERMINAL" laya install
    [ "$status" -eq 1 ]
    [[ "$output" == *'laya install: the checkpoint download failed: laya-serve ended before it answered'* ]] || false
    [[ "$output" == *'boom'* ]] || false
    [[ "$output" != *'AKIA'* ]] || false
    [ -f "$venv/.clux-installed" ]
    [ -z "$(ls -A "$tmp")" ]
}

@test "the skill and the release notes have no author notes" {
    ! grep -n 'inferred' "$REPO_ROOT/plugins/clux/skills/terminal/SKILL.md" "$REPO_ROOT/CHANGELOG.md" || false
}

@test "the terminal skill covers Laya and the time limits of terminal.sh" {
    local skill="$REPO_ROOT/plugins/clux/skills/terminal/SKILL.md" t g
    read -r t g < <(bash -c "source '$TERMINAL'; echo \"\$RUN_TIMEOUT_DEFAULT \$LAYA_GUARD_LIMIT\"")
    grep -qF 'terminal.sh laya install' "$skill"
    grep -qF '600000' "$skill"
    grep -qF '[held by laya:' "$skill"
    grep -qF 'config/laya/' "$skill"
    grep -qF 'laya confirmation' "$skill"
    grep -qF '| 6 |' "$skill"
    grep -qF "The default time limit is $t seconds" "$skill"
    # 46 s of Laya checks at most, plus a 10 s margin.
    grep -qF "S + 56" "$skill"
    grep -qF "(S + 56) × 1000" "$skill"
}

@test "the 4.0.0 release names Laya and the run time limit" {
    local t section
    t=$(bash -c "source '$TERMINAL'; echo \"\$RUN_TIMEOUT_DEFAULT\"")
    grep -q '"version": "4.0.0"' "$REPO_ROOT/plugins/clux/.claude-plugin/plugin.json"
    [ "$(grep -m1 '^## \[' "$REPO_ROOT/CHANGELOG.md")" = '## [4.0.0]' ]
    section=$(awk '/^## \[4\.0\.0\]/ { on = 1; next } /^## \[/ { on = 0 } on' "$REPO_ROOT/CHANGELOG.md")
    [[ "$section" == *'needs Laya'* ]] || false
    [[ "$section" == *"$t seconds"* ]] || false
    grep -q 'terminal.sh laya install' "$REPO_ROOT/README.md"
}
