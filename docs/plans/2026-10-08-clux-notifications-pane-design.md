# clux Notifications Pane Implementation Plan

**Goal:** Add `/clux:notifications`, a Claude Code pane that lists the clux notification queue and lets the person jump to a row or take a row out, and move the parse of a queue line into one shell script that the two tmux keys share.

**Architecture:** One new shell script, `scripts/notification-line.sh`, holds the only parse of a queue line and answers three verbs (`path`, `jump`, `remove`); `jump-to-notification.sh` and `notification-picker.sh` become thin callers of it. One new function-hooks folder, `hooks/notifications/`, holds a pure helper (`lines.ts`) and the pane (`register.tsx`): a 2-second poll of the queue file into a plugin atom, a `Pane` with one button for each row and the hotkeys `j`, `k` and `x`, and one label at the end of the prompt footer. `hooks.json` takes exactly one `modules` entry, so a new composer module `hooks/register.tsx` calls the notifications `register` and then the sessions `register`.

**Tech Stack:** bash with bats (tmux and fzf stubs), TypeScript and TSX function hooks against the `claude-code` 2.1.294 types, `claude plugin test`, `claude plugin validate`, `tsc --noEmit`.

---

## Overview

The spec is `docs/superpowers/specs/2026-10-08-clux-notifications-pane-design.md`. Tasks 1 to 6 are the shell half: the new `notification-line.sh`, then the two tmux callers that lose their own copy of the parse. Tasks 7 to 13 are the mod half: the types, the pure helpers, the one hooks module, the pane, the command, Enter, `j` / `k`, `x` and the footer label. Task 14 is the documentation, and task 15 is the whole-suite check.

Work only in `/Users/jazz/dev/github.com/ai-advanced-futures/clux-remove-sound`, on branch `fix/remove-needs-input-sound`. Do not change `plugins/clux/hooks/sessions/`. Task 8 changes one assertion of `plugins/clux/tests/sessions.test.tsx`, the one the composed hooks module invalidates, and nothing else in that file. [inferred] The version stays 4.6.0: do not touch `plugins/clux/.claude-plugin/plugin.json`, and add to the existing `[4.6.0]` entry of `CHANGELOG.md` instead of making a new one. Never write a `.js` file under `plugins/clux`.

**Who commits.** The implementer runs no git mutation. Each task's step 5 gives the exact `git add` and `git commit` commands, and the coordinator of this run runs them. Report a task as done, with its message, and go on to the next task.

### What the key spike already settled

A spike ran on 2026-10-08 against Claude Code 2.1.294 (`claude plugin test`, `claude plugin validate`). It answers four questions the spec left open, and three of its answers change the design. Each one is in the task that needs it.

| Question | Answer from the spike | Where it lands |
|---|---|---|
| Can `hooks.json` name two modules, as spec §4.1 says? | No. `claude plugin validate` says: ``modules: hooks.json `modules` names one hooks module per plugin; a second entry is refused``. `claude plugin test` then loads nothing at all. | Task 8 adds the composer module `hooks/register.tsx` and `modules` keeps one entry. This is the first fallback of spec §6.0, and it changes no file under `hooks/sessions/`. |
| Does the engine raise a repeat error when one module registers the same event twice? | Only when neither registration carries a matcher: `on("session.start") is registered twice without a matcher`. Two `ui.render` hooks on `{ component: 'SessionMode' }` both load and chain. | Task 8: the notifications `session.start` hook carries the matcher `{ isInteractive: true }`, so it sits beside the unmatched one of the sessions pane. The second fallback of spec §6.0, which would change `hooks/sessions/`, is **not** needed. |
| Which `SessionMode` hook draws on the left? | The hook registered **first** is the outermost: it draws `next(e)` before its own label. With `notifications(on)` before `sessions(on)` the drawn button order is `open-sessions`, then `open-notifications`. | Task 8 (the composer order) and task 13 (the footer test asserts the order). |
| Can a test prove that `$.ui.focus` moves the ring? | No. In `claude plugin test` the plugin's `$.ui.focus({ requestId, key })` **rejects** with `HooksError: no implementation for ui.focus`, whatever the test registers with `on('ui.focus', ...)`. A test can still raise the `ui.focus` **event** (`$.ui.focus({ component, requestId, element, origin })`), and the mod's `ui.focus` hook sees it. | Task 10: the mod catches the rejection and writes the row key to the debug log, and the test reads that line. The live proof stays the human step §6.0 below. |

Two more facts the spike confirmed, used by the tests: `$.plugin.root` is the plugin folder, and a `{ deny }` from a test's `process.run` hook makes the mod's `$.process.run` reject with `HooksError: clux: $.process.run: <reason>`.

### Open human steps, not tasks

- **Spec §6.0, the live key spike.** Load the plugin with `--plugin-dir` in a real tmux session and press `j`, `k`, `x` and Enter in the pane, to see the ring move. A mock cannot prove it, and in `claude plugin test` the call rejects. If the ring does not move, the fallback is `autoFocus` and the arrows alone: drop the `nav-down` and `nav-up` buttons of task 10 and keep everything else.
- **Spec §6.3, the live check.** The five steps of §6.3 in a real tmux session, with two notifications in two other windows.

Both need a person at a terminal. Leave them open and say so when the work is reported.

---

## Task 1: The notification-line.sh script and its `path` verb

**Goal:** Add `scripts/notification-line.sh` with the `path` verb, so the mod and both tmux keys read one queue path from one place.

**Files touched:**
- Create: `plugins/clux/scripts/notification-line.sh`
- Create: `test/notification-line.bats`
- Modify: `plugins/clux/config/deploy-manifest.txt`
- Modify: `CONTRIBUTING.md`

**Steps:**

- [ ] Step 1 (failing test). Write `test/notification-line.bats`:

```bash
#!/usr/bin/env bats
# notification-line.bats — scripts/notification-line.sh: the one parse of one
# queue line, shared by the tmux keys (prefix + m, prefix + M) and the Claude
# Code notifications pane. Before this script, jump-to-notification.sh and
# notification-picker.sh each carried their own copy of the parse.

load test_helper

SCRIPT="$SCRIPTS_DIR/notification-line.sh"

# ---------------------------------------------------------------------------
# path — the three tiers of resolve_notify_file(), through the script
# ---------------------------------------------------------------------------
@test "notification-line path: prints CLUX_NOTIFY_FILE when it is set" {
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        bash '$SCRIPT' path
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$QUEUE_FILE" ]
}

@test "notification-line path: prints the sidecar path when only the sidecar is set" {
    mkdir -p "$HOME/.config/clux"
    printf '%s\n' "/tmp/sidecar-queue" > "$HOME/.config/clux/notify-file-path"

    run bash -c "
        export CLUX_NOTIFY_FILE=
        bash '$SCRIPT' path
    "
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp/sidecar-queue" ]
}

@test "notification-line path: prints the HOME default with no env and no sidecar" {
    run bash -c "
        export CLUX_NOTIFY_FILE=
        bash '$SCRIPT' path
    "
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.config/tmux/claude_notification" ]
}

@test "notification-line: an unknown verb exits 2" {
    run bash "$SCRIPT" wobble
    [ "$status" -eq 2 ]
}
```

- [ ] Step 2 (run the test, observe FAIL). `bats test/notification-line.bats` fails on every test with `bash: .../plugins/clux/scripts/notification-line.sh: No such file or directory` (status 127).

- [ ] Step 3 (minimal implementation). Write `plugins/clux/scripts/notification-line.sh`:

```bash
#!/usr/bin/env bash
# One parse of one notification queue line, for every caller.
#
#   notification-line.sh path             prints the queue path
#   notification-line.sh jump "<line>"    goes to the window of a line
#   notification-line.sh remove "<line>"  takes a line out of the queue
#
# Before this file, jump-to-notification.sh and notification-picker.sh each
# held their own copy of the parse, and they already disagreed: the picker
# jumped by name and the key jumped by id. The Claude Code notifications pane
# would have been a third copy, so the parse lives here alone and every
# caller runs this script.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"
NOTIFY_FILE=$(resolve_notify_file)
LOCKDIR="${NOTIFY_FILE}.lock"

VERB="${1:-}"
LINE="${2:-}"

case "$VERB" in
    path)
        printf '%s\n' "$NOTIFY_FILE"
        exit 0
        ;;
    *)
        printf 'usage: notification-line.sh path|jump <line>|remove <line>\n' >&2
        exit 2
        ;;
esac
```

Make it executable (`test/deploy-manifest.bats` asserts the bit):

```bash
chmod +x plugins/clux/scripts/notification-line.sh
```

Add the line to `plugins/clux/config/deploy-manifest.txt`, under the `# Notifications` heading, right after `show-notification.sh`:

```
# Notifications
show-notification.sh
notification-line.sh
jump-to-notification.sh
dismiss-notification.sh
notification-picker.sh
notify-sound.sh
truncate-title.sh
```

Add the line to the file tree of `CONTRIBUTING.md` (`test/docs-tree.bats` asserts both directions), right after `show-notification.sh`:

```
│   ├── show-notification.sh     # Renders the notification token
│   ├── notification-line.sh     # The one parse of a queue line: path, jump, remove
│   ├── jump-to-notification.sh  # Jump to notifying window
```

- [ ] Step 4 (run the test, observe PASS). `bats test/notification-line.bats test/deploy-manifest.bats test/docs-tree.bats` — all tests pass.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/scripts/notification-line.sh test/notification-line.bats plugins/clux/config/deploy-manifest.txt CONTRIBUTING.md
git commit -m "feat(clux): notification-line.sh with the path verb"
```

**Verification:**

```bash
bats test/notification-line.bats
# 4 tests, 4 passing

bats test/deploy-manifest.bats test/docs-tree.bats
# 12 tests, 12 passing

plugins/clux/scripts/notification-line.sh path
# prints a path, e.g. /Users/jazz/.config/tmux/claude_notification

CLUX_NOTIFY_FILE=/tmp/q plugins/clux/scripts/notification-line.sh path
# prints: /tmp/q

plugins/clux/scripts/notification-line.sh wobble; echo "status=$?"
# prints the usage line on standard error, then: status=2
```

---

## Task 2: The `remove` verb

**Goal:** `notification-line.sh remove "<line>"` takes the lock and removes each line that is **equal** to the argument.

**Files touched:**
- Modify: `plugins/clux/scripts/notification-line.sh`
- Modify: `test/notification-line.bats`

**Steps:**

- [ ] Step 1 (failing test). Append to `test/notification-line.bats`:

```bash
# ---------------------------------------------------------------------------
# remove — an EQUAL line only, under the queue lock
# ---------------------------------------------------------------------------
@test "notification-line remove: removes an equal line and keeps a longer line that holds it" {
    local short='main:editor done|||$sess1:@win3'
    local long="prefix $short"
    printf '%s\n%s\n' "$short" "$long" > "$QUEUE_FILE"

    run bash "$SCRIPT" remove "$short"
    [ "$status" -eq 0 ]
    run grep -qxF "$short" "$QUEUE_FILE"
    [ "$status" -ne 0 ]
    grep -qxF "$long" "$QUEUE_FILE" || false
}

@test "notification-line remove: deletes the queue file when the last line goes" {
    local line='main:editor done|||$sess1:@win3'
    printf '%s\n' "$line" > "$QUEUE_FILE"

    run bash "$SCRIPT" remove "$line"
    [ "$status" -eq 0 ]
    [ ! -e "$QUEUE_FILE" ]
}

