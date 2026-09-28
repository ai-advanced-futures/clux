# clux Companion Terminal Implementation Plan

**Goal:** Build the opt-in `clux:terminal` companion pane, with persistent shell state, file-backed command results, interactive control, credential protection, and session-end cleanup.

**Architecture:** One Bash 3.2-compatible script owns a private per-Claude-session directory keyed by tmux server and owner pane. It creates either a split pane on the user's server or an isolated socket server, drives a known interactive Bash through tmux, and separates plain file-backed runs from screen-based interactive commands. Unit tests use the committed tmux stub; end-to-end tests use a real throwaway `tmux -S` server.

**Tech Stack:** Bash 3.2, tmux 3.2+, Bats, JSON hook configuration, Markdown Claude Code skills

---

## Overview

Implement the terminal as sequential vertical slices. Keep `plugins/clux/scripts/terminal.sh` in the plugin tree rather than the deploy manifest, because hooks and skills resolve it through `CLAUDE_PLUGIN_ROOT`. Keep all mutable data below `${CLUX_TERMINAL_DIR:-${TMPDIR:-/tmp}/clux-terminal-$(id -u)}` with `umask 077`; never write command output to logs.

Three format choices are inferred where the spec leaves representation open: `state` uses one `key=value` field per line; a credential-pattern line beginning with `!` is an exclusion whose marker is removed before `grep -E`; output truncation keeps the first `N` lines and adds a deterministic note. Preserve the user's existing change to `docs/superpowers/specs/2026-09-26-clux-companion-terminal-design.md`; this plan never modifies the spec.

## Task 1: Add the CLI boundary and credential-line classifier

**Goal:** Create the executable entry point, shipped pattern file, outside-tmux guard, and hidden `check-line` test seam without touching tmux for classification.

**Files touched:**
- Create: `plugins/clux/scripts/terminal.sh`
- Create: `plugins/clux/config/credential-patterns.txt`
- Create: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): create `test/terminal.bats` with the classifier matrix, custom-pattern filtering, and the tmux precondition.

```bash
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
        'run --timeout' 'run --max-lines' 'read --lines'; do  # missing option values [inferred]
        run env TMUX=fake TMUX_PANE=%0 bash -c "'$TERMINAL' $args"
        [ "$status" -eq 2 ] || { echo "$args returned $status"; false; }
    done
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats`; expect `FAIL` because `terminal.sh` and the pattern file do not exist.
- [ ] Step 3 (minimal implementation): add the pattern file and this initial dispatcher. Exclusion lines use the inferred leading `!` syntax. The yes/no exclusions stay only in the pattern file, so there is one copy of each rule and the user can change them. [inferred]

```text
# Include patterns. Each active line is an extended regular expression.
passw(or)?d
pass ?phrase
passcode
\bpin\b
\botp\b
one-time
verification code
2fa
mfa
\btoken\b
secret
private key
enter .*key
sudo\]
authenticat(e|ion)[^a-z]*$
security code
api key
access key
credential
yubikey
touch id
enter .*code

# Exclusions. A leading ! marks an exclusion and is not part of the regex.
!\[y/N\]:?$
!\[Y/n\]:?$
!\[y/n\]$
!\(y/n\)\??$
!\(yes/no\)\??$
```

```bash
#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIPPED_PATTERNS="$SCRIPT_DIR/../config/credential-patterns.txt"

usage() {
    printf '%s\n' 'usage: terminal.sh open|run|send|read|wait|close|list|check-line' >&2
    exit 2
}

fail() {
    printf '%s\n' "$1" >&2
    exit "${2:-2}"
}

require_tmux() {
    [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] \
        || fail 'clux terminal must run inside tmux' 2
}

_pattern_file_matches() {
    local line="$1" file="$2" kind="$3" raw clean pattern
    [ -r "$file" ] || return 1
    while IFS= read -r raw || [ -n "$raw" ]; do
        clean=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//')
        case "$clean" in
            ''|'#'*) continue ;;
        esac
        case "$kind:$clean" in
            exclude:'!'*) pattern="${clean#\!}" ;;
            include:'!'*) continue ;;
            include:*) pattern="$clean" ;;
            *) continue ;;
        esac
        printf '%s\n' "$line" | grep -E -i -q -- "$pattern" && return 0
    done < "$file"
    return 1
}

line_is_credential() {
    local line="$1" override="${2:-}" trimmed user_patterns
    trimmed=$(printf '%s' "$line" | sed 's/[[:space:]]*$//')
    case "$trimmed" in
        *:|*\?|*\]) ;;
        *) return 1 ;;
    esac
    if [ -n "$override" ]; then
        _pattern_file_matches "$trimmed" "$override" exclude && return 1
        _pattern_file_matches "$trimmed" "$override" include
        return $?
    fi

    _pattern_file_matches "$trimmed" "$SHIPPED_PATTERNS" exclude && return 1
    user_patterns=$(tmux show-option -gqv '@clux-terminal-patterns' 2>/dev/null || true)
    [ -n "$user_patterns" ] && _pattern_file_matches "$trimmed" "$user_patterns" exclude && return 1
    _pattern_file_matches "$trimmed" "$SHIPPED_PATTERNS" include && return 0
    [ -n "$user_patterns" ] && _pattern_file_matches "$trimmed" "$user_patterns" include && return 0
    return 1
}

check_line_command() {
    local patterns="" line=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --patterns) [ "$#" -ge 2 ] || usage; patterns="$2"; shift 2 ;;
            --) shift; line="$*"; break ;;
            *) usage ;;
        esac
    done
    [ -n "$patterns" ] || patterns="$SHIPPED_PATTERNS"
    line_is_credential "$line" "$patterns"
}

main() {
    [ "$#" -gt 0 ] || usage
    case "$1" in
        check-line) shift; check_line_command "$@"; return $? ;;
        close)
            if [ "${2:-}" = '--hook' ]; then
                cat >/dev/null
                return 0
            fi
            ;;
    esac
    require_tmux
    usage
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
```

Run `chmod +x plugins/clux/scripts/terminal.sh`.

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats`; expect every current test to report `PASS`.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh plugins/clux/config/credential-patterns.txt test/terminal.bats && git commit -m "feat(terminal): add credential prompt classifier"`.

From this commit until Task 13, `bats test/` also reports two known failures. [inferred] `test/deploy-manifest.bats` "every runtime script on disk is listed" fails because `terminal.sh` is not in the manifest and not in the non-deployed list. [inferred] `test/docs-tree.bats` "every script and hook on disk appears in the tree" fails because the CONTRIBUTING tree has no `terminal.sh` line. [inferred] Task 13 closes both. [inferred] For this reason each task below verifies only the terminal test files. [inferred]

**Verification:** Run `bash -n plugins/clux/scripts/terminal.sh` and expect no output; run `plugins/clux/scripts/terminal.sh check-line -- 'Password:'` and expect exit 0; run it with `-- 'token: null'` and expect exit 1.

## Task 2: Add owner identity, state access, listing, and reaping

**Goal:** Key each companion by tmux server plus owner pane and safely classify live, gone, and foreign directories.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): append unit coverage that sources the script, gives the stub a real server key/listing, and proves the three-field directory name is split correctly.

```bash
_write_identity_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    display-message) printf '%s\n' '1234-1700000000' ;;
    list-panes) printf '%s\n' '1234-1700000000 %0' '1234-1700000000 %8' ;;
esac
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "reaper splits server key from owner pane before validation" {
    _write_identity_tmux_stub
    local root="$BATS_TEST_TMPDIR/terminal"
    mkdir -p "$root/1234-1700000000-0" "$root/1234-1700000000-9"
    printf 'mode=split\npane=%%8\nseq=0\n' > "$root/1234-1700000000-0/state"
    printf 'mode=split\npane=%%9\nseq=0\n' > "$root/1234-1700000000-9/state"

    run env CLUX_TERMINAL_DIR="$root" TMUX=fake TMUX_PANE=%0 \
        STUB_LOG="$BATS_TEST_TMPDIR/stub.log" \
        bash -c "source '$TERMINAL'; terminal_init; reap_companions"
    [ "$status" -eq 0 ]
    [ -d "$root/1234-1700000000-0" ]
    [ ! -e "$root/1234-1700000000-9" ]
    grep -qF 'kill-pane -t %9' "$BATS_TEST_TMPDIR/stub.log"     # [inferred]
    ! grep -qF 'kill-pane -t %8' "$BATS_TEST_TMPDIR/stub.log"   # [inferred]
}

@test "list reports the current owner alive and a live foreign server foreign" {
    _write_identity_tmux_stub
    local root="$BATS_TEST_TMPDIR/terminal"
    mkdir -p "$root/1234-1700000000-0"
    printf 'mode=split\npane=%%8\nseq=0\n' > "$root/1234-1700000000-0/state"
    mkdir -p "$root/2222-1700000001-4"
    printf 'mode=split\npane=%%4\nseq=0\n' > "$root/2222-1700000001-4/state"
    kill() { return 0; }
    export -f kill

    run env CLUX_TERMINAL_DIR="$root" TMUX=fake TMUX_PANE=%0 \
        bash -c "source '$TERMINAL'; kill() { return 0; }; list_command"
    [ "$status" -eq 0 ]
    [[ "$output" == *'owner=1234-1700000000-0 mode=split pane=%8 state=alive'* ]]
    [[ "$output" == *'owner=2222-1700000001-4 mode=split pane=%4 state=foreign'* ]]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats`; expect failures for undefined `terminal_init`, `reap_companions`, and `list_command`.
- [ ] Step 3 (minimal implementation): source `path.sh`, then add state helpers and the reaper before `main`; route `list` to `list_command`.

