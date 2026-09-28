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
        'close --bogus' 'bogus'; do
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
    run env STUB_LOG="$log" CLUX_TERMINAL_DIR="$root" TMUX=fake TMUX_PANE=%0 bash -c \
        "source '$TERMINAL'; terminal_init; reap_companions"
    [ "$status" -eq 0 ]
    [ -d "$root/1234-1700000000-0" ]
    [ ! -e "$root/1234-1700000000-9" ]
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