@test "notification-line remove: a line that is not there is exit 0 and changes nothing" {
    local line='main:editor done|||$sess1:@win3'
    printf '%s\n' "$line" > "$QUEUE_FILE"

    run bash "$SCRIPT" remove 'main:other gone|||$sess1:@win9'
    [ "$status" -eq 0 ]
    grep -qxF "$line" "$QUEUE_FILE" || false
}

@test "notification-line remove: a missing queue file is exit 0 and takes no lock" {
    rm -f "$QUEUE_FILE"

    run bash "$SCRIPT" remove 'main:editor done|||$sess1:@win3'
    [ "$status" -eq 0 ]
    [ ! -d "${QUEUE_FILE}.lock" ]
}

@test "notification-line remove: exits 1 while a fresh lock directory is held" {
    local line='main:editor done|||$sess1:@win3'
    printf '%s\n' "$line" > "$QUEUE_FILE"
    mkdir "${QUEUE_FILE}.lock"

    run bash "$SCRIPT" remove "$line"
    [ "$status" -eq 1 ]
    # The line is still in the queue, and the lock is still the holder's.
    grep -qxF "$line" "$QUEUE_FILE" || false
    [ -d "${QUEUE_FILE}.lock" ]
    rmdir "${QUEUE_FILE}.lock"
}

@test "notification-line remove: removes from the sidecar queue when only the sidecar is set" {
    local sidecar_queue="$BATS_TEST_TMPDIR/sidecar-queue"
    local line='main:editor done|||$sess1:@win3'
    mkdir -p "$HOME/.config/clux"
    printf '%s\n' "$sidecar_queue" > "$HOME/.config/clux/notify-file-path"
    printf '%s\n' "$line" > "$sidecar_queue"

    run bash -c "
        export CLUX_NOTIFY_FILE=
        bash '$SCRIPT' remove '$line'
    "
    [ "$status" -eq 0 ]
    [ ! -e "$sidecar_queue" ]
}
```

- [ ] Step 2 (run the test, observe FAIL). `bats test/notification-line.bats` — the six new tests fail with status 2, because `remove` falls into the usage arm.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/notification-line.sh`, add the two functions above the `case`, and a `remove` arm to the `case`:

```bash
# Take the queue lock, as dismiss-notification.sh does. mkdir is atomic on
# every filesystem; five tries at 100 ms is the 500 ms budget of a key the
# person pressed. A lock older than 10 seconds is the leftover of a killed
# process, so it goes.
_take_lock() {
    local now mtime i=0
    if [ -d "$LOCKDIR" ]; then
        now=$(date +%s)
        # GNU stat (-c %Y) first: on Linux `stat -f` means --file-system and
        # "succeeds" with garbage instead of failing, so it must not be tried
        # first. BSD/macOS stat rejects -c and falls through to -f %m.
        mtime=$(stat -c %Y "$LOCKDIR" 2>/dev/null || stat -f %m "$LOCKDIR" 2>/dev/null || echo "$now")
        [ $(( now - mtime )) -gt 10 ] && rm -rf "$LOCKDIR"
    fi
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -ge 5 ] && return 1
        sleep 0.1
    done
    trap 'rm -rf "$LOCKDIR"' EXIT
    return 0
}

# Remove each line EQUAL to $LINE. The picker used `grep -vF`, which also
# removes a longer line that holds the argument inside it; -x removes an equal
# line only. The new file goes into place with mv, so a reader never sees a
# part list. grep exits 1 when every line matched, which is the "queue is now
# empty" case and not a failure, so the exit code of the script is its own.
_remove() {
    [ -n "$LINE" ] || return 0
    [ -s "$NOTIFY_FILE" ] || return 0
    _take_lock || return 1
    grep -vxF "$LINE" "$NOTIFY_FILE" > "${NOTIFY_FILE}.tmp" 2>/dev/null
    if [ -s "${NOTIFY_FILE}.tmp" ]; then
        mv "${NOTIFY_FILE}.tmp" "$NOTIFY_FILE"
    else
        rm -f "${NOTIFY_FILE}.tmp" "$NOTIFY_FILE"
    fi
    return 0
}
```

```bash
case "$VERB" in
    path)
        printf '%s\n' "$NOTIFY_FILE"
        exit 0
        ;;
    remove)
        _remove
        exit $?
        ;;
    *)
        printf 'usage: notification-line.sh path|jump <line>|remove <line>\n' >&2
        exit 2
        ;;
esac
```

- [ ] Step 4 (run the test, observe PASS). `bats test/notification-line.bats` — 10 tests, 10 passing.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/scripts/notification-line.sh test/notification-line.bats
git commit -m "feat(clux): notification-line.sh remove verb, equal lines only"
```

**Verification:**

```bash
bats test/notification-line.bats
# 10 tests, 10 passing

printf 'a|||$s1:@w1\nprefix a|||$s1:@w1\n' > /tmp/q
CLUX_NOTIFY_FILE=/tmp/q plugins/clux/scripts/notification-line.sh remove 'a|||$s1:@w1'; echo "status=$?"
# status=0
cat /tmp/q
# prefix a|||$s1:@w1
```

---

## Task 3: The `jump` verb for a window line

**Goal:** `notification-line.sh jump "<line>"` goes to the tmux window of an id line, a legacy `|ID:` line or a name line, and exits 1 when the line names no target.

**Files touched:**
- Modify: `plugins/clux/scripts/notification-line.sh`
- Modify: `test/notification-line.bats`

**Steps:**

- [ ] Step 1 (failing test). Append to `test/notification-line.bats`:

```bash
# ---------------------------------------------------------------------------
# jump — a window line, by id, by the legacy marker, and by name
# ---------------------------------------------------------------------------
@test "notification-line jump: a ||| id line selects the window and switches the client" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump 'main:editor Task done|||\$sess1:@win3'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t $sess1:@win3' "$stub_log" || false
    grep -qF 'switch-client -t $sess1' "$stub_log" || false
}

@test "notification-line jump: a legacy |ID: line selects the window by id too" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump 'main:editor Task done|ID:\$sess1:@win3'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t $sess1:@win3' "$stub_log" || false
}

@test "notification-line jump: a line with no marker falls back to the name parse" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump 'main:editor Task done'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t main:editor' "$stub_log" || false
    grep -qF 'switch-client -t main' "$stub_log" || false
}

@test "notification-line jump: a line with no target exits 1 and calls no tmux" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump 'a notification with no target at all'
    "
    [ "$status" -eq 1 ]
    [ ! -f "$stub_log" ] || [ ! -s "$stub_log" ]
}

@test "notification-line jump: an empty line exits 1" {
    run bash "$SCRIPT" jump ''
    [ "$status" -eq 1 ]
}
```

- [ ] Step 2 (run the test, observe FAIL). `bats test/notification-line.bats` — the five new tests fail with status 2 (the usage arm).

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/notification-line.sh`, add the two jump helpers above the `case`, add a `jump` arm that falls through, and add the jump block after the `case`:

```bash
# A "<session_id>:<window_id>" tail, from ||| or from the legacy |ID: marker.
# A tail with no colon leaves both halves equal to the whole tail, which is a
# line that names no target, so the equality guard is the target test.
_jump_ids() {
    local id_part="$1" session_id window_id
    session_id="${id_part%%:*}"
    window_id="${id_part#*:}"
    [ -n "$session_id" ] && [ -n "$window_id" ] && [ "$session_id" != "$window_id" ] || return 1
    tmux select-window -t "$session_id:$window_id" 2>/dev/null || return 1
    tmux switch-client -t "$session_id" 2>/dev/null || return 1
    return 0
}

# The oldest shape: "<session>:<window> <message>", by name.
_jump_name() {
    local session remainder window
    case "$LINE" in
        *:*) ;;
        *) return 1 ;;
    esac
    session="${LINE%%:*}"
    remainder="${LINE#*:}"
    window="${remainder%% *}"
    [ -n "$session" ] && [ -n "$window" ] || return 1
    tmux select-window -t "$session:$window" 2>/dev/null || return 1
    tmux switch-client -t "$session" 2>/dev/null || return 1
    return 0
}
```

```bash
case "$VERB" in
    path)
        printf '%s\n' "$NOTIFY_FILE"
        exit 0
        ;;
    remove)
        _remove
        exit $?
        ;;
    jump) ;;
    *)
        printf 'usage: notification-line.sh path|jump <line>|remove <line>\n' >&2
        exit 2
        ;;
esac

# --- jump ------------------------------------------------------------------
[ -n "$LINE" ] || exit 1

case "$LINE" in
    *"|||"*)
        _jump_ids "${LINE##*|||}"
        exit $?
        ;;
    *"|ID:"*)
        _jump_ids "${LINE##*|ID:}"
        exit $?
        ;;
    *)
        _jump_name
        exit $?
        ;;
esac
```

- [ ] Step 4 (run the test, observe PASS). `bats test/notification-line.bats` — 15 tests, 15 passing.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/scripts/notification-line.sh test/notification-line.bats
git commit -m "feat(clux): notification-line.sh jump verb for a window line"
```

**Verification:**

```bash
bats test/notification-line.bats
# 15 tests, 15 passing

plugins/clux/scripts/notification-line.sh jump 'no target here'; echo "status=$?"
# status=1
```

---

## Task 4: The `jump` verb for an agent line

**Goal:** An `|||agent:` line goes through `agent_jump`, loses its queue entry, and asks tmux to redraw — and never through the id parse.

**Files touched:**
- Modify: `plugins/clux/scripts/notification-line.sh`
- Modify: `test/notification-line.bats`

**Steps:**

- [ ] Step 1 (failing test). Append to `test/notification-line.bats`:

```bash
# ---------------------------------------------------------------------------
# jump — an agent line. The agent check MUST run before the generic |||
# check: an agent line also holds |||, and the generic branch would try
# `tmux select-window -t "agent:<sid>"`.
# ---------------------------------------------------------------------------
@test "notification-line jump: a new-format agent line fast-paths to the embedded pane and clears it" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    # The fast-path probe must find %pane3 alive (bare pane_id listing); the
    # cwd resolver's listing (it asks for pane_current_path) stays empty, so
    # the fast path is the one taken.
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
if [ "$1" = "list-panes" ]; then
    case "$*" in
        *pane_current_path*) : ;;
        *) printf '%%pane3\n' ;;
    esac
fi
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"

    printf '⚡ agents / x|||agent:abc-123@@$s9:@w9:%%pane3@@/c\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump '⚡ agents / x|||agent:abc-123@@\$s9:@w9:%pane3@@/c'
    "
    [ "$status" -eq 0 ]
    # Routed by the embedded pane id (the last colon token of segment 2).
    grep -qF 'send-keys -t %pane3' "$stub_log" || false
    # Only this branch asks for the redraw.
    grep -qF 'refresh-client -S' "$stub_log" || false
    # Clear-on-jump took the entry out.
    run grep -qF '|||agent:abc-123@@' "$QUEUE_FILE"
    [ "$status" -ne 0 ]
}