```bash
source "$SCRIPT_DIR/path.sh"

terminal_init() {
    ROOT="${CLUX_TERMINAL_DIR:-${TMPDIR:-/tmp}/clux-terminal-$(id -u)}"
    SERVER_KEY=$(resolve_agent_server_key)
    _clux_valid_server_key "$SERVER_KEY" || fail 'cannot identify the tmux server' 2
    OWNER_PANE="${TMUX_PANE#%}"
    case "$OWNER_PANE" in ''|*[!0-9]*) fail 'invalid owner pane' 2 ;; esac
    OWNER_KEY="$SERVER_KEY-$OWNER_PANE"
    D="$ROOT/$OWNER_KEY"
}

state_get_from() {
    local dir="$1" key="$2"
    sed -n "s/^${key}=//p" "$dir/state" 2>/dev/null | head -n 1
}

state_get() {
    state_get_from "$D" "$1"
}

listing_has_pane() {
    local listing="$1" pane="$2"
    case $'\n'"$listing"$'\n' in *$'\n'*" $pane"$'\n'*) return 0 ;; esac
    return 1
}

remove_companion_dir() {
    local dir="$1" kill_split="${2:-0}" mode pane socket
    mode=$(state_get_from "$dir" mode)
    pane=$(state_get_from "$dir" pane)
    socket=$(state_get_from "$dir" socket)
    if [ "$mode" = socket ] && [ -n "$socket" ]; then
        tmux -S "$socket" kill-server >/dev/null 2>&1 || true
    elif [ "$kill_split" -eq 1 ] && [ -n "$pane" ]; then
        tmux kill-pane -t "$pane" >/dev/null 2>&1 || true
    fi
    rm -rf "$dir"
}

reap_companions() {
    local listing base dir server owner pid
    listing=$(tmux list-panes -a -F '#{pid}-#{start_time} #{pane_id}' 2>/dev/null)
    [ -n "$listing" ] || return 0
    for dir in "$ROOT"/*; do
        [ -d "$dir" ] || continue
        base="${dir##*/}"
        server="${base%-*}"
        owner="${base##*-}"
        _clux_valid_server_key "$server" || continue
        case "$owner" in ''|*[!0-9]*) continue ;; esac
        if [ "$server" = "$SERVER_KEY" ]; then
            listing_has_pane "$listing" "%$owner" || remove_companion_dir "$dir" 1
            continue
        fi
        pid="${server%%-*}"
        kill -0 "$pid" 2>/dev/null && continue
        remove_companion_dir "$dir" 0
    done
}

companion_state() {
    local dir="$1" listing="$2" base server pane mode socket pid
    base="${dir##*/}"
    server="${base%-*}"
    pane=$(state_get_from "$dir" pane)
    mode=$(state_get_from "$dir" mode)
    socket=$(state_get_from "$dir" socket)
    if [ "$server" = "$SERVER_KEY" ]; then
        if [ "$mode" = socket ]; then
            tmux -S "$socket" list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q -x -F "$pane" && printf alive || printf gone
        else
            listing_has_pane "$listing" "$pane" && printf alive || printf gone
        fi
        return
    fi
    pid="${server%%-*}"
    kill -0 "$pid" 2>/dev/null && printf foreign || printf gone
}

list_command() {
    local listing dir base mode pane state
    terminal_init
    listing=$(tmux list-panes -a -F '#{pid}-#{start_time} #{pane_id}' 2>/dev/null)
    for dir in "$ROOT"/*; do
        [ -f "$dir/state" ] || continue
        base="${dir##*/}"
        mode=$(state_get_from "$dir" mode)
        pane=$(state_get_from "$dir" pane)
        state=$(companion_state "$dir" "$listing")
        printf 'owner=%s mode=%s pane=%s state=%s\n' "$base" "$mode" "$pane" "$state"
    done
}
```

Replace the guarded dispatch tail with:

```bash
    require_tmux
    case "$1" in
        list) list_command ;;
        *) usage ;;
    esac
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats`; expect every current test to report `PASS`.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh test/terminal.bats && git commit -m "feat(terminal): add owner-scoped state reaper"`.

**Verification:** Run `bats test/terminal.bats -f 'reaper|list reports'`; expect two passing tests. The reaper test sets `STUB_LOG` and asserts that the stub log holds `kill-pane -t %9` but no `kill-pane -t %8`. [inferred]

## Task 3: Open and reuse a split companion

**Goal:** Start a known interactive Bash below the Claude pane, wait for its prompt, and reuse it while it remains alive.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Create: `test/terminal-e2e.bats`
- Modify: `test/terminal.bats`   [inferred]

**Steps:**
- [ ] Step 1 (failing test): create the real-server Bats harness and the first split-pane case.

```bash
#!/usr/bin/env bats

load test_helper

REAL_TMUX="$(command -v tmux)"
TERMINAL="$SCRIPTS_DIR/terminal.sh"

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    # A short root keeps "$D/sock" under the 100-byte tmux socket limit. [inferred]
    CLUX_TERMINAL_DIR=$(mktemp -d /tmp/ct.XXXX)
    export CLUX_TERMINAL_DIR
    export TMUX_SOCKET="$BATS_TEST_TMPDIR/owner.sock"
    mkdir -p "$HOME"
    # 3>&- removes one copy of the TAP stream of Bats from the new tmux server, but it does not remove them all, so teardown() must stop every server a test starts. [inferred]
    "$REAL_TMUX" -S "$TMUX_SOCKET" -f /dev/null new-session -d -s owner -x 120 -y 40 3>&-
    local pid
    pid=$("$REAL_TMUX" -S "$TMUX_SOCKET" display-message -p '#{pid}')
    export TMUX="$TMUX_SOCKET,$pid,0"
    export TMUX_PANE
    TMUX_PANE=$("$REAL_TMUX" -S "$TMUX_SOCKET" list-panes -t owner:0 -F '#{pane_id}')
    export PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin"
}

