# clux Companion Background Sessions Implementation Plan

**Goal:** Make `terminal.sh` open, drive and close a companion for a Claude Code session that has no tmux pane (a background session). The companion is a window in the tmux session of the `claude agents` dashboard, or a private tmux server. This is clux 4.1.0.

**Architecture:** `require_owner` takes the place of `require_tmux` and selects the owner. A pane owner has `TMUX` and `TMUX_PANE`, and its path is the 4.0.0 path with no change. A session owner has a session ID and `CLAUDE_PID`. Its private directory is `$ROOT/sessions/<first 8 characters>`. It calls tmux only with `-S`, and it marks its pane with the pane option `@clux-companion`. A watchdog process, the `SessionEnd` hook (`close --hook` with the `session_id` of the payload) and a new reaper loop close the companion and stop its Laya server.

**Tech Stack:** Bash 3.2 and later, tmux 3.2 and later, Bats 1.5 and later, Python 3 (the fake Laya server of the tests)

---

## Overview

The spec is `docs/superpowers/specs/2026-09-30-clux-companion-background-sessions-design.md`. The prototype in `docs/superpowers/specs/2026-09-30-clux-companion-background-sessions-prototype/` (`bgc.sh`, `test.sh`) is the tested reference for the new mechanics. This plan does not change the spec. The work goes in this order: the owner identity (Task 1), the state fields (Task 2), the pane identity (Task 3), the close paths (Task 4), the reaper (Task 5), `open` for a session owner (Task 6), the watchdog (Task 7), the `SessionStart` hook (Task 8), `list` and `laya status` (Task 9), and the documents and the release (Task 10). The foreground path (a pane owner) does not change: all 4.0.0 tests pass after each task.

Spec coverage:

| Spec section | Tasks |
|---|---|
| 5. Owner identity | 1 (`require_owner`), 8 (`session-env --hook`) |
| 6. The private directory and the new `state` fields | 1 (`D`), 2 (fields, write through a rename) |
| 7. Placement | 6 |
| 8. tmux calls, the pane identity, the `window` arm | 3, and 6 (the mark) |
| 9. Lifetime: open, watchdog, close, reaper | 6 (first `state`), 7 (watchdog), 4 (close), 5 (reaper) |
| 10. What the user sees | 6 (`report_open`) |
| 11. Changes by verb | 4, 6, 7, 8, 9 |
| 12. New messages | 1, 4, 6 |
| 14. Tests | each task; e2e tests 1, 2, 4, 5, 6 in Task 6, e2e test 3 in Task 7 |
| 15. Skill and document changes | 8 (`hooks.json`), 10 |

Sections 1 to 4 (goal, facts, viability, decisions) and 13 (the results of the open questions and the prototype) give the reasons for the design; sections 5 to 12 hold the rules that the tasks put into code. Section 16 (out of scope) needs no task: this plan does not add those items.

Rules for the implementer:

- Run all commands from the worktree root, `/Users/jazz/dev/github.com/ai-advanced-futures/clux/.claude/worktrees/companion-bg-sessions`. Read and change files only in this worktree.
- Do not run git commands that change the repository. The coordinator commits one time after the last task. Each task keeps its Step 5 (commit) as a record of the paths. Skip Step 5.
- The working tree has the untracked spec and prototype (`docs/superpowers/specs/2026-09-30-clux-companion-background-sessions-design.md` and the `...-prototype/` directory). Do not delete them.
- The scripts must run on macOS `/bin/bash` 3.2: no `declare -A`, no `readarray` or `mapfile`, no `${var,,}` or `${var^^}`, no `&>>`, no negative substring offsets. `${SESSION_ID:0:8}` is a positive offset and is correct.
- This plan adds no new script, so `config/deploy-manifest.txt` and the file tree in `CONTRIBUTING.md` do not change.
- Write all prose (comments, the skill, the README, the reference, the CHANGELOG) in ASD-STE100 Simplified Technical English. Do not write the word `inferred` in `plugins/clux/skills/terminal/SKILL.md` or `CHANGELOG.md`: a test refuses it there. It is correct in comments of `terminal.sh`.
- Tests that use the fake Laya server skip when `CLUX_LAYA_PYTHON` cannot import `laya`. On this machine the venv `~/.local/share/clux/laya` imports it. When you look for FAIL or PASS, make sure that bats did not print `# skip` for the test.
- `bats -f` takes a regular expression. Copy the test names from this plan with no change.
- A test never kills a process that it did not start. Some unit tests override `laya_stop_server` with a function that prints its arguments, so the pid `4242` in the tests never goes to `kill`. Do not remove these overrides. When the committed `ps` stub is on `PATH`, `laya_pid_is_server` returns 1 for each pid, so `open_abort` also never kills `4242`.
- Do not change these source checks of `test/terminal.bats`: `grep -c '/dev/urandom'` must stay 2, `grep -c 'random_hex [0-9]'` must stay 2, and no line may contain `rm -rf "$D"; fail`. Task 6 changes the `open_abort` count from 3 to 4.

### Decisions that the spec leaves open

Each item is marked `[inferred]`. Later tasks use these names and formats with no change.

1. **The owner globals.** [inferred] `require_owner` sets `OWNER_KIND` to `pane` or `session`. For a session owner it also sets `SESSION_ID`, `OWNER_PID` and `OWNER_START`. An empty `OWNER_KIND` (a unit test that sources the script and calls `terminal_init` with no `require_owner`) keeps the 4.0.0 pane path.
2. **The ID check.** [inferred] `valid_session_id` uses a regular expression with the explicit characters `[0123456789abcdef]`, not the range `[0-9a-f]`, so the locale cannot change the check. Only lower case is correct: the spec gives `0-9`, `a-f` and `-`. The script does not change `LC_ALL`, because the pane text code needs the locale of the user.
3. **The name of a session directory.** [inferred] `valid_short_id` accepts 8 characters of `[0123456789abcdef]`. The sessions reaper and `watch` skip or refuse other names.
4. **The state format.** [inferred] `mode`, `pane`, `socket` and `seq` are always in `state`. `session`, `owner_pid`, `owner_start`, `server` and `watch_pid` come after the laya fields, each one only when it is not empty. Thus a pane owner has the same `state` as in 4.0.0. The temporary file is `$D/state.$$`.
5. **The reaper and the owner kinds.** [inferred] A session owner does not read the tmux listing and does not run the pane-owner loop: it does not reach the directories of pane owners. Both owner kinds run the sessions loop.
6. **The dashboard pane check.** [inferred] `find_dashboard` checks the pane with `list-panes -t`, not `display-message`: the comment above `current_companion_alive` says that `display-message -p` can exit 0 for a pane that is gone. With a cache file whose pane is gone, `open` uses socket mode and does not try `resolve_agents_pane_by_cwd`.
7. **`attach_in_tmux=`.** [inferred] `report_open` prints it for each companion in socket mode, also for a pane owner with `--socket`, as the table in spec section 10 shows.
8. **`close` of a session owner.** [inferred] With no `state`, `close` exits 0. With the `state` of another session (the same first 8 characters), `close` exits 4 and touches nothing. `close --session` with an ID that is not in the UUID form exits 2 with `invalid Claude session id`.
9. **The mark fails.** [inferred] When `set-option -p` fails, `open` kills the new pane itself (the `window` arm kills only a pane with the mark), then calls `open_abort 1 'cannot mark the companion pane' 1`. The exit code is 1, as for the other pane failures.
10. **The order of the checks in `open`.** [inferred] The "belongs to another session" check comes before `laya_open_check`, so it needs no Laya.
11. **The watchdog.** [inferred] `WATCH_INTERVAL=10` is a global, not an environment variable. The unit tests set it to 0 after they source the script. `watch_is_ours` finds the watchdog by its command line (`ps -ww -o command=`), which ends with `terminal.sh watch --session <short>`. `watch_ensure` takes the typing lock in the create path and in the re-use path, so no `run` writes its `seq` at the same time. `watch_start` gets the absolute directory of the script with `cd "$SCRIPT_DIR" && pwd`, because `SCRIPT_DIR` can be relative.
12. **`clear-history` on close of a session owner.** [inferred] `close_session_dir` sends `clear-history` only to a pane with the mark, so a stale pane ID does not clear a pane of the user.
13. **The hook payload.** [inferred] `hook_session_id` accepts spaces before and after the colon of `"session_id"`. `session-env --hook` writes nothing when `CLAUDE_ENV_FILE` is not set or the ID is not in the UUID form.
14. **`laya status` of a session owner.** [inferred] `server=` names a server only when `state` has the session ID of the caller.
15. **`list`.** [inferred] A session owner does not read the tmux listing. It sees the directories of pane owners as `state=foreign`. Each owner kind lists the session directories, with `state=alive` when the pane has the mark.
16. **`docs/reference.md`.** [inferred] The spec names only the README, but the reference has the long companion section, so it gets a "Background sessions" subsection too.
17. **The e2e owner.** [inferred] The e2e tests use the session ID `0123abcd-4567-4890-abcd-ef0123456789`. The `/clear` test changes to `fedcba98-4567-4890-abcd-ef0123456789` through `CLUX_SESSION_ID`. The dashboard session of the test server is `dash`.

### Test helpers that this plan adds

Tasks 1, 3 and 6 add the helpers of `test/terminal.bats`. Task 6 adds the helpers of `test/terminal-e2e.bats`. Later tasks use them with no change.

| Helper | File | Task |
|---|---|---|
| `use_real_ps` | `test/terminal.bats` | 1 |
| `session_tmux_stub` | `test/terminal.bats` | 3 |
| `open_session_tmux_stub` | `test/terminal.bats` | 6 |
| `bg_setup`, `bg_add_cache`, `bg_dir`, `bg_window_count` | `test/terminal-e2e.bats` | 6 |

## Task 1: Identify a session owner outside tmux

**Goal:** Replace `require_tmux` with `require_owner`, which accepts a pane owner (4.0.0) or a Claude session owner, and put the directory of a session owner at `$ROOT/sessions/<first 8 characters>` (spec sections 5, 6 and 12).

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `test/test_helper.bash`
- Test: `test/terminal.bats`, `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/test_helper.bash`, replace the function `setup` with:

```bash
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
```

In `test/terminal-e2e.bats`, in the function `setup`, add this line as the first line of the body (before `export HOME=...`):

```bash
    unset CLAUDE_CODE_SESSION_ID CLUX_SESSION_ID CLAUDE_PID
```

In `test/terminal.bats`, replace the test `tmux verbs refuse outside tmux while hook close is silent` with:

```bash
@test "tmux verbs refuse outside tmux while hook close is silent" {
    local args
    for args in 'open' 'run -- true' 'send -- x' 'read' 'wait --idle' 'close' 'list'; do
        run env -u TMUX -u TMUX_PANE -u CLAUDE_CODE_SESSION_ID -u CLUX_SESSION_ID -u CLAUDE_PID \
            bash -c "'$TERMINAL' $args"
        [ "$status" -eq 2 ] || { echo "$args returned $status"; false; }
        [ "$output" = 'clux terminal must run inside tmux or in a Claude Code session' ]
    done

    run env -u TMUX -u TMUX_PANE -u CLAUDE_CODE_SESSION_ID -u CLUX_SESSION_ID -u CLAUDE_PID \
        bash -c "printf hook-input | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
```

In `test/terminal.bats`, add this helper and these tests after the test `tmux verbs refuse outside tmux while hook close is silent`:

```bash
# use_real_ps — a session owner needs `ps -o lstart=`, and the committed ps
# stub prints nothing.
use_real_ps() {
    local real=/bin/ps
    [ -x "$real" ] || real=/usr/bin/ps
    ln -sf "$real" "$BATS_TEST_TMPDIR/stubs/ps"
}

@test "a session owner needs a valid session id and a live CLAUDE_PID" {
    use_real_ps
    local root="$BATS_TEST_TMPDIR/root" sid=0123abcd-4567-4890-abcd-ef0123456789 id pid
    for id in ../../etc 0123ABCD-4567-4890-abcd-ef0123456789 0123abcd-4567-4890-abcd-ef01234567890 x; do
        run env -u TMUX -u TMUX_PANE CLUX_TERMINAL_DIR="$root" CLAUDE_CODE_SESSION_ID="$id" \
            CLAUDE_PID=$$ "$TERMINAL" list
        [ "$status" -eq 2 ] || { echo "$id returned $status"; false; }
        [ "$output" = 'invalid Claude session id' ]
    done
    # CLUX_SESSION_ID comes first, also when it is not valid.
    run env -u TMUX -u TMUX_PANE CLUX_TERMINAL_DIR="$root" CLUX_SESSION_ID=bad \
        CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PID=$$ "$TERMINAL" list
    [ "$status" -eq 2 ]
    [ "$output" = 'invalid Claude session id' ]
    for pid in '' 0 12x 99999999; do
        run env -u TMUX -u TMUX_PANE CLUX_TERMINAL_DIR="$root" CLAUDE_CODE_SESSION_ID="$sid" \
            CLAUDE_PID="$pid" "$TERMINAL" list
        [ "$status" -eq 2 ] || { echo "pid '$pid' returned $status"; false; }
        [ "$output" = 'cannot identify the Claude session process' ]
    done
    run env -u TMUX -u TMUX_PANE -u CLAUDE_PID CLUX_TERMINAL_DIR="$root" CLAUDE_CODE_SESSION_ID="$sid" \
        "$TERMINAL" list
    [ "$status" -eq 2 ]
    [ "$output" = 'cannot identify the Claude session process' ]
    [ ! -e "$root" ]
}

@test "a session owner has its directory under sessions, named by the first 8 characters of its id" {
    use_real_ps
    local root="$BATS_TEST_TMPDIR/root"
    run env -u TMUX -u TMUX_PANE CLUX_TERMINAL_DIR="$root" \
        CLAUDE_CODE_SESSION_ID=0123abcd-4567-4890-abcd-ef0123456789 CLAUDE_PID=$$ bash -c \
        "source '$TERMINAL'; require_owner; terminal_init
        echo \"\$OWNER_KIND \$D \$OWNER_PID\"; [ -n \"\$OWNER_START\" ]"
    [ "$status" -eq 0 ]
    [ "$output" = "session $root/sessions/0123abcd $$" ]
    # CLUX_SESSION_ID comes first.
    run env -u TMUX -u TMUX_PANE CLUX_TERMINAL_DIR="$root" CLUX_SESSION_ID=fedcba98-4567-4890-abcd-ef0123456789 \
        CLAUDE_CODE_SESSION_ID=0123abcd-4567-4890-abcd-ef0123456789 CLAUDE_PID=$$ bash -c \
        "source '$TERMINAL'; require_owner; terminal_init; echo \"\$D\""
    [ "$status" -eq 0 ]
    [ "$output" = "$root/sessions/fedcba98" ]
    # TMUX and TMUX_PANE make a pane owner, also with a session id.
    run env TMUX=fake TMUX_PANE=%0 CLAUDE_CODE_SESSION_ID=0123abcd-4567-4890-abcd-ef0123456789 \
        CLAUDE_PID=$$ bash -c "source '$TERMINAL'; require_owner; echo \"\$OWNER_KIND\""
    [ "$status" -eq 0 ]
    [ "$output" = pane ]
}

@test "the socket path of a session owner fits in 100 bytes under a 49-byte TMPDIR" {
    use_real_ps
    local tmp
    # 49 bytes with the slash at the end, as the macOS TMPDIR.
    tmp=$(printf '/%047s/' '' | tr ' ' x)
    [ "${#tmp}" -eq 49 ]
    run env -u TMUX -u TMUX_PANE -u CLUX_TERMINAL_DIR TMPDIR="$tmp" \
        CLAUDE_CODE_SESSION_ID=0123abcd-4567-4890-abcd-ef0123456789 CLAUDE_PID=$$ bash -c \
        "source '$TERMINAL'; require_owner; terminal_init; printf '%s' \"\$D/sock\""
    [ "$status" -eq 0 ]
    [ "${#output}" -le 100 ] || { echo "${#output} bytes: $output"; false; }
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'refuse outside tmux|session owner'`. Expect four `not ok` lines:
  - `tmux verbs refuse outside tmux while hook close is silent`: the output is `clux terminal must run inside tmux`.
  - `a session owner needs a valid session id and a live CLAUDE_PID`: the output is `clux terminal must run inside tmux`.
  - `a session owner has its directory under sessions, ...`: status 127, `require_owner: command not found`.
  - `the socket path of a session owner fits in 100 bytes ...`: status 127, `require_owner: command not found`.
- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/terminal.sh`, replace the first four lines of the file header:

```bash
#!/usr/bin/env bash
# terminal.sh — the companion terminal. One private directory per Claude
# session, keyed by tmux server and owner pane, driving a known interactive
# Bash through tmux.
```

with:

```bash
#!/usr/bin/env bash
# terminal.sh — the companion terminal. One private directory per Claude
# session, driving a known interactive Bash through tmux. A pane owner (in
# tmux) has a directory keyed by tmux server and owner pane. A session owner
# (a Claude Code session with no tmux pane) has a directory keyed by the
# first 8 characters of its session id.
```

Replace the function `require_tmux`:

```bash
require_tmux() {
    [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] \
        || fail 'clux terminal must run inside tmux' 2
}
```

with:

```bash
# The owner of the companion (spec 2026-09-30-clux-companion-background-
# sessions-design.md, section 5). A pane owner has TMUX and TMUX_PANE: the
# 4.0.0 path. Each other Claude Code session is a session owner:
# CLUX_SESSION_ID (the SessionStart hook writes it) first, then
# CLAUDE_CODE_SESSION_ID, and the process CLAUDE_PID. Sets OWNER_KIND, and
# for a session owner SESSION_ID, OWNER_PID and OWNER_START. An empty
# OWNER_KIND (a test that sources this file) keeps the pane path.
OWNER_KIND=
SESSION_ID=
OWNER_PID=
OWNER_START=
require_owner() {
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
        OWNER_KIND=pane
        return 0
    fi
    SESSION_ID="${CLUX_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
    [ -n "$SESSION_ID" ] || fail 'clux terminal must run inside tmux or in a Claude Code session' 2
    valid_session_id "$SESSION_ID" || fail 'invalid Claude session id' 2
    OWNER_PID="${CLAUDE_PID:-}"
    positive_integer "$OWNER_PID" && process_start "$OWNER_PID" \
        || fail 'cannot identify the Claude session process' 2
    OWNER_START="$PROC_START"
    OWNER_KIND=session
}

# A session id is a UUID in lower case. The script puts it in a path only
# after this check. The characters are explicit, not a range: in some
# locales a range also matches other characters.
SESSION_ID_RE='^[0123456789abcdef]{8}-[0123456789abcdef]{4}-[0123456789abcdef]{4}-[0123456789abcdef]{4}-[0123456789abcdef]{12}$'
valid_session_id() {
    [[ $1 =~ $SESSION_ID_RE ]]
}

# process_start PID — the start time of PID in PROC_START, with the spaces
# at the end removed: macOS ps adds them. A pid alone can repeat, the pid
# and its start time cannot. Fails when ps does not know PID.
PROC_START=
process_start() {
    local out
    PROC_START=
    out=$(ps -o lstart= -p "$1" 2>/dev/null) || return 1
    rtrim "$out"
    PROC_START="$RTRIM"
    [ -n "$PROC_START" ]
}

# owner_alive PID START — PID runs and started at START.
owner_alive() {
    positive_integer "${1:-}" && [ -n "${2:-}" ] && process_start "$1" && [ "$PROC_START" = "$2" ]
}
```

Replace the function `terminal_init` with:

```bash
terminal_init() {
    # Every file and directory this process makes ($D, state, busy, <n>.cmd)
    # is private. The pane shell keeps the user's own umask.
    umask 077
    resolve_root
    if [ "$OWNER_KIND" = session ]; then
        # A session owner needs no tmux server key (spec 2026-09-30,
        # section 6). The full id would make the socket path too long.
        SERVER_KEY=
        D="$ROOT/sessions/${SESSION_ID:0:8}"
        return 0
    fi
    SERVER_KEY=$(resolve_agent_server_key)
    _clux_valid_server_key "$SERVER_KEY" || fail 'cannot identify the tmux server' 2
    OWNER_PANE="${TMUX_PANE#%}"
    case "$OWNER_PANE" in ''|*[!0-9]*) fail 'invalid owner pane' 2 ;; esac
    D="$ROOT/$SERVER_KEY-$OWNER_PANE"
}
```

Replace the function `main` with:

```bash
main() {
    [ "$#" -gt 0 ] || usage
    case "$1" in
        check-line) shift; check_line_command "$@"; return $? ;;
        # No require_owner: install and status operate outside tmux too.
        laya) shift; laya_command "$@"; return $? ;;
    esac
    if [ "$1" = close ] && [ "${2:-}" = --hook ]; then
        shift
        ( close_command "$@" ) >/dev/null 2>&1 || true
        return 0
    fi
    require_owner
    case "$1" in
        open) shift; open_command "$@" ;;
        run) shift; run_command "$@" ;;
        send) shift; send_command "$@" ;;
        read) shift; read_command "$@" ;;
        wait) shift; wait_command "$@" ;;
        close) shift; close_command "$@" ;;
        list) list_command ;;
        *) usage ;;
    esac
}
```

In the function `close_command`, change the comment line `# No require_tmux here: main already ran it on the verb path, and the --hook` to `# No require_owner here: main already ran it on the verb path, and the --hook`.

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'refuse outside tmux|session owner'`. Expect four `ok` lines. Then run `bats test/terminal.bats`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/scripts/terminal.sh test/test_helper.bash test/terminal.bats test/terminal-e2e.bats
git commit -m "feat(clux): identify a Claude session owner outside tmux"
```

**Verification:**
- `bats test/terminal.bats -f 'session owner'` prints `ok` for the three new tests.
- `grep -c 'require_tmux' plugins/clux/scripts/terminal.sh` prints `0`.
- `bats test/terminal.bats | grep -c '^not ok'` prints `0`.

## Task 2: Add the session fields to state and write state through a rename

**Goal:** Make `state_load` read and `write_state` write `session`, `owner_pid`, `owner_start`, `server` and `watch_pid` on each call, and make `write_state` write a temporary file and rename it (spec section 6).

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Test: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/terminal.bats`, add this test after the test `write_state and state_load carry the three laya fields`:

```bash
@test "write_state keeps the session fields on each rewrite and renames a temporary file" {
    run bash -c "source '$TERMINAL'
        D='$BATS_TEST_TMPDIR/d'; mkdir -p \"\$D\"
        S_SESSION=0123abcd-4567-4890-abcd-ef0123456789 S_OWNER_PID=77
        S_OWNER_START='Wed Sep 30 10:00:00 2026' S_SERVER=1234-1700000000 S_WATCH_PID=88
        write_state window %3 /tmp/user.sock 0 4242 http://127.0.0.1:5 k1
        S_SESSION=; S_OWNER_PID=; S_OWNER_START=; S_SERVER=; S_WATCH_PID=
        state_load
        write_state \"\$S_MODE\" \"\$S_PANE\" \"\$S_SOCKET\" 1
        cat \"\$D/state\"
        ls \"\$D\"
        printf 'mode=split\npane=%%1\nsocket=\nseq=0\n' > \"\$D/state\"
        state_load
        echo \"[\$S_SESSION\$S_OWNER_PID\$S_OWNER_START\$S_SERVER\$S_WATCH_PID]\""
    [ "$status" -eq 0 ]
    [ "$output" = $'mode=window\npane=%3\nsocket=/tmp/user.sock\nseq=1\nlaya_pid=4242\nlaya_url=http://127.0.0.1:5\nlaya_key=k1\nsession=0123abcd-4567-4890-abcd-ef0123456789\nowner_pid=77\nowner_start=Wed Sep 30 10:00:00 2026\nserver=1234-1700000000\nwatch_pid=88\nstate\n[]' ]
    grep -qF 'mv -f "$tmp" "$D/state"' "$TERMINAL"
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'write_state keeps the session fields'`. Expect `not ok`: the `state` has no `session=` line and ends after `laya_key=k1`.
- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/terminal.sh`, replace the global block:

```bash
S_MODE=
S_PANE=
S_SOCKET=
S_SEQ=
S_LAYA_PID=
S_LAYA_URL=
S_LAYA_KEY=
S_TOKEN=
```

with:

```bash
S_MODE=
S_PANE=
S_SOCKET=
S_SEQ=
S_LAYA_PID=
S_LAYA_URL=
S_LAYA_KEY=
S_TOKEN=
# The fields of a session owner (spec 2026-09-30, section 6).
S_SESSION=
S_OWNER_PID=
S_OWNER_START=
S_SERVER=
S_WATCH_PID=
```

Replace the function `state_load` (not its comment) with:

```bash
state_load() {
    local dir="${1:-$D}" key value
    S_MODE=''; S_PANE=''; S_SOCKET=''; S_SEQ=''
    S_LAYA_PID=''; S_LAYA_URL=''; S_LAYA_KEY=''; S_TOKEN=''
    S_SESSION=''; S_OWNER_PID=''; S_OWNER_START=''; S_SERVER=''; S_WATCH_PID=''
    [ -f "$dir/state" ] || return 1
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in
            mode) S_MODE="$value" ;;
            pane) S_PANE="$value" ;;
            socket) S_SOCKET="$value" ;;
            seq) S_SEQ="$value" ;;
            laya_pid) S_LAYA_PID="$value" ;;
            laya_url) S_LAYA_URL="$value" ;;
            laya_key) S_LAYA_KEY="$value" ;;
            token) S_TOKEN="$value" ;;
            session) S_SESSION="$value" ;;
            owner_pid) S_OWNER_PID="$value" ;;
            owner_start) S_OWNER_START="$value" ;;
            server) S_SERVER="$value" ;;
            watch_pid) S_WATCH_PID="$value" ;;
        esac
    done 2>/dev/null < "$dir/state"
    # A companion that an older clux opened has no token.
    PROMPT_MARK='clux$'
    CONT_MARK=
    [ -z "$S_TOKEN" ] || { PROMPT_MARK="clux-$S_TOKEN\$"; CONT_MARK="clux-$S_TOKEN> "; }
    return 0
}
```

Replace the comment above `write_state` and the function `write_state` with:

```bash
# The ONE state-file writer. After open, seq changes on each run, the laya
# fields change when laya_restart_if_down starts a new server, and a session
# owner gets watch_pid when open starts the watchdog. Each call writes all
# the fields again from the S_* globals, also the session-owner fields.
# write_state MODE PANE SOCKET SEQ [LAYA_PID LAYA_URL LAYA_KEY]: with four
# arguments the laya fields keep the values that state_load read. mode,
# pane, socket and seq are always written; each other field only when it is
# not empty, so a pane owner has the same state as in 4.0.0.
# [inferred] The write goes to a temporary file in $D, and mv renames it to
# state, so a reader (the watchdog, the reaper) never sees a half-written
# file.
write_state() {
    local tmp="$D/state.$$"
    S_MODE="$1"
    S_PANE="$2"
    S_SOCKET="$3"
    S_SEQ="${4:-0}"
    if [ "$#" -ge 5 ]; then
        S_LAYA_PID="$5"
        S_LAYA_URL="${6:-}"
        S_LAYA_KEY="${7:-}"
    fi
    {
        printf 'mode=%s\npane=%s\nsocket=%s\nseq=%s\n' "$S_MODE" "$S_PANE" "$S_SOCKET" "$S_SEQ"
        [ -z "$S_TOKEN" ] || printf 'token=%s\n' "$S_TOKEN"
        [ -z "$S_LAYA_PID" ] || printf 'laya_pid=%s\n' "$S_LAYA_PID"
        [ -z "$S_LAYA_URL" ] || printf 'laya_url=%s\n' "$S_LAYA_URL"
        [ -z "$S_LAYA_KEY" ] || printf 'laya_key=%s\n' "$S_LAYA_KEY"
        [ -z "$S_SESSION" ] || printf 'session=%s\n' "$S_SESSION"
        [ -z "$S_OWNER_PID" ] || printf 'owner_pid=%s\n' "$S_OWNER_PID"
        [ -z "$S_OWNER_START" ] || printf 'owner_start=%s\n' "$S_OWNER_START"
        [ -z "$S_SERVER" ] || printf 'server=%s\n' "$S_SERVER"
        [ -z "$S_WATCH_PID" ] || printf 'watch_pid=%s\n' "$S_WATCH_PID"
    } > "$tmp" && mv -f "$tmp" "$D/state"
}
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'write_state'`. Expect `ok` for `write_state and state_load carry the three laya fields` and for `write_state keeps the session fields on each rewrite and renames a temporary file`. Then run `bats test/terminal.bats`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/scripts/terminal.sh test/terminal.bats
git commit -m "feat(clux): keep the session-owner fields in state and write state through a rename"
```

**Verification:**
- `bats test/terminal.bats -f 'write_state'` prints two `ok` lines.
- `grep -c '> "\$D/state"$' plugins/clux/scripts/terminal.sh` prints `0`: no writer writes `state` in place.

## Task 3: Find the companion of a session owner by its pane mark

**Goal:** Make each tmux call of a session owner use `-S`, make `current_companion_alive` and `kill_companion` check the `@clux-companion` mark, and add the `window` arm that never uses `kill-server` (spec section 8).

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Test: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/terminal.bats`, add this helper and these tests after the test `the reaper reads the server key from the first two fields`:

```bash
# session_tmux_stub — tmux for the session-owner tests. It writes each call
# to STUB_LOG. display-message gives STUB_MARK for the @clux-companion mark,
# else the server key 1234-1700000000. list-panes gives %0.
session_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
    *'#{@clux-companion}'*) printf '%s\n' "${STUB_MARK:-}" ;;
    *display-message*) echo 1234-1700000000 ;;
    *list-panes*) echo %0 ;;
esac
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "the window arm kills only a pane that holds the mark, and never the server" {
    session_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run env STUB_LOG="$log" STUB_MARK=ffff0000 bash -c "source '$TERMINAL'; S_TOKEN=ab12cd34
        kill_companion window %5 /tmp/user.sock 1"
    [ "$status" -eq 0 ]
    ! grep -q 'kill-pane' "$log" || false
    run env STUB_LOG="$log" STUB_MARK=ab12cd34 bash -c "source '$TERMINAL'; S_TOKEN=ab12cd34
        kill_companion window %5 /tmp/user.sock 0"
    [ "$status" -eq 0 ]
    grep -qx 'tmux -S /tmp/user.sock kill-pane -t %5' "$log"
    ! grep -q 'kill-server' "$log" || false
}

@test "a session owner finds its companion by the mark and by its session id" {
    session_tmux_stub
    local d="$BATS_TEST_TMPDIR/d" log="$BATS_TEST_TMPDIR/stub.log" sid=0123abcd-4567-4890-abcd-ef0123456789
    mkdir -p "$d"
    printf 'mode=window\npane=%%5\nsocket=/tmp/user.sock\nseq=0\ntoken=ab12cd34\nsession=%s\n' "$sid" > "$d/state"
    alive_as() {
        run env STUB_LOG="$log" STUB_MARK="$1" bash -c "source '$TERMINAL'; D='$d'
            OWNER_KIND=session SESSION_ID=$2
            if current_companion_alive; then echo alive; else echo gone; fi"
    }
    alive_as ab12cd34 "$sid"
    [ "$output" = alive ]
    alive_as ffff0000 "$sid"
    [ "$output" = gone ]
    grep -qx "tmux -S /tmp/user.sock display-message -p -t %5 #{@clux-companion}" "$log"
    ! grep -q 'list-panes' "$log" || false
    # The state of another session with the same first 8 characters.
    : > "$log"
    alive_as ab12cd34 0123abcd-9999-4890-abcd-ef0123456789
    [ "$output" = gone ]
    [ ! -s "$log" ]
}

@test "tmux_state and the user patterns use the socket of a window companion" {
    session_tmux_stub
    local log="$BATS_TEST_TMPDIR/stub.log"
    run env STUB_LOG="$log" bash -c "source '$TERMINAL'; S_MODE=window S_SOCKET=/tmp/user.sock
        tmux_state send-keys -t %5 x
        _load_user_patterns"
    [ "$status" -eq 0 ]
    [ "$(cat "$log")" = $'tmux -S /tmp/user.sock send-keys -t %5 x\ntmux -S /tmp/user.sock show-option -gqv @clux-terminal-patterns' ]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'window arm|finds its companion by the mark|socket of a window companion'`. Expect three `not ok` lines:
  - the window arm test: `kill_companion` has no `window` arm, so the log has no `kill-pane`.
  - the mark test: the output is `alive` for the mark `ffff0000`, because `list-panes` answers.
  - the `tmux_state` test: the log has `tmux send-keys -t %5 x` with no `-S`.
- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/terminal.sh`, replace the function `_load_user_patterns` with:

```bash
_load_user_patterns() {
    [ -z "$_CLUX_USER_PATTERNS_SET" ] || return 0
    _CLUX_USER_PATTERNS_SET=1
    # [inferred] Window mode reads the option from the server of the user
    # (spec 2026-09-30, section 8). The other modes read the default server:
    # for a pane owner it is the server of the owner pane; for a session
    # owner with no default server, no user patterns apply.
    if [ "$S_MODE" = window ]; then
        _CLUX_USER_PATTERNS=$(tmux -S "$S_SOCKET" show-option -gqv '@clux-terminal-patterns' 2>/dev/null || true)
    else
        _CLUX_USER_PATTERNS=$(tmux show-option -gqv '@clux-terminal-patterns' 2>/dev/null || true)
    fi
}
```

Replace the comment above `kill_companion` and the function `kill_companion` with:

```bash
# The one place that decides how a companion is torn down. A private server
# goes as a whole; a split pane goes only when the caller owns it; a window
# pane on the server of the user goes only when it holds the mark. The
# window arm never uses kill-server: that server is the server of the user.
#
# A case, not if/elif: a socket-mode state with an empty socket field must do
# nothing. Its pane id names a pane on the PRIVATE server, and an elif that
# fell through would kill the pane with that id on the user's own server.
kill_companion() {
    local mode="$1" pane="$2" socket="$3" kill_split="${4:-0}"
    case "$mode" in
        socket)
            [ -z "$socket" ] || tmux -S "$socket" kill-server >/dev/null 2>&1 || true ;;
        split)
            [ "$kill_split" -ne 1 ] || [ -z "$pane" ] || tmux kill-pane -t "$pane" >/dev/null 2>&1 || true ;;
        window)
            # The user's own server: kill the companion pane (its window closes with
            # it), never the server. The identity check stops a stale pane id from
            # naming a pane of the user after a server restart.
            [ -z "$socket" ] || [ -z "$pane" ] || ! companion_pane_is_ours "$socket" "$pane" \
                || tmux -S "$socket" kill-pane -t "$pane" >/dev/null 2>&1 || true ;;
    esac
}
```

Replace the function `tmux_state` with:

```bash
# A session owner has no TMUX, so plain tmux can reach another server:
# socket and window mode always name the server with -S. No fork: the poll
# loops call this.
tmux_state() {
    case "$S_MODE" in
        socket|window) tmux -S "$S_SOCKET" "$@" ;;
        *) tmux "$@" ;;
    esac
}
```

Replace the function `current_companion_alive` (keep its comment) with:

```bash
current_companion_alive() {
    state_load || return 1
    [ -n "$S_PANE" ] || return 1
    state_is_ours || return 1
    if [ "$OWNER_KIND" = session ]; then
        companion_pane_is_ours "$S_SOCKET" "$S_PANE"
        return
    fi
    tmux_state list-panes -t "$S_PANE" >/dev/null 2>&1
}