@test "notification-line jump: an agent line never reaches the generic ||| parse" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    printf '⚡ needs input|||agent:s-abc-123\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        bash '$SCRIPT' jump '⚡ needs input|||agent:s-abc-123'
    "
    [ "$status" -eq 0 ]
    # The legacy line has no coordinates, so agent_jump opens the agents view.
    grep -qF "new-window" "$stub_log" || false
    run grep -F "select-window -t agent:" "$stub_log"
    [ "$status" -ne 0 ]
}
```

- [ ] Step 2 (run the test, observe FAIL). `bats test/notification-line.bats` — the two new tests fail: the generic `|||` arm runs `tmux select-window -t agent:...`, so `send-keys -t %pane3`, `refresh-client -S` and `new-window` are all absent from the stub log.

- [ ] Step 3 (minimal implementation). In `plugins/clux/scripts/notification-line.sh`, put an agent arm **first** in the jump `case` and add the agent block after it. The block sits at the top level of the script, not inside a function, because `helpers.sh` assigns its globals at source time:

```bash
case "$LINE" in
    # FIRST, before the generic ||| arm below: an agent line also holds |||.
    *"|||agent:"*) ;;
    *"|||"*)
        _jump_ids "${LINE##*|||}"
        exit $?
        ;;
    *"|ID:"*)
        _jump_ids "${LINE##*|ID:}"
        exit $?
        ;;
    *)
        _jump_name
        exit $?
        ;;
esac

# --- jump, an agent line ---------------------------------------------------
# Line shape (new):    "<marker> <label>|||agent:<SID>@@<TMUXSID>:<WID>:<PID>@@<CWD>"
# Line shape (legacy): "<marker> <label>|||agent:<SID>"
_AGENT_QUEUE="$NOTIFY_FILE"   # the queue the three tiers resolved
# shellcheck source=./helpers.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/helpers.sh"
# helpers.sh re-derives NOTIFY_FILE from get_tmux_option at source time, which
# knows nothing of the three tiers — put the resolved queue back, so
# _agent_remove_entry locks and clears the file this script read.
NOTIFY_FILE="$_AGENT_QUEUE"
recompute_lock_target

rest="${LINE##*|||agent:}"
# Split rest on @@ into three segments. For a legacy line (no @@) seg2 and
# seg3 MUST be force-emptied: ${rest#*@@} returns rest UNCHANGED when there is
# no delimiter, which would make seg2 wrongly equal the SID.
seg1="${rest%%@@*}"
if [[ "$rest" != *@@* ]]; then
    seg2=""
    seg3=""
else
    after1="${rest#*@@}"
    seg2="${after1%%@@*}"
    seg3="${after1#*@@}"
fi
remove_key="$seg1"   # the dedup key is the display SID, NOT the pane coords

# The pane id is seg2's LAST colon token (TMUXSID:WID:PID), not seg1.
if [ -n "$seg2" ]; then
    pane_id="${seg2##*:}"
    sid="${seg2%%:*}"
    _mid="${seg2#*:}"
    wid="${_mid%%:*}"
    target="$sid $wid $pane_id"
else
    target=""
fi

agent_jump "$target" "$seg3"      # fast-path / re-resolve / v3 fallback
_agent_remove_entry "$remove_key" # clear-on-jump, both line formats
tmux refresh-client -S 2>/dev/null
exit 0
```

- [ ] Step 4 (run the test, observe PASS). `bats test/notification-line.bats` — 17 tests, 17 passing.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/scripts/notification-line.sh test/notification-line.bats
git commit -m "feat(clux): notification-line.sh jump verb for an agent line"
```

**Verification:**

```bash
bats test/notification-line.bats
# 17 tests, 17 passing

bash -n plugins/clux/scripts/notification-line.sh; echo "syntax=$?"
# syntax=0
```

---

## Task 5: jump-to-notification.sh calls the shared script

**Goal:** `prefix + m` keeps its behaviour, loses its copy of the parse, and gains the sidecar tier of the queue path.

**Files touched:**
- Modify: `plugins/clux/scripts/jump-to-notification.sh`
- Modify: `test/notification-line.bats`

**Steps:**

- [ ] Step 1 (failing test). Append to `test/notification-line.bats`:

```bash
# ---------------------------------------------------------------------------
# The callers. Both tmux keys now run this script, and both resolve the queue
# with the three tiers of resolve_notify_file(), as the status bar does. They
# used to read two tiers and ignore the sidecar file.
# ---------------------------------------------------------------------------
@test "jump-to-notification: jumps to the top line of the sidecar queue" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local sidecar_queue="$BATS_TEST_TMPDIR/sidecar-queue"
    mkdir -p "$HOME/.config/clux"
    printf '%s\n' "$sidecar_queue" > "$HOME/.config/clux/notify-file-path"
    printf 'main:editor Task done|||$sess1:@win3\n' > "$sidecar_queue"

    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE=
        bash '$SCRIPTS_DIR/jump-to-notification.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t $sess1:@win3' "$stub_log" || false
}
```

- [ ] Step 2 (run the test, observe FAIL). `bats test/notification-line.bats` — the new test fails: the old script reads `$HOME/.config/tmux/claude_notification`, which is not there, so it exits 0 and the stub log is empty (`grep` finds nothing).

- [ ] Step 3 (minimal implementation). Replace `plugins/clux/scripts/jump-to-notification.sh` whole:

```bash
#!/usr/bin/env bash

# Jump to the tmux session/window of the TOP notification (prefix + m).
# The status bar pops a notification for the current window as it arrives, so
# the top line is the one the person wants. The parse of that line lives in
# notification-line.sh, shared with the fzf popup and the Claude Code pane.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"
NOTIFY_FILE=$(resolve_notify_file)

[ -f "$NOTIFY_FILE" ] || exit 0

FIRST=$(head -1 "$NOTIFY_FILE")
[ -n "$FIRST" ] || exit 0

"$CURRENT_DIR/notification-line.sh" jump "$FIRST"

# A key binding that exits non-zero makes tmux draw an error line, so a line
# with no target ends quietly here, exactly as it did before.
exit 0
```

- [ ] Step 4 (run the test, observe PASS). `bats test/notification-line.bats test/jump.bats` — 18 + 5 tests, all passing, with no change to any assertion of `jump.bats`.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/scripts/jump-to-notification.sh test/notification-line.bats
git commit -m "refactor(clux): jump-to-notification.sh calls notification-line.sh"
```

**Verification:**

```bash
bats test/notification-line.bats test/jump.bats
# 23 tests, 23 passing

grep -c 'notification-line.sh' plugins/clux/scripts/jump-to-notification.sh
# 2  — the comment that says where the parse lives, and the call itself

grep -c 'agent:' plugins/clux/scripts/jump-to-notification.sh
# 0  — the agent parse now lives in notification-line.sh alone

grep -c 'resolve_notify_file' plugins/clux/scripts/jump-to-notification.sh
# 1  — the two-tier expression of line 6 is gone
```

---

## Task 6: notification-picker.sh calls the shared script

**Goal:** The `prefix + M` popup routes Enter and Ctrl-D through the shared script. Two behaviours change on purpose: Enter jumps by id, and Ctrl-D removes an equal line only.

**Files touched:**
- Modify: `plugins/clux/scripts/notification-picker.sh`
- Modify: `test/notification-line.bats`
- Modify: `test/picker.bats`

**Steps:**

- [ ] Step 1 (failing test). Append to `test/notification-line.bats`:

```bash
@test "notification-picker: Ctrl-D removes an equal line and keeps a longer line that holds it" {
    local short='main:editor done|||$sess1:@win3'
    local long="prefix $short"
    printf '%s\n%s\n' "$short" "$long" > "$QUEUE_FILE"

    run bash -c "
        export FZF_STUB_KEY='ctrl-d'
        export FZF_STUB_LINE='main:editor done|||\$sess1:@win3'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    run grep -qxF "$short" "$QUEUE_FILE"
    [ "$status" -ne 0 ]
    grep -qxF "$long" "$QUEUE_FILE" || false
}

@test "notification-picker: Enter on an interactive line jumps by id, never by name" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    printf 'main:editor Task done|||$sess1:@win3\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export FZF_STUB_KEY=''
        export FZF_STUB_LINE='main:editor Task done|||\$sess1:@win3'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t $sess1:@win3' "$stub_log" || false
    run grep -F 'select-window -t main:editor' "$stub_log"
    [ "$status" -ne 0 ]
}

@test "notification-picker: Ctrl-D removes from the sidecar queue" {
    local sidecar_queue="$BATS_TEST_TMPDIR/sidecar-queue"
    local line='main:editor done|||$sess1:@win3'
    mkdir -p "$HOME/.config/clux"
    printf '%s\n' "$sidecar_queue" > "$HOME/.config/clux/notify-file-path"
    printf '%s\n' "$line" > "$sidecar_queue"

    run bash -c "
        export CLUX_NOTIFY_FILE=
        export FZF_STUB_KEY='ctrl-d'
        export FZF_STUB_LINE='main:editor done|||\$sess1:@win3'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    [ ! -e "$sidecar_queue" ]
}
```

- [ ] Step 2 (run the test, observe FAIL). `bats test/notification-line.bats` — the three new tests fail: the old `grep -vF` removes the longer line too, the old Enter branch runs `select-window -t main:editor`, and the old two-tier path never reads the sidecar queue.

- [ ] Step 3 (minimal implementation). Replace everything in `plugins/clux/scripts/notification-picker.sh` from the top of the file down to the end, keeping the fzf checks as they are:

```bash
#!/usr/bin/env bash

# Interactive notification picker using fzf (prefix + M). The parse of the
# selected line lives in notification-line.sh, so this popup, prefix + m and
# the Claude Code notifications pane route a line the same way.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./path.sh
# shellcheck disable=SC1091
source "$CURRENT_DIR/path.sh"
NOTIFY_FILE=$(resolve_notify_file)

# Check fzf is installed
if ! command -v fzf &>/dev/null; then
    echo "fzf is required but not installed."
    echo ""
    echo "Install via:"
    echo "  brew install fzf        # macOS"
    echo "  apt install fzf         # Debian/Ubuntu"
    echo "  pacman -S fzf           # Arch"
    echo ""
    echo "See https://github.com/junegunn/fzf#installation"
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

# Check notifications exist
if [ ! -f "$NOTIFY_FILE" ] || [ ! -s "$NOTIFY_FILE" ]; then
    echo "No notifications."
    read -n 1 -s -r -p "Press any key to close..."
    exit 0
fi

selected=$(fzf --reverse \
    --header="Enter=jump  Ctrl-D=dismiss  Esc=close" \
    --expect=ctrl-d \
    < "$NOTIFY_FILE")

# fzf exits 130 on Esc/ctrl-c
[ -z "$selected" ] && exit 0

key=$(head -1 <<< "$selected")
line=$(tail -1 <<< "$selected")

[ -z "$line" ] && exit 0

if [ "$key" = "ctrl-d" ]; then
    "$CURRENT_DIR/notification-line.sh" remove "$line"
else
    "$CURRENT_DIR/notification-line.sh" jump "$line"
fi