teardown() {
    local socket
    for socket in "$CLUX_TERMINAL_DIR"/*/sock; do
        [ -S "$socket" ] || continue
        "$REAL_TMUX" -S "$socket" kill-server >/dev/null 2>&1 || true
    done
    "$REAL_TMUX" -S "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$BATS_TEST_TMPDIR" "$CLUX_TERMINAL_DIR"   # [inferred] remove the short root
}

_field() {
    printf '%s\n' "$output" | sed -n "s/^$1=//p" | head -n 1
}

@test "open creates a titled split and a second open reuses it" {
    run "$TERMINAL" open --size 25%
    [ "$status" -eq 0 ]
    [ "$(_field mode)" = split ]
    local pane="$(_field pane)"
    [ -n "$pane" ]
    "$REAL_TMUX" -S "$TMUX_SOCKET" list-panes -a -F '#{pane_id} #{pane_title}' \
        | grep -q -F "$pane clux-terminal"

    run "$TERMINAL" open
    [ "$status" -eq 0 ]
    [ "$(_field pane)" = "$pane" ]

    local owner="${TMUX_PANE#%}" server
    server=$("$REAL_TMUX" -S "$TMUX_SOCKET" display-message -p '#{pid}-#{start_time}')
    [ -f "$CLUX_TERMINAL_DIR/$server-$owner/state" ]
    [ -f "$CLUX_TERMINAL_DIR/$server-$owner/rc.bash" ]
}
```

Append this unit test to `test/terminal.bats`; it holds `wait_for_prompt` to its own limit argument, which a single `local` line cannot do: [inferred]

```bash
@test "wait_for_prompt honors its limit argument with no caller limit" {
    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *cursor_y*)    printf '%s\n' '0' ;;
    *start_time*)  printf '%s\n' '1234-1700000000' ;;
esac
[ "$1" != capture-pane ] || printf '%s\n' 'no prompt here'
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    local root="$BATS_TEST_TMPDIR/terminal"
    mkdir -p "$root/1234-1700000000-0"
    printf 'mode=split\npane=%%8\nseq=0\n' > "$root/1234-1700000000-0/state"

    local start=$SECONDS
    run env PATH="$BATS_TEST_TMPDIR/stubs:$PATH" \
        CLUX_TERMINAL_DIR="$root" TMUX=fake TMUX_PANE=%0 \
        bash -c "source '$TERMINAL'; terminal_init; wait_for_prompt 1"
    local spent=$((SECONDS - start))
    [ "$status" -eq 1 ]
    [ "$spent" -ge 1 ]
    [ "$spent" -le 3 ]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal-e2e.bats`; expect `FAIL` because `open` is not dispatched.
- [ ] Step 3 (minimal implementation): add the rc-file writer and split-open helpers, then dispatch `open`.

```bash
write_rc_file() {
    cat > "$D/rc.bash" <<'EOF'
unset HISTFILE
set +o history
PS1='clux$ '
PROMPT_COMMAND=

exit() { printf '%s\n' 'refused: this word closes the companion'; return 1; }
exec() { printf '%s\n' 'refused: this word closes the companion'; return 1; }
logout() { printf '%s\n' 'refused: this word closes the companion'; return 1; }
__clux_clear() { printf '\033[2J\033[H'; }
EOF
}

write_state() {
    local mode="$1" pane="$2" socket="${3:-}"
    {
        printf 'mode=%s\n' "$mode"
        printf 'pane=%s\n' "$pane"
        printf 'socket=%s\n' "$socket"
        printf 'seq=0\n'
    } > "$D/state"
}

tmux_state() {
    local mode socket
    mode=$(state_get mode)
    socket=$(state_get socket)
    if [ "$mode" = socket ]; then
        tmux -S "$socket" "$@"
    else
        tmux "$@"
    fi
}

capture_cursor_line() {
    local pane cy
    pane=$(state_get pane)
    cy=$(tmux_state display-message -p -t "$pane" '#{cursor_y}' 2>/dev/null) || return 1
    tmux_state capture-pane -p -J -t "$pane" -S 0 -E "$cy" 2>/dev/null | tail -n 1
}

at_prompt() {
    local line trimmed
    line=$(capture_cursor_line) || return 1
    trimmed=$(printf '%s' "$line" | sed 's/[[:space:]]*$//')
    case "$trimmed" in *'clux$') return 0 ;; esac
    return 1
}

wait_for_prompt() {
    local limit="$1" deadline   # [inferred] bash expands every word of a local line before it assigns
    deadline=$((SECONDS + limit))   # [inferred] so the deadline needs its own line
    while [ "$SECONDS" -lt "$deadline" ]; do
        at_prompt && return 0
        sleep 0.2
    done
    return 1
}

check_tmux_version() {
    local version major minor
    version=$(tmux -V 2>/dev/null) || fail 'tmux is required' 2
    version=$(printf '%s\n' "$version" | sed 's/^tmux //; s/[^0-9.].*$//')
    major=${version%%.*}
    minor=${version#*.}; minor=${minor%%.*}
    case "$major:$minor" in *[!0-9:]*|:) fail 'cannot read the tmux version' 2 ;; esac
    [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 2 ]; } \
        || fail 'clux terminal needs tmux 3.2 or newer' 2
}

current_companion_alive() {
    local pane listing
    [ -f "$D/state" ] || return 1
    pane=$(state_get pane)
    listing=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)
    printf '%s\n' "$listing" | grep -q -x -F "$pane"
}

print_open_result() {
    printf 'pane=%s\n' "$(state_get pane)"
    printf 'mode=%s\n' "$(state_get mode)"
}

open_command() {
    local size='30%' shell_command pane bash_path
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --size) [ "$#" -ge 2 ] || usage; size="$2"; shift 2 ;;
            --socket) fail 'socket mode is not available yet' 2 ;;
            *) usage ;;
        esac
    done
    printf '%s\n' "$size" | grep -E -q '^([1-9]|[1-9][0-9]|100)%$' || fail 'size must be N%' 2
    terminal_init
    check_tmux_version
    mkdir -p "$ROOT"
    chmod 700 "$ROOT"
    reap_companions
    if current_companion_alive; then
        print_open_result
        return 0
    fi
    [ ! -e "$D" ] || remove_companion_dir "$D" 1
    umask 077
    mkdir -p "$D"
    write_rc_file
    bash_path=$(command -v bash) || fail 'bash is required' 2
    printf -v shell_command '%q --noprofile --rcfile %q -i' "$bash_path" "$D/rc.bash"
    pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" -v -l "$size" \
        -e "PATH=$PATH" -e "CLUX_TERMINAL_D=$D" "$shell_command" 3>&-) \
        || { rm -rf "$D"; fail 'cannot open the companion pane' 1; }
    write_state split "$pane"
    tmux select-pane -t "$pane" -T clux-terminal >/dev/null 2>&1 || true
    if ! wait_for_prompt 5; then
        tmux kill-pane -t "$pane" >/dev/null 2>&1 || true
        rm -rf "$D"
        fail 'the companion shell did not reach its prompt' 1
    fi
    print_open_result
}
```

`3>&-` on every tmux launch removes descriptor 3, which is the descriptor Bats writes its TAP stream on. [inferred] It is not sufficient on its own: Bats 1.13 runs each test body with the same pipe open on more descriptors, so a tmux server that outlives its test still makes `bats test/` hang after the last test with no message instead of reporting a failure. [inferred] The rule that keeps the run correct is this: every test must stop every tmux server it starts, and `teardown()` must be able to reach that server, so that a failed assertion cannot leave a server alive. [inferred] Put every test socket below `$CLUX_TERMINAL_DIR`, which is the root that `teardown()` scans. [inferred]

Add `open) shift; open_command "$@" ;;` to the post-`require_tmux` dispatch.

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats test/terminal-e2e.bats`; expect the split/reuse test and the `wait_for_prompt` limit test to report `PASS`. [inferred]
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh test/terminal.bats test/terminal-e2e.bats && git commit -m "feat(terminal): open a persistent split companion"`.

**Verification:** Run `bats test/terminal-e2e.bats -f 'open creates'`; expect one passing test. Run `bats test/terminal.bats -f 'wait_for_prompt honors'`; expect one passing test that ends in about one second. [inferred] Run `bash -n plugins/clux/scripts/terminal.sh` and expect no output.

## Task 4: Add socket mode and stale-pane recovery

**Goal:** Open isolated private servers, enforce the socket path limit, print an attach command, and replace a companion whose target pane disappeared.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `test/terminal-e2e.bats`
- Modify: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): add real-server coverage for socket mode and split recovery, plus a stubbed old-version refusal.

```bash
@test "socket mode uses a private server and prints its attach command" {
    run "$TERMINAL" open --socket
    [ "$status" -eq 0 ]
    [ "$(_field mode)" = socket ]
    local pane="$(_field pane)" attach="$(_field attach)"
    [[ "$attach" == tmux\ -S\ *\ attach ]]
    local socket
    socket=$(printf '%s\n' "$attach" | sed 's/^tmux -S //; s/ attach$//')
    "$REAL_TMUX" -S "$socket" list-panes -a -F '#{pane_id} #{pane_title}' \
        | grep -q -F "$pane clux-terminal"
}

@test "open replaces a split companion whose pane is gone" {
    run "$TERMINAL" open
    [ "$status" -eq 0 ]
    local first="$(_field pane)"
    "$REAL_TMUX" -S "$TMUX_SOCKET" kill-pane -t "$first"

    run "$TERMINAL" open
    [ "$status" -eq 0 ]
    local second="$(_field pane)"
    [ -n "$second" ]
    [ "$second" != "$first" ]
}
```

```bash
@test "open refuses tmux older than 3.2" {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    -V) printf '%s\n' 'tmux 3.1c' ;;
    display-message) printf '%s\n' '1234-1700000000' ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    run env TMUX=fake TMUX_PANE=%0 CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/ct" "$TERMINAL" open
    [ "$status" -eq 2 ]
    [[ "$output" == *'3.2 or newer'* ]]
}
```

Append this unit test to `test/terminal.bats`; it holds the prompt-failure path to the mode-aware helper, so a socket-mode failure cannot kill the user's own pane or orphan the private server: [inferred]

```bash
@test "the prompt-failure path stops a private server instead of a user pane" {
    grep -A1 -F 'if ! wait_for_prompt 5; then' "$TERMINAL" \
        | grep -qF 'remove_companion_dir "$D" 1'
    ! grep -A1 -F 'if ! wait_for_prompt 5; then' "$TERMINAL" \
        | grep -qF 'kill-pane'

    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
[ "$1" != display-message ] || printf '%s\n' '1234-1700000000'
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    local root="$BATS_TEST_TMPDIR/terminal" dir
    dir="$root/1234-1700000000-0"
    mkdir -p "$dir"
    printf 'mode=socket\npane=%%0\nsocket=%s/sock\nseq=0\n' "$dir" > "$dir/state"

    run env PATH="$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin" \
        CLUX_TERMINAL_DIR="$root" TMUX=fake TMUX_PANE=%0 \
        STUB_LOG="$BATS_TEST_TMPDIR/stub.log" \
        bash -c "source '$TERMINAL'; terminal_init; remove_companion_dir '$dir' 1"
    [ "$status" -eq 0 ]
    [ ! -e "$dir" ]
    grep -qF "kill-server" "$BATS_TEST_TMPDIR/stub.log"
    ! grep -qF "kill-pane" "$BATS_TEST_TMPDIR/stub.log"
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats test/terminal-e2e.bats`; expect the socket-mode test and the prompt-failure-path test to fail. [inferred] The stale-recovery test and the old-version test already pass with the Task 3 code, because `open_command` reaps, finds the killed pane gone, and splits again, and `check_tmux_version` exists. [inferred]
- [ ] Step 3 (minimal implementation): make liveness mode-aware, accept `--socket`, and add the private-server branch.

```bash
current_companion_alive() {
    local mode pane socket
    [ -f "$D/state" ] || return 1
    mode=$(state_get mode)
    pane=$(state_get pane)
    socket=$(state_get socket)
    if [ "$mode" = socket ]; then
        tmux -S "$socket" list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q -x -F "$pane"
    else
        tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q -x -F "$pane"
    fi
}
```

In `open_command`, parse mode and reject `--size` with socket mode:

```bash
    local mode=split size='30%' size_set=0 socket shell_command pane bash_path
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --socket) mode=socket; shift ;;
            --size) [ "$#" -ge 2 ] || usage; size="$2"; size_set=1; shift 2 ;;
            *) usage ;;
        esac
    done
    [ "$mode" != socket ] || [ "$size_set" -eq 0 ] || fail '--size applies only to split mode' 2
```

Replace the split-only creation with:

```bash
    if [ "$mode" = socket ]; then
        socket="$D/sock"
        [ "${#socket}" -le 100 ] || { rm -rf "$D"; fail 'the private tmux socket path is longer than 100 bytes' 2; }
        pane=$(tmux -S "$socket" -f /dev/null new-session -d -P -F '#{pane_id}' \
            -s clux-terminal -e "PATH=$PATH" -e "CLUX_TERMINAL_D=$D" "$shell_command" 3>&-) \
            || { rm -rf "$D"; fail 'cannot open the private companion server' 1; }
        write_state socket "$pane" "$socket"
        tmux -S "$socket" select-pane -t "$pane" -T clux-terminal >/dev/null 2>&1 || true
    else
        pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" -v -l "$size" \
            -e "PATH=$PATH" -e "CLUX_TERMINAL_D=$D" "$shell_command" 3>&-) \
            || { rm -rf "$D"; fail 'cannot open the companion pane' 1; }
        write_state split "$pane"
        tmux select-pane -t "$pane" -T clux-terminal >/dev/null 2>&1 || true
    fi
```

Replace the prompt-failure path, because a plain `tmux kill-pane` in socket mode goes to the user's server and kills the user's pane with the same id, and `rm -rf "$D"` then deletes the private socket and leaves the private server with no way to stop it: [inferred]

```bash
    if ! wait_for_prompt 5; then
        remove_companion_dir "$D" 1
        fail 'the companion shell did not reach its prompt' 1
    fi
```

`remove_companion_dir` already picks `tmux -S "$socket" kill-server` for socket mode and `tmux kill-pane` for split mode, and `write_state` runs before this point, so the state file holds the mode. [inferred]

Extend `print_open_result`:

```bash
print_open_result() {
    local mode socket
    mode=$(state_get mode)
    printf 'pane=%s\n' "$(state_get pane)"
    printf 'mode=%s\n' "$mode"
    if [ "$mode" = socket ]; then
        socket=$(state_get socket)
        printf 'attach=tmux -S %s attach\n' "$socket"
    fi
}
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats test/terminal-e2e.bats`; expect all current unit and end-to-end tests to report `PASS`.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh test/terminal.bats test/terminal-e2e.bats && git commit -m "feat(terminal): support private socket companions"`.

**Verification:** Run `bats test/terminal-e2e.bats -f 'socket mode|replaces'`; expect two passing tests and no surviving private tmux server after Bats teardown. Confirm the surviving-server claim with `pgrep -fl 'tmux -S /tmp/ct\.'`; expect empty output. [inferred] Run `bats test/terminal.bats -f 'prompt-failure path'`; expect one passing test. [inferred] Do not set `CLUX_TERMINAL_DIR` in the environment, because `setup()` builds its own short root. [inferred]

## Task 5: Run plain commands with complete file-backed results

**Goal:** Execute plain commands in the pane shell, preserve shell state, return complete output plus exit status, and protect wrapper state from user variables.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `test/terminal.bats`
- Modify: `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): add the wrapper-shape assertion and end-to-end cases for output, exit status, state persistence, modes, large output, protected words, variable collisions, prompts after unterminated output, an abandoned run lock, and a pane shell that ends during a run. [inferred]

```bash
@test "run wrapper puts umask 077 inside the tee process substitution" {
    grep -qF '> >(umask 077; tee "$__clux_d/$__clux_n.out"; : > "$__clux_d/$__clux_n.done") 2>&1' "$TERMINAL"
    run grep -qE '^umask 077$' "$TERMINAL"
    [ "$status" -ne 0 ]
}
```

```bash
_open() {
    "$TERMINAL" open >/dev/null
}

_owner_dir() {
    local server owner
    server=$("$REAL_TMUX" -S "$TMUX_SOCKET" display-message -p '#{pid}-#{start_time}')
    owner="${TMUX_PANE#%}"
    printf '%s/%s-%s\n' "$CLUX_TERMINAL_DIR" "$server" "$owner"
}

_mode() {
    if stat -f %Lp "$1" >/dev/null 2>&1; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

@test "run returns output and the command exit code without returning that code" {
    _open
    run "$TERMINAL" run -- 'echo hi'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'run=1' ]
    [[ "$output" == *$'\nhi\nexit=0'* ]]

    run "$TERMINAL" run -- 'false'
    [ "$status" -eq 0 ]
    [[ "$output" == *'exit=1'* ]]
    [ ! -e "$(_owner_dir)/2.out" ]
}

@test "run uses the same result protocol in socket mode" {
    run "$TERMINAL" open --socket
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'echo socket-ok'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'socket-ok\nexit=0'* ]]
}

@test "run preserves cwd and exported variables" {
    _open
    run "$TERMINAL" run -- 'cd /tmp'
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'pwd'
    [[ "$output" == *$'\n/tmp\nexit=0'* ]]

    run "$TERMINAL" run -- 'export X=1'
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'echo $X'
    [[ "$output" == *$'\n1\nexit=0'* ]]
}

@test "run isolates wrapper variables and refuses shell-closing first words" {
    _open
    run "$TERMINAL" run -- 'for n in 7 8; do echo $n; done'
    [[ "$output" == *$'\n7\n8\nexit=0'* ]]
    run "$TERMINAL" run -- 'D=oops; echo hi'
    [[ "$output" == *$'\nhi\nexit=0'* ]]

    for word in exit exec logout return; do
        run "$TERMINAL" run -- "$word"
        [ "$status" -eq 2 ]
    done
    run "$TERMINAL" run -- 'echo a; exit'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\na\nrefused: this word closes the companion\nexit=1'* ]]
    run "$TERMINAL" run -- 'echo still-alive'
    [[ "$output" == *'still-alive'* ]]
}

@test "run leaves the pane prompt usable after large and unterminated output" {
    _open
    run "$TERMINAL" run --max-lines 3 -- 'seq 1 30000'
    [ "$status" -eq 0 ]
    [[ "$output" == *'output truncated after 3 lines'* ]]
    run "$TERMINAL" run -- 'printf hi'
    [[ "$output" == *$'\nhiexit=0'* || "$output" == *$'\nhi\nexit=0'* ]]
    run "$TERMINAL" run -- 'echo after'
    [[ "$output" == *'after'* ]]
}

@test "an abandoned run does not lock the companion" {
    _open
    # `return 1` leaves the wrapper before it writes 1.rc, so this call can only end at its
    # limit. --timeout 2 keeps the wait at 2 seconds instead of the 100-second default. [inferred]
    run "$TERMINAL" run --timeout 2 -- 'true && return 1'
    [ "$status" -eq 1 ]
    run "$TERMINAL" run -- 'echo ok'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'ok\nexit=0'* ]]
}

@test "run stops when the companion shell ends" {
    _open
    run "$TERMINAL" run --timeout 20 -- 'set -e; false'
    [ "$status" -eq 4 ]
    [[ "$output" == *'closed during the run'* ]]
}

@test "only the private directory and captured output force private modes" {
    _open
    local made="$BATS_TEST_TMPDIR/user-file"
    run "$TERMINAL" run -- "umask 022; touch '$made'; echo kept"
    [ "$status" -eq 0 ]
    [ "$(_mode "$(_owner_dir)")" = 700 ]
    [ "$(_mode "$(_owner_dir)/1.cmd")" = 600 ]
    [ "$(_mode "$made")" = 644 ]
    [ ! -e "$(_owner_dir)/1.out" ]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats test/terminal-e2e.bats`; expect failures because `__clux_run` and the `run` verb do not exist.
- [ ] Step 3 (minimal implementation): extend `write_rc_file` with the exact wrapper, then add result formatting and `run` dispatch.

```bash
__clux_run() {
  local __clux_n="$1" __clux_d="$CLUX_TERMINAL_D" __clux_cmd __clux_rc __clux_i
  __clux_cmd=$(cat "$__clux_d/$__clux_n.cmd")
  printf '$ %s\n' "$__clux_cmd"
  { eval "$__clux_cmd"; } > >(umask 077; tee "$__clux_d/$__clux_n.out"; : > "$__clux_d/$__clux_n.done") 2>&1
  __clux_rc=$?
  __clux_i=0
  while [ ! -e "$__clux_d/$__clux_n.done" ] && [ "$__clux_i" -lt 20 ]; do
    sleep 0.05
    __clux_i=$((__clux_i + 1))
  done
  printf '%s\n' "$__clux_rc" > "$__clux_d/$__clux_n.rc.tmp" && mv "$__clux_d/$__clux_n.rc.tmp" "$__clux_d/$__clux_n.rc"
}
```

Add these script functions:

```bash
ensure_open() {
    terminal_init
    current_companion_alive || fail 'no companion is open for this owner' 4
}

write_seq() {
    local value="$1" tmp="$D/state.tmp"
    sed "s/^seq=.*/seq=$value/" "$D/state" > "$tmp" && mv "$tmp" "$D/state"
}