# state_is_ours — the state that state_load read belongs to this owner. For
# a session owner the session field must be the session id of the caller:
# two sessions can have the same first 8 characters, and after /clear the
# old companion has the old id (spec 2026-09-30, section 6).
state_is_ours() {
    [ "$OWNER_KIND" != session ] || [ "$S_SESSION" = "$SESSION_ID" ]
}

# companion_pane_is_ours SOCKET PANE — PANE on the server at SOCKET holds
# the token of this state in its @clux-companion option (spec 2026-09-30,
# section 8). A pane id is unique only in one server, and a restarted server
# starts again at %0: without the mark, a stale pane id can name a pane of
# the user. For a pane that is gone, the value is empty or tmux fails, so
# the compare fails.
companion_pane_is_ours() {
    local mark
    [ -n "$1" ] && [ -n "$2" ] && [ -n "$S_TOKEN" ] || return 1
    mark=$(tmux -S "$1" display-message -p -t "$2" '#{@clux-companion}' 2>/dev/null) || return 1
    [ "$mark" = "$S_TOKEN" ]
}
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'window arm|finds its companion by the mark|socket of a window companion'`. Expect three `ok` lines. Then run `bats test/terminal.bats`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/scripts/terminal.sh test/terminal.bats
git commit -m "feat(clux): find the companion of a session owner by its pane mark"
```

**Verification:**
- `bats test/terminal.bats -f 'window arm|by the mark|window companion'` prints three `ok` lines.
- `grep -n 'kill-server' plugins/clux/scripts/terminal.sh` shows only the `socket)` arm of `kill_companion` and comments.

## Task 4: Close the companion of a session owner from the verb and from the hook

**Goal:** Add `close_session_dir`, `close --session <id>`, `close --hook` with no `TMUX` (the `session_id` of the payload), the exit 4 for the `state` of another session, and the stop of the watchdog (spec section 9, "Close").

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Test: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/terminal.bats`, add these tests after the test `tmux_state and the user patterns use the socket of a window companion`:

```bash
@test "close --hook with no tmux closes the companion of the session in the payload" {
    session_tmux_stub
    local root="$BATS_TEST_TMPDIR/root" log="$BATS_TEST_TMPDIR/stub.log" sid=0123abcd-4567-4890-abcd-ef0123456789
    mkdir -p "$root/sessions/0123abcd"
    printf 'mode=window\npane=%%5\nsocket=/tmp/user.sock\nseq=0\ntoken=ab12cd34\nsession=%s\n' "$sid" \
        > "$root/sessions/0123abcd/state"
    # A bad session_id does nothing.
    run env -u TMUX -u TMUX_PANE STUB_LOG="$log" STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" bash -c \
        "printf '{\"session_id\":\"../../x\",\"reason\":\"other\"}' | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -d "$root/sessions/0123abcd" ]
    # Another session with the same first 8 characters does nothing.
    run env -u TMUX -u TMUX_PANE STUB_LOG="$log" STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" bash -c \
        "printf '{\"session_id\":\"0123abcd-9999-4890-abcd-ef0123456789\"}' | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -d "$root/sessions/0123abcd" ]
    ! grep -q 'kill-pane' "$log" || false
    run env -u TMUX -u TMUX_PANE STUB_LOG="$log" STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" bash -c \
        "printf '{\"session_id\": \"$sid\", \"hook_event_name\": \"SessionEnd\"}' | '$TERMINAL' close --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$root/sessions/0123abcd" ]
    grep -qx 'tmux -S /tmp/user.sock clear-history -t %5' "$log"
    grep -qx 'tmux -S /tmp/user.sock kill-pane -t %5' "$log"
    ! grep -q 'kill-server' "$log" || false
}

@test "close --session needs a valid id, and close by another session exits 4 and changes nothing" {
    use_real_ps
    session_tmux_stub
    local root="$BATS_TEST_TMPDIR/root" log="$BATS_TEST_TMPDIR/stub.log"
    local sid=0123abcd-4567-4890-abcd-ef0123456789 other=0123abcd-9999-4890-abcd-ef0123456789
    mkdir -p "$root/sessions/0123abcd"
    printf 'mode=window\npane=%%5\nsocket=/tmp/user.sock\nseq=0\ntoken=ab12cd34\nsession=%s\n' "$sid" \
        > "$root/sessions/0123abcd/state"
    run env -u TMUX -u TMUX_PANE CLUX_TERMINAL_DIR="$root" "$TERMINAL" close --session ../x
    [ "$status" -eq 2 ]
    [ "$output" = 'invalid Claude session id' ]
    run env -u TMUX -u TMUX_PANE STUB_LOG="$log" STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" \
        CLAUDE_CODE_SESSION_ID="$other" CLAUDE_PID=$$ "$TERMINAL" close
    [ "$status" -eq 4 ]
    [ "$output" = 'no companion is open for this owner' ]
    run env -u TMUX -u TMUX_PANE STUB_LOG="$log" STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" \
        "$TERMINAL" close --session "$other"
    [ "$status" -eq 0 ]
    [ -d "$root/sessions/0123abcd" ]
    ! grep -q 'kill-pane\|clear-history' "$log" || false
    run env -u TMUX -u TMUX_PANE STUB_LOG="$log" STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" \
        CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PID=$$ "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ ! -e "$root/sessions/0123abcd" ]
    grep -qx 'tmux -S /tmp/user.sock kill-pane -t %5' "$log"
}