# The popup always ends well, as prefix + m does: a line with no target or a
# busy queue must not leave an error line inside display-popup.
exit 0
```

In the same step, change the one assertion of `test/picker.bats` that this deliberate behaviour change invalidates. Replace the whole "Case 3" block with:

```bash
# ---------------------------------------------------------------------------
# Case 3: ENTER on an interactive line → the id parse (4.6.0)
# Until 4.6.0 the picker parsed SESSION:WINDOW out of the text of the line and
# jumped by name, while prefix + m jumped by the ids after |||. Both now run
# notification-line.sh, so the popup jumps by id too: a session renamed after
# the notification arrived still lands on the right window.
# Falsifiable: the id target must appear, the name target must not, and
# agent_jump's new-window must not be invoked.
# ---------------------------------------------------------------------------
@test "picker: ENTER on interactive line jumps by the ids in the line" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"

    printf 'main:editor Task done|||$sess1:@win3\n' > "$QUEUE_FILE"

    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FZF_STUB_KEY=''
        export FZF_STUB_LINE='main:editor Task done|||\$sess1:@win3'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    grep -qF 'select-window -t $sess1:@win3' "$stub_log" || false
    run grep -F 'select-window -t main:editor' "$stub_log"
    [ "$status" -ne 0 ]
    # agent_jump's new-window must NOT have been called (no mis-routing)
    run grep -qF "new-window" "$stub_log"
    [ "$status" -ne 0 ]
}
```

- [ ] Step 4 (run the test, observe PASS). `bats test/notification-line.bats test/picker.bats` — 21 + 7 tests, all passing.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/scripts/notification-picker.sh test/notification-line.bats test/picker.bats
git commit -m "refactor(clux): the picker calls notification-line.sh, and jumps by id"
```

**Verification:**

```bash
bats test/notification-line.bats test/picker.bats test/jump.bats test/path.bats
# 37 tests, 37 passing

grep -c 'agent:' plugins/clux/scripts/notification-picker.sh
# 0  — the agent parse and the lock both left the picker

bats test/deploy-manifest.bats
# 9 tests, 9 passing  — the source closure still holds (both scripts source path.sh)
```

---

## Task 7: The NotifRow type and the pure queue helpers

**Goal:** `hooks/notifications/lines.ts` turns the queue text into rows, with no `$`, so the tests call it directly.

**Files touched:**
- Create: `plugins/clux/hooks/notifications/lines.ts`
- Create: `plugins/clux/tests/notifications-lines.test.ts`
- Modify: `plugins/clux/types/index.d.ts`

**Steps:**

- [ ] Step 1 (failing test). Write `plugins/clux/tests/notifications-lines.test.ts`:

```ts
import { describe, expect, test } from 'claude-code/testing'

import { displayText, toRows } from '../hooks/notifications/lines'

const WINDOW = 'main:editor Task done|||$sess1:@win3'
const LEGACY = 'main:editor Task done|ID:$sess1:@win3'
const AGENT = '⚡ agents / pr-flow|||agent:abc-123@@$s9:@w9:%pane3@@/code/clux'
const OLD_AGENT = '⚡ needs input|||agent:s-abc-123'
const BARE = 'main:editor Task done'

describe('displayText', () => {
  test('cuts the ||| marker', () => {
    expect(displayText(WINDOW)).toBe('main:editor Task done')
  })

  test('cuts the legacy |ID: marker', () => {
    expect(displayText(LEGACY)).toBe('main:editor Task done')
  })

  test('cuts the marker of an agent line, new shape and legacy shape', () => {
    expect(displayText(AGENT)).toBe('⚡ agents / pr-flow')
    expect(displayText(OLD_AGENT)).toBe('⚡ needs input')
  })

  test('leaves a line with no marker as it is', () => {
    expect(displayText(BARE)).toBe('main:editor Task done')
  })
})

describe('toRows', () => {
  test('one row for each line, in file order, the whole line kept', () => {
    expect(toRows(`${WINDOW}\n${AGENT}\n`)).toEqual([
      { line: WINDOW, text: 'main:editor Task done', kind: 'window' },
      { line: AGENT, text: '⚡ agents / pr-flow', kind: 'agent' },
    ])
  })

  test('an empty file is no rows', () => {
    expect(toRows('')).toEqual([])
  })

  test('a blank line is no row', () => {
    expect(toRows(`\n${WINDOW}\n\n`)).toEqual([
      { line: WINDOW, text: 'main:editor Task done', kind: 'window' },
    ])
  })

  test('a legacy agent line is an agent row, and a bare line a window row', () => {
    expect(toRows(`${OLD_AGENT}\n${BARE}\n`).map(row => row.kind)).toEqual(['agent', 'window'])
  })
})
```

- [ ] Step 2 (run the test, observe FAIL). `/Users/jazz/.local/bin/claude plugin test plugins/clux` fails on this file with a module that cannot be found: `../hooks/notifications/lines`.

- [ ] Step 3 (minimal implementation). Write `plugins/clux/hooks/notifications/lines.ts`:

```ts
// Pure helpers: the notification queue file as rows. No `$` here, so the
// tests can call these directly.
//
// There is deliberately NO target parse here. scripts/notification-line.sh
// owns that, and a second copy in TypeScript is the copy that goes out of
// step. These functions only cut the id marker off the text a person reads.

import type { NotifRow } from '../../types'

// What the person reads: the part before the id marker. show-notification.sh
// cuts the same two markers for the status bar.
export function displayText(line: string): string {
  const triple = line.indexOf('|||')
  if (triple !== -1) return line.slice(0, triple)
  const legacy = line.indexOf('|ID:')
  if (legacy !== -1) return line.slice(0, legacy)
  return line
}

// One row for each line that is not empty, in file order. The row keeps the
// whole line, because `jump` and `remove` take the line exactly as it is.
export function toRows(text: string): NotifRow[] {
  return text.split('\n').flatMap(line =>
    line === ''
      ? []
      : [{
          line,
          text: displayText(line),
          kind: line.includes('|||agent:') ? ('agent' as const) : ('window' as const),
        }],
  )
}
```

Make two edits to `plugins/clux/types/index.d.ts`. Add the type after `BgSession`:

```ts
// One line of the clux notification queue, as the notifications pane draws
// it. `line` is the whole line, the argument of notification-line.sh; `text`
// is what the person reads. The pane does not draw `kind`: the text of an
// agent line already starts with its marker.
export type NotifRow = {
  line: string
  text: string
  kind: 'agent' | 'window'
}
```

Then add one line, `notifications: NotifRow[]`, inside the `declare module 'claude-code'` block the file already has:

```ts
declare module 'claude-code' {
  interface PluginState {
    'clux': {
      sessions: BgSession[]
      notifications: NotifRow[]
    }
  }
}
```

- [ ] Step 4 (run the test, observe PASS). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — the 8 tests of `notifications-lines.test.ts` pass, and the 25 tests that were already there still pass.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/hooks/notifications/lines.ts plugins/clux/tests/notifications-lines.test.ts plugins/clux/types/index.d.ts
git commit -m "feat(clux): NotifRow and the pure queue-line helpers"
```

**Verification:**

```bash
/Users/jazz/.local/bin/claude plugin test plugins/clux
# 33 pass, 0 fail, across 3 files

npx -y -p typescript@5.6.3 tsc -p plugins/clux --noEmit
# no output, exit 0

git status --porcelain plugins/clux | grep '\.js$'
# no output — no .js file was written
```

---

## Task 8: One hooks module, the poll, the pane and Enter

**Goal:** `hooks/register.tsx` loads both panes from one module, and the notifications pane polls the queue, draws one button for each row, and jumps on Enter.

**Files touched:**
- Create: `plugins/clux/hooks/register.tsx`
- Create: `plugins/clux/hooks/notifications/register.tsx`
- Create: `plugins/clux/tests/notifications.test.tsx`
- Modify: `plugins/clux/hooks/hooks.json`
- Modify: `plugins/clux/tests/sessions.test.tsx` (one assertion, line 237) [inferred]

**Steps:**

- [ ] Step 1 (failing test). Write `plugins/clux/tests/notifications.test.tsx`:

```tsx
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

const ROOT = '/code/clux'
const QUEUE = '/home/me/.config/tmux/claude_notification'
const NOW = Date.parse('2026-10-08T09:00:00.000Z')
const IN_TMUX = { TMUX: '/tmp/tmux-1000/default,1,0' }

const WINDOW = 'main:editor Task done|||$sess1:@win3'
const AGENT = '⚡ agents / pr-flow|||agent:abc-123@@$s9:@w9:%pane3@@/code/clux'
const THIRD = 'main:tests 8/8 green|||$sess1:@win5'

const out = (stdout: string, exitCode = 0) => ({
  exitCode,
  stdout,
  stderr: '',
  isStdoutTruncated: false,
  isStderrTruncated: false,
})

// What the queue file holds; `null` is a file that is not there.
type Queue = { text: string | null }

// The world beneath the mod: the queue file, notification-line.sh, a host.
// The sessions pane loads from the same hooks module, so the calls it makes
// are answered here too.
function world(on: On, queue: Queue, env: Record<string, string> = {}) {
  const ran: string[][] = []
  const toasts: string[] = []
  const logs: string[] = []
  const closes: string[] = []
  const focuses: (string | undefined)[] = []
  // How notification-line.sh answers. `exits` and `rejects` are set by the
  // tests of the failure paths; by default every verb exits 0.
  const script = { exits: {} as Record<string, number>, rejects: new Set<string>() }
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/me', ...env })
  on('session.repo', () => ({ value: { root: ROOT, remote: null, internal: false, name: null } }))
  on('session.cwd', () => ({ value: ROOT }))
  on('session.id', () => ({ value: 'self' }))
  // The sessions pane reads ~/.claude/jobs: no background session here.
  on('fs.list', () => ({ value: [] }))
  on('fs.stat', ($, e) => ({
    value: { kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false, realPath: e.path },
  }))
  // Every read of the queue is counted, so a test can prove how many polls
  // one tick made.
  const reads = { count: 0 }
  on('fs.read', ($, e) => {
    if (e.path !== QUEUE) return { deny: 'ENOENT' }
    reads.count += 1
    if (queue.text === null) return { deny: 'ENOENT' }
    return { value: queue.text }
  })
  on('process.run', ($, e) => {
    ran.push([...e.argv])
    if (e.argv[0] === 'git') return { value: out('') }
    const verb = e.argv[1] ?? ''
    if (verb === 'path') return { value: out(`${QUEUE}\n`) }
    if (script.rejects.has(verb)) return { deny: 'spawn EACCES' }
    return { value: out('', script.exits[verb] ?? 0) }
  })
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  // The bottom of the focus chain: the ring moves where the hooks left it.
  on('ui.focus', ($, e) => {
    focuses.push(e.element)
    return {}
  })
  // The panes this plugin has open, as the engine would keep them.
  const panes = new Set<string>()
  on('ui.open', ($, e) => {
    panes.add(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', ($, e) => {
    panes.delete(e.id)
    closes.push(e.id)
    return { value: undefined }
  })
  on('ui.panes', () => ({
    value: [...panes].map(id => ({
      id, title: id, isShown: true, isFocused: true, isPlaced: true, plugin: 'clux',
    })),
  }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('ui.render', { component: 'SessionMode' }, ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box key="engine-modes">
        <Text dimColor>{e.props.modes.join(' & ')}</Text>
      </Box>
    )
  })

  return { clock, ran, toasts, logs, closes, focuses, panes, queue, reads, script }
}

const PANE_PROPS = {
  title: 'Notifications',
  isFocused: false,
  bodyColumns: 80,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 20 },
  view: {},
}

const mountPane = ($: Engine, isFocused = false) =>
  $.ui.mount({
    plugin: 'clux',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'notifications',
    props: { ...PANE_PROPS, isFocused },
  })

const start = ($: Engine) =>
  $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })

// The verb and the line of each notification-line.sh run, in order. The one
// `path` run of the session start is left out.
const lineRuns = (ran: string[][]) =>
  ran
    .filter(argv => (argv[0] ?? '').endsWith('/scripts/notification-line.sh') && argv[1] !== 'path')
    .map(argv => [argv[1], argv[2]])