send_literal() {
    tmux_state send-keys -t "$(state_get pane)" -l -- "$1"
}

send_key() {
    tmux_state send-keys -t "$(state_get pane)" "$1"
}

print_run_result() {
    local n="$1" max_lines="$2" incomplete="${3:-0}" count rc
    rc=$(cat "$D/$n.rc")
    if [ ! -e "$D/$n.secret" ] && [ -f "$D/$n.out" ]; then
        count=$(wc -l < "$D/$n.out" | tr -d ' ')
        sed -n "1,${max_lines}p" "$D/$n.out"
        [ "$count" -le "$max_lines" ] || printf 'output truncated after %s lines\n' "$max_lines"
        [ "$incomplete" -eq 0 ] || printf '%s\n' 'output may be incomplete: a process still holds the output'
    fi
    printf 'exit=%s\n' "$rc"
    rm -f "$D/$n.out"
    rmdir "$D/busy" 2>/dev/null || true
}

wait_for_run_files() {
    local n="$1" limit="$2" grace polls=0 deadline   # [inferred]
    deadline=$((SECONDS + limit))   # [inferred] a separate line reads the $2 of this call
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$D/$n.rc" ]; then
            [ -e "$D/$n.done" ] && return 0
            grace=$((SECONDS + 1))
            while [ "$SECONDS" -lt "$grace" ]; do
                [ -e "$D/$n.done" ] && return 0
                sleep 0.2
            done
            return 6
        fi
        # The pane shell can end, for example on `set -e; false`. Stop early. [inferred]
        polls=$((polls + 1))
        [ $((polls % 5)) -ne 0 ] || current_companion_alive || return 4
        sleep 0.2
    done
    return 1
}

