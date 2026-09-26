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
        [[ "$output" == *'inside tmux'* ]]
    done

    run env -u TMUX -u TMUX_PANE bash -c "printf hook-input | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "malformed verb arguments exit 2" {
    local args
    for args in 'open --size wrong' 'run --timeout x -- true' 'send --key' 'read --lines 0' 'wait --timeout x --idle' 'close --owner' \
        'run --timeout' 'run --max-lines' 'read --lines'; do
        run env TMUX=fake TMUX_PANE=%0 bash -c "'$TERMINAL' $args"
        [ "$status" -eq 2 ] || { echo "$args returned $status"; false; }
    done
}