@test "watch_stop stops only the watchdog of the same directory" {
    use_real_ps
    local fake="$BATS_TEST_TMPDIR/fake" watch other rc=0
    mkdir -p "$fake"
    # A process with the command line of a watchdog. Short sleeps: when the
    # kill stops the script, its sleep child ends in 1 s.
    printf 'while :; do sleep 1; done\n' > "$fake/terminal.sh"
    bash "$fake/terminal.sh" watch --session abcdef01 </dev/null >/dev/null 2>&1 3>&- &
    watch=$!
    sleep 60 </dev/null >/dev/null 2>&1 3>&- &
    other=$!
    run bash -c "source '$TERMINAL'; watch_stop $other abcdef01; watch_stop $watch 12345678; watch_stop '' abcdef01"
    [ "$status" -eq 0 ]
    kill -0 "$watch"
    kill -0 "$other"
    run bash -c "source '$TERMINAL'; watch_stop $watch abcdef01"
    kill "$other"
    [ "$status" -eq 0 ]
    wait "$watch" || rc=$?
    [ "$rc" -eq 143 ]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'close --hook with no tmux|close --session needs|watch_stop stops'`. Expect three `not ok` lines:
  - the hook test: the directory stays, because `close --hook` returns when `TMUX` is not set.
  - the `close --session` test: status 2 with `clux terminal must run inside tmux or in a Claude Code session`.
  - the `watch_stop` test: status 127, `watch_stop: command not found`.
- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/terminal.sh`, add these functions directly above the function `close_command`:

```bash
# hook_session_id JSON — the session_id field of a hook payload in
# HOOK_SESSION_ID, read with parameter expansion as hooks/agent-state.sh
# does. Empty when the field is not there. The caller checks the UUID form.
# [inferred] Spaces before and after the colon are accepted.
HOOK_SESSION_ID=
hook_session_id() {
    local rest="${1#*\"session_id\"}"
    HOOK_SESSION_ID=
    [ "$rest" != "$1" ] || return 0
    rest="${rest#"${rest%%[![:space:]]*}"}"
    rest="${rest#:}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    rest="${rest#\"}"
    HOOK_SESSION_ID="${rest%%\"*}"
}

# watch_is_ours PID SHORT — PID is the watchdog of sessions/SHORT: its
# command line ends with "terminal.sh watch --session SHORT". A new process
# can get the pid of a watchdog that ended.
watch_is_ours() {
    local command
    positive_integer "${1:-}" || return 1
    command=$(ps -ww -o command= -p "$1" 2>/dev/null) || return 1
    rtrim "$command"
    case "$RTRIM" in *"terminal.sh watch --session $2") return 0 ;; esac
    return 1
}

# watch_stop PID SHORT — stop the watchdog of sessions/SHORT.
watch_stop() {
    watch_is_ours "${1:-}" "${2:-}" || return 0
    kill "$1" 2>/dev/null || true
}

# close_session_dir DIR [WHO] — the close steps for the companion of a
# session owner in DIR (sessions/<short>). WHO is "watchdog" when the
# watchdog calls it: it does not stop itself. WHO is "hook" when the
# SessionEnd hook calls it: a separate process stops the Laya server,
# because the hook has 5 s. The screen, the pane and DIR go first, as in
# close_command. [inferred] clear-history goes only to a pane with the mark.
close_session_dir() {
    D="$1"
    state_load || { rm -rf "$D"; return 0; }
    if companion_pane_is_ours "$S_SOCKET" "$S_PANE"; then
        tmux -S "$S_SOCKET" clear-history -t "$S_PANE" >/dev/null 2>&1 || true
    fi
    kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" 1
    rm -rf "$D"
    [ "${2:-}" = watchdog ] || watch_stop "$S_WATCH_PID" "${D##*/}"
    if [ "${2:-}" = hook ]; then
        laya_stop_server_later "$S_LAYA_PID"
    else
        laya_stop_server "$S_LAYA_PID"
    fi
}

# close_session ID [WHO] — close the companion of the session ID: for the
# hook and for close --session. The state must name the same full id: two
# sessions can have the same first 8 characters.
close_session() {
    resolve_root
    D="$ROOT/sessions/${1:0:8}"
    state_load || return 0
    [ "$S_SESSION" = "$1" ] || return 0
    close_session_dir "$D" "${2:-}"
}
```

Replace the function `close_command` with:

```bash
close_command() {
    local hook=0 owner="" session="" input
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --hook) hook=1; shift ;;
            --owner) [ "$#" -ge 2 ] || usage; owner="$2"; shift 2 ;;
            --session) [ "$#" -ge 2 ] || usage; session="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    # --hook makes this a Claude SessionEnd hook: read stdin and say nothing.
    # With no tmux, the owner is the session of the payload (spec
    # 2026-09-30, section 9). A bad session_id is nothing to do.
    if [ "$hook" -eq 1 ]; then
        input=$(cat)
        if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
            hook_session_id "$input"
            valid_session_id "$HOOK_SESSION_ID" || return 0
            close_session "$HOOK_SESSION_ID" hook
            return 0
        fi
    fi
    # [inferred] close --session ID is for internal use. main runs it before
    # require_owner: the owner comes from the argument and from state.
    if [ -n "$session" ]; then
        valid_session_id "$session" || fail 'invalid Claude session id' 2
        close_session "$session"
        return 0
    fi
    # No require_owner here: main already ran it on the verb path, and the
    # two arms above find their owner their own way.
    # $ROOT needs no tmux, so an absent root answers the whole question before
    # paying for a server-key round trip.
    resolve_root
    [ -d "$ROOT" ] || return 0
    if [ -n "$owner" ]; then
        TMUX_PANE="%${owner#%}"
        OWNER_KIND=pane
    fi
    terminal_init
    state_load || return 0
    if [ "$OWNER_KIND" = session ]; then
        # [inferred] The state of another session: exit 4, touch nothing.
        state_is_ours || fail 'no companion is open for this owner' 4
        close_session_dir "$D"
        return 0
    fi
    # The screen, the pane and $D (with the key) go first: the SessionEnd
    # hook has 5 s, and the server can be slow to stop. In --hook mode a
    # separate process stops the server (kill -9 after 3 s), because $D
    # with the pid is gone and the reaper cannot find it again.
    tmux_state clear-history -t "$S_PANE" >/dev/null 2>&1 || true
    kill_companion "$S_MODE" "$S_PANE" "$S_SOCKET" 1
    rm -rf "$D"
    if [ "$hook" -eq 1 ]; then
        laya_stop_server_later "$S_LAYA_PID"
    else
        laya_stop_server "$S_LAYA_PID"
    fi
}
```

Replace the function `main` with:

```bash
main() {
    [ "$#" -gt 0 ] || usage
    case "$1" in
        check-line) shift; check_line_command "$@"; return $? ;;
        # No require_owner: install and status operate outside tmux too.
        laya) shift; laya_command "$@"; return $? ;;
    esac
    if [ "$1" = close ] && [ "${2:-}" = --hook ]; then
        shift
        ( close_command "$@" ) >/dev/null 2>&1 || true
        return 0
    fi
    # close --session finds its owner from its argument and from state.
    if [ "$1" = close ] && [ "${2:-}" = --session ]; then
        shift
        close_command "$@"
        return $?
    fi
    require_owner
    case "$1" in
        open) shift; open_command "$@" ;;
        run) shift; run_command "$@" ;;
        send) shift; send_command "$@" ;;
        read) shift; read_command "$@" ;;
        wait) shift; wait_command "$@" ;;
        close) shift; close_command "$@" ;;
        list) list_command ;;
        *) usage ;;
    esac
}
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'close --hook with no tmux|close --session needs|watch_stop stops'`. Expect three `ok` lines. Then run `bats test/terminal.bats`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/scripts/terminal.sh test/terminal.bats
git commit -m "feat(clux): close the companion of a session owner from the verb and the SessionEnd hook"
```

**Verification:**
- `bats test/terminal.bats -f 'close'` prints `ok` for each test, with the new `close --hook with no tmux ...` and `close --session needs ...`.
- `bats test/terminal-e2e.bats -f 'close --hook'` prints three `ok` lines: the foreground hook path did not change. [inferred] The three tests are `close removes the pane and the directory, close --hook is silent` and the two later tests whose names hold `close --hook`. [inferred]

## Task 5: Reap the directories of session owners

**Goal:** Add a reaper loop over `$ROOT/sessions/*` that runs for both owner kinds, removes the directory of a dead owner, of a `/clear` left-over and of a pane with no mark, and keeps a young half-made directory (spec section 9, "The reaper").

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Test: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/terminal.bats`, add these tests after the test `watch_stop stops only the watchdog of the same directory`:

```bash
@test "the sessions reaper removes the directory of a dead owner, stops its laya server, and keeps a live one" {
    use_real_ps
    session_tmux_stub
    local root="$BATS_TEST_TMPDIR/root" log="$BATS_TEST_TMPDIR/stub.log" live dead start
    sleep 60 </dev/null >/dev/null 2>&1 3>&- &
    live=$!
    sleep 60 </dev/null >/dev/null 2>&1 3>&- &
    dead=$!
    start=$(ps -o lstart= -p "$live")
    start="${start%"${start##*[![:space:]]}"}"
    mkdir -p "$root/sessions/aaaaaaaa" "$root/sessions/bbbbbbbb"
    printf 'mode=window\npane=%%5\nsocket=/tmp/user.sock\nseq=0\ntoken=ab12cd34\nsession=aaaaaaaa-4567-4890-abcd-ef0123456789\nowner_pid=%s\nowner_start=%s\n' \
        "$live" "$start" > "$root/sessions/aaaaaaaa/state"
    # The first state of open: the owner and the Laya pid, no pane yet.
    printf 'mode=\npane=\nsocket=\nseq=0\nlaya_pid=4242\nsession=bbbbbbbb-4567-4890-abcd-ef0123456789\nowner_pid=%s\nowner_start=x\n' \
        "$dead" > "$root/sessions/bbbbbbbb/state"
    kill "$dead"
    wait "$dead" 2>/dev/null || true
    run env STUB_LOG="$log" STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" TMUX=fake TMUX_PANE=%0 bash -c \
        "source '$TERMINAL'; laya_stop_server() { echo \"stop \$*\"; }; terminal_init; reap_companions"
    kill "$live"
    [ "$status" -eq 0 ]
    [ "$output" = 'stop 4242' ]
    [ -d "$root/sessions/aaaaaaaa" ]
    [ ! -e "$root/sessions/bbbbbbbb" ]
    ! grep -q 'kill-pane\|kill-server' "$log" || false
}

@test "the sessions reaper keeps a young directory with no state and removes an old one, a clear left-over and a pane with no mark" {
    use_real_ps
    session_tmux_stub
    local root="$BATS_TEST_TMPDIR/root" log="$BATS_TEST_TMPDIR/stub.log" s start other other_start
    start=$(ps -o lstart= -p $$)
    start="${start%"${start##*[![:space:]]}"}"
    sleep 60 </dev/null >/dev/null 2>&1 3>&- &
    other=$!
    other_start=$(ps -o lstart= -p "$other")
    other_start="${other_start%"${other_start##*[![:space:]]}"}"
    for s in 11111111 22222222 33333333 44444444 55555555; do mkdir -p "$root/sessions/$s"; done
    # 11111111: no state, young. 22222222: no state, old.
    # 33333333: the process of the caller with another session id (a /clear left-over).
    printf 'mode=window\npane=%%5\nsocket=/tmp/user.sock\nseq=0\ntoken=ab12cd34\nsession=33333333-4567-4890-abcd-ef0123456789\nowner_pid=%s\nowner_start=%s\n' \
        "$$" "$start" > "$root/sessions/33333333/state"
    # 44444444: another live owner, old, and its pane holds another mark.
    printf 'mode=window\npane=%%6\nsocket=/tmp/user.sock\nseq=0\ntoken=cd34ab12\nsession=44444444-4567-4890-abcd-ef0123456789\nowner_pid=%s\nowner_start=%s\n' \
        "$other" "$other_start" > "$root/sessions/44444444/state"
    # 55555555: the companion of the caller.
    printf 'mode=window\npane=%%7\nsocket=/tmp/user.sock\nseq=0\ntoken=ab12cd34\nsession=55555555-4567-4890-abcd-ef0123456789\nowner_pid=%s\nowner_start=%s\n' \
        "$$" "$start" > "$root/sessions/55555555/state"
    touch -t 202601010000 "$root/sessions/22222222" "$root/sessions/44444444"
    run env -u TMUX -u TMUX_PANE STUB_LOG="$log" STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" \
        CLAUDE_CODE_SESSION_ID=55555555-4567-4890-abcd-ef0123456789 CLAUDE_PID=$$ bash -c \
        "source '$TERMINAL'; require_owner; terminal_init; reap_companions"
    kill "$other"
    [ "$status" -eq 0 ]
    [ -d "$root/sessions/11111111" ]
    [ ! -e "$root/sessions/22222222" ]
    [ ! -e "$root/sessions/33333333" ]
    [ ! -e "$root/sessions/44444444" ]
    [ -d "$root/sessions/55555555" ]
    grep -qx 'tmux -S /tmp/user.sock kill-pane -t %5' "$log"
    ! grep -q 'kill-pane -t %6\|kill-pane -t %7\|kill-server\|list-panes' "$log" || false
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'the sessions reaper'`. Expect two `not ok` lines: the output is empty and `bbbbbbbb`, `22222222`, `33333333` and `44444444` stay, because no loop reads `$ROOT/sessions`.
- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/terminal.sh`, add after the line `LAYA_INSTALL_BUDGET=540`:

```bash

# [inferred] A session owner (spec 2026-09-30, section 9): the time that
# open can take. It is more than laya_wait_ready (60 s) and
# wait_for_prompt 5. The sessions reaper keeps a directory with no state,
# or with no pane mark, while it is younger than this: an open can be at
# work in it.
OPEN_BUDGET_DEFAULT=120
```

Add after the function `valid_session_id`:

```bash

# [inferred] The name of a session directory: the first 8 characters of a
# session id.
SHORT_ID_RE='^[0123456789abcdef]{8}$'
valid_short_id() {
    [[ $1 =~ $SHORT_ID_RE ]]
}
```

Replace the function `reap_companions` with:

```bash
reap_companions() {
    local listing
    # [inferred] A session owner does not read the tmux listing and does not
    # reach the directories of pane owners.
    if [ "$OWNER_KIND" != session ]; then
        listing=$(companion_listing)
        [ -z "$listing" ] || reap_pane_dirs "$listing"
    fi
    reap_session_dirs
    stop_reaped_servers
}

# reap_pane_dirs LISTING — the 4.0.0 loop over $ROOT/<server-key>-<pane>.
# _clux_valid_server_key refuses the name "sessions", so this loop skips
# the directories of session owners.
reap_pane_dirs() {
    local listing="$1" dir base server owner pid
    for dir in "$ROOT"/*; do
        [ -d "$dir" ] || continue
        base="${dir##*/}"
        server="${base%-*}"
        owner="${base##*-}"
        _clux_valid_server_key "$server" || continue
        case "$owner" in ''|*[!0-9]*) continue ;; esac
        if [ "$server" = "$SERVER_KEY" ]; then
            listing_has_pane "$listing" "%$owner" || remove_companion_dir "$dir" 1
        else
            # kill -0 is the whole liveness test for a foreign server: had the
            # kernel reused that pid, the start time in the key could not match.
            pid="${server%%-*}"
            kill -0 "$pid" 2>/dev/null || remove_companion_dir "$dir" 0
        fi
    done
}

# reap_session_dirs — the loop over $ROOT/sessions/* (spec 2026-09-30,
# section 9). It needs no tmux listing, so it also runs when the default
# server does not answer. A directory goes when:
#   - its owner process is gone, or has another start time;
#   - the caller is a session owner, the owner process is the process of
#     the caller, but the session id is different: one Claude process runs
#     one session at a time, so this is a companion left from a /clear
#     whose SessionEnd hook did not run;
#   - its pane does not hold the mark (section 8).
# A directory with no state, or with no mark on its pane, stays while it is
# younger than OPEN_BUDGET_DEFAULT. The Laya pid goes to REAP_PIDS, as in
# reap_pane_dirs.
reap_session_dirs() {
    local dir now age
    [ -d "$ROOT/sessions" ] || return 0
    now=$(date +%s)
    for dir in "$ROOT"/sessions/*; do
        [ -d "$dir" ] || continue
        valid_short_id "${dir##*/}" || continue
        age=$((now - $(dir_mtime "$dir")))
        if ! state_load "$dir"; then
            [ "$age" -lt "$OPEN_BUDGET_DEFAULT" ] || rm -rf "$dir"
            continue
        fi
        if ! owner_alive "$S_OWNER_PID" "$S_OWNER_START" \
            || { [ "$OWNER_KIND" = session ] && [ "$S_OWNER_PID" = "$OWNER_PID" ] \
                && [ "$S_OWNER_START" = "$OWNER_START" ] && [ "$S_SESSION" != "$SESSION_ID" ]; } \
            || { [ "$age" -ge "$OPEN_BUDGET_DEFAULT" ] && ! companion_pane_is_ours "$S_SOCKET" "$S_PANE"; }; then
            remove_companion_dir "$dir" 0
            watch_stop "$S_WATCH_PID" "${dir##*/}"
        fi
    done
}

# dir_mtime DIR — the last change of DIR in seconds since the epoch: GNU
# stat, then BSD stat (the method of dismiss-notification.sh). 0 when both
# fail, so the directory counts as old.
dir_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'the sessions reaper|the reaper reads the server key'`. Expect three `ok` lines. Then run `bats test/terminal.bats`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/scripts/terminal.sh test/terminal.bats
git commit -m "feat(clux): reap the companion directories of session owners"
```

**Verification:**
- `bats test/terminal.bats -f 'reaper'` prints `ok` for each test.
- `bats test/terminal-e2e.bats -f 'reaper'` prints `ok`: the pane-owner reaper still stops the server of a pane that is gone.

## Task 6: Open the companion of a session owner in the dashboard session or on a private server

**Goal:** Make `open` of a session owner find the `claude agents` dashboard, open a window in its tmux session (else a private server), write a first `state` before the pane, mark the pane, and print the `window=` or both attach lines (spec sections 7, 9 "Open", 10 and 12).

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Test: `test/terminal.bats`, `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/terminal.bats`, in the test `each failure path of open goes through open_abort`, change `-eq 3 ]` to `-eq 4 ]`. The test is then:

```bash
@test "each failure path of open goes through open_abort" {
    ! grep -q 'rm -rf "$D"; fail' "$TERMINAL" || false
    [ "$(grep -c "open_abort [01] 'cannot open\|open_abort 1 'the companion shell did not reach its prompt' 1" "$TERMINAL")" -eq 4 ]
}
```