run_command() {
    local limit=100 max_lines=200 secret=0 command first n wait_status out base
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) [ "$#" -ge 2 ] || usage; limit="$2"; shift 2 ;;      # [inferred] guard
            --max-lines) [ "$#" -ge 2 ] || usage; max_lines="$2"; shift 2 ;;  # [inferred] guard
            --secret) secret=1; shift ;;
            --) shift; command="$*"; break ;;
            *) usage ;;
        esac
    done
    [ -n "${command:-}" ] || usage
    case "$limit:$max_lines" in *[!0-9:]*) usage ;; esac
    first=$(printf '%s\n' "$command" | awk '{print $1}')
    case "$first" in exit|exec|logout|return) fail "refused command first word: $first" 2 ;; esac
    ensure_open
    if ! mkdir "$D/busy" 2>/dev/null; then
        n=$(state_get seq)
        # A missing <n>.rc with an idle pane means run n was abandoned, for example
        # by `return` inside the command. Treat that lock as stale. [inferred]
        [ -f "$D/$n.rc" ] || at_prompt || fail 'the companion is busy' 5
        [ -f "$D/$n.rc" ] || rm -f "$D/$n.done" "$D/$n.out"   # [inferred]
        rmdir "$D/busy" 2>/dev/null || true
        mkdir "$D/busy" || fail 'the companion is busy' 5
    fi
    if ! at_prompt; then
        rmdir "$D/busy" 2>/dev/null || true
        fail 'the pane is not at the prompt: use wait --idle, send or read' 5
    fi
    for out in "$D"/*.out; do
        [ -f "$out" ] || continue
        base="${out%.out}"
        [ -f "$base.rc" ] && rm -f "$out"
    done
    n=$(( $(state_get seq) + 1 ))
    write_seq "$n"
    umask 077
    printf '%s' "$command" > "$D/$n.cmd"
    [ "$secret" -eq 0 ] || : > "$D/$n.secret"
    printf 'run=%s\n' "$n"
    send_literal "__clux_run $n"
    send_key Enter
    wait_for_run_files "$n" "$limit"
    wait_status=$?
    case "$wait_status" in
        0) print_run_result "$n" "$max_lines" 0; return 0 ;;
        4) fail 'the companion closed during the run' 4 ;;   # [inferred]
        6) print_run_result "$n" "$max_lines" 1; return 0 ;;
        *) return 1 ;;
    esac
}
```

Add `run) shift; run_command "$@" ;;` to the dispatch.

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats test/terminal-e2e.bats`; expect every plain-run case to report `PASS`.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh test/terminal.bats test/terminal-e2e.bats && git commit -m "feat(terminal): add file-backed command runs"`.

**Verification:** Run `bats test/terminal-e2e.bats -f 'run returns|run uses|preserves|isolates|large|private modes|abandoned run|companion shell ends'`; expect eight passing tests, `exit=1` to remain data rather than the tool status, and no `<n>.out` file after a completed run. [inferred] In the abandoned-run case the first call must exit 1 after about 2 seconds, and the second call must print `ok`. [inferred] The ended-shell case must exit 4 well before its 20-second limit. [inferred]

## Task 6: Add run timeouts, locking, and deferred result waits

**Goal:** Keep one run active at a time, return before the Bash tool timeout, and let `wait --run N` collect a later result.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): add cases for timeout recovery and a concurrent run refusal.

```bash
@test "a timed-out run keeps its lock and wait --run collects it" {
    _open
    run "$TERMINAL" run --timeout 1 -- 'sleep 3; echo done'
    [ "$status" -eq 1 ]
    [ "${lines[0]}" = 'run=1' ]
    [ -d "$(_owner_dir)/busy" ]

    run "$TERMINAL" wait --timeout 10 --run 1
    [ "$status" -eq 0 ]
    [[ "$output" == *$'done\nexit=0'* ]]
    [ ! -d "$(_owner_dir)/busy" ]
}

@test "a second run is refused while the first run is incomplete" {
    _open
    run "$TERMINAL" run --timeout 1 -- 'sleep 4'
    [ "$status" -eq 1 ]
    run "$TERMINAL" run -- 'echo wrong'
    [ "$status" -eq 5 ]
    [[ "$output" == *'busy'* ]]
    run "$TERMINAL" wait --timeout 10 --run 1
    [ "$status" -eq 0 ]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal-e2e.bats -f 'timed-out|second run'`; expect `wait` to fail with usage.
- [ ] Step 3 (minimal implementation): add numeric validation, `wait --run`, and its result handoff.

```bash
positive_integer() {
    case "$1" in ''|*[!0-9]*|0) return 1 ;; esac
    return 0
}

wait_run_command() {
    local n="$1" limit="$2" max_lines="$3" wait_status
    ensure_open
    [ "$n" -le "$(state_get seq)" ] || fail "unknown run: $n" 2
    wait_for_run_files "$n" "$limit"
    wait_status=$?
    case "$wait_status" in
        0) print_run_result "$n" "$max_lines" 0; return 0 ;;
        4) fail 'the companion closed during the run' 4 ;;   # [inferred]
        6) print_run_result "$n" "$max_lines" 1; return 0 ;;
        *) return 1 ;;
    esac
}

wait_command() {
    local limit=60 max_lines=200 mode="" value=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) [ "$#" -ge 2 ] || usage; limit="$2"; shift 2 ;;
            --max-lines) [ "$#" -ge 2 ] || usage; max_lines="$2"; shift 2 ;;
            --run) [ "$#" -ge 2 ] || usage; mode=run; value="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [ "$mode" = run ] || usage
    positive_integer "$limit" && positive_integer "$max_lines" && positive_integer "$value" || usage
    wait_run_command "$value" "$limit" "$max_lines"
}
```

Use `positive_integer` for `run --timeout` and `--max-lines`, and add `wait) shift; wait_command "$@" ;;` to dispatch.

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal-e2e.bats -f 'timed-out|second run'`; expect two passing tests.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh test/terminal-e2e.bats && git commit -m "feat(terminal): wait for timed-out command results"`.

**Verification:** Run `bats test/terminal-e2e.bats -f 'timed-out|second run'`; expect `run` status 1 before the command ends, `wait --run 1` status 0 later, and removal of `busy` only after result collection.

## Task 7: Bound output completion when a background process holds the pipe

**Goal:** Return a normal result with a clear incomplete-output note when a child keeps the process-substitution pipe open.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): add the background-process regression.

```bash
@test "a background process cannot hold run open or leave the lock" {
    _open
    local started=$SECONDS
    run "$TERMINAL" run -- 'sleep 5 & echo started'
    local elapsed=$((SECONDS - started))
    [ "$status" -eq 0 ]
    [ "$elapsed" -lt 5 ]
    [[ "$output" == *'started'* ]]
    [[ "$output" == *'output may be incomplete: a process still holds the output'* ]]
    [[ "$output" == *'exit=0'* ]]
    [ ! -d "$(_owner_dir)/busy" ]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal-e2e.bats -f 'background process'`; expect the command to take about five seconds or omit the incomplete-output note. If the Task 5 grace window already returns 6 after about two seconds, the test passes here instead. [inferred] Record that result and treat Step 3 as a confirmation that the grace logic and the return code 6 stay in place. [inferred]
- [ ] Step 3 (minimal implementation): ensure `wait_for_run_files` starts its one-second grace as soon as `<n>.rc` appears, even when the wrapper's own one-second done poll has expired; retain return code 6 as the internal incomplete signal. Compare the function with the Task 5 form; when it is already the same, make no edit. [inferred]

```bash
wait_for_run_files() {
    local n="$1" limit="$2" grace polls=0 deadline   # [inferred]
    deadline=$((SECONDS + limit))   # [inferred] a separate line reads the $2 of this call
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$D/$n.rc" ]; then
            [ -e "$D/$n.done" ] && return 0
            grace=$((SECONDS + 1))
            while [ "$SECONDS" -lt "$grace" ]; do
                [ -e "$D/$n.done" ] && return 0
                sleep 0.2
            done
            return 6
        fi
        # The pane shell can end, for example on `set -e; false`. Stop early. [inferred]
        polls=$((polls + 1))
        [ $((polls % 5)) -ne 0 ] || current_companion_alive || return 4
        sleep 0.2
    done
    return 1
}
```

Keep the `6)` branches in both `run_command` and `wait_run_command` mapped to `print_run_result ... 1` and a public exit status of 0.

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal-e2e.bats -f 'background process'`; expect one passing test in less than five seconds.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh test/terminal-e2e.bats && git commit -m "fix(terminal): bound background output collection"`.

**Verification:** Run `time bats test/terminal-e2e.bats -f 'background process'`; expect `PASS`, the incomplete-output note, `exit=0`, and elapsed test time below the background sleep duration plus Bats setup overhead.

## Task 8: Add interactive send, read, idle, and pattern operations

**Goal:** Drive TTY-requiring commands through literal text or named keys and inspect the visible pane without corrupting a program that is already reading input.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): add a small interactive conversation and a not-at-prompt refusal.

```bash
@test "send, wait pattern, read, and wait idle drive an interactive command" {
    _open
    run "$TERMINAL" send --enter -- 'read -p "Name? " name; echo "hello:$name"'
    [ "$status" -eq 0 ]
    run "$TERMINAL" wait --timeout 5 --pattern 'Name\?'
    [ "$status" -eq 0 ]
    run "$TERMINAL" send --enter -- 'Ada'
    [ "$status" -eq 0 ]
    run "$TERMINAL" wait --timeout 5 --idle
    [ "$status" -eq 0 ]
    run "$TERMINAL" read --lines 20
    [ "$status" -eq 0 ]
    [[ "$output" == *'hello:Ada'* ]]
}

@test "run refuses a typed line and named C-c restores the prompt" {
    _open
    run "$TERMINAL" send -- 'echo not-entered'
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'echo wrong'
    [ "$status" -eq 5 ]
    [[ "$output" == *'not at the prompt'* ]]
    run "$TERMINAL" send --key C-c
    [ "$status" -eq 0 ]
    run "$TERMINAL" wait --timeout 5 --idle
    [ "$status" -eq 0 ]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal-e2e.bats -f 'interactive command|typed line'`; expect `send`, `read`, `--idle`, and `--pattern` to fail with usage.
- [ ] Step 3 (minimal implementation): add screen capture, argument validation, and polling for the two interactive wait modes.

```bash
capture_screen() {
    local lines="$1"
    tmux_state capture-pane -p -J -t "$(state_get pane)" -S "-$lines"
}

send_command() {
    local enter=0 key="" text=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --enter) enter=1; shift ;;
            --key) [ "$#" -ge 2 ] || usage; key="$2"; shift 2 ;;
            --) shift; text="$*"; break ;;
            *) text="$*"; break ;;
        esac
    done
    ensure_open
    if [ -n "$key" ]; then
        [ -z "$text" ] && [ "$enter" -eq 0 ] || usage
        send_key "$key"
        return
    fi
    [ -n "$text" ] || usage
    send_literal "$text"
    [ "$enter" -eq 0 ] || send_key Enter
}

read_command() {
    local lines=50 n
    while [ "$#" -gt 0 ]; do
        case "$1" in --lines) [ "$#" -ge 2 ] || usage; lines="$2"; shift 2 ;; *) usage ;; esac  # [inferred] guard
    done
    positive_integer "$lines" || usage
    ensure_open
    capture_screen "$lines"
    n=$(state_get seq)
    [ "$n" -eq 0 ] || [ ! -f "$D/$n.rc" ] || rmdir "$D/busy" 2>/dev/null || true
}

wait_screen_command() {
    local mode="$1" value="$2" limit="$3" screen deadline   # [inferred]
    deadline=$((SECONDS + limit))   # [inferred] a separate line reads the $3 of this call
    ensure_open
    while [ "$SECONDS" -lt "$deadline" ]; do
        case "$mode" in
            idle) at_prompt && return 0 ;;
            pattern)
                screen=$(capture_screen 50)
                printf '%s\n' "$screen" | grep -E -q -- "$value" && return 0
                ;;
        esac
        sleep 0.2
    done
    return 1
}
```

Replace `wait_command` so exactly one of `--idle`, `--pattern RE`, or `--run N` is accepted:

```bash
wait_command() {
    local limit=60 max_lines=200 mode="" value=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout) [ "$#" -ge 2 ] || usage; limit="$2"; shift 2 ;;
            --max-lines) [ "$#" -ge 2 ] || usage; max_lines="$2"; shift 2 ;;
            --idle) [ -z "$mode" ] || usage; mode=idle; shift ;;
            --pattern) [ -z "$mode" ] && [ "$#" -ge 2 ] || usage; mode=pattern; value="$2"; shift 2 ;;
            --run) [ -z "$mode" ] && [ "$#" -ge 2 ] || usage; mode=run; value="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    positive_integer "$limit" && positive_integer "$max_lines" || usage
    case "$mode" in
        run) positive_integer "$value" || usage; wait_run_command "$value" "$limit" "$max_lines" ;;
        idle|pattern) wait_screen_command "$mode" "$value" "$limit" ;;
        *) usage ;;
    esac
}
```

Add these dispatch branches:

```bash
        send) shift; send_command "$@" ;;
        read) shift; read_command "$@" ;;
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal-e2e.bats -f 'interactive command|typed line'`; expect two passing tests.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh test/terminal-e2e.bats && git commit -m "feat(terminal): add interactive pane controls"`.

**Verification:** Run `bats test/terminal-e2e.bats -f 'interactive command|typed line'`; expect the captured screen to contain `hello:Ada`, a typed but unsubmitted line to make `run` exit 5, and `C-c` to restore idle state.

## Task 9: Detect credentials during live operations

**Goal:** Stop returning or injecting text when the cursor line is a credential prompt, mark the active run secret, and let only `wait --run N` continue without reading that prompt.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `test/terminal.bats`
- Modify: `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): add live credential cases for `run`, `read`, `wait --idle`, and completion-before-detection ordering, plus unit coverage of the user pattern file. [inferred]

Append this unit test to `test/terminal.bats`, because `check-line --patterns` never reads the tmux option: [inferred]

```bash
@test "user patterns extend the shipped list and user exclusions win" {
    local user="$BATS_TEST_TMPDIR/user-patterns" stub="$BATS_TEST_TMPDIR/stubs/tmux"
    printf 'unlock phrase\n!^Password:$\n' > "$user"
    cat > "$stub" <<EOF
#!/usr/bin/env bash
[ "\$1" = show-option ] && printf '%s\n' '$user'
exit 0
EOF
    chmod +x "$stub"

    run env PATH="$BATS_TEST_TMPDIR/stubs:$PATH" bash -c \
        "source '$TERMINAL'; line_is_credential 'Unlock phrase:'"
    [ "$status" -eq 0 ]

    run env PATH="$BATS_TEST_TMPDIR/stubs:$PATH" bash -c \
        "source '$TERMINAL'; line_is_credential 'Password:'"
    [ "$status" -eq 1 ]
}
```

```bash
@test "run marks a credential prompt secret and wait run never returns its screen" {
    _open
    run "$TERMINAL" run --timeout 10 -- 'read -s -p "Password: " p'
    [ "$status" -eq 3 ]
    [ "${lines[0]}" = 'run=1' ]
    [[ "$output" == *'credential prompt in the companion pane'* ]]
    [[ "$output" != *'Password:'* ]]

    run "$TERMINAL" read
    [ "$status" -eq 3 ]
    run "$TERMINAL" wait --timeout 1 --run 1
    [ "$status" -eq 1 ]

    local pane
    pane=$(sed -n 's/^pane=//p' "$(_owner_dir)/state")
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$pane" -l -- 'typed-by-user'
    "$REAL_TMUX" -S "$TMUX_SOCKET" send-keys -t "$pane" Enter
    run "$TERMINAL" wait --timeout 10 --run 1
    [ "$status" -eq 0 ]
    [ "$output" = 'exit=0' ]
}

@test "interactive waits and sends refuse a credential prompt" {
    _open
    run "$TERMINAL" send --enter -- 'read -s -p "Password: " p'
    [ "$status" -eq 0 ]
    run "$TERMINAL" wait --timeout 5 --idle
    [ "$status" -eq 3 ]
    run "$TERMINAL" send --enter -- 'must-not-be-sent'
    [ "$status" -eq 3 ]
    run "$TERMINAL" send --key Enter   # [inferred] no flag skips the check
    [ "$status" -eq 3 ]
}

@test "a completed command wins before a matching cursor-line check" {
    _open
    run "$TERMINAL" run -- 'echo token: abc'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'token: abc\nexit=0'* ]]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal-e2e.bats -f 'credential prompt|completed command'`; expect credential operations to time out or expose the screen.
- [ ] Step 3 (minimal implementation): add the shared cursor-line check, insert it after completion checks in run polling, and guard interactive verbs.

```bash
credential_on_cursor() {
    local line
    line=$(capture_cursor_line) || return 1
    line_is_credential "$line"
}

credential_refusal() {
    printf '%s\n' 'credential prompt in the companion pane: the user must answer it there' >&2
    return 3
}

highest_run_is_secret() {
    local n
    n=$(state_get seq)
    [ "$n" -gt 0 ] && [ -e "$D/$n.secret" ]
}
```

Replace `wait_for_run_files` with a credential-aware form:

```bash
wait_for_run_files() {
    local n="$1" limit="$2" skip_credential="${3:-0}" grace polls=0 deadline   # [inferred]
    deadline=$((SECONDS + limit))   # [inferred] a separate line reads the $2 of this call
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$D/$n.rc" ]; then
            [ -e "$D/$n.done" ] && return 0
            grace=$((SECONDS + 1))
            while [ "$SECONDS" -lt "$grace" ]; do
                [ -e "$D/$n.done" ] && return 0
                sleep 0.2
            done
            return 6
        fi
        if [ "$skip_credential" -eq 0 ] && credential_on_cursor; then
            : > "$D/$n.secret"
            return 3
        fi
        # Keep the Task 5 liveness poll. [inferred]
        polls=$((polls + 1))
        [ $((polls % 5)) -ne 0 ] || current_companion_alive || return 4
        sleep 0.2
    done
    return 1
}
```

Handle status 3 in `run_command` and `wait_run_command` with `credential_refusal; return 3`. In `wait_run_command`, pass `skip_credential=1` only when `$D/$n.secret` exists. Before `send` writes anything, and before each `read`, `wait --idle`, or `wait --pattern` poll, call `credential_on_cursor && { credential_refusal; return 3; }`. For `read` and `wait --pattern`, also reject when `highest_run_is_secret`; do not apply that marker-only block to `wait --idle`.

Use these exact integrations:

```bash
# In run_command, after wait_for_run_files:
        3) credential_refusal; return 3 ;;

# In wait_run_command:
    local skip_credential=0
    [ ! -e "$D/$n.secret" ] || skip_credential=1
    wait_for_run_files "$n" "$limit" "$skip_credential"
    wait_status=$?
    case "$wait_status" in
        0) print_run_result "$n" "$max_lines" 0; return 0 ;;
        3) credential_refusal; return 3 ;;
        4) fail 'the companion closed during the run' 4 ;;   # [inferred]
        6) print_run_result "$n" "$max_lines" 1; return 0 ;;
        *) return 1 ;;
    esac

# In send_command, directly after ensure_open and before the `if [ -n "$key" ]`
# branch, so that --key cannot skip the check: [inferred]
    credential_on_cursor && { credential_refusal; return 3; }

# Replace read_command's body after option parsing:
    positive_integer "$lines" || usage
    ensure_open
    highest_run_is_secret && { credential_refusal; return 3; }
    credential_on_cursor && { credential_refusal; return 3; }
    capture_screen "$lines"
    n=$(state_get seq)
    [ "$n" -eq 0 ] || [ ! -f "$D/$n.rc" ] || rmdir "$D/busy" 2>/dev/null || true

# Add these checks at the top of each wait_screen_command poll:
        if [ "$mode" = pattern ] && highest_run_is_secret; then
            credential_refusal
            return 3
        fi
        if credential_on_cursor; then
            credential_refusal
            return 3
        fi
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal-e2e.bats -f 'credential prompt|completed command'`; expect all three tests to report `PASS` and no credential screen text in captured Bats output.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh test/terminal-e2e.bats && git commit -m "feat(terminal): block credential prompt capture"`.

**Verification:** Run `bats test/terminal-e2e.bats -f 'credential prompt|completed command'`; expect exit 3 on the live prompt, exit 1 from the first secret `wait --run`, only `exit=0` after the user-side tmux input, and normal output for the already-complete `token: abc` command.

## Task 10: Suppress explicit secrets and clear their scrollback

**Goal:** Make `run --secret` return no command output and make the next plain run erase the visible screen and tmux history before it starts.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): add explicit-secret and post-secret clearing regressions.

```bash
@test "secret run returns only its run number and exit code" {
    _open
    run "$TERMINAL" run --secret -- 'echo token-value'
    [ "$status" -eq 0 ]
    [ "$output" = $'run=1\nexit=0' ]
    run "$TERMINAL" wait --timeout 1 --pattern 'token-value'
    [ "$status" -eq 3 ]
    run "$TERMINAL" read
    [ "$status" -eq 3 ]
}

@test "the next plain run clears secret screen text and history" {
    _open
    run "$TERMINAL" run --secret -- 'echo token-value'
    [ "$status" -eq 0 ]
    run "$TERMINAL" run -- 'true'
    [ "$status" -eq 0 ]
    run "$TERMINAL" read --lines 50
    [ "$status" -eq 0 ]
    [[ "$output" != *'token-value'* ]]

    local pane
    pane=$(sed -n 's/^pane=//p' "$(_owner_dir)/state")
    run "$REAL_TMUX" -S "$TMUX_SOCKET" capture-pane -p -S -50 -t "$pane"
    [ "$status" -eq 0 ]
    [[ "$output" != *'token-value'* ]]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal-e2e.bats -f 'secret run|next plain run'`; expect the first test to pass output suppression but the second to find `token-value` in scrollback.
- [ ] Step 3 (minimal implementation): add the five-step clear sequence and invoke it only for a plain run whose predecessor has a secret marker.

```bash
clear_previous_secret() {
    local previous="$1"
    [ "$previous" -gt 0 ] && [ -e "$D/$previous.secret" ] || return 0
    send_literal '__clux_clear'
    send_key Enter
    # run_command holds the busy lock here, so release it before fail exits. [inferred]
    wait_for_prompt 5 \
        || { rmdir "$D/busy" 2>/dev/null || true; fail 'the companion did not return after clearing secret output' 1; }
    tmux_state clear-history -t "$(state_get pane)" >/dev/null 2>&1 \
        || { rmdir "$D/busy" 2>/dev/null || true; fail 'cannot clear companion history' 1; }
    rm -f "$D"/*.secret
}
```

In `run_command`, keep the lock test and `at_prompt` test first. Before incrementing `seq`, add:

```bash
    local previous
    previous=$(state_get seq)
    [ "$secret" -eq 1 ] || clear_previous_secret "$previous"
    n=$((previous + 1))
```

Do not send `C-l`; the helper must send the literal `__clux_clear` command, wait for `clux$`, then run `clear-history` in that order.

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal-e2e.bats -f 'secret run|next plain run'`; expect both tests to report `PASS`.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh test/terminal-e2e.bats && git commit -m "feat(terminal): clear secret companion output"`.

**Verification:** Run `bats test/terminal-e2e.bats -f 'secret run|next plain run'`; expect the secret value to be absent from both `read` and direct `tmux capture-pane -S -50` after the plain run.

## Task 11: Close companions and wire session-end cleanup

**Goal:** Clear scrollback, stop the correct pane or private server, delete private state, make hook cleanup silent, and reap only owners or servers proven gone.

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `plugins/clux/hooks/hooks.json`
- Modify: `test/terminal.bats`
- Modify: `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): add shutdown, hook registration, outside-tmux, dead-server hook, and live-foreign reaper coverage. [inferred] Put the `SessionEnd` jq test in `test/terminal.bats` with the dead-server hook test; put the real-server cases in `test/terminal-e2e.bats`. [inferred]

```bash
@test "SessionEnd registers terminal close as its third command" {
    local hooks="$REPO_ROOT/plugins/clux/hooks/hooks.json"
    run "$REAL_JQ" -r '.hooks.SessionEnd[0].hooks[2].command' "$hooks"
    [ "$status" -eq 0 ]
    [ "$output" = '${CLAUDE_PLUGIN_ROOT}/scripts/terminal.sh close --hook' ]
}
```

```bash
@test "close removes a split pane and its private directory" {
    _open
    local dir="$(_owner_dir)" pane
    pane=$(sed -n 's/^pane=//p' "$dir/state")
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$dir" ]
    run "$REAL_TMUX" -S "$TMUX_SOCKET" list-panes -a -F '#{pane_id}'
    [[ "$output" != *"$pane"* ]]
}

@test "close stops a private socket server" {
    run "$TERMINAL" open --socket
    [ "$status" -eq 0 ]
    local dir="$(_owner_dir)" socket
    socket=$(sed -n 's/^socket=//p' "$dir/state")
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ ! -e "$dir" ]
    run "$REAL_TMUX" -S "$socket" list-panes
    [ "$status" -ne 0 ]
}

@test "hook close is silent with no companion and outside tmux" {
    # close --hook reads stdin, so every call needs an explicit stdin. [inferred]
    run bash -c "printf event | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run env -u TMUX -u TMUX_PANE bash -c "printf event | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook close removes an open companion" {
    # This case proves that `close --hook` closes a live companion, not only that it stays silent. [inferred]
    _open
    local dir="$(_owner_dir)" pane
    pane=$(sed -n 's/^pane=//p' "$dir/state")
    run bash -c "printf event | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$dir" ]
    run "$REAL_TMUX" -S "$TMUX_SOCKET" list-panes -a -F '#{pane_id}'
    [[ "$output" != *"$pane"* ]]
}

@test "hook close stays silent when the tmux server is gone" {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
    run env PATH="$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin" TMUX=fake TMUX_PANE=%0 \
        bash -c "printf event | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "reaper removes a gone owner and keeps a live foreign server" {
    _open
    # The foreign socket sits below $CLUX_TERMINAL_DIR so that teardown() stops its server even when an assertion below fails; the reaper skips the "foreign" directory because it is not a valid server key. [inferred]
    local owned="$(_owner_dir)" foreign_socket="$CLUX_TERMINAL_DIR/foreign/sock"
    mkdir -p "$CLUX_TERMINAL_DIR/foreign"
    "$REAL_TMUX" -S "$foreign_socket" -f /dev/null new-session -d -s foreign 3>&-
    local foreign_key foreign_dir
    foreign_key=$("$REAL_TMUX" -S "$foreign_socket" display-message -p '#{pid}-#{start_time}')
    foreign_dir="$CLUX_TERMINAL_DIR/$foreign_key-0"
    mkdir -p "$foreign_dir"
    printf 'mode=socket\npane=%%0\nsocket=%s\nseq=0\n' "$foreign_socket" > "$foreign_dir/state"

    "$REAL_TMUX" -S "$TMUX_SOCKET" kill-pane -t "$TMUX_PANE"
    run bash -c "source '$TERMINAL'; terminal_init; reap_companions"
    [ "$status" -eq 0 ]
    [ ! -e "$owned" ]
    [ -d "$foreign_dir" ]
    "$REAL_TMUX" -S "$foreign_socket" kill-server
}

@test "all pane verbs keep their documented outside-tmux exit codes" {
    local args
    for args in 'open' 'run -- true' 'send -- x' 'read' 'wait --idle' 'close' 'list'; do
        run env -u TMUX -u TMUX_PANE bash -c "'$TERMINAL' $args"
        [ "$status" -eq 2 ] || { echo "$args returned $status"; false; }
    done
    run env -u TMUX -u TMUX_PANE "$TERMINAL" check-line -- 'Password:'
    [ "$status" -eq 0 ]
}

@test "owner verbs return 4 when no companion is open" {
    local args
    for args in 'run -- true' 'send -- x' 'read' 'wait --idle'; do
        run bash -c "'$TERMINAL' $args"
        [ "$status" -eq 4 ] || { echo "$args returned $status"; false; }
    done
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats test/terminal-e2e.bats`; expect `close` and the hook JSON assertion to fail.
- [ ] Step 3 (minimal implementation): allow an owner override, add mode-aware close, make hook mode unconditional and silent, and append the third SessionEnd command.

```bash
terminal_init() {
    local owner_source="${1:-${TMUX_PANE:-}}"
    ROOT="${CLUX_TERMINAL_DIR:-${TMPDIR:-/tmp}/clux-terminal-$(id -u)}"
    SERVER_KEY=$(resolve_agent_server_key)
    _clux_valid_server_key "$SERVER_KEY" || fail 'cannot identify the tmux server' 2
    OWNER_PANE="${owner_source#%}"
    case "$OWNER_PANE" in ''|*[!0-9]*) fail 'invalid owner pane' 2 ;; esac
    OWNER_KEY="$SERVER_KEY-$OWNER_PANE"
    D="$ROOT/$OWNER_KEY"
}

close_command() {
    local hook=0 owner="${TMUX_PANE:-}" mode pane socket
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --hook) hook=1; shift ;;
            --owner) [ "$#" -ge 2 ] || usage; owner="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    if [ "$hook" -eq 1 ]; then
        cat >/dev/null
        [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
    else
        require_tmux
    fi
    terminal_init "$owner"
    [ -f "$D/state" ] || return 0
    mode=$(state_get mode)
    pane=$(state_get pane)
    socket=$(state_get socket)
    if [ "$mode" = socket ]; then
        tmux -S "$socket" clear-history -t "$pane" >/dev/null 2>&1 || true
        tmux -S "$socket" kill-server >/dev/null 2>&1 || true
    else
        tmux clear-history -t "$pane" >/dev/null 2>&1 || true
        tmux kill-pane -t "$pane" >/dev/null 2>&1 || true
    fi
    rm -rf "$D"
    return 0
}
```

Handle `close --hook` before `require_tmux` and silence it. This `if` block replaces the `close)` arm that Task 1 put in the first `case` of `main`, so that first `case` keeps only the `check-line` arm. [inferred]

```bash
    if [ "$1" = close ] && [ "${2:-}" = --hook ]; then
        shift
        # fail calls exit, so `|| true` cannot catch it. Use a subshell. [inferred]
        ( close_command "$@" ) >/dev/null 2>&1 || true
        return 0
    fi
```

Route ordinary `close` after `require_tmux` with `close) shift; close_command "$@" ;;`. Append this object after `agent-state.sh remove` in `SessionEnd`:

```json
{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/terminal.sh close --hook", "timeout": 5 }
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats test/terminal-e2e.bats`; expect shutdown, hook, reaper, and outside-tmux cases to report `PASS`.
- [ ] Step 5 (commit): run `git add plugins/clux/scripts/terminal.sh plugins/clux/hooks/hooks.json test/terminal.bats test/terminal-e2e.bats && git commit -m "feat(terminal): close companions at session end"`.

**Verification:** Run `bats test/terminal.bats test/terminal-e2e.bats -f 'close removes|close stops|hook close|server is gone|reaper removes|outside-tmux|owner verbs'` and `jq empty plugins/clux/hooks/hooks.json`; the `hook close` part of the filter selects both the silent case and "hook close removes an open companion". [inferred] Expect eight passing Bats cases, valid JSON, exit 0 and no output from every hook close, including the dead-server case, and the live foreign directory to remain. [inferred]

## Task 12: Add the clux terminal skill

**Goal:** Teach Claude when and how to opt into plain runs versus interactive pane control without ever typing a credential.

**Files touched:**
- Create: `plugins/clux/skills/terminal/SKILL.md`
- Modify: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): add contract assertions for root resolution, command quoting, exit-code handling, secret handling, background commands, and `/clear`.

```bash
@test "terminal skill carries every safety and invocation rule" {
    local skill="$REPO_ROOT/plugins/clux/skills/terminal/SKILL.md"
    [ -f "$skill" ]
    grep -qF '## Snippet S1: resolve the plugin source root' "$skill"
    grep -qF 'run -- '\''command text'\''' "$skill"
    grep -qF 'wait --run <n>' "$skill"
    grep -qF 'Never type into a credential prompt' "$skill"
    grep -qF 'run --secret' "$skill"
    grep -qF 'starts a background process' "$skill"
    grep -qF '`/clear` closes the companion' "$skill"
    grep -qF 'depends on the clux plugin' "$skill"
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'terminal skill'`; expect `FAIL` because the skill is absent.
- [ ] Step 3 (minimal implementation): create the skill in ASD-STE100 style and copy Snippet S1 verbatim from `configuring-tmux/SKILL.md`.

````markdown
---
name: terminal
description: Use when a task must run visible operating-system commands in one persistent tmux companion pane, or when an interactive command needs a TTY. Other skills can opt in by naming clux:terminal and must depend on the clux plugin.
---

# clux companion terminal

Use one companion for the current Claude Code session. The companion keeps its directory and exported variables. The user can watch it and can type credentials in it.

## Snippet S1: resolve the plugin source root

```bash
# Tier 1: the harness exported CLAUDE_PLUGIN_ROOT (hook processes always;
# command/subagent Bash calls sometimes). Tier 2: the installed cache
# ~/.claude/plugins/cache/<marketplace>/clux/<version>/ or a flat
# ~/.claude/plugins/clux/. Tier 3: a plain checkout at or below the cwd.
PLUGIN_ROOT=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/scripts/show-notification.sh" ]; then
    PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
    # Tier 2a: the loaded cache copy, searched ALONE first. A marketplace
    # source checkout at ~/.claude/plugins/marketplaces/<mp>/plugins/clux/
    # matches the same glob, and `marketplaces` sorts after `cache`, so one
    # combined search returns that git tree instead of the version Claude
    # Code actually loaded.
    HIT=$(find "$HOME/.claude/plugins/cache" -maxdepth 5 -type f \
        -path "*/clux/*/scripts/show-notification.sh" 2>/dev/null \
        | LC_ALL=C sort -V | tail -1)
    # Tier 2b: any other install shape under ~/.claude/plugins.
    [ -n "$HIT" ] || HIT=$(find "$HOME/.claude/plugins" -maxdepth 6 -type f \
        \( -path "*/clux/*/scripts/show-notification.sh" \
        -o -path "*/clux/scripts/show-notification.sh" \) 2>/dev/null \
        | LC_ALL=C sort -V | tail -1)
    [ -n "$HIT" ] || HIT=$(find "$PWD" -maxdepth 4 -type f \
        -path "*/plugins/clux/scripts/show-notification.sh" 2>/dev/null \
        | LC_ALL=C sort -V | tail -1)
    [ -n "$HIT" ] && PLUGIN_ROOT="${HIT%/scripts/show-notification.sh}"