const rowLabels = async (ui: Awaited<ReturnType<typeof mountPane>>) =>
  (await ui.findAll({ type: 'Button' }))
    .filter(button => (button.key ?? '').startsWith('row:'))
    .map(button => String(button.props.label))

test('the pane draws one row for each line of the queue', async ($, on) => {
  world(on, { text: `${WINDOW}\n${AGENT}\n` })
  await start($)

  const ui = await mountPane($)
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
  expect(texts).toContain('Notifications · 2')
  expect(await rowLabels(ui)).toEqual(['main:editor Task done', '⚡ agents / pr-flow'])
  expect((await ui.find({ key: 'row:0' }))?.props.autoFocus).toBe(true)
  expect((await ui.find({ key: 'row:1' }))?.props.autoFocus).toBeUndefined()
  await ui.unmount()
})

test('a queue file that is not there is an empty list', async ($, on) => {
  world(on, { text: null })
  await start($)

  const ui = await mountPane($)
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
  expect(texts).toContain('Notifications · 0')
  expect(texts).toContain('No notifications.')
  expect(await ui.find({ key: 'row:0' })).toBeUndefined()
  await ui.unmount()
})

test('a pane without the keys says how to move into it', async ($, on) => {
  world(on, { text: `${WINDOW}\n` })
  await start($)
  const hint = 'ctrl+x tab: move into the list'

  const texts = async (isFocused: boolean) => {
    const ui = await mountPane($, isFocused)
    const all = (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')
    await ui.unmount()
    return all
  }
  // A draft in the message box: Claude Code opens the pane without the keys.
  expect(await texts(false)).toContain(hint)
  expect((await texts(true)).includes(hint)).toBe(false)
})

test('Enter on a row jumps, takes the line out and closes the pane', async ($, on) => {
  const { ran, closes, queue } = world(on, { text: `${WINDOW}\n${AGENT}\n` }, IN_TMUX)
  await start($)
  const ui = await mountPane($, true)

  // The jump removes the line, so the next poll sees the shorter queue.
  queue.text = `${AGENT}\n`
  await ui.press({ key: 'row:0' })

  expect(lineRuns(ran)).toEqual([['jump', WINDOW], ['remove', WINDOW]])
  expect(closes).toEqual(['notifications'])
  expect(await rowLabels(ui)).toEqual(['⚡ agents / pr-flow'])
  await ui.unmount()
})

test('a run with no person at the prompt does not poll', async ($, on) => {
  const { clock, ran } = world(on, { text: `${WINDOW}\n` })
  await $.session.start({ cwd: ROOT, surface: null, isInteractive: false })
  await clock.advance(2000)
  await clock.settle()
  expect(ran.filter(argv => (argv[0] ?? '').endsWith('/scripts/notification-line.sh'))).toEqual([])
})

test('a start that runs twice keeps one timer', async ($, on) => {
  const { clock, reads } = world(on, { text: `${WINDOW}\n` })
  await start($)
  await start($)

  // Two live timers would read the queue twice in one tick.
  const before = reads.count
  await clock.advance(2000)
  await clock.settle()
  expect(reads.count - before).toBe(1)
})
```

- [ ] Step 2 (run the test, observe FAIL). `/Users/jazz/.local/bin/claude plugin test plugins/clux` fails every test of `notifications.test.tsx` with `$.ui.mount: no implementation for ui.render` (no hook draws the `notifications` pane).

- [ ] Step 3 (minimal implementation). Write `plugins/clux/hooks/notifications/register.tsx`:

```tsx
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { NotifRow } from '../../types'
import { toRows } from './lines'

const PANE = 'notifications'
const TITLE = 'Notifications'
// The status bar of tmux shows a new notification sooner, on its own
// interval; this is one file read.
const POLL_MS = 2000

const notifications = atom({ plugin: 'clux', key: 'notifications' } as const, [])

// The poll loop of this session: the queue path, read one time at the start.
const loop: { queue?: string; timer?: Timer; isPolling: boolean } = { isPolling: false }

// The plugin's own copy of the script, so the pane works from `--plugin-dir`
// with no /clux:setup. The tmux keys run the copy in ~/.config/clux/scripts/.
const script = ($: EngineInterface) => `${$.plugin.root}/scripts/notification-line.sh`

// One source for the queue path: the script resolves the three tiers.
async function queuePath($: EngineInterface): Promise<string> {
  const answer = await $.process.run([script($), 'path']).catch(() => undefined)
  const path = answer?.exitCode === 0 ? answer.stdout.trim() : ''
  if (path !== '') return path
  return `${await $.env.get('HOME')}/.config/tmux/claude_notification`
}

// A missing queue file is an empty list. The poll takes no lock: a writer can
// leave the file empty for a moment, and the next poll draws the right list.
async function poll($: EngineInterface) {
  const queue = loop.queue
  if (!queue) return
  const text = await $.fs.read(queue).catch(() => '')
  const list = toRows(typeof text === 'string' ? text : '')
  const before = await read($, notifications)
  if (JSON.stringify(list) !== JSON.stringify(before)) {
    await update($, notifications, () => list)
  }
}

// One poll at a time, so a slow poll and the next tick never overlap.
async function tick($: EngineInterface) {
  if (loop.isPolling) return
  loop.isPolling = true
  try {
    await poll($)
  } catch (error) {
    $.ui.log(`clux notifications: poll failed: ${String(error)}`, { to: 'debug' })
  } finally {
    loop.isPolling = false
  }
}

async function runLine($: EngineInterface, verb: 'jump' | 'remove', row: NotifRow) {
  const answer = await $.process.run([script($), verb, row.line])
  return answer.exitCode === 0
}

// Enter on a row. The jump leaves tmux on another window, so the pane closes:
// a pane that stays open shows the list of the window the person just left.
// The remove is needed because the status bar removes only the top line; for
// an agent line the jump removed it already and `remove` finds nothing.
async function jumpTo($: EngineInterface, row: NotifRow) {
  await runLine($, 'jump', row)
  await runLine($, 'remove', row)
  await $.ui.close({ id: PANE })
  await tick($)
}

export const register: Register = on => {
  // The matcher does two jobs. A `-p` run or the SDK has no person at the
  // prompt and no pane to show; and the sessions pane already registers
  // `session.start` with no matcher, and two unmatched hooks on one event in
  // one module are refused by the engine.
  on('session.start', { isInteractive: true }, async ($, e, next) => {
    try {
      loop.queue = await queuePath($)
      await tick($)
      loop.timer?.cancel()
      loop.timer = $.clock.every(POLL_MS, () => void tick($))
    } catch (error) {
      $.ui.log(`clux notifications: start failed: ${String(error)}`, { to: 'debug' })
    }

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, notifications)
    // The row text is cut to the pane, so one long notification cannot
    // reflow the list.
    const width = Math.max(8, e.props.bodyColumns - 1)

    return (
      <Box flexDirection="column">
        <Box>
          <Text bold>{TITLE} · {list.length} </Text>
        </Box>
        {/* Claude Code opens a pane without the keys while the message box
            has a draft, and a mod cannot take them: the person moves in. */}
        {!e.props.isFocused && list.length > 0 && (
          <Text dimColor>ctrl+x tab: move into the list</Text>
        )}
        {list.length === 0 && <Text dimColor>No notifications.</Text>}
        {list.map((row, i) => (
          <Button
            key={`row:${i}`}
            autoFocus={i === 0 ? true : undefined}
            plain
            label={row.text.slice(0, width)}
            onPress={() => jumpTo($, row)}
          />
        ))}
      </Box>
    )
  })
}
```

Write `plugins/clux/hooks/register.tsx`:

```tsx
// The one hooks module of clux.
//
// `hooks.json` takes a single `modules` entry for each plugin — `claude
// plugin validate` says so plainly: "hooks.json `modules` names one hooks
// module per plugin; a second entry is refused" — so this file composes the
// panes instead. Each pane keeps its own folder and its own `register`.
//
// The order is load-bearing. Two `ui.render` hooks on `SessionMode` chain,
// and the one registered FIRST is the outermost: it draws `next(e)` before
// its own label. Notifications first therefore leaves the sessions label on
// the left of the footer and puts the notifications label on the right.

import type { Register } from 'claude-code'

import { register as notifications } from './notifications/register'
import { register as sessions } from './sessions/register'

export const register: Register = (on, options) => {
  notifications(on, options)
  sessions(on, options)
}
```

Change the last line of `plugins/clux/hooks/hooks.json`:

```json
  "modules": ["./register.tsx"]
```

The composed module now runs the notifications `session.start` hook inside `plugins/clux/tests/sessions.test.tsx` too, and that file's test `a new question raises no toast and plays no sound` asserts the `process.run` list is empty of everything but `git` and `tmux`. The notifications hook's `queuePath` runs `notification-line.sh path`, so that one assertion must let it through. [inferred] The person allowed this one change only: let through only an `argv[0]` that ends in `/scripts/notification-line.sh` with `argv[1] === 'path'`; every other process (an audio player, `osascript`) still fails the test; the `toasts` assertion stays unchanged; no other line of `tests/sessions.test.tsx` or `hooks/sessions/` changes. Change line 237 of `plugins/clux/tests/sessions.test.tsx` from: [inferred]

```ts
expect(ran.filter(argv => argv[0] !== 'git' && argv[0] !== 'tmux')).toEqual([])
```

to: [inferred]

```ts
expect(ran.filter(argv => argv[0] !== 'git' && argv[0] !== 'tmux' && !((argv[0] ?? '').endsWith('/scripts/notification-line.sh') && argv[1] === 'path'))).toEqual([])
```

- [ ] Step 4 (run the test, observe PASS). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — 39 pass, 0 fail, across 4 files (the 13 sessions tests still pass from the composed module).

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/hooks/register.tsx plugins/clux/hooks/notifications/register.tsx plugins/clux/hooks/hooks.json plugins/clux/tests/notifications.test.tsx plugins/clux/tests/sessions.test.tsx
git commit -m "feat(clux): the notifications pane, its poll and Enter on a row"
```

**Verification:**

```bash
/Users/jazz/.local/bin/claude plugin test plugins/clux
# 39 pass, 0 fail

/Users/jazz/.local/bin/claude plugin validate plugins/clux
# "Validation passed with warnings", and the hooks line names both panes:
#   ./register.tsx hooks: session.start{isInteractive=true},
#   ui.render{component=Pane, requestId=notifications}, session.start,
#   command.run{command=clux:sessions}, ui.render{component=Pane,
#   requestId=sessions}, ui.render{component=SessionMode}

npx -y -p typescript@5.6.3 tsc -p plugins/clux --noEmit
# no output, exit 0
```

---

## Task 9: A jump that cannot happen

**Goal:** A failed jump, a session outside tmux, and a script that cannot start all show one toast, keep the row and keep the pane open.

**Files touched:**
- Modify: `plugins/clux/hooks/notifications/register.tsx`
- Modify: `plugins/clux/tests/notifications.test.tsx`

**Steps:**

- [ ] Step 1 (failing test). Append to `plugins/clux/tests/notifications.test.tsx`:

```tsx
test('a jump that exits 1 shows a toast, keeps the row and runs no remove', async ($, on) => {
  const { ran, toasts, closes, script } = world(on, { text: `${WINDOW}\n` }, IN_TMUX)
  await start($)
  script.exits.jump = 1
  const ui = await mountPane($, true)

  await ui.press({ key: 'row:0' })

  expect(lineRuns(ran)).toEqual([['jump', WINDOW]])
  expect(toasts).toEqual(['Could not jump to main:editor Task done.'])
  expect(closes).toEqual([])
  expect(await rowLabels(ui)).toEqual(['main:editor Task done'])
  await ui.unmount()
})

test('outside tmux Enter shows the toast and runs no script at all', async ($, on) => {
  const { ran, toasts, closes } = world(on, { text: `${WINDOW}\n` })
  await start($)
  const ui = await mountPane($, true)

  await ui.press({ key: 'row:0' })

  expect(lineRuns(ran)).toEqual([])
  expect(toasts).toEqual(['Could not jump to main:editor Task done.'])
  expect(closes).toEqual([])
  await ui.unmount()
})

test('a script that cannot start reads as exit 1, and says why in the debug log', async ($, on) => {
  const { toasts, logs, closes, script } = world(on, { text: `${WINDOW}\n` }, IN_TMUX)
  await start($)
  script.rejects.add('jump')
  const ui = await mountPane($, true)

  await ui.press({ key: 'row:0' })

  expect(toasts).toEqual(['Could not jump to main:editor Task done.'])
  expect(closes).toEqual([])
  expect(logs.some(line => line.includes('jump failed') && line.includes('EACCES'))).toBe(true)
  await ui.unmount()
})
```

- [ ] Step 2 (run the test, observe FAIL). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — the three new tests fail: no toast is raised, `remove` runs after a failed jump, the pane closes, and the rejecting script leaves the press errored.

- [ ] Step 3 (minimal implementation). In `plugins/clux/hooks/notifications/register.tsx`, replace `runLine` and `jumpTo`:

```tsx
// One verb of the shared script on one line. A script that cannot start, or
// that overruns its budget, reads as a failure exactly as a non-zero exit
// does; the reason goes to the debug log, never to the person.
async function runLine($: EngineInterface, verb: 'jump' | 'remove', row: NotifRow) {
  const answer = await $.process.run([script($), verb, row.line]).catch(error => {
    $.ui.log(`clux notifications: ${verb} failed: ${String(error)}`, { to: 'debug' })
    return undefined
  })
  return answer?.exitCode === 0
}

// Enter on a row. The jump leaves tmux on another window, so the pane closes:
// a pane that stays open shows the list of the window the person just left.
// The remove is needed because the status bar removes only the top line; for
// an agent line the jump removed it already and `remove` finds nothing.
//
// No tmux around Claude Code means no window to go to, so the script is not
// even started; the pane and the row both stay, and the person can still
// press `x`.
async function jumpTo($: EngineInterface, row: NotifRow) {
  const tmux = await $.env.get('TMUX')
  if (!tmux || !(await runLine($, 'jump', row))) {
    $.ui.toast(`Could not jump to ${row.text}.`)
    return
  }
  await runLine($, 'remove', row)
  await $.ui.close({ id: PANE })
  await tick($)
}
```

- [ ] Step 4 (run the test, observe PASS). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — 42 pass, 0 fail.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/hooks/notifications/register.tsx plugins/clux/tests/notifications.test.tsx
git commit -m "feat(clux): one toast for every jump the notifications pane cannot make"
```

**Verification:**

```bash
/Users/jazz/.local/bin/claude plugin test plugins/clux
# 42 pass, 0 fail

npx -y -p typescript@5.6.3 tsc -p plugins/clux --noEmit
# no output, exit 0
```

---

## Task 10: The focus hook, and the `j` and `k` keys

**Goal:** The pane remembers which row the ring is on, and `j` and `k` ask the engine to move it one row, inside the list.

**Files touched:**
- Modify: `plugins/clux/hooks/notifications/register.tsx`
- Modify: `plugins/clux/tests/notifications.test.tsx`

**Steps:**

- [ ] Step 1 (failing test). Append to `plugins/clux/tests/notifications.test.tsx`:

```tsx
// The row key of the last focus the mod asked for. `$.ui.focus` has no
// implementation beneath `claude plugin test` — it rejects with "no
// implementation for ui.focus", whatever the test registers — so every
// request is refused and the mod writes the key it asked for to the debug
// log. That the ring really moves is the live check of spec §6.0.
const lastFocusAsked = (logs: string[]) =>
  logs.filter(line => line.includes('the ring stayed off')).at(-1)?.match(/row:\d+/)?.[0]

const raiseFocus = ($: Engine, element?: string) =>
  $.ui.focus({
    component: 'Pane',
    requestId: 'notifications',
    element,
    origin: { kind: 'person' },
  })

test('the focus hook passes every move on, whatever takes the ring', async ($, on) => {
  const { focuses } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)
  const ui = await mountPane($, true)

  // A row, a header button, and one of the engine's own stops (no element).
  expect(await raiseFocus($, 'row:1')).toEqual({})
  expect(await raiseFocus($, 'nav-down')).toEqual({})
  expect(await raiseFocus($, undefined)).toEqual({})
  // A hook that does not call `next` would keep the ring where it was, and
  // Tab, the arrows, `j`, `k` and `x` would all move nothing.
  expect(focuses).toEqual(['row:1', 'nav-down', undefined])
  await ui.unmount()
})

test('j asks for the next row, and k stops at the first', async ($, on) => {
  const { logs } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)
  const ui = await mountPane($, true)

  expect((await ui.find({ key: 'nav-down' }))?.props.hotkey).toBe('j')
  expect((await ui.find({ key: 'nav-down' }))?.props.label).toBe('down')
  expect((await ui.find({ key: 'nav-up' }))?.props.hotkey).toBe('k')

  // The ring starts on the first row, so `j` asks for the second.
  await ui.press({ key: 'nav-down' })
  expect(lastFocusAsked(logs)).toBe('row:1')
  // The move was refused, so `focused` is still 0 and `k` stops there.
  await ui.press({ key: 'nav-up' })
  expect(lastFocusAsked(logs)).toBe('row:0')
  await ui.unmount()
})

test('j stops at the last row the list has', async ($, on) => {
  const { logs } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)
  const ui = await mountPane($, true)

  await raiseFocus($, 'row:2')
  await ui.press({ key: 'nav-down' })
  expect(lastFocusAsked(logs)).toBe('row:2')
  await ui.unmount()
})

test('j on an empty list asks for nothing', async ($, on) => {
  const { logs } = world(on, { text: null })
  await start($)
  const ui = await mountPane($, true)

  await ui.press({ key: 'nav-down' })
  expect(lastFocusAsked(logs)).toBeUndefined()
  await ui.unmount()
})
```

- [ ] Step 2 (run the test, observe FAIL). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — the four new tests fail: `ui.press: no element keyed nav-down is drawn`, and the first fails with `nothing beneath the plugins answers ui.focus` turning into an unmatched `focuses` list.

- [ ] Step 3 (minimal implementation). In `plugins/clux/hooks/notifications/register.tsx`, add the module variable and the two helpers after `jumpTo`:

```tsx
// The row the ring sits on. The `ui.focus` hook below is its only writer
// apart from `openPane`, which puts it back on the first row.
let focused = 0

// Move the ring. The pane may not hold the keys, and then the engine refuses
// the move: the person sees nothing, `focused` keeps its value, and the
// reason goes to the debug log. `j`, `k` and `x` all follow this rule.
async function focusRow($: EngineInterface, index: number) {
  const key = `row:${index}`
  const moved = await $.ui
    .focus({ requestId: PANE, key })
    .catch(error => ({ deny: String(error) }))
  if (moved.deny) {
    $.ui.log(`clux notifications: the ring stayed off ${key}: ${moved.deny}`, { to: 'debug' })
  }
}

// `j` and `k`: one row on, limited to the list. A poll can make the list
// shorter with no key press, so the upper limit is read from the list the
// last poll wrote.
async function move($: EngineInterface, by: number) {
  const list = await read($, notifications)
  if (list.length === 0) return
  await focusRow($, Math.min(list.length - 1, Math.max(0, focused + by)))
}
```

Add the hook, inside `register`, between the `session.start` hook and the `ui.render` hook:

```tsx
  // The ring records the row it lands on, then moves on: a `ui.focus` hook
  // that does not call `next` keeps the ring where it was, so Tab, the
  // arrows, `j`, `k` and `x` would all move nothing. A header button, or one
  // of the engine's own stops (the close mark, with no `element`), leaves
  // `focused` as it was, so `x` still acts on the row last focused.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
    const key = e.element ?? ''
    if (key.startsWith('row:')) {
      const index = Number(key.slice(4))
      if (Number.isInteger(index) && index >= 0) focused = index
    }

    return next(e)
  }).catch(($, e, next) => (next.called ? {} : next(e)))
```

Add the two buttons to the pane header:

```tsx
        <Box>
          <Text bold>{TITLE} · {list.length} </Text>
          {/* Claude Code draws a plain Button with a hotkey as "j: down". */}
          <Button key="nav-down" plain hotkey="j" label="down" onPress={() => move($, 1)} />
          <Text> </Text>
          <Button key="nav-up" plain hotkey="k" label="up" onPress={() => move($, -1)} />
        </Box>
```

- [ ] Step 4 (run the test, observe PASS). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — 46 pass, 0 fail.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/hooks/notifications/register.tsx plugins/clux/tests/notifications.test.tsx
git commit -m "feat(clux): j and k move the focus in the notifications pane"
```

**Verification:**

```bash
/Users/jazz/.local/bin/claude plugin test plugins/clux
# 46 pass, 0 fail

/Users/jazz/.local/bin/claude plugin validate plugins/clux
# "Validation passed with warnings"; the hooks line now names
# ui.focus{requestId=notifications}, and it is NOT listed under
# "gating hook without .catch"

npx -y -p typescript@5.6.3 tsc -p plugins/clux --noEmit
# no output, exit 0
```

---

## Task 11: The `x` key

**Goal:** `x` takes the focused row out of the queue, polls again, and leaves the ring at the same place in the shorter list.

**Files touched:**
- Modify: `plugins/clux/hooks/notifications/register.tsx`
- Modify: `plugins/clux/tests/notifications.test.tsx`

**Steps:**

- [ ] Step 1 (failing test). Append to `plugins/clux/tests/notifications.test.tsx`. These tests use `world`, `mountPane`, `start`, `lineRuns` and `rowLabels`, written in task 8, and `raiseFocus`, written in task 10:

```tsx
test('x takes the focused row out and polls again', async ($, on) => {
  const { ran, queue } = world(on, { text: `${WINDOW}\n${AGENT}\n` })
  await start($)
  const ui = await mountPane($, true)

  await raiseFocus($, 'row:1')
  queue.text = `${WINDOW}\n`
  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([['remove', AGENT]])
  expect(await rowLabels(ui)).toEqual(['main:editor Task done'])
  await ui.unmount()
})

test('x with no focus before it takes the first row out', async ($, on) => {
  const { ran, queue } = world(on, { text: `${WINDOW}\n${AGENT}\n` })
  await start($)
  const ui = await mountPane($, true)

  queue.text = `${AGENT}\n`
  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([['remove', WINDOW]])
  expect((await ui.find({ key: 'row-remove' }))?.props.hotkey).toBe('x')
  await ui.unmount()
})

test('x after a poll made the list shorter takes the last row out', async ($, on) => {
  const { ran, queue, clock } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)
  const ui = await mountPane($, true)

  await raiseFocus($, 'row:2')
  // The status bar took the top line while nobody pressed a key.
  queue.text = `${AGENT}\n${THIRD}\n`
  await clock.advance(2000)
  await clock.settle()
  queue.text = `${AGENT}\n`
  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([['remove', THIRD]])
  await ui.unmount()
})

test('a busy queue says so and keeps the row', async ($, on) => {
  const { ran, toasts, script, queue } = world(on, { text: `${WINDOW}\n` })
  await start($)
  script.exits.remove = 1
  const ui = await mountPane($, true)

  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([['remove', WINDOW]])
  expect(toasts).toEqual(['The queue is busy. Try again.'])
  expect(queue.text).toBe(`${WINDOW}\n`)
  expect(await rowLabels(ui)).toEqual(['main:editor Task done'])
  await ui.unmount()
})

test('x on an empty list runs nothing', async ($, on) => {
  const { ran } = world(on, { text: null })
  await start($)
  const ui = await mountPane($, true)

  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([])
  await ui.unmount()
})
```