In `test/terminal.bats`, add this helper and these tests after the test `open refuses when the CLUX_LAYA_URL server does not answer`:

```bash
# open_session_tmux_stub — tmux for open of a session owner. new-window
# copies STUB_STATE to STUB_STATE_COPY (the state before the pane) and gives
# the pane %7. The window line of report_open gets dash:1.
open_session_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$*" in
    -V) echo 'tmux 3.4' ;;
    *new-window*) cp "$STUB_STATE" "$STUB_STATE_COPY"; echo %7 ;;
    *'#{session_name}:#{window_index}'*) echo dash:1 ;;
esac
exit 0
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

@test "open of a session owner writes state with laya_pid before the pane, then marks a window in the dashboard session" {
    use_real_ps
    open_session_tmux_stub
    local root="$BATS_TEST_TMPDIR/root" log="$BATS_TEST_TMPDIR/stub.log" sid=0123abcd-4567-4890-abcd-ef0123456789 d before token
    d="$root/sessions/0123abcd"
    before="$BATS_TEST_TMPDIR/state.before"
    # The Laya functions are replaced: the pid 4242 is only a record here.
    # watch_start is replaced too: Task 7 starts a watchdog in open.
    run env -u TMUX -u TMUX_PANE -u CLUX_LAYA_URL STUB_LOG="$log" STUB_STATE="$d/state" STUB_STATE_COPY="$before" \
        CLUX_TERMINAL_DIR="$root" CLUX_AGENT_STATE_DIR="$BATS_TEST_TMPDIR/agents" \
        CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PID=$$ bash -c "source '$TERMINAL'
        laya_open_check() { :; }
        laya_start_server() { LAYA_PID=4242 LAYA_URL=http://127.0.0.1:9 LAYA_KEY=k1; }
        laya_wait_ready() { :; }
        wait_for_prompt() { :; }
        watch_start() { :; }
        find_dashboard() { DASH_SERVER=1234-1700000000 DASH_SOCKET=/tmp/user.sock DASH_PANE=%3 DASH_SESSION=dash; }
        require_owner
        open_command"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$output" = $'pane=%7\nmode=window\nwindow=dash:1' ]
    grep -qx 'mode=' "$before"
    grep -qx 'pane=' "$before"
    grep -qx 'laya_pid=4242' "$before"
    grep -qx "session=$sid" "$before"
    grep -qx "owner_pid=$$" "$before"
    grep -q '^owner_start=[A-Z]' "$before"
    grep -qx 'mode=window' "$d/state"
    grep -qx 'pane=%7' "$d/state"
    grep -qx 'socket=/tmp/user.sock' "$d/state"
    grep -qx 'server=1234-1700000000' "$d/state"
    token=$(sed -n 's/^token=//p' "$d/state")
    grep -qF "tmux -S /tmp/user.sock new-window -d -P -F #{pane_id} -t dash: -n clux-terminal 0123abcd -c $PWD -e PATH=" "$log"
    grep -qx 'tmux -S /tmp/user.sock set-option -w -t %7 automatic-rename off' "$log"
    grep -qx "tmux -S /tmp/user.sock set-option -p -t %7 @clux-companion $token" "$log"
    ! grep -q 'split-window\|kill-server\|kill-pane' "$log" || false
}

@test "open exits 2 when another live session with the same first 8 characters owns the directory" {
    use_real_ps
    open_session_tmux_stub
    local root="$BATS_TEST_TMPDIR/root" log="$BATS_TEST_TMPDIR/stub.log" other start
    sleep 60 </dev/null >/dev/null 2>&1 3>&- &
    other=$!
    start=$(ps -o lstart= -p "$other")
    start="${start%"${start##*[![:space:]]}"}"
    mkdir -p "$root/sessions/0123abcd"
    printf 'mode=window\npane=%%5\nsocket=/tmp/user.sock\nseq=0\ntoken=ab12cd34\nsession=0123abcd-9999-4890-abcd-ef0123456789\nowner_pid=%s\nowner_start=%s\n' \
        "$other" "$start" > "$root/sessions/0123abcd/state"
    # No Laya (XDG_DATA_HOME has no venv): the check of the owner comes first.
    run env -u TMUX -u TMUX_PANE -u CLUX_LAYA_URL STUB_LOG="$log" CLUX_TERMINAL_DIR="$root" \
        XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" CLUX_AGENT_STATE_DIR="$BATS_TEST_TMPDIR/agents" \
        CLAUDE_CODE_SESSION_ID=0123abcd-4567-4890-abcd-ef0123456789 CLAUDE_PID=$$ "$TERMINAL" open
    kill "$other"
    [ "$status" -eq 2 ]
    [ "$output" = 'the companion directory belongs to another session' ]
    grep -q '^session=0123abcd-9999' "$root/sessions/0123abcd/state"
    ! grep -q 'new-window\|new-session\|kill-pane' "$log" || false
}
```

In `test/terminal-e2e.bats`, replace the function `teardown` with:

```bash
teardown() {
    local sock
    stop_fake_laya
    for sock in "$CLUX_TERMINAL_DIR"/*/sock "$CLUX_TERMINAL_DIR"/sessions/*/sock; do
        [ -S "$sock" ] && "$REAL_TMUX" -S "$sock" kill-server >/dev/null 2>&1 || true
    done
    # bg_setup: the default server of the test and the owner process.
    # An empty bg-tmpdir would name the default server of the user: skip it.
    if [ -s "$BATS_TEST_TMPDIR/bg-tmpdir" ] && [ -n "$(cat "$BATS_TEST_TMPDIR/bg-tmpdir")" ]; then
        env -u TMUX TMUX_TMPDIR="$(cat "$BATS_TEST_TMPDIR/bg-tmpdir")" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
        rm -rf "$(cat "$BATS_TEST_TMPDIR/bg-tmpdir")"
    fi
    [ ! -f "$BATS_TEST_TMPDIR/bg-owner" ] || kill "$(cat "$BATS_TEST_TMPDIR/bg-owner")" 2>/dev/null || true
    "$REAL_TMUX" -S "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "$CLUX_TERMINAL_DIR" "$BATS_TEST_TMPDIR"
}
```

In `test/terminal-e2e.bats`, add these helpers after the function `pane_shows`:

```bash
# bg_setup — a background Claude session: no TMUX and no TMUX_PANE, a
# session id, and an owner process (a sleep of the test). TMUX_TMPDIR makes
# the default tmux server a test server, with the dashboard session "dash".
bg_setup() {
    local raw
    unset TMUX TMUX_PANE CLUX_SESSION_ID
    export TMUX_TMPDIR
    raw=$(mktemp -d /tmp/ctt.XXXX)
    [ -n "$raw" ] && [ -d "$raw" ] || { echo 'bg_setup: no test tmux directory'; return 1; }
    # tmux resolves TMUX_TMPDIR with realpath. On macOS /tmp is a link to
    # /private/tmp, so the guard below needs the resolved path, as the
    # prototype does (test.sh, pwd -P). [inferred] The cd is a separate step:
    # with an empty mktemp result, cd would stay in the current directory.
    TMUX_TMPDIR=$(cd "$raw" && pwd -P) && [ -n "$TMUX_TMPDIR" ] && [ -d "$TMUX_TMPDIR" ] \
        || { echo 'bg_setup: no test tmux directory'; return 1; }
    printf '%s\n' "$TMUX_TMPDIR" > "$BATS_TEST_TMPDIR/bg-tmpdir"
    export CLUX_AGENT_STATE_DIR="$BATS_TEST_TMPDIR/agents"
    export CLAUDE_CODE_SESSION_ID=0123abcd-4567-4890-abcd-ef0123456789
    sleep 600 </dev/null >/dev/null 2>&1 3>&- &
    export CLAUDE_PID=$!
    printf '%s\n' "$CLAUDE_PID" > "$BATS_TEST_TMPDIR/bg-owner"
    "$REAL_TMUX" -f /dev/null new-session -d -s dash -x 120 -y 40 3>&-
    # The isolation guard of the prototype: the default server must be the
    # test server. Test 4 stops the default server; it must never be the
    # server of the user.
    case "$("$REAL_TMUX" display-message -p '#{socket_path}')" in
        "$TMUX_TMPDIR"/*) ;;
        *) echo 'bg_setup: the default tmux server is not the test server'; return 1 ;;
    esac
    BG_DASH_PANE=$("$REAL_TMUX" list-panes -t dash -F '#{pane_id}')
    BG_DASH_KEY=$("$REAL_TMUX" display-message -p '#{pid}-#{start_time}')
}

# bg_add_cache — the agent-state file that maps the session to the
# dashboard pane, as hooks/agent-state.sh writes it at the first prompt.
bg_add_cache() {
    local sid="${CLUX_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"
    mkdir -p "$CLUX_AGENT_STATE_DIR/$BG_DASH_KEY/agents"
    : > "$CLUX_AGENT_STATE_DIR/$BG_DASH_KEY/agents/$BG_DASH_PANE~$sid"
}

# bg_dir — the private directory of the session owner of the test.
bg_dir() {
    local sid="${CLUX_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"
    printf '%s' "$CLUX_TERMINAL_DIR/sessions/${sid:0:8}"
}

# bg_window_count — the number of windows in the dashboard session.
bg_window_count() {
    "$REAL_TMUX" list-windows -t dash | wc -l | tr -d ' '
}
```

At the end of `test/terminal-e2e.bats`, add:

```bash
# Background 1
@test "a background session opens a window in the dashboard session and closes it" {
    bg_setup
    bg_add_cache
    local want
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *$'\nmode=window\nwindow=dash:1' ]] || false
    [ "$("$REAL_TMUX" list-windows -t dash -F '#{window_name}' | tail -1)" = 'clux-terminal 0123abcd' ]
    run "$TERMINAL" run -- 'echo hi'
    [ "$status" -eq 0 ]
    [[ "$output" == *$'hi\nexit=0' ]] || false
    want=$(pwd -P)
    run "$TERMINAL" run -- 'pwd -P'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$want"$'\nexit=0' ]] || false
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ ! -e "$(bg_dir)" ]
    [ "$(bg_window_count)" = 1 ]
}

# Background 2
@test "a background session with no dashboard opens a private server and prints both attach lines" {
    bg_setup
    local sock
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    sock="$(bg_dir)/sock"
    [[ "$output" == *$'\nmode=socket\nattach=tmux -S '"$sock"$' attach\nattach_in_tmux=TMUX= tmux -S '"$sock"' attach' ]] || false
    run "$TERMINAL" run -- 'echo sock-ok'
    [[ "$output" == *$'sock-ok\nexit=0' ]] || false
    [ "$(bg_window_count)" = 1 ]
    "$TERMINAL" close
    ! "$REAL_TMUX" -S "$sock" list-sessions >/dev/null 2>&1 || false
}

# Background 4
@test "after a restart of the tmux server, a stale pane id reaches no pane of the user" {
    bg_setup
    bg_add_cache
    local d stale i=0
    "$TERMINAL" open >/dev/null
    d=$(bg_dir)
    stale=$(sed -n 's/^pane=//p' "$d/state")
    # Stop the watchdog, so that only the verbs of the test act on $d.
    # [inferred] This matters only from Task 7, which starts the watchdog.
    [ -z "$(sed -n 's/^watch_pid=//p' "$d/state")" ] || kill "$(sed -n 's/^watch_pid=//p' "$d/state")"
    "$REAL_TMUX" kill-server
    sleep .5
    "$REAL_TMUX" -f /dev/null new-session -d -s user -x 120 -y 40 'bash --noprofile --norc -i' 3>&-
    while ! "$REAL_TMUX" list-panes -t "$stale" >/dev/null 2>&1 && [ "$i" -lt 8 ]; do
        "$REAL_TMUX" split-window -d -t user 'bash --noprofile --norc -i' 3>&- 2>/dev/null \
            || "$REAL_TMUX" new-window -d -t user 'bash --noprofile --norc -i' 3>&-
        i=$((i + 1))
    done
    "$REAL_TMUX" list-panes -t "$stale" >/dev/null
    # History in the pane of the user, so that a clear-history would show.
    "$REAL_TMUX" send-keys -t "$stale" 'seq 1 100' Enter
    i=0
    while [ "$("$REAL_TMUX" display-message -p -t "$stale" '#{history_size}')" -eq 0 ] && [ "$i" -lt 25 ]; do
        sleep .2
        i=$((i + 1))
    done
    run "$TERMINAL" run -- 'echo SHOULD-NOT-TYPE'
    [ "$status" -eq 4 ]
    ! "$REAL_TMUX" capture-pane -p -t "$stale" | grep -q SHOULD-NOT-TYPE || false
    run "$TERMINAL" close
    [ "$status" -eq 0 ]
    [ ! -e "$d" ]
    "$REAL_TMUX" list-panes -t "$stale" >/dev/null
    [ "$("$REAL_TMUX" display-message -p -t "$stale" '#{history_size}')" -gt 0 ]
}

# Background 5
@test "after a clear with no hook, open under the new session id closes the old companion" {
    bg_setup
    bg_add_cache
    local old
    "$TERMINAL" open >/dev/null
    old=$(bg_dir)
    export CLUX_SESSION_ID=fedcba98-4567-4890-abcd-ef0123456789
    run "$TERMINAL" run -- 'echo x'
    [ "$status" -eq 4 ]
    [ -d "$old" ]
    bg_add_cache
    run "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ ! -e "$old" ]
    [ -d "$(bg_dir)" ]
    [ "$("$REAL_TMUX" list-windows -t dash -F '#{window_name}' | grep -c '^clux-terminal 0123abcd$')" = 0 ]
    [ "$("$REAL_TMUX" list-windows -t dash -F '#{window_name}' | grep -c '^clux-terminal fedcba98$')" = 1 ]
    "$TERMINAL" close
}

# Background 6
@test "the directory and the exported variables stay between runs in window mode" {
    bg_setup
    bg_add_cache
    run "$TERMINAL" open
    [[ "$output" == *'mode=window'* ]] || false
    "$TERMINAL" run -- 'cd /tmp' >/dev/null
    "$TERMINAL" run -- 'export X=1' >/dev/null
    run "$TERMINAL" run -- 'pwd; echo $X'
    [[ "$output" == *$'/tmp\n1\nexit=0' ]] || false
    "$TERMINAL" close
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'each failure path of open|open of a session owner|another live session'`. Expect three `not ok` lines: the `open_abort` count is 3; the open test prints `mode=split`; the other-session test exits 6 with `laya not installed: run terminal.sh laya install`. Then run `bats test/terminal-e2e.bats -f 'background session|stale pane id|clear with no hook|in window mode'`. Expect five `not ok` lines: `open` of a session owner does not give `mode=window` or `mode=socket`.
- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/terminal.sh`, add these lines directly above the function `open_command`:

```bash
# find_dashboard — the pane of the `claude agents` dashboard that owns this
# session, on the default tmux server (spec 2026-09-30, section 7). Sets
# DASH_SERVER, DASH_SOCKET, DASH_PANE and DASH_SESSION. Fails when the
# default server does not answer or no dashboard pane is found: open then
# uses socket mode. A session owner needs no server key, so a server that
# does not answer is not an error here.
DASH_SERVER=
DASH_SOCKET=
DASH_PANE=
DASH_SESSION=
find_dashboard() {
    local info file found sessions
    DASH_SERVER= DASH_SOCKET= DASH_PANE= DASH_SESSION=
    info=$(tmux display-message -p '#{pid}-#{start_time} #{socket_path}' 2>/dev/null) || return 1
    DASH_SERVER="${info%% *}"
    DASH_SOCKET="${info#* }"
    _clux_valid_server_key "$DASH_SERVER" && [ -n "$DASH_SOCKET" ] || return 1
    # hooks/agent-state.sh writes agents/<pane>~<session id> at the first
    # prompt, so the file is there before the first Bash call.
    for file in "$(resolve_agent_state_dir)/$DASH_SERVER/agents/"*"~$SESSION_ID"; do
        [ -e "$file" ] || continue
        found="${file##*/}"
        DASH_PANE="${found%%'~'*}"
        break
    done
    if [ -z "$DASH_PANE" ]; then
        found=$(resolve_agents_pane_by_cwd "$PWD")
        DASH_PANE="${found##* }"
    fi
    [ -n "$DASH_PANE" ] || return 1
    # [inferred] list-panes, not display-message: display-message -p can exit
    # 0 for a pane that is gone.
    sessions=$(tmux -S "$DASH_SOCKET" list-panes -t "$DASH_PANE" -F '#{session_id}' 2>/dev/null) || return 1
    DASH_SESSION="${sessions%%$'\n'*}"
    [ -n "$DASH_SESSION" ]
}
```

Replace the function `open_command` with:

```bash
open_command() {
    local mode=split size=30% socket pane shell
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --socket) mode=socket; shift ;;
            --size) [ "$#" -ge 2 ] || usage; size="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    case "$size" in
        [1-9]%|[1-9][0-9]%|100%) ;;
        *) fail 'size must be N%' 2 ;;
    esac
    terminal_init
    check_tmux_version
    mkdir -p "$ROOT"; chmod 700 "$ROOT"
    if [ "$OWNER_KIND" = session ]; then
        mkdir -p "$ROOT/sessions"; chmod 700 "$ROOT/sessions"
    fi
    reap_companions
    if current_companion_alive; then
        laya_restart_if_down || return
        report_open
        return
    fi
    # [inferred] Two sessions can have the same first 8 characters (spec
    # 2026-09-30, section 6). The directory of another live session stays.
    if [ "$OWNER_KIND" = session ] && state_load && ! state_is_ours \
        && owner_alive "$S_OWNER_PID" "$S_OWNER_START"; then
        fail 'the companion directory belongs to another session' 2
    fi
    laya_open_check
    # [inferred] A dead companion of this owner can still own a Laya server,
    # so its directory goes through remove_companion_dir, not rm -rf.
    if [ -d "$D" ]; then
        remove_companion_dir "$D" 0
        [ "$OWNER_KIND" != session ] || watch_stop "$S_WATCH_PID" "${D##*/}"
        stop_reaped_servers
    fi
    umask 077; mkdir -p "$D"
    # The fields of a session owner (spec 2026-09-30, section 6). The old
    # state can have set them, so each one gets its value here.
    S_SESSION=; S_OWNER_PID=; S_OWNER_START=; S_SERVER=; S_WATCH_PID=
    if [ "$OWNER_KIND" = session ]; then
        S_SESSION="$SESSION_ID"
        S_OWNER_PID="$OWNER_PID"
        S_OWNER_START="$OWNER_START"
        # Placement (section 7): a window in the tmux session of the
        # dashboard, else a private server. --socket forces the private
        # server. [inferred] --size does not apply and gives no error.
        if [ "$mode" != socket ] && find_dashboard; then
            mode=window
        else
            mode=socket
        fi
    fi
    # The prompt has a random token, so output text that shows clux$ is not
    # the prompt (spec section 9).
    S_TOKEN=$(random_hex 4) || S_TOKEN=
    [ "${#S_TOKEN}" -eq 8 ] || S_TOKEN=$(printf '%04x%04x' "$RANDOM" "$RANDOM")
    PROMPT_MARK="clux-$S_TOKEN\$"
    CONT_MARK="clux-$S_TOKEN> "
    write_rc_file
    socket="$D/sock"
    if [ "$mode" = socket ] && [ "${#socket}" -gt 100 ]; then
        rm -rf "$D"
        fail 'the private tmux socket path is longer than 100 bytes' 2
    fi
    LAYA_PID=
    LAYA_URL="${CLUX_LAYA_URL:-}"
    LAYA_KEY="${CLUX_LAYA_KEY:-}"
    if [ -z "$LAYA_URL" ]; then
        : > "$D/laya.log"
        laya_start_server "$D/laya.log" 1 || open_abort 0 'laya not available: the server did not start'
    fi
    # [inferred] A session owner writes a first state before the pane: a
    # directory with a Laya server always has a record of its pid and its
    # owner, also when open stops early, so the reaper can stop the server.
    [ "$OWNER_KIND" != session ] || write_state "" "" "" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
    printf -v shell '%q --noprofile --rcfile %q -i' "$(command -v bash)" "$D/rc.bash"
    # [inferred] A pane or prompt failure keeps exit code 1, as in 3.9.0.
    case "$mode" in
        window)
            # -d keeps the focus of the user where it is. [inferred] -c: the
            # shell starts in the directory of the Bash call, as in socket mode.
            pane=$(tmux -S "$DASH_SOCKET" new-window -d -P -F '#{pane_id}' -t "$DASH_SESSION:" \
                -n "clux-terminal ${D##*/}" -c "$PWD" \
                -e "PATH=$PATH" -e BASH_SILENCE_DEPRECATION_WARNING=1 "$shell" 3>&-) \
                || open_abort 0 'cannot open companion' 1
            S_SERVER="$DASH_SERVER"
            write_state window "$pane" "$DASH_SOCKET" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
            # [inferred] The clux window rename must not change the name.
            tmux_state set-option -w -t "$pane" automatic-rename off >/dev/null 2>&1 || true
            ;;
        socket)
            pane=$(tmux -S "$socket" -f /dev/null new-session -d -P -F '#{pane_id}' -s clux-terminal \
                -e "PATH=$PATH" -e BASH_SILENCE_DEPRECATION_WARNING=1 "$shell" 3>&-) \
                || open_abort 0 'cannot open private companion' 1
            write_state socket "$pane" "$socket" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
            ;;
        *)
            pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$TMUX_PANE" -v -l "$size" \
                -e "PATH=$PATH" -e BASH_SILENCE_DEPRECATION_WARNING=1 "$shell" 3>&-) \
                || open_abort 0 'cannot open companion' 1
            write_state split "$pane" "" 0 "$LAYA_PID" "$LAYA_URL" "$LAYA_KEY"
            ;;
    esac
    # The mark of a session owner (section 8): the verbs and the reaper take
    # a pane with no mark as gone.
    if [ "$OWNER_KIND" = session ] \
        && ! tmux_state set-option -p -t "$pane" @clux-companion "$S_TOKEN" >/dev/null 2>&1; then
        # [inferred] The window arm of kill_companion kills only a pane with
        # the mark, so this pane goes here.
        [ "$S_MODE" != window ] || tmux_state kill-pane -t "$pane" >/dev/null 2>&1
        open_abort 1 'cannot mark the companion pane' 1
    fi
    tmux_state select-pane -t "$pane" -T clux-terminal
    if [ -n "$S_LAYA_PID" ]; then
        laya_wait_ready || open_abort 1 'laya not available: the server did not answer'
    fi
    wait_for_prompt 5 || open_abort 1 'the companion shell did not reach its prompt' 1
    report_open
}
```

Replace the function `report_open` with:

```bash
report_open() {
    echo "pane=$S_PANE"
    echo "mode=$S_MODE"
    case "$S_MODE" in
        socket)
            echo "attach=tmux -S $S_SOCKET attach"
            # tmux refuses an attach from inside tmux when TMUX is set.
            echo "attach_in_tmux=TMUX= tmux -S $S_SOCKET attach"
            ;;
        window)
            echo "window=$(tmux_state display-message -p -t "$S_PANE" '#{session_name}:#{window_index}' 2>/dev/null)"
            ;;
    esac
}
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'each failure path of open|open of a session owner|another live session'`. Expect three `ok` lines. Run `bats test/terminal-e2e.bats -f 'background session|stale pane id|clear with no hook|in window mode'`. Expect five `ok` lines with no `# skip`. Then run `bats test/terminal.bats test/terminal-e2e.bats`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/scripts/terminal.sh test/terminal.bats test/terminal-e2e.bats
git commit -m "feat(clux): open the companion of a background session in the dashboard session or on a private server"
```

**Verification:**
- `bats test/terminal-e2e.bats -f 'Background|background|stale pane id|clear with no hook|in window mode'` prints five `ok` lines.
- `bats test/terminal-e2e.bats -f 'split pane|socket mode opens a private server'` prints two `ok` lines: the pane-owner `open` did not change, and the socket-mode output of a pane owner has the new `attach_in_tmux=` line. [inferred]
- After the run, `ls -d /tmp/ctt.* 2>/dev/null | wc -l` prints `0`: teardown removed each test tmux directory.

## Task 7: Close a background companion when the session process ends

**Goal:** Add the hidden verb `watch --session <short>`, start it from `open` with `nohup`, and start it again when `open` finds it gone (spec section 9, "The watchdog").

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Test: `test/terminal.bats`, `test/terminal-e2e.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/terminal.bats`, add these tests after the test `open exits 2 when another live session with the same first 8 characters owns the directory`:

```bash
@test "the watchdog closes the companion when its owner is gone, and exits when a newer watchdog owns the directory" {
    use_real_ps
    session_tmux_stub
    local root="$BATS_TEST_TMPDIR/root" log="$BATS_TEST_TMPDIR/stub.log" dead
    sleep 60 </dev/null >/dev/null 2>&1 3>&- &
    dead=$!
    kill "$dead"
    wait "$dead" 2>/dev/null || true
    mkdir -p "$root/sessions/aaaaaaaa" "$root/sessions/bbbbbbbb"
    # aaaaaaaa: another watchdog (pid 1) owns it.
    printf 'mode=window\npane=%%5\nsocket=/tmp/user.sock\nseq=0\ntoken=ab12cd34\nowner_pid=%s\nowner_start=x\nwatch_pid=1\n' \
        "$dead" > "$root/sessions/aaaaaaaa/state"
    # bbbbbbbb: this watchdog owns it, and its owner is gone. The subshell
    # has the $$ of its parent, so watch_pid=$$ names the watchdog.
    run env STUB_LOG="$log" STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" bash -c "source '$TERMINAL'
        WATCH_INTERVAL=0
        laya_stop_server() { echo \"stop \$*\"; }
        ( watch_command --session aaaaaaaa ); echo \"a=\$?\"
        D='$root/sessions/bbbbbbbb' S_TOKEN=ab12cd34 S_OWNER_PID=$dead S_OWNER_START=x S_WATCH_PID=\$\$
        write_state window %6 /tmp/user.sock 0 4242 '' ''
        ( watch_command --session bbbbbbbb ); echo \"b=\$?\""
    [ "$status" -eq 0 ]
    [ "$output" = $'a=0\nstop 4242\nb=0' ]
    [ -d "$root/sessions/aaaaaaaa" ]
    [ ! -e "$root/sessions/bbbbbbbb" ]
    grep -qx 'tmux -S /tmp/user.sock kill-pane -t %6' "$log"
    ! grep -q 'kill-pane -t %5' "$log" || false
}

@test "watch_ensure starts one watchdog with nohup and keeps the seq" {
    use_real_ps
    local d="$BATS_TEST_TMPDIR/root/sessions/abcdef01" first
    mkdir -p "$d"
    # CLUX_TERMINAL_DIR: the watchdog reads the state of this test, not of
    # the user.
    run env CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" bash -c "source '$TERMINAL'; D='$d'; OWNER_KIND=session
        write_state window %5 /tmp/user.sock 3
        watch_ensure
        state_load
        echo \"\$S_WATCH_PID \$S_SEQ\"
        sleep .5
        watch_ensure
        state_load
        echo \"\$S_WATCH_PID\""
    [ "$status" -eq 0 ]
    first="${lines[0]% *}"
    [ "${lines[0]#* }" = 3 ]
    [ "${lines[1]}" = "$first" ]
    ps -ww -o command= -p "$first" | grep -q 'terminal.sh watch --session abcdef01'
    [ ! -e "$d/typing" ]
    kill "$first"
}

@test "watch_ensure fails, keeps state and frees the lock when the watchdog cannot start" {
    use_real_ps
    local d="$BATS_TEST_TMPDIR/root/sessions/abcdef01"
    mkdir -p "$d"
    run env CLUX_TERMINAL_DIR="$BATS_TEST_TMPDIR/root" bash -c "source '$TERMINAL'; D='$d'; OWNER_KIND=session
        write_state window %5 /tmp/user.sock 3
        SCRIPT_DIR='$BATS_TEST_TMPDIR/no-such-dir'
        watch_ensure; echo \"rc=\$?\"
        state_load
        echo \"[\$S_WATCH_PID] \$S_SEQ\""
    [ "$status" -eq 0 ]
    [ "$output" = $'rc=1\n[] 3' ]
    [ ! -e "$d/typing" ]
    # open tells the user and keeps the live companion, or undoes a new one.
    grep -qF "fail 'cannot start the companion watchdog' 1" "$TERMINAL"
    grep -qF "open_abort 1 'cannot start the companion watchdog' 1" "$TERMINAL"
}

@test "watch refuses a name that is not 8 hex characters" {
    run "$TERMINAL" watch --session ../x
    [ "$status" -eq 2 ]
    [ "$output" = 'invalid Claude session id' ]
    run "$TERMINAL" watch
    [ "$status" -eq 2 ]
}
```

At the end of `test/terminal-e2e.bats`, add:

```bash
@test "open starts a watchdog for a background companion, open starts it again when it is gone, and close stops it" {
    bg_setup
    bg_add_cache
    local d watch new i=0
    "$TERMINAL" open >/dev/null
    d=$(bg_dir)
    watch=$(sed -n 's/^watch_pid=//p' "$d/state")
    [ -n "$watch" ]
    ps -ww -o command= -p "$watch" | grep -q 'terminal.sh watch --session 0123abcd'
    "$TERMINAL" open >/dev/null
    [ "$(sed -n 's/^watch_pid=//p' "$d/state")" = "$watch" ]
    kill "$watch"
    while kill -0 "$watch" 2>/dev/null && [ "$i" -lt 25 ]; do sleep .2; i=$((i + 1)); done
    "$TERMINAL" open >/dev/null
    new=$(sed -n 's/^watch_pid=//p' "$d/state")
    [ -n "$new" ]
    [ "$new" != "$watch" ]
    kill -0 "$new"
    "$TERMINAL" close
    i=0
    while kill -0 "$new" 2>/dev/null && [ "$i" -lt 25 ]; do sleep .2; i=$((i + 1)); done
    ! kill -0 "$new" 2>/dev/null || false
}

# Background 3
@test "the watchdog closes a background companion and stops its laya server when the owner process ends" {
    bg_setup
    bg_add_cache
    local data="$BATS_TEST_TMPDIR/data" d pid i=0
    make_fake_venv "$data/clux/laya"
    make_fake_checkpoint "$BATS_TEST_TMPDIR/hf"
    run env CLUX_LAYA_URL= CLUX_LAYA_KEY= XDG_DATA_HOME="$data" HF_HUB_CACHE="$BATS_TEST_TMPDIR/hf" \
        "$TERMINAL" open
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    d=$(bg_dir)
    pid=$(sed -n 's/^laya_pid=//p' "$d/state")
    [ -n "$pid" ]
    kill -0 "$pid"
    kill "$CLAUDE_PID"
    wait "$CLAUDE_PID" 2>/dev/null || true
    while [ -e "$d" ] && [ "$i" -lt 75 ]; do sleep .2; i=$((i + 1)); done
    [ ! -e "$d" ] || { echo 'the directory stayed'; false; }
    [ "$(bg_window_count)" = 1 ] || { echo 'the window stayed'; false; }
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 25 ]; do sleep .2; i=$((i + 1)); done
    ! kill -0 "$pid" 2>/dev/null || { kill -9 "$pid"; echo 'the laya server stayed'; false; }
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'the watchdog closes|watch_ensure starts|watch_ensure fails|watch refuses'`. Expect four `not ok` lines: `watch_command: command not found`, `watch_ensure: command not found` (two tests), and status 2 with `clux terminal must run inside tmux or in a Claude Code session` for `watch`. Run `bats test/terminal-e2e.bats -f 'open starts a watchdog|the watchdog closes'`. Expect two `not ok` lines: `state` has no `watch_pid`, and the directory stays after the owner ends.
- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/terminal.sh`, add after the line `OPEN_BUDGET_DEFAULT=120`:

```bash
# The pause of the watchdog of a session owner (spec 2026-09-30, section 9).
WATCH_INTERVAL=10
```

Add these functions after the function `close_session`:

```bash
# watch_start — start the watchdog of this directory and write its pid to
# state. nohup, stdin and stdout to /dev/null and fd 3 closed: the end of
# the Bash call does not stop it. [inferred] SCRIPT_DIR can be relative,
# so the watchdog gets the absolute path. [inferred] It returns 1, with no
# change to state, when the script directory is not known. Otherwise it
# returns the status of write_state. [inferred] It prints nothing when the
# directory is not known: the callers print the message. [inferred]
watch_start() {
    local dir
    dir=$(cd "$SCRIPT_DIR" 2>/dev/null && pwd) || return 1
    nohup "$BASH" "$dir/terminal.sh" watch --session "${D##*/}" < /dev/null > /dev/null 2>&1 3>&- &
    S_WATCH_PID=$!
    write_state "$S_MODE" "$S_PANE" "$S_SOCKET" "$S_SEQ"
}

# watch_ensure — for a session owner, start the watchdog when the one in
# state is not alive (spec 2026-09-30, section 9). [inferred] The typing
# lock, then the state again: no run writes its seq at the same time.
# [inferred] The status is 5 when the lock is not free, 1 when watch_start
# fails, and 0 otherwise. The lock is released in each path. A companion with
# no watchdog can stay after a crash of the session (spec section 13), so the
# callers do not ignore status 1. [inferred]
watch_ensure() {
    local rc=0
    [ "$OWNER_KIND" = session ] || return 0
    ! watch_is_ours "$S_WATCH_PID" "${D##*/}" || return 0
    lock_and_load || return 5
    watch_is_ours "$S_WATCH_PID" "${D##*/}" || watch_start || rc=1
    release_typing_lock
    return "$rc"
}

# watch_command --session SHORT — the hidden watchdog of sessions/SHORT.
# Each WATCH_INTERVAL seconds it reads state (a whole file: write_state
# renames it). No state, or another watch_pid: a close or a new open came
# first, so it exits. When the owner process is gone or has another start
# time, it runs the close steps for its directory, then exits. It never
# reads the Laya key. It does not use require_owner: the owner is gone.
watch_command() {
    local short dir
    [ "$#" -eq 2 ] && [ "$1" = --session ] || usage
    short="$2"
    valid_short_id "$short" || fail 'invalid Claude session id' 2
    trap '' HUP INT
    resolve_root
    dir="$ROOT/sessions/$short"
    while sleep "$WATCH_INTERVAL"; do
        state_load "$dir" || exit 0
        [ "$S_WATCH_PID" = "$$" ] || exit 0
        owner_alive "$S_OWNER_PID" "$S_OWNER_START" && continue
        close_session_dir "$dir" watchdog
        exit 0
    done
}
```

In the function `open_command`, replace:

```bash
    if current_companion_alive; then
        laya_restart_if_down || return
        report_open
        return
    fi
```

with:

```bash
    if current_companion_alive; then
        laya_restart_if_down || return
        # [inferred] The companion is alive and stays. With no watchdog, open
        # says so and exits 1; the next open tries again. [inferred]
        watch_ensure || { [ "$?" -eq 5 ] && return 5; fail 'cannot start the companion watchdog' 1; }
        report_open
        return
    fi
```

In the function `open_command`, replace:

```bash
    wait_for_prompt 5 || open_abort 1 'the companion shell did not reach its prompt' 1
    report_open
}
```

with:

```bash
    wait_for_prompt 5 || open_abort 1 'the companion shell did not reach its prompt' 1
    # The watchdog of a session owner (spec 2026-09-30, section 9).
    # [inferred] A new companion with no watchdog is not safe: open undoes it
    # and exits 1, as for the other failures of a new companion. [inferred]
    watch_ensure || open_abort 1 'cannot start the companion watchdog' 1
    report_open
}
```

Replace the function `main` with:

```bash
main() {
    [ "$#" -gt 0 ] || usage
    case "$1" in
        check-line) shift; check_line_command "$@"; return $? ;;
        # No require_owner: install and status operate outside tmux too.
        laya) shift; laya_command "$@"; return $? ;;
        # The hidden verbs find the owner from their arguments and from
        # state, not from CLAUDE_PID (spec 2026-09-30, section 5).
        watch) shift; watch_command "$@"; return $? ;;
    esac
    if [ "$1" = close ] && [ "${2:-}" = --hook ]; then
        shift
        ( close_command "$@" ) >/dev/null 2>&1 || true
        return 0
    fi
    # close --session finds its owner from its argument and from state.
    if [ "$1" = close ] && [ "${2:-}" = --session ]; then
        shift
        close_command "$@"
        return $?
    fi
    require_owner
    case "$1" in
        open) shift; open_command "$@" ;;
        run) shift; run_command "$@" ;;
        send) shift; send_command "$@" ;;
        read) shift; read_command "$@" ;;
        wait) shift; wait_command "$@" ;;
        close) shift; close_command "$@" ;;
        list) list_command ;;
        *) usage ;;
    esac
}
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'the watchdog closes|watch_ensure starts|watch_ensure fails|watch refuses|open of a session owner'`. Expect five `ok` lines. Run `bats test/terminal-e2e.bats -f 'open starts a watchdog|the watchdog closes'`. Expect two `ok` lines with no `# skip` (the second takes about 10 to 15 seconds). Then run `bats test/terminal.bats test/terminal-e2e.bats`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/scripts/terminal.sh test/terminal.bats test/terminal-e2e.bats
git commit -m "feat(clux): close a background companion when its session process ends"
```

**Verification:**
- `bats test/terminal-e2e.bats -f 'watchdog'` prints two `ok` lines.
- About 15 seconds after the e2e run, `pgrep -f 'terminal.sh watch --session' | wc -l` prints `0` (unless a real Claude session on this machine has a background companion).
- `grep -c '^ *nohup ' plugins/clux/scripts/terminal.sh` prints `2` (the code lines of laya-serve and of the watchdog; comments do not count).

## Task 8: Write the session ID to the environment of the session from the SessionStart hook

**Goal:** Add the hidden verb `session-env --hook`, which writes `export CLUX_SESSION_ID=<id>` to `CLAUDE_ENV_FILE`, and run it from the `SessionStart` hook (spec sections 5 and 15).

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Modify: `plugins/clux/hooks/hooks.json`
- Test: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/terminal.bats`, add these tests after the test `watch refuses a name that is not 8 hex characters`:

```bash
@test "session-env --hook appends the session id to CLAUDE_ENV_FILE and prints nothing" {
    local env_file="$BATS_TEST_TMPDIR/env" sid=0123abcd-4567-4890-abcd-ef0123456789
    printf 'export OTHER=1\n' > "$env_file"
    run env -u TMUX -u TMUX_PANE CLAUDE_ENV_FILE="$env_file" bash -c \
        "printf '{\"session_id\":\"$sid\",\"source\":\"startup\"}' | '$TERMINAL' session-env --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$env_file")" = "export OTHER=1"$'\n'"export CLUX_SESSION_ID=$sid" ]
    # A bad id writes nothing.
    run env -u TMUX -u TMUX_PANE CLAUDE_ENV_FILE="$env_file" bash -c \
        "printf '{\"session_id\":\"../../x\"}' | '$TERMINAL' session-env --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(wc -l < "$env_file" | tr -d ' ')" = 2 ]
    # No CLAUDE_ENV_FILE: nothing to do.
    run env -u TMUX -u TMUX_PANE -u CLAUDE_ENV_FILE bash -c \
        "printf '{\"session_id\":\"$sid\"}' | '$TERMINAL' session-env --hook"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the SessionStart hook runs session-env after the agent-state remove" {
    run python3 -c 'import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"]
print("\n".join(h["command"] + " " + str(h["timeout"]) for h in hooks))' "$REPO_ROOT/plugins/clux/hooks/hooks.json"
    [ "$status" -eq 0 ]
    [ "$output" = $'${CLAUDE_PLUGIN_ROOT}/hooks/agent-state.sh remove 5\n${CLAUDE_PLUGIN_ROOT}/scripts/terminal.sh session-env --hook 5' ]
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'session-env'`. Expect two `not ok` lines: `session-env` exits 2 with `clux terminal must run inside tmux or in a Claude Code session`, and the hook list has only the `agent-state.sh remove` line.
- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/terminal.sh`, add this function after the function `watch_command`:

```bash
# session_env_command --hook — the SessionStart hook (spec 2026-09-30,
# section 5). It reads session_id from the payload on stdin and appends
# `export CLUX_SESSION_ID=<id>` to CLAUDE_ENV_FILE, so the Bash calls of the
# session and of its subagents get the id from a documented source. It
# appends, because other hooks write the same file. [inferred] No
# CLAUDE_ENV_FILE, or an id that is not in the UUID form: nothing to do.
# main runs it in a subshell that prints nothing and exits 0.
session_env_command() {
    local input
    [ "$#" -eq 1 ] && [ "$1" = --hook ] || return 0
    input=$(cat)
    [ -n "${CLAUDE_ENV_FILE:-}" ] || return 0
    hook_session_id "$input"
    valid_session_id "$HOOK_SESSION_ID" || return 0
    printf 'export CLUX_SESSION_ID=%s\n' "$HOOK_SESSION_ID" >> "$CLAUDE_ENV_FILE"
}
```

Replace the function `main` with:

```bash
main() {
    [ "$#" -gt 0 ] || usage
    case "$1" in
        check-line) shift; check_line_command "$@"; return $? ;;
        # No require_owner: install and status operate outside tmux too.
        laya) shift; laya_command "$@"; return $? ;;
        # The hidden verbs find the owner from their arguments and from
        # state, not from CLAUDE_PID (spec 2026-09-30, section 5).
        watch) shift; watch_command "$@"; return $? ;;
        session-env)
            shift
            ( session_env_command "$@" ) >/dev/null 2>&1 || true
            return 0
            ;;
    esac
    if [ "$1" = close ] && [ "${2:-}" = --hook ]; then
        shift
        ( close_command "$@" ) >/dev/null 2>&1 || true
        return 0
    fi
    # close --session finds its owner from its argument and from state.
    if [ "$1" = close ] && [ "${2:-}" = --session ]; then
        shift
        close_command "$@"
        return $?
    fi
    require_owner
    case "$1" in
        open) shift; open_command "$@" ;;
        run) shift; run_command "$@" ;;
        send) shift; send_command "$@" ;;
        read) shift; read_command "$@" ;;
        wait) shift; wait_command "$@" ;;
        close) shift; close_command "$@" ;;
        list) list_command ;;
        *) usage ;;
    esac
}
```

In `plugins/clux/hooks/hooks.json`, replace:

```json
    "SessionStart": [{ "matcher": "startup|resume|clear", "hooks": [
      { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/agent-state.sh remove", "timeout": 5 }
    ] }],
```

with:

```json
    "SessionStart": [{ "matcher": "startup|resume|clear", "hooks": [
      { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/agent-state.sh remove", "timeout": 5 },
      { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/terminal.sh session-env --hook", "timeout": 5 }
    ] }],
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'session-env'`. Expect two `ok` lines. Then run `bats test/terminal.bats test/agent-state.bats`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/scripts/terminal.sh plugins/clux/hooks/hooks.json test/terminal.bats
git commit -m "feat(clux): write the Claude session id to CLAUDE_ENV_FILE from the SessionStart hook"
```

**Verification:**
- `python3 -m json.tool plugins/clux/hooks/hooks.json >/dev/null && echo valid` prints `valid`.
- `bats test/terminal.bats -f 'session-env'` prints two `ok` lines.

## Task 9: Show the companions of session owners in list and laya status

**Goal:** Make `list` also print `$ROOT/sessions/*` and make `laya status` name the server of a session owner (spec section 11).

**Files touched:**
- Modify: `plugins/clux/scripts/terminal.sh`
- Test: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/terminal.bats`, add these tests after the test `the SessionStart hook runs session-env after the agent-state remove`:

```bash
@test "list shows the directories of session owners with the state of their mark" {
    session_tmux_stub
    local root="$BATS_TEST_TMPDIR/root"
    mkdir -p "$root/sessions/aaaaaaaa" "$root/sessions/bbbbbbbb"
    printf 'mode=window\npane=%%5\nsocket=/tmp/user.sock\nseq=0\ntoken=ab12cd34\n' > "$root/sessions/aaaaaaaa/state"
    printf 'mode=socket\npane=%%0\nsocket=/tmp/private.sock\nseq=0\ntoken=cd34ab12\n' > "$root/sessions/bbbbbbbb/state"
    run env TMUX=fake TMUX_PANE=%0 STUB_MARK=ab12cd34 CLUX_TERMINAL_DIR="$root" "$TERMINAL" list
    [ "$status" -eq 0 ]
    [ "$output" = $'owner=sessions/aaaaaaaa mode=window pane=%5 state=alive\nowner=sessions/bbbbbbbb mode=socket pane=%0 state=gone' ]
}

@test "laya status names the server of a session owner" {
    require_laya_python
    use_real_ps
    start_fake_laya '{}'
    local root="$BATS_TEST_TMPDIR/root" sid=0123abcd-4567-4890-abcd-ef0123456789
    mkdir -p "$root/sessions/0123abcd"
    printf 'mode=socket\npane=%%1\nsocket=/tmp/private.sock\nseq=0\nlaya_url=%s\nlaya_key=%s\nsession=%s\n' \
        "$CLUX_LAYA_URL" "$CLUX_LAYA_KEY" "$sid" > "$root/sessions/0123abcd/state"
    run env -u TMUX -u TMUX_PANE CLUX_TERMINAL_DIR="$root" XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
        CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PID=$$ "$TERMINAL" laya status
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nserver=external health=ok' ]] || false
    # Another session with the same first 8 characters has no server here.
    run env -u TMUX -u TMUX_PANE CLUX_TERMINAL_DIR="$root" XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" \
        CLAUDE_CODE_SESSION_ID=0123abcd-9999-4890-abcd-ef0123456789 CLAUDE_PID=$$ "$TERMINAL" laya status
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nserver=none' ]] || false
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'list shows the directories|laya status names the server of a session owner'`. Expect two `not ok` lines: `list` prints nothing, and `laya status` prints `server=none`, because it reads the server only when `TMUX` is set.
- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/terminal.sh`, replace the function `list_command` with:

```bash
list_command() {
    local listing="" dir base server state
    terminal_init
    # [inferred] A session owner does not read the tmux listing: the
    # directories of pane owners are foreign to it.
    [ "$OWNER_KIND" = session ] || listing=$(companion_listing)
    for dir in "$ROOT"/*; do
        state_load "$dir" || continue
        base="${dir##*/}"
        server="${base%-*}"
        if [ "$server" != "$SERVER_KEY" ]; then
            state=foreign
        elif listing_has_pane "$listing" "$S_PANE"; then
            state=alive
        else
            state=gone
        fi
        printf 'owner=%s mode=%s pane=%s state=%s\n' "$base" "$S_MODE" "$S_PANE" "$state"
    done
    # The directories of session owners (spec 2026-09-30, section 11): alive
    # when the pane holds the mark.
    for dir in "$ROOT"/sessions/*; do
        state_load "$dir" || continue
        state=gone
        ! companion_pane_is_ours "$S_SOCKET" "$S_PANE" || state=alive
        printf 'owner=sessions/%s mode=%s pane=%s state=%s\n' "${dir##*/}" "$S_MODE" "$S_PANE" "$state"
    done
}
```

Replace the comment above `laya_status_server` and the functions `laya_status_server` and `laya_status` with:

```bash
# The server of the companion of this owner: none, or "owned" or "external"
# with the health answer. A subshell, because require_owner and
# terminal_init can exit. With no owner, the subshell prints nothing and
# laya_status gives none.
laya_status_server() {
    (
        require_owner 2>/dev/null
        terminal_init 2>/dev/null
        state_load && state_is_ours && [ -n "$S_LAYA_URL" ] || { echo none; exit 0; }
        owner=external
        [ -z "$S_LAYA_PID" ] || owner=owned
        if laya_call health >/dev/null; then
            echo "$owner health=ok"
        else
            echo "$owner health=failed"
        fi
    )
}

laya_status() {
    local version=none checkpoint=missing server=none
    if [ -f "$LAYA_MARKER" ]; then
        version=$("$LAYA_VENV/bin/python3" "$LAYA_CLIENT" version 2>/dev/null) || version=unknown
    fi
    laya_checkpoint_present && checkpoint=present
    server=$(laya_status_server 2>/dev/null) || server=none
    [ -n "$server" ] || server=none
    printf 'venv=%s\nversion=%s\ncheckpoint=%s\nserver=%s\n' "$LAYA_VENV" "$version" "$checkpoint" "$server"
}
```

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'list shows the directories|laya status'`. Expect `ok` for the two new tests and for `laya status with no venv` and `laya status with the venv and the checkpoint`, with no `# skip`. Run `bats test/terminal-e2e.bats -f 'laya status'`. Expect `ok`. Then run `bats test/terminal.bats`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/scripts/terminal.sh test/terminal.bats
git commit -m "feat(clux): show the companions of session owners in list and laya status"
```

**Verification:**
- `bats test/terminal.bats -f 'laya status|list shows'` prints four `ok` lines.
- `env -u TMUX -u TMUX_PANE -u CLAUDE_CODE_SESSION_ID -u CLUX_SESSION_ID -u CLAUDE_PID XDG_DATA_HOME=/nonexistent plugins/clux/scripts/terminal.sh laya status` prints `venv=/nonexistent/clux/laya`, `version=none`, `checkpoint=missing` and `server=none`, and no other line.

## Task 10: Document background sessions and release 4.1.0

**Goal:** Tell Claude and the user how a background companion operates (the skill, the README, the reference), write the 4.1.0 CHANGELOG entry, and set the plugin version to 4.1.0 (spec section 15).

**Files touched:**
- Modify: `plugins/clux/skills/terminal/SKILL.md`
- Modify: `README.md`
- Modify: `docs/reference.md`
- Modify: `CHANGELOG.md`
- Modify: `plugins/clux/.claude-plugin/plugin.json`
- Test: `test/terminal.bats`

**Steps:**
- [ ] Step 1 (failing test): In `test/terminal.bats`, replace the test `the 4.0.0 release names Laya and the run time limit` with these tests:

```bash
@test "the 4.0.0 release names Laya and the run time limit" {
    local t section
    t=$(bash -c "source '$TERMINAL'; echo \"\$RUN_TIMEOUT_DEFAULT\"")
    section=$(awk '/^## \[4\.0\.0\]/ { on = 1; next } /^## \[/ { on = 0 } on' "$REPO_ROOT/CHANGELOG.md")
    [[ "$section" == *'needs Laya'* ]] || false
    [[ "$section" == *"$t seconds"* ]] || false
    grep -q 'terminal.sh laya install' "$REPO_ROOT/README.md"
}

@test "the 4.1.0 release names background sessions" {
    local section
    grep -q '"version": "4.1.0"' "$REPO_ROOT/plugins/clux/.claude-plugin/plugin.json"
    [ "$(grep -m1 '^## \[' "$REPO_ROOT/CHANGELOG.md")" = '## [4.1.0]' ]
    section=$(awk '/^## \[4\.1\.0\]/ { on = 1; next } /^## \[/ { on = 0 } on' "$REPO_ROOT/CHANGELOG.md")
    [[ "$section" == *'background sessions'* ]] || false
    [[ "$section" == *'clux terminal must run inside tmux or in a Claude Code session'* ]] || false
    [[ "$section" == *'attach_in_tmux='* ]] || false
    grep -q 'Background sessions' "$REPO_ROOT/README.md"
    grep -q '^### Background sessions' "$REPO_ROOT/docs/reference.md"
}

@test "the terminal skill covers background sessions and hides the internal verbs" {
    local skill="$REPO_ROOT/plugins/clux/skills/terminal/SKILL.md"
    grep -qF 'window=' "$skill"
    grep -qF 'attach_in_tmux=' "$skill"
    grep -qF 'claude agents' "$skill"
    grep -qF 'Use `open` again' "$skill"
    ! grep -qF 'The script refuses to operate outside tmux (exit code 2)' "$skill" || false
    ! grep -q 'session-env\|close --session\|watch --session' "$skill" || false
}
```

- [ ] Step 2 (run test, observe FAIL): run `bats test/terminal.bats -f 'release names|covers background sessions'`. Expect `ok` for `the 4.0.0 release names Laya and the run time limit`, and `not ok` for the 4.1.0 test (`plugin.json` has `4.0.0`) and for the skill test (the skill has no `window=`).
- [ ] Step 3 (minimal implementation):

In `plugins/clux/skills/terminal/SKILL.md`, replace the line:

```markdown
- `terminal.sh open --socket` opens the companion on a private tmux server. Use it only when the user asks for it. Give the user the `attach=` line from the output.
```

with:

```markdown
- `terminal.sh open --socket` opens the companion on a private tmux server. Use it only when the user asks for it. Give the user the `attach=` line from the output. When the user is in tmux, give the `attach_in_tmux=` line: tmux refuses an attach from inside tmux when `TMUX` is set.
```

Replace the line:

```markdown
- The script refuses to operate outside tmux (exit code 2). Tell the user to start Claude Code in tmux.
```

with:

```markdown
- In a Claude Code session with no tmux pane (for example a background session that `claude --bg` or a `claude agents` dashboard starts), `open` opens the companion as a new window, `clux-terminal <id>`, in the tmux session of the dashboard. Give the user the `window=` line from the output. When there is no dashboard, `open` opens the companion on a private tmux server: give the user the `attach=` line and the `attach_in_tmux=` line.
- When the session restarts (for example `claude stop`, then `claude attach`), the companion closes, and a verb gives exit code 4. Use `open` again.
- Outside tmux and outside a Claude Code session, the script does not operate (exit code 2). Tell the user to start Claude Code in tmux.
```

In the table "Exit codes", replace the row that starts with `| 2 | The script cannot operate: not in tmux,` with:

```markdown
| 2 | The script cannot operate: not in tmux and not in a Claude Code session, a bad argument, or no tmux. Also a line or a command that is too long for Laya, or a key that does not work at the clux prompt. Also `--enter` or a key that ends the line at a nested shell prompt. | Correct the call, or tell the user. At a nested shell prompt, send the text with no `--enter` and ask the user to press Enter in the pane. |
```

Replace the row `| 4 | No companion is open for this session. | Use `open`. |` with:

```markdown
| 4 | No companion is open for this session. This is also true after the session restarts. | Use `open`. |
```

In the section "Close the companion", replace the paragraph with:

```markdown
`terminal.sh close` clears the history, closes the pane or the window (or stops the private server), deletes the private files, and then stops the Laya server that `open` started. The `SessionEnd` hook does the same at the end of the session. In a session with no tmux pane, a watchdog process also closes the companion when the session process ends, also after a crash.
```

In `README.md`, add this paragraph after the `laya install` code block of the section "Companion terminal", before the line `For more detail, read the [reference](docs/reference.md).`:

```markdown
**Background sessions.** A Claude Code session with no tmux pane (`claude --bg`, or a session that a `claude agents` dashboard starts) also gets a companion. It opens as a new window, `clux-terminal <id>`, in the tmux session of the dashboard. With no dashboard, it opens on a private tmux server, and Claude gives you the line to attach to it. The companion closes when the session ends, also after a crash.
```

In `docs/reference.md`, add this subsection at the end of the section "Companion terminal (clux:terminal)", after the paragraph that starts with `The policies are in`:

```markdown
### Background sessions

From 4.1.0, the companion also operates in a Claude Code session with no tmux pane, for example a `claude --bg` session or a session that a `claude agents` dashboard starts:

- `open` opens a new window, `clux-terminal <id>`, in the tmux session of the dashboard, on your default tmux server. `<id>` is the first 8 characters of the session ID. The output has a `window=<session>:<index>` line.
- With no dashboard, or with `--socket`, `open` opens the companion on a private tmux server. The output has an `attach=` line, and an `attach_in_tmux=` line to use inside tmux.
- The `SessionStart` hook writes `CLUX_SESSION_ID` to the environment of the session. The companion uses it, else `CLAUDE_CODE_SESSION_ID`, and the session process `CLAUDE_PID`.
- A watchdog process closes the companion and stops its Laya server when the session process ends, also after a crash. The `SessionEnd` hook closes it at the end of the session and at `/clear`.
- The companion pane holds a mark. After a restart of the tmux server, a verb that does not find the mark gives exit code 4 and types nothing.
- clux finds only a dashboard on the default tmux server. A dashboard on another server (`tmux -L name`) gives a private server.
```

In `CHANGELOG.md`, add this entry directly above the line `## [4.0.0]`:

```markdown
## [4.1.0]

### Added

- **The companion operates in background sessions.** In a Claude Code session with no tmux pane (`claude --bg`, or a session that a `claude agents` dashboard starts), `terminal.sh open` opens the companion as a new window, `clux-terminal <id>`, in the tmux session of the dashboard (`mode=window`, `window=<session>:<index>`). With no dashboard, or with `--socket`, it opens on a private tmux server. The owner is the Claude session: `CLUX_SESSION_ID`, which the `SessionStart` hook now writes to `CLAUDE_ENV_FILE`, else `CLAUDE_CODE_SESSION_ID`, and the process `CLAUDE_PID`. Its private directory is `sessions/<first 8 characters of the session id>`
- A watchdog process closes a background companion and stops its Laya server when the session process ends, also after a crash with no `SessionEnd`. `close --hook` with no `TMUX` closes the companion of the `session_id` in the hook payload
- A background companion pane holds a mark (`@clux-companion`). A verb that does not find the mark gives exit code 4, so a stale pane ID after a restart of the tmux server never names a pane of the user
- The reaper also removes the directory of a session whose process ended, and a companion left from a `/clear` whose `SessionEnd` hook did not run

### Changed

- Outside tmux and outside a Claude Code session, the verbs give exit code 2 and `clux terminal must run inside tmux or in a Claude Code session` (it was `clux terminal must run inside tmux`)
- `open` in socket mode also prints `attach_in_tmux=TMUX= tmux -S <sock> attach`, because tmux refuses an attach from inside tmux when `TMUX` is set
- `state` is written to a temporary file and then renamed, so a reader never sees a half-written file

```

In `plugins/clux/.claude-plugin/plugin.json`, change `"version": "4.0.0",` to `"version": "4.1.0",`.

- [ ] Step 4 (run test, observe PASS): run `bats test/terminal.bats -f 'release names|covers background sessions|no author notes|Snippet S1|covers Laya'`. Expect six `ok` lines. Then run the full suite: `bats test/`. Expect no `not ok` line.
- [ ] Step 5 (commit):

```bash
git add plugins/clux/skills/terminal/SKILL.md README.md docs/reference.md CHANGELOG.md \
    plugins/clux/.claude-plugin/plugin.json test/terminal.bats
git commit -m "docs(clux): document the companion in background sessions and release 4.1.0"
```

**Verification:**
- `bats test/ | grep -c '^not ok'` prints `0`.
- `grep -m1 '^## \[' CHANGELOG.md` prints `## [4.1.0]`.
- `grep -n 'inferred' plugins/clux/skills/terminal/SKILL.md CHANGELOG.md; echo "rc=$?"` prints only `rc=1`.
- `git status --short` shows changes only in the files of Tasks 1 to 10, the untracked spec, the untracked prototype and this plan.
- Live check, by hand, one time (spec section 14; the user does it, not the implementer): start `claude --bg` from a `claude agents` dashboard in tmux, ask for `/clux:terminal`, run one plain command and one dangerous command, answer `y` in the window, then run `claude stop <id>`. Expect: the window and the Laya server are gone within 5 seconds.