fi
PLUGIN_SCRIPTS_DIR="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts}"
MANIFEST="${PLUGIN_ROOT:+$PLUGIN_ROOT/config/deploy-manifest.txt}"
[ -f "$MANIFEST" ] || MANIFEST=""
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
echo "PLUGIN_SCRIPTS_DIR=$PLUGIN_SCRIPTS_DIR"
echo "MANIFEST=$MANIFEST"
```

Stop if `PLUGIN_ROOT` is empty. Set `TERMINAL="$PLUGIN_ROOT/scripts/terminal.sh"`.

## Open the companion

Use `"$TERMINAL" open` for the default split below Claude. Use `"$TERMINAL" open --socket` only when the user selected the private-server mode. Give the printed attach command to the user in socket mode.

## Run a plain command

Use this form:

```bash
"$TERMINAL" run -- 'command text'
```

Pass the full command as one single-quoted argument. The script joins separate words with spaces. Read `run=<n>` from the first output line. Read `exit=<rc>` as the command result. The script itself exits 0 after a completed command, also when `<rc>` is not zero.

Use `--timeout S` when the command needs a different limit. Keep `S` below 120 by default. If `S` is more than 100, set the Bash tool timeout to more than `S` seconds.

If the script exits 1, the run continues. Use `"$TERMINAL" wait --run <n>`. If the script exits 5, use `wait`, `send`, or `read` before a new run.

Use `send`, not `run`, for a command that starts a background process.

## Run an interactive command

Use `send --enter -- 'text'` to start a command that needs a TTY. Use `send --key NAME` for a named key. Use `wait --pattern 'REGEX'`, `wait --idle`, and `read --lines N` to inspect progress.

Claude answers ordinary yes/no prompts and menus. The user answers credential prompts in the pane.

Never type into a credential prompt. Exit 3 means a credential prompt is on the cursor line. Tell the user to answer it in the pane. For a run, use `wait --run <n>` after the user answers. Do not use `read` or `wait --pattern` while the run is secret.

Use `run --secret -- 'command text'` when output can contain a password, token, private key, or other secret. The pane can show it, but Claude gets only `exit=<rc>`. `read` stays blocked until the next plain run clears the screen and tmux history.

## Close and session lifetime

Use `"$TERMINAL" close` when the companion is no longer needed. The `SessionEnd` hook also closes it. `/clear` closes the companion because `/clear` ends the current session. Warn the user before `/clear` when the companion holds useful shell state.

## Exit codes

- 0: the terminal operation completed. For `run`, read `exit=<rc>`.
- 1: the time limit ended. The command can still run.
- 2: arguments, tmux, or the environment are invalid.
- 3: a credential prompt or secret-screen block is active.
- 4: no companion is open for this owner.
- 5: another run is active, or the pane is not at `clux$`.

## Skill authors

Another skill opts in by naming `clux:terminal`. That skill depends on the clux plugin. Do not route unrelated Bash commands through the companion.
````

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'terminal skill'`; expect one passing test.
- [ ] Step 5 (commit): run `git add plugins/clux/skills/terminal/SKILL.md test/terminal.bats && git commit -m "docs(terminal): add companion usage skill"`.