- [ ] Step 2 (run the test, observe FAIL). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — the five new tests fail with `ui.press: no element keyed row-remove is drawn`.

- [ ] Step 3 (minimal implementation). In `plugins/clux/hooks/notifications/register.tsx`, add the helper after `move`:

```tsx
// `x`: the queue keeps a notification until the person has read it somewhere
// else, so this is the way to drop one from the pane. The index is limited
// to the list the last poll wrote, the same limit `j` and `k` use, because a
// poll can make the list shorter with no key press.
async function removeRow($: EngineInterface) {
  const list = await read($, notifications)
  if (list.length === 0) return
  const row = list[Math.min(focused, list.length - 1)]
  if (!row) return
  if (!(await runLine($, 'remove', row))) {
    $.ui.toast('The queue is busy. Try again.')
    return
  }
  await tick($)
  const after = await read($, notifications)
  // The ring stays at the same place, so taking the last row out moves it up
  // one. An empty list draws "No notifications." and has no row key at all.
  if (after.length > 0) await focusRow($, Math.min(focused, after.length - 1))
}
```

Add the third button to the pane header:

```tsx
        <Box>
          <Text bold>{TITLE} · {list.length} </Text>
          {/* Claude Code draws a plain Button with a hotkey as "j: down". */}
          <Button key="nav-down" plain hotkey="j" label="down" onPress={() => move($, 1)} />
          <Text> </Text>
          <Button key="nav-up" plain hotkey="k" label="up" onPress={() => move($, -1)} />
          <Text> </Text>
          <Button key="row-remove" plain hotkey="x" label="remove" onPress={() => removeRow($)} />
        </Box>
```

- [ ] Step 4 (run the test, observe PASS). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — 51 pass, 0 fail.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/hooks/notifications/register.tsx plugins/clux/tests/notifications.test.tsx
git commit -m "feat(clux): x takes a row out of the notification queue"
```

**Verification:**

```bash
/Users/jazz/.local/bin/claude plugin test plugins/clux
# 51 pass, 0 fail

npx -y -p typescript@5.6.3 tsc -p plugins/clux --noEmit
# no output, exit 0
```

---

## Task 12: The /clux:notifications command

**Goal:** `/clux:notifications` toggles the pane, `on` opens it and `off` closes it, and an older Claude Code gets a fallback text.

**Files touched:**
- Modify: `plugins/clux/hooks/notifications/register.tsx`
- Create: `plugins/clux/commands/notifications.md`
- Modify: `plugins/clux/tests/notifications.test.tsx`

**Steps:**

- [ ] Step 1 (failing test). Append to `plugins/clux/tests/notifications.test.tsx`. These tests use `world`, `mountPane`, `start` and `rowLabels`, written in task 8, and `lastFocusAsked`, written in task 10:

```tsx
const runNotifications = ($: Engine, args = '') =>
  $.command.run({
    command: 'clux:notifications',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 100 },
  })

test('/clux:notifications opens the pane, and /clux:notifications again closes it', async ($, on) => {
  const { panes } = world(on, { text: `${WINDOW}\n` })
  await start($)

  expect((await runNotifications($)).text).toContain('opened')
  expect(panes.has('notifications')).toBe(true)
  expect((await runNotifications($)).text).toContain('closed')
  expect(panes.has('notifications')).toBe(false)

  await runNotifications($, 'on')
  await runNotifications($, 'on')
  expect(panes.has('notifications')).toBe(true)
  await runNotifications($, 'off')
  expect(panes.has('notifications')).toBe(false)
})

test('opening the pane polls the queue first, and puts the ring on the first row', async ($, on) => {
  const { queue, logs } = world(on, { text: null })
  await start($)

  // A notification arrived between the last poll and the command.
  queue.text = `${WINDOW}\n${AGENT}\n`
  await runNotifications($, 'on')

  const ui = await mountPane($, true)
  expect(await rowLabels(ui)).toEqual(['main:editor Task done', '⚡ agents / pr-flow'])
  // The ring was put back on the first row, so `k` stays there.
  await ui.press({ key: 'nav-up' })
  expect(lastFocusAsked(logs)).toBe('row:0')
  await ui.unmount()
})
```

- [ ] Step 2 (run the test, observe FAIL). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — both new tests fail with `HooksError: no implementation for command.run` (nothing answers `clux:notifications`).

- [ ] Step 3 (minimal implementation). In `plugins/clux/hooks/notifications/register.tsx`, add the helper right after `tick`:

```tsx
// Asked (a command, a press) it seats at any width; `focus` hands it the
// keys. The ring goes back to the first row, so the command and the footer
// label share one reset and `j`, `k` and `x` act on the row the person sees
// first, until a `ui.focus` says otherwise.
async function openPane($: EngineInterface) {
  focused = 0
  await tick($)
  return $.ui.open({ id: PANE, title: TITLE, focus: true })
}
```

Move the `let focused = 0` declaration above `openPane`, so it is declared before its first use, and add the command hook inside `register`, after the `session.start` hook:

```tsx
  // `/clux:notifications` alone toggles the pane: it closes a pane that
  // shows, and opens one that is closed or a tab behind another. `on` and
  // `off` set it.
  on('command.run', { command: COMMAND }, async ($, e) => {
    const arg = e.args.trim()
    const isShown = (await $.ui.panes()).some(pane => pane.id === PANE && pane.isShown)
    if (arg === 'off' || (arg !== 'on' && isShown)) {
      await $.ui.close({ id: PANE })
      return { text: 'Notifications pane closed.' }
    }
    await openPane($)

    return { text: 'Notifications pane opened. Press Enter to go to a notification, or x to remove it.' }
  }).catch(($, e, next) => {
    $.ui.log(`clux notifications: command failed: ${String(next.error)}`, { to: 'debug' })
    return { text: 'The notifications pane did not respond. Try the command again.' }
  })
```

Add the constant next to `PANE`:

```tsx
// commands/notifications.md declares it; the hook below answers it.
const COMMAND = 'clux:notifications'
```

Write `plugins/clux/commands/notifications.md`:

```markdown
---
description: Show the clux notification queue in a pane
argument-hint: "[on|off]"
---

# clux Notifications

The clux notifications pane answers this command itself, so this text runs only when Claude Code did not load the pane.

Tell the person, in two short sentences: the notifications pane did not load, because it needs a Claude Code version with function hooks (2.1.291 or later). After an update, they start a new session and run `/clux:notifications` again.

Do nothing more.
```

- [ ] Step 4 (run the test, observe PASS). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — 53 pass, 0 fail.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/hooks/notifications/register.tsx plugins/clux/commands/notifications.md plugins/clux/tests/notifications.test.tsx
git commit -m "feat(clux): /clux:notifications toggles the notifications pane"
```

**Verification:**

```bash
/Users/jazz/.local/bin/claude plugin test plugins/clux
# 53 pass, 0 fail

/Users/jazz/.local/bin/claude plugin validate plugins/clux
# "Validation passed with warnings"; command.run{command=clux:notifications}
# is listed under "gating hook with .catch"

npx -y -p typescript@5.6.3 tsc -p plugins/clux --noEmit
# no output, exit 0

bats test/validate-hooks.bats test/setup-skill.bats
# all passing — the new command file changes no hook check
```

---

## Task 13: The footer label

**Goal:** One label at the end of the prompt footer counts the queue and opens the pane, to the right of the sessions label.

**Files touched:**
- Modify: `plugins/clux/hooks/notifications/register.tsx`
- Modify: `plugins/clux/tests/notifications.test.tsx`

**Steps:**

- [ ] Step 1 (failing test). Append to `plugins/clux/tests/notifications.test.tsx`:

```tsx
const FOOTER = {
  plugin: 'clux',
  surface: 'terminal' as const,
  component: 'SessionMode' as const,
}

test('the footer label counts the queue, and sits after the sessions label', async ($, on) => {
  const { clock, queue } = world(on, { text: `${WINDOW}\n${AGENT}\n${THIRD}\n` })
  await start($)

  const ui = await $.ui.mount({ ...FOOTER, props: { modes: ['focus'] } })
  const label = await ui.find({ key: 'open-notifications' })
  expect(label?.props.label).toBe('3 notifs')
  expect(label?.props.dimColor).toBe(false)
  // No chord: the label has no engine action to borrow.
  expect(label?.props.action).toBeUndefined()
  // The sessions label keeps the left of the footer.
  expect((await ui.findAll({ type: 'Button' })).map(button => button.key)).toEqual([
    'open-sessions',
    'open-notifications',
  ])
  await ui.unmount()

  queue.text = null
  await clock.advance(2000)
  await clock.settle()
  const quiet = await $.ui.mount({ ...FOOTER, props: { modes: [] } })
  const quietLabel = await quiet.find({ key: 'open-notifications' })
  expect(quietLabel?.props.label).toBe('notifs')
  expect(quietLabel?.props.dimColor).toBe(true)
  await quiet.unmount()
})

test('a click on the footer label opens the pane', async ($, on) => {
  const { panes } = world(on, { text: `${WINDOW}\n` })
  await start($)

  const ui = await $.ui.mount({ ...FOOTER, props: { modes: [] } })
  await ui.press({ key: 'open-notifications' })
  expect(panes.has('notifications')).toBe(true)
  await ui.unmount()
})
```

- [ ] Step 2 (run the test, observe FAIL). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — both new tests fail: `open-notifications` is not drawn, so `label` is undefined and `ui.press` finds no element.

- [ ] Step 3 (minimal implementation). In `plugins/clux/hooks/notifications/register.tsx`, add the last hook, after the `Pane` render hook:

```tsx
  // No band: one label at the end of the prompt footer, so a click opens the
  // pane while it is closed. It is dim until the queue has something in it,
  // and it carries no `action`, because this pane has no chord.
  //
  // `next(e)` draws first, so the sessions label stays on the left. The
  // separator needs no condition: the sessions hook always draws its own
  // label, so `next(e)` is never empty.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const list = await read($, notifications)
    const { Box, Text, Button } = $.ui.resolve(e)

    return (
      <Box>
        {await next(e)}
        <Text dimColor> & </Text>
        <Button
          key="open-notifications"
          plain
          dimColor={list.length === 0}
          label={list.length > 0 ? `${list.length} notifs` : 'notifs'}
          onPress={() => openPane($)}
        />
      </Box>
    )
  })
```