**Verification:** Run `bats test/terminal.bats -f 'terminal skill'` and `diff <(awk '/^## Snippet S1:/{s=1} /^```bash$/{if(s)f=1} f{print} f && /^```$/{exit}' plugins/clux/skills/configuring-tmux/SKILL.md) <(awk '/^## Snippet S1:/{s=1} /^```bash$/{if(s)f=1} f{print} f && /^```$/{exit}' plugins/clux/skills/terminal/SKILL.md)`; expect the Bats test to pass and the snippet diff to print nothing. The awk range starts at the ```` ```bash ```` fence, because `configuring-tmux/SKILL.md` holds a prose line between the heading and the fence that the terminal skill does not copy. [inferred]

## Task 13: Integrate validation, packaging metadata, docs, and release notes

**Goal:** Ship version 3.9.0 with an accurate non-deployed-script contract, documented plugin tree, validator check, and a full green suite.

**Files touched:**
- Modify: `test/deploy-manifest.bats`
- Modify: `test/terminal.bats`
- Modify: `plugins/clux/config/deploy-manifest.txt`
- Modify: `plugins/clux/commands/validate.md`
- Modify: `plugins/clux/.claude-plugin/plugin.json`
- Modify: `CONTRIBUTING.md`
- Modify: `CHANGELOG.md`

**Steps:**
- [ ] Step 1 (failing test): rename the manifest-test category and add release-integration assertions.

```bash
# Runs from the plugin tree, never from ~/.config/clux/scripts. Keep this list
# in step with the deploy-manifest header.
NOT_DEPLOYED="render-clux-conf.sh verify-tmux-conf.sh terminal.sh"
```

Replace every `SETUP_ONLY` reference in `test/deploy-manifest.bats` with `NOT_DEPLOYED`, rename the test to `deploy-manifest: deliberately non-deployed scripts are absent`, and change its failure text to `is deliberately not deployed`.

Append to `test/terminal.bats`:

```bash
@test "release metadata and documentation include the companion terminal" {
    grep -qF 'terminal.sh close --hook' "$REPO_ROOT/plugins/clux/commands/validate.md"
    grep -qF 'terminal.sh' "$REPO_ROOT/CONTRIBUTING.md"
    grep -qF 'credential-patterns.txt' "$REPO_ROOT/CONTRIBUTING.md"
    grep -qF 'terminal/' "$REPO_ROOT/CONTRIBUTING.md"
    grep -qF 'runs from the plugin tree, never from ~/.config/clux/scripts' \
        "$REPO_ROOT/plugins/clux/config/deploy-manifest.txt"
    run "$REAL_JQ" -r '.version' "$REPO_ROOT/plugins/clux/.claude-plugin/plugin.json"
    [ "$status" -eq 0 ]
    [ "$output" = '3.9.0' ]
    grep -qF '## [3.9.0]' "$REPO_ROOT/CHANGELOG.md"
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/deploy-manifest.bats test/docs-tree.bats test/terminal.bats`; expect failures for the unlisted runtime script, missing tree entries, old version, missing release section, and missing validator check.
- [ ] Step 3 (minimal implementation): make the following focused metadata and documentation edits.

Change the manifest header to:

```text
# Left out on purpose: render-clux-conf.sh, verify-tmux-conf.sh and terminal.sh.
# Each runs from the plugin tree, never from ~/.config/clux/scripts. The first two run
# during setup. terminal.sh runs at Claude time through the clux:terminal skill
# and the SessionEnd hook.
```

Add these entries to the `CONTRIBUTING.md` plugin tree:

```text
│   ├── terminal/                # Persistent visible companion terminal
│   │   └── SKILL.md             #   Plain, interactive, and secret command rules
│   ├── terminal.sh              # Companion pane lifecycle and command transport
│   ├── credential-patterns.txt  # Credential prompt includes and exclusions
```

Place `terminal/` under `skills/`, `terminal.sh` under `scripts/`, and `credential-patterns.txt` under `config/` while preserving the tree indentation.

Change the plugin version:

```json
"version": "3.9.0"
```

In the validator's hooks block, after the existing agent-state pairs, add:

```bash
       if grep -qF 'terminal.sh close --hook' "$HOOKS_FILE"; then
           echo "OK  hook: SessionEnd → terminal.sh close --hook"
       else
           echo "FAIL hook: SessionEnd not wired to terminal.sh close --hook"
       fi
```

Add `✓ hooks.json: SessionEnd → terminal.sh close --hook` to the example Hooks output. Add this release section immediately before 3.8.0:

```markdown
## [3.9.0]

### Added

- **`clux:terminal` opens one visible companion shell for a Claude Code session.** The default is a split below Claude in the user's current tmux window. An optional private-socket mode prints its attach command. The companion keeps its current directory and exported variables across commands.
- Plain `run` commands return file-backed output and an exit code after both the wrapper result and the `tee` completion marker arrive. Interactive `send`, `read`, and `wait` operations use the pane screen for commands that need a TTY.
- Credential prompts stop screen capture and input from Claude. `run --secret` suppresses result output, and the next plain run clears both the visible screen and tmux scrollback.
- The `SessionEnd` hook closes the pane or private server and removes its private directory. Stale-owner reaping handles sessions whose end hook did not run.

### Internal

- `test/terminal.bats` covers arguments, outside-tmux behavior, credential patterns, wrapper invariants, state-key parsing, the skill contract, and release integration. `test/terminal-e2e.bats` runs the lifecycle on real throwaway tmux servers.
- `terminal.sh` runs from the plugin tree and is deliberately absent from `config/deploy-manifest.txt`.
```

- [ ] Step 4 (run test, observe PASS): run `bats test/`; expect the complete suite to report only passing tests.
- [ ] Step 5 (commit): run `git add test/deploy-manifest.bats test/terminal.bats plugins/clux/config/deploy-manifest.txt plugins/clux/commands/validate.md plugins/clux/.claude-plugin/plugin.json CONTRIBUTING.md CHANGELOG.md && git commit -m "feat(clux): release companion terminal 3.9.0"`.

**Verification:** Run `bash -n plugins/clux/scripts/terminal.sh`, `jq empty plugins/clux/hooks/hooks.json plugins/clux/.claude-plugin/plugin.json`, `grep -nE '^## Task [0-9]+:' docs/plans/2026-09-26-clux-companion-terminal-design.md`, and `bats test/`; expect both syntax checks to print nothing, JSON parsing to exit 0, task headings numbered 1 through 13, and the full Bats suite to pass.

## Refinement Status

Refinement: CONVERGED round 5 (plan-simulator on fable, plan-fixer on opus; rounds 1 to 4 fixed 16, 4, 1 and 1 critical or important findings; round 5 found 0 critical and 0 important findings; minor findings are not applied).