- [ ] Step 4 (run the test, observe PASS). `/Users/jazz/.local/bin/claude plugin test plugins/clux` — 55 pass, 0 fail, and the sessions test `the footer label holds the chord, and the band stays empty` still passes.

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add plugins/clux/hooks/notifications/register.tsx plugins/clux/tests/notifications.test.tsx
git commit -m "feat(clux): a notifs label at the end of the prompt footer"
```

**Verification:**

```bash
/Users/jazz/.local/bin/claude plugin test plugins/clux
# 55 pass, 0 fail

/Users/jazz/.local/bin/claude plugin validate plugins/clux
# "Validation passed with warnings"; ./register.tsx hooks names
# ui.render{component=SessionMode} twice, once for each pane

npx -y -p typescript@5.6.3 tsc -p plugins/clux --noEmit
# no output, exit 0
```

---

## Task 14: The changelog, the readme and the file tree

**Goal:** The 4.6.0 entry, the readme and the CONTRIBUTING file tree describe the pane and the two behaviour changes of the popup.

**Files touched:**
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `CONTRIBUTING.md`

**Steps:**

- [ ] Step 1 (failing test). `test/docs-tree.bats` is the test here, and it fails as soon as the tree misses a file. There is no new test file; the check is the whole bats suite of task 15 plus the two commands in the verification below. Run them first to see the state before the edit:

```bash
bats test/docs-tree.bats
# 3 tests, 3 passing (notification-line.sh went in at task 1)

grep -c 'clux:notifications' CHANGELOG.md README.md
# CHANGELOG.md:0
# README.md:0
```

- [ ] Step 2 (run the test, observe FAIL). The grep above prints `0` for both files: nothing in the released documentation mentions the pane's command. That is the gap this task closes. [inferred]

- [ ] Step 3 (minimal implementation). In `CHANGELOG.md`, put an `### Added` block between the `## [4.6.0]` heading and the existing `### Changed` heading, and put four lines at the top of that `### Changed` block, above the existing `**The sessions pane puts a session in the message box.**` line:

```markdown
## [4.6.0]

### Added

- **The notifications pane: `/clux:notifications`.** One pane for the clux notification queue — the same list the tmux status bar and the `prefix + M` popup show. Each row is one notification. `/clux:notifications` toggles the pane; `/clux:notifications on` and `/clux:notifications off` set it
- The keys of the pane: `j` and `k` move the focus, and the Down and Up arrows and Tab do the same. Enter goes to the tmux window (or the agents pane) of the focused row, takes that row out of the queue, and closes the pane. `x` takes the focused row out and keeps the pane open. Esc gives the keys back to the prompt. The header draws the three keys as buttons: `j: down`, `k: up` and `x: remove`
- The keys work only while the pane has the keyboard. With a draft in the message box, Claude Code opens the pane without it, and the pane shows `ctrl+x tab: move into the list`
- At the right end of the prompt footer, a dim `notifs` label opens the pane, and shows the count when the queue is not empty (`3 notifs`). The pane has no chord
- Outside tmux the pane still lists the queue and `x` still works; Enter says `Could not jump to <text>.`
- clux reads the queue file every 2 seconds, one poll at a time. A queue file that is not there is an empty list
- `scripts/notification-line.sh`, the one parse of a queue line: `path` prints the queue path, `jump "<line>"` goes to the window of a line, and `remove "<line>"` takes a line out of the queue. `prefix + m` and `prefix + M` both call it, so the two tmux keys and the pane share one copy of the parse

### Changed

- **`prefix + M` jumps by id.** Enter on an interactive line now uses the session id and the window id in the line, as `prefix + m` always did. Before, it used the session name and the window name, so a session renamed after the notification arrived went to the wrong window, or nowhere
- `prefix + M` with Ctrl-D removes an equal line only. Before, it also removed a longer line that held the selected line inside it
- `jump-to-notification.sh` and `notification-picker.sh` resolve the queue path with the same three tiers as the status bar: `CLUX_NOTIFY_FILE`, then `~/.config/clux/notify-file-path`, then `~/.config/tmux/claude_notification`. Before, both read two tiers and ignored the sidecar file
- clux has one hooks module, `hooks/register.tsx`, and it loads both panes. `hooks.json` takes one `modules` entry for each plugin
```

In `README.md`, add this section between the `## Background sessions pane` section and the `## Companion terminal` section:

````markdown
## Notifications pane

`/clux:notifications` opens one pane for the clux notification queue — the list the tmux status bar and the `prefix + M` popup show. `/clux:notifications` again closes it. This pane has no chord.

```
Notifications · 3        j: down  k: up  x: remove
main:editor Task done
⚡ agents / pr-flow needs you
main:tests 8/8 green
```

- `j` and `k` move the focus, and so do the Down and Up arrows and Tab. Enter goes to the tmux window of the focused row (or to the agents pane of an agent row), takes the row out of the queue, and closes the pane. `x` takes the focused row out and keeps the pane open. Esc gives the keyboard back to the prompt.
- The keys work only while the pane has the keyboard. When the message box has a draft, Claude Code opens the pane without it, and the pane says `ctrl+x tab: move into the list`. Press `ctrl+x tab` to move in.
- At the right end of the prompt footer, a dim `notifs` label opens the pane. When the queue is not empty, the label shows the count, for example `3 notifs`.
- clux reads the queue file every 2 seconds. The tmux status bar shows a new notification sooner, because tmux runs its own job on its own interval.
- Outside tmux the pane still lists the queue and `x` still works. Enter then says it could not jump.

The pane is a function-hooks mod (`hooks/notifications/`). It needs Claude Code 2.1.291 or later. The keys of this pane and the keys of the `prefix + M` popup both run `scripts/notification-line.sh`, so a jump means the same thing in both.
````

In `CONTRIBUTING.md`, change three parts of the file tree. The commands:

```
│   ├── follow.md                # /clux:follow — mirror mode on and off
│   ├── sessions.md              # /clux:sessions — the hooks module answers it
│   └── notifications.md         # /clux:notifications — the hooks module answers it
```

The hooks, the tests and the types:

```
├── hooks/
│   ├── hooks.json               # Auto-registered hooks, and the hooks module
│   ├── register.tsx             # The one hooks module: it loads both panes
│   ├── notify-tmux.sh           # Writes the notification queue
│   ├── agent-state.sh           # Writes the per-pane agent-state file
│   ├── notifications/           # The notification queue pane (function hooks)
│   │   ├── register.tsx         #   Pane, footer label, /clux:notifications
│   │   └── lines.ts             #   Pure helpers: the queue text as rows
│   └── sessions/                # The background sessions pane (function hooks)
│       ├── register.tsx         #   Pane, footer label, /clux:sessions, ctrl+x b
│       └── jobs.ts              #   Pure helpers: a job's state.json as one row
├── tests/                       # claude plugin test: both panes
├── types/index.d.ts             # The state of both panes
├── tsconfig.json                # tsc for the panes
```

And one sentence under the tree, after the paragraph about `config/deploy-manifest.txt`:

```markdown
`hooks/hooks.json` names exactly one hooks module, and `claude plugin validate`
refuses a second entry. `hooks/register.tsx` is that module: it calls the
`register` of each pane. Two hooks on one event in one module need a matcher on
at least one of them, and the `ui.render` hook registered first is the outermost
— it draws `next(e)` before its own label.
```

- [ ] Step 4 (run the test, observe PASS). `bats test/docs-tree.bats` — 3 tests, 3 passing, and `grep -c 'clux:notifications' CHANGELOG.md README.md` prints a count above zero for both files. [inferred]

- [ ] Step 5 (commit). The coordinator runs:

```bash
git add CHANGELOG.md README.md CONTRIBUTING.md
git commit -m "docs(clux): the notifications pane in 4.6.0, the readme and the file tree"
```

**Verification:**

```bash
bats test/docs-tree.bats test/deploy-manifest.bats
# 12 tests, 12 passing

grep -n '^## \[' CHANGELOG.md | head -2
# 5:## [4.6.0]
# ...:## [4.5.0]        — no new version entry was added

grep -n '"version"' plugins/clux/.claude-plugin/plugin.json
#   "version": "4.6.0",          — unchanged

grep -c 'notification-line.sh' CONTRIBUTING.md CHANGELOG.md
# both at least 1
```

---

## Task 15: The whole suite, and the report

**Goal:** Every check the run names passes, with only the two known failures, and the two human steps are reported as open.

**Files touched:** none.

**Steps:**

- [ ] Step 1 (failing test). There is nothing left to write. Run the four commands of the run as one block, and read every failure:

```bash
cd /Users/jazz/dev/github.com/ai-advanced-futures/clux-remove-sound
/Users/jazz/.local/bin/claude plugin test plugins/clux
/Users/jazz/.local/bin/claude plugin validate plugins/clux
npx -y -p typescript@5.6.3 tsc -p plugins/clux --noEmit
bats test/
```

- [ ] Step 2 (run the test, observe FAIL). Only two failures are allowed, both in `test/upgrade-clux.bats` and both already failing on `main`. Confirm that this is what is left:

```bash
bats test/ 2>&1 | grep '^not ok'
# exactly two lines, both naming test/upgrade-clux.bats cases
```

Any other failure is a defect of this work: go back to the task that owns the file named in it.

- [ ] Step 3 (minimal implementation). Check that nothing compiled was left behind, and that the module list and the version are as the run requires:

```bash
find plugins/clux -name '*.js' -not -path '*/node_modules/*'
# no output

git status --porcelain
# only the files the 14 tasks touched, nothing under plugins/clux/hooks/sessions/

git diff --stat HEAD -- plugins/clux/hooks/sessions plugins/clux/.claude-plugin/plugin.json
# no output — two untouched paths [inferred]

git diff HEAD -- plugins/clux/tests/sessions.test.tsx
# one line changed, the process.run filter of task 8 [inferred]
```

- [ ] Step 4 (run the test, observe PASS). The four commands give: `55 pass, 0 fail` from `claude plugin test`; `Validation passed with warnings` from `claude plugin validate`; no output from `tsc`; and `bats test/` with exactly the two known `upgrade-clux.bats` failures.

- [ ] Step 5 (commit). Nothing to commit. Report the work, and name the two steps that are still open:

- Spec §6.0, the live key spike: `j`, `k`, `x` and Enter in a real tmux session with `--plugin-dir`, to see the ring move. In `claude plugin test` the plugin's `$.ui.focus` has no implementation and every request is refused, so only a person can see this. If the ring does not move, drop the `nav-down` and `nav-up` buttons and keep `autoFocus` and the arrows.
- Spec §6.3, the live check: the five steps of §6.3 with two notifications in two other windows.

Also report the three design changes the spike forced, all of them inside the fallback spec §6.0 names, and none of them touching `hooks/sessions/`:

1. `hooks.json` keeps one `modules` entry, and the new `hooks/register.tsx` calls both panes' `register`.
2. The notifications `session.start` hook carries the matcher `{ isInteractive: true }`, so it sits beside the unmatched one of the sessions pane.
3. The pane logs a refused `$.ui.focus` to the debug log, which is what makes `j`, `k` and `x` testable at all.

**Verification:**

```bash
/Users/jazz/.local/bin/claude plugin test plugins/clux
# 55 pass, 0 fail, across 4 files

/Users/jazz/.local/bin/claude plugin validate plugins/clux
# ✔ Validation passed with warnings

npx -y -p typescript@5.6.3 tsc -p plugins/clux --noEmit
# no output, exit 0

bats test/ 2>&1 | tail -3
# the run total, with 2 failures, both in test/upgrade-clux.bats

bats test/notification-line.bats
# 21 tests, 21 passing
```
