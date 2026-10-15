# clux notification filters and ctrl+x delete — Implementation Plan

**Goal:** Ship clux 5.2.0. Ctrl-X in the `prefix + M` popup deletes a notification and keeps the popup open. A per-repo file, `<main repo root>/.claude/clux-filters.local`, hides the notifications of some Claude sessions with `allow`/`deny` regex rules. The Claude Code notifications pane has a Filters view to edit the file, and the tmux status bar shows a mark when the repo of the active pane has filters.

**Architecture:** One new shell script, `scripts/notify-filter.sh`, owns the filter file: the path, the parse, the order rule, the `grep -E` regex check and every write. The hook (`hooks/notify-tmux.sh`), the status bar (`scripts/session-bar-refresh.sh`) and the pane mod (`hooks/notifications/register.tsx`) all run it, so there is one parser and one regex type. The popup (`scripts/notification-picker.sh`) runs fzf in a shell loop, so a delete starts fzf again on the new queue.

**Tech Stack:** bash (3.2 and 5.x), git 2.31 or later (`rev-parse --path-format`), grep -E, awk, tmux 3.x, fzf, bats-core, Claude Code function-hooks mods (TypeScript/TSX, `claude plugin test`, `tsc`).

---

## Overview

The spec is `docs/superpowers/specs/2026-10-15-clux-notification-filters-design.md`. The plan builds the filter script first (Task 1: the read verbs; Task 2: the write verbs), because the hook (Task 3), the status bar mark (Task 5) and the pane (Tasks 6 to 8) all call it. The popup loop (Task 4) does not use the filter and can be done in any order. Task 9 sets the version to 5.2.0 and writes the docs. After each task, the bats files and the mod tests that the task touches pass, and `bats test/deploy-manifest.bats test/docs-tree.bats` stays green (Task 1 adds the manifest line and the file tree line in the same commit as the new script).

All the code in this plan was run against a copy of the repo before the plan was written: the 22 `notify-filter.bats` tests, the 5 new `notify-tmux.bats` tests, the 5 new `picker.bats` tests, the 8 new `session-bar-refresh.bats` tests, `deploy-manifest.bats`, `docs-tree.bats`, all 85 mod tests and `tsc -p plugins/clux` passed. The red step was also run for Tasks 2, 3, 4, 7 and 8; for Tasks 1, 5, 6 and 9 the expected failure follows from a missing script, a missing mark, a missing module or a missing skill line.

### How to run the tests

- bats: `bats <file>` from the repo root. If `bats` is not on `PATH`, run `eval "$(fnm env)"` first, which puts the fnm global `bats` on `PATH`; if that still does not find `bats`, install it (for example `npm install -g bats`) before continuing.
- Mod tests: `claude plugin test plugins/clux` runs every `*.test.ts` and `*.test.tsx` under `plugins/clux/tests/`. It has no file filter; read the `(pass)` and `(fail)` lines.
- Type check: `tsc -p plugins/clux`. It needs `plugins/clux/.claude-plugin/types/`, which Claude Code writes when it loads the plugin (for example `claude --plugin-dir plugins/clux`, then quit). Do not commit that folder.
- Known failures on this machine, also on `main`: the `box:` tests of `test/new-workspace-prompt.bats`, `the retry after a 503 runs only in the time that is left in the gate limit` in `test/clef-client.bats`, and 5 Laya/Python tests in `test/terminal.bats`. They are not regressions of this plan. The full `bats test/` run takes more than 15 minutes.
- Commits: the push refuses `404.pilo.code@gmail.com`, which is the `user.email` of this checkout. Each `git commit` below sets the noreply identity with `-c user.email=1195406+404pilo@users.noreply.github.com`.

### Decisions this plan makes where the spec is open

- `set` and `remove` accept each line that `list` prints, also an `invalid` line, so the person can mend or remove a bad line. They exit 3 only for a blank line, a comment or a line number past the end. [inferred]
- The parse accepts spaces or tabs between the word and the regex, and spaces before the word. A line whose first non-space character is `#` is a comment. [inferred]
- `add`, `set` and `remove` outside a git repo exit 1 with `not in a git repo: <cwd>` on stderr. `list` with no file prints nothing and exits 0. A bad kind or a bad line number exits 2. `add` and `set` remove the spaces at the start and the end of the regex, and refuse a regex with a line break (exit 2). [inferred]
- On the quiet path, argument 2 of `session-bar-refresh.sh` is `#{client_pid}`, and `display-message -c` takes a client name, not a pid. So the mark code maps the pid to the active pane path with one `tmux list-clients -F` call. [inferred]
- `#{@clux-filter-mark}` gives an empty string both for an unset option and for an empty value. `tmux show-option -gv` (with no `-q`) exits 1 for an unset option (checked on tmux 3.6), so the mark code uses the default only on that exit. [inferred]
- The pane reads `path` one time at the session start, not when the pane opens, so a pane that is drawn before `/clux:notifications` already knows the file. [inferred]
- The `editing` state has a `value` field that holds the text of the rule box. After a refused rule it holds what the person typed, so a redraw does not lose the text. [inferred]
- `InputProps` has no Esc callback. Esc gives the keys back to the focus ring, and the `ui.focus` hook closes the rule box when the ring lands on an element that is not the box. A live check in Task 9 confirms this. [inferred]
- A `Button` has no `color` prop, so an `invalid` row is a red `invalid ` text before the Button that holds the raw line. [inferred]
- The mobile surface has no `Input`: there the pane draws no rule box. [inferred]
- Toasts: a first word that is not `allow` or `deny` gives `A rule starts with allow or deny.`; exit 2 with no stderr gives `The rule was not saved.`; a script that does not start, or another exit code, gives `The filter file did not change.` [inferred]
- `t` on an `invalid` row does nothing; `e` mends it. Exit 3 from the rule box closes the box, because its line number is no longer true. [inferred]
- `@clux-filter-mark` gets no `render-clux-conf.sh` flag. The setup skill lists it as an option that the person sets in their own file, as it does for `@clux-agent-glyph-busy-frames`. [inferred]

---

## Task 1: notify-filter.sh reads the filter file

**Goal:** `scripts/notify-filter.sh` has the `path`, `list`, `check` and `active` verbs, and the deploy manifest and the CONTRIBUTING file tree list it.

**Files touched:**
- Create: `plugins/clux/scripts/notify-filter.sh`
- Modify: `plugins/clux/config/deploy-manifest.txt`
- Modify: `CONTRIBUTING.md`
- Test: `test/notify-filter.bats` (new)
- Test: `test/deploy-manifest.bats`

**Steps:**

- [ ] Step 1 (failing test): Create `test/notify-filter.bats` with this content:

```bash
#!/usr/bin/env bats
# notify-filter.bats — scripts/notify-filter.sh: the per-repo notification
# filter file. Its path from a checkout and from a worktree, its parse, the
# order rule of allow and deny, and (Task 2) its writes.

load test_helper

FILTER="$SCRIPTS_DIR/notify-filter.sh"
HEADER='# clux notification filters. Regex type: grep -E, case-sensitive.'

# A git repo with one commit, so that a worktree can be added. The path is
# canonical (pwd -P): git prints the real path, and /tmp is a link on macOS.
_repo() {
    REPO="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/repo"
    git init -q "$REPO"
    git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
    RULES="$REPO/.claude/clux-filters.local"
}

# _rules LINE... — the filter file of $REPO, one line for each argument.
_rules() {
    mkdir -p "$REPO/.claude"
    printf '%s\n' "$@" > "$RULES"
}

@test "notify-filter: path is the file of the main checkout, also from a subfolder" {
    _repo
    mkdir -p "$REPO/src/deep"
    run "$FILTER" path "$REPO/src/deep"
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO/.claude/clux-filters.local" ]
}

@test "notify-filter: a worktree finds the file of the main checkout" {
    _repo
    git -C "$REPO" worktree add -q "$BATS_TEST_TMPDIR/wt" -b wt 2>/dev/null
    _rules 'deny ^wt$'
    run "$FILTER" path "$BATS_TEST_TMPDIR/wt"
    [ "$status" -eq 0 ]
    [ "$output" = "$RULES" ]
    run "$FILTER" check "$BATS_TEST_TMPDIR/wt" wt
    [ "$status" -eq 1 ]
}

@test "notify-filter: outside git, path and list exit 1, check exits 0, active exits 1" {
    local plain="$BATS_TEST_TMPDIR/plain"
    mkdir -p "$plain"
    export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
    run "$FILTER" path "$plain"
    [ "$status" -eq 1 ]
    run "$FILTER" list "$plain"
    [ "$status" -eq 1 ]
    run "$FILTER" check "$plain" anything
    [ "$status" -eq 0 ]
    run "$FILTER" active "$plain"
    [ "$status" -eq 1 ]
}

@test "notify-filter: list skips comments and blank lines, trims spaces, and marks invalid lines" {
    _repo
    _rules '# my filters' '' 'allow   ^feat-  ' '  deny wip' 'block foo' 'deny (' 'deny' "$(printf 'allow\ttab')"
    run "$FILTER" list "$REPO"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '3\tallow\t^feat-\n4\tdeny\twip\n5\tinvalid\tblock foo\n6\tinvalid\tdeny (\n7\tinvalid\tdeny\n8\tallow\ttab')" ]
}

@test "notify-filter: list with no file prints nothing and exits 0" {
    _repo
    run "$FILTER" list "$REPO"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "notify-filter: check with no file, or with no valid rule, shows the notification" {
    _repo
    run "$FILTER" check "$REPO" main
    [ "$status" -eq 0 ]
    _rules '# only bad lines' 'deny (' 'block main'
    run "$FILTER" check "$REPO" main
    [ "$status" -eq 0 ]
}

@test "notify-filter: deny only hides the names it matches" {
    _repo
    _rules 'deny wip'
    run "$FILTER" check "$REPO" feat-wip
    [ "$status" -eq 1 ]
    run "$FILTER" check "$REPO" main
    [ "$status" -eq 0 ]
}

@test "notify-filter: allow only lets only the names it matches notify" {
    _repo
    _rules 'allow ^feat-'
    run "$FILTER" check "$REPO" feat-login
    [ "$status" -eq 0 ]
    run "$FILTER" check "$REPO" main
    [ "$status" -eq 1 ]
}

@test "notify-filter: allow and deny together — allow first, then deny, whatever the line order" {
    _repo
    _rules 'deny wip' 'allow ^feat-'
    run "$FILTER" check "$REPO" feat-login
    [ "$status" -eq 0 ]
    run "$FILTER" check "$REPO" feat-wip
    [ "$status" -eq 1 ]
    run "$FILTER" check "$REPO" main
    [ "$status" -eq 1 ]
}

@test "notify-filter: active needs one valid rule" {
    _repo
    run "$FILTER" active "$REPO"
    [ "$status" -eq 1 ]
    _rules '# comment' '' 'deny ('
    run "$FILTER" active "$REPO"
    [ "$status" -eq 1 ]
    _rules '# comment' 'deny wip'
    run "$FILTER" active "$REPO"
    [ "$status" -eq 0 ]
}
```

Then add this test at the end of `test/deploy-manifest.bats`:

```bash
@test "deploy-manifest: lists notify-filter.sh — the status bar runs the deployed copy" {
    # session-bar-refresh.sh runs from ~/.config/clux/scripts and calls
    # notify-filter.sh beside it, so the filter script must be deployed too.
    _manifest_entries | grep -qxF notify-filter.sh
}
```

- [ ] Step 2 (run test, observe FAIL):

```
bats test/notify-filter.bats test/deploy-manifest.bats
```

Expected: all 10 `notify-filter:` tests fail (`run` gives status 127: the script does not exist), and `deploy-manifest: lists notify-filter.sh — the status bar runs the deployed copy` fails.

- [ ] Step 3 (minimal implementation): Create `plugins/clux/scripts/notify-filter.sh` with this content, then run `chmod +x plugins/clux/scripts/notify-filter.sh`:

```bash
#!/usr/bin/env bash
# The per-repo notification filter: one file, one parser, one regex type.
#
#   notify-filter.sh path   <cwd>                          prints the file path
#   notify-filter.sh check  <cwd> <name>                   0 show, 1 hide
#   notify-filter.sh active <cwd>                          0 if a valid rule exists
#   notify-filter.sh list   <cwd>                          "<n>\t<kind>\t<regex>" lines
#   notify-filter.sh add    <cwd> allow|deny <regex>       adds a rule at the end
#   notify-filter.sh set    <cwd> <n> allow|deny <regex>   replaces line <n>
#   notify-filter.sh remove <cwd> <n>                      removes line <n>
#
# The file is <main repo root>/.claude/clux-filters.local, so all the
# worktrees of a repo read one file. A rule is "allow <regex>" or
# "deny <regex>". The regex is grep -E, case-sensitive, and it matches the
# Claude session name. If the file has an allow rule, the name must match
# one; then a deny rule that matches hides the notification.
#
# The hook (notify-tmux.sh), the status bar (session-bar-refresh.sh) and the
# notifications pane all run this script. No caller has a second parser that
# can disagree with this one (for example on \d).
#
# Exit codes: 0 done. 1 no: check hides, active finds no valid rule, and
# path, list, add, set and remove find no git repo. 2 a bad regex, an empty
# regex or a bad argument. 3 line <n> is not a rule line (the file changed
# after the list of the caller).

VERB="${1:-}"
CWD="${2:-}"

RULE_RE='^(allow|deny)[[:space:]]+(.*[^[:space:]])[[:space:]]*$'

COMMON=""
ROOT=""
FILE=""

_locate() {
    [ -n "$CWD" ] || return 1
    COMMON=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    [ -n "$COMMON" ] || return 1
    ROOT=$(dirname "$COMMON")
    FILE="$ROOT/.claude/clux-filters.local"
}

_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_regex_ok() {
    printf '' | grep -E -- "$1" >/dev/null 2>&1
    [ $? -ne 2 ]
}

_parse() {
    local line
    line=$(_trim "$1")
    case "$line" in
        ''|'#'*) return 1 ;;
    esac
    KIND=invalid
    REGEX="$1"
    if [[ "$line" =~ $RULE_RE ]] && _regex_ok "${BASH_REMATCH[2]}"; then
        KIND="${BASH_REMATCH[1]}"
        REGEX="${BASH_REMATCH[2]}"
    fi
    return 0
}

_match() {
    printf '%s\n' "$1" | grep -Eq -- "$2" 2>/dev/null
}

_list() {
    local n=0 line
    [ -f "$FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        _parse "$line" || continue
        printf '%s\t%s\t%s\n' "$n" "$KIND" "$REGEX"
    done < "$FILE"
}

_check() {
    local name="$1" line has_allow=0 allowed=0 denied=0
    [ -f "$FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        _parse "$line" || continue
        case "$KIND" in
            allow)
                has_allow=1
                _match "$name" "$REGEX" && allowed=1
                ;;
            deny)
                _match "$name" "$REGEX" && denied=1
                ;;
        esac
    done < "$FILE"
    [ "$has_allow" = 1 ] && [ "$allowed" = 0 ] && return 1
    [ "$denied" = 1 ] && return 1
    return 0
}

_active() {
    local line
    [ -f "$FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        _parse "$line" || continue
        [ "$KIND" = invalid ] || return 0
    done < "$FILE"
    return 1
}

case "$VERB" in
    path)
        _locate || exit 1
        printf '%s\n' "$FILE"
        exit 0
        ;;
    check)
        _locate || exit 0
        _check "${3:-}"
        exit $?
        ;;
    active)
        _locate || exit 1
        _active
        exit $?
        ;;
    list)
        _locate || exit 1
        _list
        exit 0
        ;;
esac
printf 'usage: notify-filter.sh path|check|active|list <cwd> ...\n' >&2
exit 2
```

In `plugins/clux/config/deploy-manifest.txt`, in the `# Notifications` group, put the new line after `notify-sound.sh`:

```
notify-sound.sh
notify-filter.sh
truncate-title.sh
```

In `CONTRIBUTING.md`, in the `plugins/clux/` tree, put the new line after the `notify-sound.sh` line:

```
│   ├── notify-sound.sh          # Sound playback per notification type
│   ├── notify-filter.sh         # The per-repo filter file: parse, check, edit
```

- [ ] Step 4 (run test, observe PASS):

```
bats test/notify-filter.bats test/deploy-manifest.bats test/docs-tree.bats
```

Expected: every test prints `ok` (10 `notify-filter:`, 10 `deploy-manifest:`, 3 `docs-tree:`).

- [ ] Step 5 (commit):

```
git add plugins/clux/scripts/notify-filter.sh plugins/clux/config/deploy-manifest.txt CONTRIBUTING.md test/notify-filter.bats test/deploy-manifest.bats
git -c user.email=1195406+404pilo@users.noreply.github.com commit -m "feat(clux): notify-filter.sh reads the per-repo filter file" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Verification:**

- `bats test/notify-filter.bats` prints `1..10` and 10 `ok` lines.
- `test -x plugins/clux/scripts/notify-filter.sh && echo exec` prints `exec`.
- Run these four commands one at a time:
  1. `git init -q /tmp/nf-check`
  2. `mkdir -p /tmp/nf-check/.claude && printf 'deny wip\n' > /tmp/nf-check/.claude/clux-filters.local`
  3. `plugins/clux/scripts/notify-filter.sh list /tmp/nf-check` prints `1	deny	wip` (a tab between the fields).
  4. `plugins/clux/scripts/notify-filter.sh check /tmp/nf-check feat-wip; echo $?` prints `1`.

  Then `rm -rf /tmp/nf-check` removes the test repo.

---

## Task 2: notify-filter.sh edits the filter file

**Goal:** `notify-filter.sh` has the `add`, `set` and `remove` verbs, with the regex check, the stale-line check, the atomic write and the `info/exclude` line.

**Files touched:**
- Modify: `plugins/clux/scripts/notify-filter.sh`
- Test: `test/notify-filter.bats`

**Steps:**

- [ ] Step 1 (failing test): Add these tests at the end of `test/notify-filter.bats`:

```bash
@test "notify-filter: add makes the folder and the file with the header, then adds at the end" {
    _repo
    run "$FILTER" add "$REPO" deny wip
    [ "$status" -eq 0 ]
    run "$FILTER" add "$REPO" allow '  ^feat-  '
    [ "$status" -eq 0 ]
    [ "$(cat "$RULES")" = "$(printf '%s\n' "$HEADER" 'deny wip' 'allow ^feat-')" ]
}

@test "notify-filter: add after a last line with no newline starts a new line" {
    _repo
    mkdir -p "$REPO/.claude"
    printf 'deny wip' > "$RULES"
    run "$FILTER" add "$REPO" deny tmp
    [ "$status" -eq 0 ]
    [ "$(cat "$RULES")" = "$(printf '%s\n' 'deny wip' 'deny tmp')" ]
}

@test "notify-filter: add writes info/exclude once, and only when git does not ignore the file" {
    _repo
    run "$FILTER" add "$REPO" deny wip
    [ "$status" -eq 0 ]
    run "$FILTER" add "$REPO" deny tmp
    [ "$status" -eq 0 ]
    [ "$(grep -cxF '/.claude/clux-filters.local' "$REPO/.git/info/exclude")" -eq 1 ]
    git -C "$REPO" check-ignore -q .claude/clux-filters.local
}

@test "notify-filter: add leaves info/exclude alone when the repo already ignores the file" {
    _repo
    printf '.claude/\n' > "$REPO/.gitignore"
    run "$FILTER" add "$REPO" deny wip
    [ "$status" -eq 0 ]
    run grep -qF 'clux-filters.local' "$REPO/.git/info/exclude"
    [ "$status" -ne 0 ]
}

@test "notify-filter: add from a worktree writes the file and the exclude of the main checkout" {
    _repo
    git -C "$REPO" worktree add -q "$BATS_TEST_TMPDIR/wt" -b wt 2>/dev/null
    run "$FILTER" add "$BATS_TEST_TMPDIR/wt" deny wip
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$RULES")" = 'deny wip' ]
    grep -qxF '/.claude/clux-filters.local' "$REPO/.git/info/exclude"
    [ ! -e "$BATS_TEST_TMPDIR/wt/.claude/clux-filters.local" ]
}

@test "notify-filter: add with a bad regex exits 2 with the grep error, and makes no file" {
    _repo
    run "$FILTER" add "$REPO" deny '('
    [ "$status" -eq 2 ]
    [ -n "$output" ]
    [ ! -e "$RULES" ]
    run "$FILTER" add "$REPO" deny '   '
    [ "$status" -eq 2 ]
    [ "$output" = 'empty regex' ]
    run "$FILTER" add "$REPO" block wip
    [ "$status" -eq 2 ]
    [ ! -e "$RULES" ]
}

@test "notify-filter: set replaces the line it names, and keeps a backslash" {
    _repo
    _rules '# filters' 'allow ^feat-' 'deny wip'
    run "$FILTER" set "$REPO" 3 allow 'a\.b'
    [ "$status" -eq 0 ]
    [ "$(cat "$RULES")" = "$(printf '%s\n' '# filters' 'allow ^feat-' 'allow a\.b')" ]
    run "$FILTER" list "$REPO"
    [ "$output" = "$(printf '2\tallow\t^feat-\n3\tallow\ta\\.b')" ]
}

@test "notify-filter: set can fix an invalid line" {
    _repo
    _rules 'deny ('
    run "$FILTER" set "$REPO" 1 deny '\('
    [ "$status" -eq 0 ]
    [ "$(cat "$RULES")" = 'deny \(' ]
}

@test "notify-filter: set with a bad regex exits 2 and does not change the file" {
    _repo
    _rules '# filters' 'allow ^feat-'
    local before; before=$(cat "$RULES")
    run "$FILTER" set "$REPO" 2 deny '('
    [ "$status" -eq 2 ]
    [ "$(cat "$RULES")" = "$before" ]
}

@test "notify-filter: set and remove on a stale line number exit 3 and do not change the file" {
    _repo
    _rules '# filters' 'allow ^feat-' ''
    local before; before=$(cat "$RULES")
    run "$FILTER" set "$REPO" 1 deny x
    [ "$status" -eq 3 ]
    run "$FILTER" set "$REPO" 3 deny x
    [ "$status" -eq 3 ]
    run "$FILTER" set "$REPO" 9 deny x
    [ "$status" -eq 3 ]
    run "$FILTER" remove "$REPO" 9
    [ "$status" -eq 3 ]
    run "$FILTER" remove "$REPO" 0
    [ "$status" -eq 2 ]
    [ "$(cat "$RULES")" = "$before" ]
}

@test "notify-filter: remove takes out the line it names, and the file stays with no rules" {
    _repo
    _rules '# filters' 'allow ^feat-' 'deny wip'
    run "$FILTER" remove "$REPO" 2
    [ "$status" -eq 0 ]
    [ "$(cat "$RULES")" = "$(printf '%s\n' '# filters' 'deny wip')" ]
    run "$FILTER" remove "$REPO" 2
    [ "$status" -eq 0 ]
    [ -f "$RULES" ]
    [ "$(cat "$RULES")" = '# filters' ]
}

@test "notify-filter: a write leaves no temporary file" {
    _repo
    run "$FILTER" add "$REPO" deny wip
    run "$FILTER" set "$REPO" 2 deny tmp
    run "$FILTER" remove "$REPO" 2
    [ "$(ls -A "$REPO/.claude")" = 'clux-filters.local' ]
}
```

- [ ] Step 2 (run test, observe FAIL):

```
bats test/notify-filter.bats
```

Expected: the 10 Task 1 tests print `ok`. The new `add`, `set` and `remove` tests print `not ok`, because each write verb reaches the usage line and exits 2 with no change. `set with a bad regex exits 2 and does not change the file` can print `ok` already, because the usage error is exit 2 too; Step 4 keeps it green for the real reason.

- [ ] Step 3 (minimal implementation): Replace the whole content of `plugins/clux/scripts/notify-filter.sh` with this content (the Task 1 script plus `HEADER`, the write functions and the `add|set|remove` arm):

```bash
#!/usr/bin/env bash
# The per-repo notification filter: one file, one parser, one regex type.
#
#   notify-filter.sh path   <cwd>                          prints the file path
#   notify-filter.sh check  <cwd> <name>                   0 show, 1 hide
#   notify-filter.sh active <cwd>                          0 if a valid rule exists
#   notify-filter.sh list   <cwd>                          "<n>\t<kind>\t<regex>" lines
#   notify-filter.sh add    <cwd> allow|deny <regex>       adds a rule at the end
#   notify-filter.sh set    <cwd> <n> allow|deny <regex>   replaces line <n>
#   notify-filter.sh remove <cwd> <n>                      removes line <n>
#
# The file is <main repo root>/.claude/clux-filters.local, so all the
# worktrees of a repo read one file. A rule is "allow <regex>" or
# "deny <regex>". The regex is grep -E, case-sensitive, and it matches the
# Claude session name. If the file has an allow rule, the name must match
# one; then a deny rule that matches hides the notification.
#
# The hook (notify-tmux.sh), the status bar (session-bar-refresh.sh) and the
# notifications pane all run this script. No caller has a second parser that
# can disagree with this one (for example on \d).
#
# Exit codes: 0 done. 1 no: check hides, active finds no valid rule, and
# path, list, add, set and remove find no git repo. 2 a bad regex, an empty
# regex or a bad argument. 3 line <n> is not a rule line (the file changed
# after the list of the caller).

VERB="${1:-}"
CWD="${2:-}"

HEADER='# clux notification filters. Regex type: grep -E, case-sensitive.'
RULE_RE='^(allow|deny)[[:space:]]+(.*[^[:space:]])[[:space:]]*$'

COMMON=""
ROOT=""
FILE=""

_locate() {
    [ -n "$CWD" ] || return 1
    COMMON=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    [ -n "$COMMON" ] || return 1
    ROOT=$(dirname "$COMMON")
    FILE="$ROOT/.claude/clux-filters.local"
}

_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_regex_ok() {
    printf '' | grep -E -- "$1" >/dev/null 2>&1
    [ $? -ne 2 ]
}

_parse() {
    local line
    line=$(_trim "$1")
    case "$line" in
        ''|'#'*) return 1 ;;
    esac
    KIND=invalid
    REGEX="$1"
    if [[ "$line" =~ $RULE_RE ]] && _regex_ok "${BASH_REMATCH[2]}"; then
        KIND="${BASH_REMATCH[1]}"
        REGEX="${BASH_REMATCH[2]}"
    fi
    return 0
}

_match() {
    printf '%s\n' "$1" | grep -Eq -- "$2" 2>/dev/null
}

_list() {
    local n=0 line
    [ -f "$FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        _parse "$line" || continue
        printf '%s\t%s\t%s\n' "$n" "$KIND" "$REGEX"
    done < "$FILE"
}

_check() {
    local name="$1" line has_allow=0 allowed=0 denied=0
    [ -f "$FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        _parse "$line" || continue
        case "$KIND" in
            allow)
                has_allow=1
                _match "$name" "$REGEX" && allowed=1
                ;;
            deny)
                _match "$name" "$REGEX" && denied=1
                ;;
        esac
    done < "$FILE"
    [ "$has_allow" = 1 ] && [ "$allowed" = 0 ] && return 1
    [ "$denied" = 1 ] && return 1
    return 0
}

_active() {
    local line
    [ -f "$FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        _parse "$line" || continue
        [ "$KIND" = invalid ] || return 0
    done < "$FILE"
    return 1
}

_check_kind() {
    case "$1" in
        allow|deny) return 0 ;;
    esac
    printf 'a rule starts with allow or deny, not "%s"\n' "$1" >&2
    return 2
}

# The regex check of every write: grep -E exits 2 on a regex it refuses, and
# its message goes to stderr, where the pane shows the first line.
_check_regex() {
    local err
    if [ -z "$1" ]; then
        printf 'empty regex\n' >&2
        return 2
    fi
    case "$1" in
        *$'\n'*) printf 'the regex has a line break\n' >&2; return 2 ;;
    esac
    err=$(printf '' | grep -E -- "$1" 2>&1 >/dev/null)
    if [ $? -eq 2 ]; then
        printf '%s\n' "${err:-bad regex}" >&2
        return 2
    fi
    return 0
}

_check_n() {
    case "$1" in
        ''|0*|*[!0-9]*) printf 'not a line number: "%s"\n' "$1" >&2; return 2 ;;
    esac
    return 0
}

# Line <n> is a line that list prints: not blank, not a comment, not past
# the end. An invalid line counts, so the person can mend or remove it.
_is_rule_line() {
    [ -f "$FILE" ] || return 1
    _parse "$(sed -n "${1}p" "$FILE")"
}

# stdin goes to a temporary file in the same folder, then mv puts it in
# place: a reader never sees a half-written file. The last write wins.
_write() {
    local tmp
    tmp=$(mktemp "${FILE}.XXXXXX") || return 1
    if cat > "$tmp" && mv "$tmp" "$FILE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Line <n> becomes TEXT, or goes when DROP is set. The values go through
# ENVIRON, not awk -v: -v reads backslash escapes, and a regex keeps its
# backslashes.
_rewrite() {
    N="$1" TEXT="${2:-}" DROP="${3:-}" awk '
        NR == ENVIRON["N"] + 0 { if (ENVIRON["DROP"] == "") print ENVIRON["TEXT"]; next }
        { print }' "$FILE" | _write
}

# A ".local" name does not make git ignore a file. The line goes in the
# info/exclude of the common dir, so it holds for every worktree and changes
# no file of the repo. check-ignore sees the line after, so it goes in once.
_exclude() {
    git -C "$ROOT" check-ignore -q -- .claude/clux-filters.local 2>/dev/null && return 0
    mkdir -p "$COMMON/info" 2>/dev/null || return 0
    printf '/.claude/clux-filters.local\n' >> "$COMMON/info/exclude"
}

_add() {
    local kind="$1" regex
    regex=$(_trim "$2")
    _check_kind "$kind" || return 2
    _check_regex "$regex" || return 2
    mkdir -p "$ROOT/.claude" || return 1
    {
        if [ -f "$FILE" ]; then
            cat "$FILE"
            # A last line with no newline must not join the new rule.
            [ -s "$FILE" ] && [ -n "$(tail -c 1 "$FILE")" ] && printf '\n'
        else
            printf '%s\n' "$HEADER"
        fi
        printf '%s %s\n' "$kind" "$regex"
    } | _write || return 1
    _exclude
    return 0
}

_set() {
    local n="$1" kind="$2" regex
    regex=$(_trim "$3")
    _check_n "$n" || return 2
    _check_kind "$kind" || return 2
    _check_regex "$regex" || return 2
    _is_rule_line "$n" || return 3
    _rewrite "$n" "$kind $regex"
}

_remove() {
    _check_n "$1" || return 2
    _is_rule_line "$1" || return 3
    _rewrite "$1" "" drop
}

case "$VERB" in
    path)
        _locate || exit 1
        printf '%s\n' "$FILE"
        exit 0
        ;;
    check)
        _locate || exit 0
        _check "${3:-}"
        exit $?
        ;;
    active)
        _locate || exit 1
        _active
        exit $?
        ;;
    list)
        _locate || exit 1
        _list
        exit 0
        ;;
    add|set|remove)
        if ! _locate; then
            printf 'not in a git repo: %s\n' "$CWD" >&2
            exit 1
        fi
        case "$VERB" in
            add)    _add "${3:-}" "${4:-}" ;;
            set)    _set "${3:-}" "${4:-}" "${5:-}" ;;
            remove) _remove "${3:-}" ;;
        esac
        exit $?
        ;;
esac
printf 'usage: notify-filter.sh path|check|active|list|add|set|remove <cwd> ...\n' >&2
exit 2
```

- [ ] Step 4 (run test, observe PASS):

```
bats test/notify-filter.bats
```

Expected: `1..22` and 22 `ok` lines.

- [ ] Step 5 (commit):

```
git add plugins/clux/scripts/notify-filter.sh test/notify-filter.bats
git -c user.email=1195406+404pilo@users.noreply.github.com commit -m "feat(clux): notify-filter.sh adds, sets and removes rules" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Verification:**

- `bats test/notify-filter.bats` prints 22 `ok` lines and no `not ok`.
- `plugins/clux/scripts/notify-filter.sh add /tmp deny x; echo $?` (with `/tmp` outside any repo) prints `not in a git repo: /tmp` on stderr and `1`.
- `test -x plugins/clux/scripts/notify-filter.sh && echo exec` prints `exec`.

---

## Task 3: The hook skips a hidden notification

**Goal:** `hooks/notify-tmux.sh` runs `notify-filter.sh check` before the sound, so a hidden notification makes no sound, no banner, no queue line and no bell, on the agent path and on the interactive path.

**Files touched:**
- Modify: `plugins/clux/hooks/notify-tmux.sh`
- Test: `test/notify-tmux.bats`

**Steps:**

- [ ] Step 1 (failing test): Add these helpers and tests at the end of `test/notify-tmux.bats`:

```bash
# ===========================================================================
# 5.2.0 — the per-repo notification filter (scripts/notify-filter.sh). A
# hidden notification makes nothing: no queue line, no sound, no desktop
# banner, no bell, on both paths.
# ===========================================================================

# _filter_repo DIR RULE... — a git repo at DIR whose filter file holds one
# line for each RULE.
_filter_repo() {
    local dir="$1"; shift
    git init -q "$dir"
    mkdir -p "$dir/.claude"
    printf '%s\n' "$@" > "$dir/.claude/clux-filters.local"
}

# The interactive tmux stub of the StopFailure test above: a pane in window
# "editor" of session "main".
_write_pane_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "\${STUB_LOG:-/dev/null}"
case "\$*" in
  *@clux_muted*) echo "" ;;
  *display-message*) echo "main|||editor|||\$1|||@win1" ;;
  *@claude-notify-file*) echo "$QUEUE_FILE" ;;
esac
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

# notify-sound.sh runs in the background, so give it time before a test
# says that it did not run.
_settle_sound() { sleep 0.5; }

@test "filter: a deny rule hides an agent notification — no queue line, no banner, no sound, no output" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local proj="$BATS_TEST_TMPDIR/proj"
    _filter_repo "$proj" 'deny ^proj$'
    local JSON="{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"s-filt-001\",\"cwd\":\"$proj\",\"message\":\"needs you\"}"
    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run grep -qF '|||agent:s-filt-001' "$QUEUE_FILE"
    [ "$status" -ne 0 ]
    _settle_sound
    run grep -qE 'notification-sound|osascript' "$stub_log"
    [ "$status" -ne 0 ]
}

@test "filter: an allow rule that does not match hides an interactive notification — no queue line, no bell" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local proj="$BATS_TEST_TMPDIR/proj"
    _filter_repo "$proj" 'allow ^feat-'
    _write_pane_tmux_stub
    local JSON="{\"hook_event_name\":\"StopFailure\",\"session_id\":\"s-int-filt\",\"error_type\":\"billing_error\",\"cwd\":\"$proj\"}"
    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export TMUX='/dev/null,1234,0'
        export TMUX_PANE='%1'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\a'* ]]
    run grep -qF 'main:editor' "$QUEUE_FILE"
    [ "$status" -ne 0 ]
    _settle_sound
    run grep -qF 'failure-sound' "$stub_log"
    [ "$status" -ne 0 ]
}

@test "filter: an allow rule that matches lets an interactive notification through" {
    local proj="$BATS_TEST_TMPDIR/proj"
    _filter_repo "$proj" 'allow ^proj$'
    _write_pane_tmux_stub
    local JSON="{\"hook_event_name\":\"StopFailure\",\"session_id\":\"s-int-ok\",\"error_type\":\"billing_error\",\"cwd\":\"$proj\"}"
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export TMUX='/dev/null,1234,0'
        export TMUX_PANE='%1'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF 'main:editor' "$QUEUE_FILE"
    [[ "$output" == *$'\a'* ]]
}

@test "filter: the rule matches the session name from the transcript, not the folder" {
    local proj="$BATS_TEST_TMPDIR/proj"
    _filter_repo "$proj" 'deny ^feat-'
    local transcript="$BATS_TEST_TMPDIR/t.jsonl"
    printf '%s\n' '{"type":"custom-title","customTitle":"feat-login"}' > "$transcript"
    local JSON="{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"s-filt-002\",\"cwd\":\"$proj\",\"transcript_path\":\"$transcript\"}"
    run bash -c "
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    run grep -qF '|||agent:s-filt-002' "$QUEUE_FILE"
    [ "$status" -ne 0 ]
}

@test "filter: a repo with no filter file notifies as before, sound included" {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    local proj="$BATS_TEST_TMPDIR/proj"
    git init -q "$proj"
    local JSON="{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"s-filt-003\",\"cwd\":\"$proj\",\"message\":\"needs you\"}"
    run bash -c "
        export STUB_LOG='$stub_log'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        printf '%s' '$JSON' | TMUX= '$NOTIFY_HOOK'
    "
    [ "$status" -eq 0 ]
    grep -qF '|||agent:s-filt-003' "$QUEUE_FILE"
    [[ "$output" == *'"terminalSequence"'* ]]
    local i=0
    until grep -qF 'notification-sound' "$stub_log" 2>/dev/null || [ "$i" -ge 20 ]; do
        sleep 0.1; i=$((i + 1))
    done
    grep -qF 'notification-sound' "$stub_log"
}
```

The sound check reads the tmux stub log: `notify-sound.sh` asks tmux for `@claude-notify-<type>-sound` first, and the hook itself never reads a `-sound` option.

- [ ] Step 2 (run test, observe FAIL):

```
bats -f '^filter:' test/notify-tmux.bats
```

Expected: `not ok` for `a deny rule hides an agent notification`, `an allow rule that does not match hides an interactive notification` and `the rule matches the session name from the transcript, not the folder` (the hook writes the queue line). `ok` for `an allow rule that matches lets an interactive notification through` and `a repo with no filter file notifies as before, sound included`: they guard the behavior of today.

- [ ] Step 3 (minimal implementation): In `plugins/clux/hooks/notify-tmux.sh`, replace these lines:

```bash
TYPE=$(map_event_to_type "$EVENT" "$NOTIFICATION_TYPE")
[ -n "$TYPE" ] || exit 0
```

with:

```bash
TYPE=$(map_event_to_type "$EVENT" "$NOTIFICATION_TYPE")
[ -n "$TYPE" ] || exit 0

# A repo can hide the notifications of some of its sessions: the rules in
# <main repo root>/.claude/clux-filters.local, which notify-filter.sh alone
# reads. The check comes before the sound, so a hidden notification makes no
# sound, no desktop banner, no queue line and no bell, on both paths. A repo
# with no filter file pays one git call; the name lookup runs only when the
# file is there. Only exit 1 hides: a filter script that fails in another way
# must not hide every notification.
_FILTER="$CURRENT_DIR/../scripts/notify-filter.sh"
if [ -n "$CWD" ] && _FILTER_FILE=$("$_FILTER" path "$CWD" 2>/dev/null) && [ -f "$_FILTER_FILE" ]; then
    "$_FILTER" check "$CWD" "$(resolve_agent_name "$SESSION_ID" "$CWD" "$TRANSCRIPT_PATH")"
    [ $? -eq 1 ] && exit 0
fi
```

`SESSION_ID` here is still the Claude session id from the payload: the interactive path replaces it with the tmux session id only later.

- [ ] Step 4 (run test, observe PASS):

```
bats test/notify-tmux.bats
```

Expected: every test prints `ok`, the 29 tests of today and the 5 `filter:` tests (`1..34`).

- [ ] Step 5 (commit):

```
git add plugins/clux/hooks/notify-tmux.sh test/notify-tmux.bats
git -c user.email=1195406+404pilo@users.noreply.github.com commit -m "feat(clux): the hook skips a notification that the repo filter hides" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Verification:**

- `bats test/notify-tmux.bats` prints 34 `ok` lines and no `not ok`.
- `grep -n '"$_FILTER" check' plugins/clux/hooks/notify-tmux.sh` prints one line. Its line number is lower than the line number that `grep -n 'scripts/notify-sound.sh" "$TYPE"' plugins/clux/hooks/notify-tmux.sh` prints (the sound call): the check comes before the sound.

---

## Task 4: Ctrl-X deletes in the popup and the popup stays open

**Goal:** `scripts/notification-picker.sh` runs fzf in a loop with the header `Enter=jump  Ctrl-X=delete  Esc=close` and `--expect=ctrl-x,ctrl-d`; a delete starts fzf again on the new queue.

**Files touched:**
- Modify: `plugins/clux/scripts/notification-picker.sh`
- Modify: `test/stubs/fzf`
- Test: `test/picker.bats`
- Modify: `test/notification-line.bats` [inferred]

**Steps:**

- [ ] Step 1 (failing test): Replace the content of `test/stubs/fzf` with this content (the old behavior stays when `FZF_STUB_KEYS` is not set):

```bash
#!/usr/bin/env bash
# stub: fzf
# Reads FZF_STUB_KEY and FZF_STUB_LINE env vars to emit controlled output.
# If FZF_STUB_EXIT is set, exits with that code instead (e.g. 130 for Esc).
# Logs invocation args.
#
# FZF_STUB_KEYS drives a caller that runs fzf in a loop: one answer for each
# call, space-separated — ctrl-x, ctrl-d, enter, or esc (exit 130). A call
# past the end of the list is esc, so a loop that does not end stops there.
# Each call selects the first line of its input, where the cursor of fzf
# starts, and saves that input as "$FZF_STUB_COUNT.<call>". FZF_STUB_COUNT
# names the file that counts the calls.
echo "fzf $*" >> "${STUB_LOG:-/dev/null}"

if [ -n "${FZF_STUB_KEYS:-}" ]; then
    count_file="${FZF_STUB_COUNT:?FZF_STUB_COUNT is needed with FZF_STUB_KEYS}"
    n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$count_file"
    cat > "$count_file.$n"
    read -r -a keys <<< "$FZF_STUB_KEYS"
    key="${keys[$((n - 1))]:-esc}"
    case "$key" in
        esc) exit 130 ;;
        enter) key="" ;;
    esac
    printf '%s\n%s\n' "$key" "$(head -1 "$count_file.$n")"
    exit 0
fi

if [ -n "${FZF_STUB_EXIT:-}" ]; then
    exit "$FZF_STUB_EXIT"
fi

# Emit key on first line, selected line on second line (matches fzf --expect output format)
printf '%s\n%s\n' "${FZF_STUB_KEY:-}" "${FZF_STUB_LINE:-}"
exit 0
```

Then add these tests at the end of `test/picker.bats`:

```bash
# ---------------------------------------------------------------------------
# 5.2.0 — ctrl-x deletes and the popup stays open. The picker runs fzf in a
# loop; FZF_STUB_KEYS gives one key for each call of fzf.
# ---------------------------------------------------------------------------
_loop_picker() {
    local stub_log="$BATS_TEST_TMPDIR/stub.log"
    FZF_CALLS="$BATS_TEST_TMPDIR/fzf.count"
    run bash -c "
        export STUB_LOG='$stub_log'
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export CLUX_NOTIFY_FILE='$QUEUE_FILE'
        export HOME='$BATS_TEST_TMPDIR/home'
        export FZF_STUB_KEYS='$1'
        export FZF_STUB_COUNT='$FZF_CALLS'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
}

@test "picker: ctrl-x removes the line, then starts fzf again on the new queue" {
    printf '%s\n' 'main:editor Task done|||$sess1:@win3' 'main:tests green|||$sess1:@win5' > "$QUEUE_FILE"
    _loop_picker 'ctrl-x esc'
    [ "$status" -eq 0 ]
    [ "$(cat "$FZF_CALLS")" -eq 2 ]
    # The second fzf got the queue without the deleted line.
    [ "$(cat "$FZF_CALLS.2")" = 'main:tests green|||$sess1:@win5' ]
    [ "$(cat "$QUEUE_FILE")" = 'main:tests green|||$sess1:@win5' ]
    grep -qF -- '--header=Enter=jump  Ctrl-X=delete  Esc=close' "$BATS_TEST_TMPDIR/stub.log"
    grep -qF -- '--expect=ctrl-x,ctrl-d' "$BATS_TEST_TMPDIR/stub.log"
}

@test "picker: ctrl-d still deletes, and the popup stays open too" {
    printf '%s\n' 'main:editor Task done|||$sess1:@win3' 'main:tests green|||$sess1:@win5' > "$QUEUE_FILE"
    _loop_picker 'ctrl-d esc'
    [ "$status" -eq 0 ]
    [ "$(cat "$FZF_CALLS")" -eq 2 ]
    [ "$(cat "$QUEUE_FILE")" = 'main:tests green|||$sess1:@win5' ]
}

@test "picker: the loop ends when the queue is empty" {
    printf '%s\n' 'main:editor Task done|||$sess1:@win3' 'main:tests green|||$sess1:@win5' > "$QUEUE_FILE"
    _loop_picker 'ctrl-x ctrl-x ctrl-x'
    [ "$status" -eq 0 ]
    [ "$(cat "$FZF_CALLS")" -eq 2 ]
    [ ! -s "$QUEUE_FILE" ]
}

@test "picker: Enter after a delete jumps and ends the loop" {
    printf '%s\n' 'main:editor Task done|||$sess1:@win3' 'main:tests green|||$sess1:@win5' > "$QUEUE_FILE"
    _loop_picker 'ctrl-x enter ctrl-x'
    [ "$status" -eq 0 ]
    [ "$(cat "$FZF_CALLS")" -eq 2 ]
    grep -qF 'select-window -t $sess1:@win5' "$BATS_TEST_TMPDIR/stub.log"
}

@test "picker: Esc ends the loop and keeps the queue" {
    printf '%s\n' 'main:editor Task done|||$sess1:@win3' > "$QUEUE_FILE"
    _loop_picker 'esc'
    [ "$status" -eq 0 ]
    [ "$(cat "$FZF_CALLS")" -eq 1 ]
    [ "$(cat "$QUEUE_FILE")" = 'main:editor Task done|||$sess1:@win3' ]
}
```

In `test/notification-line.bats`, replace the test `notification-picker: Ctrl-D removes an equal line and keeps a longer line that holds it` (it still uses the legacy single-answer stub, which now answers every fzf call alike; the new loop calls fzf again after a ctrl-d that does not empty the queue, so the legacy answer repeats forever) with this content, which drives the loop with the same `FZF_STUB_KEYS`/`FZF_STUB_COUNT` mechanism as `test/picker.bats`: [inferred]

```bash
@test "notification-picker: Ctrl-D removes an equal line and keeps a longer line that holds it" {
    local short='main:editor done|||$sess1:@win3'
    local long="prefix $short"
    printf '%s\n%s\n' "$short" "$long" > "$QUEUE_FILE"

    run bash -c "
        export FZF_STUB_KEYS='ctrl-d esc'
        export FZF_STUB_COUNT='$BATS_TEST_TMPDIR/fzf.count'
        bash '$SCRIPTS_DIR/notification-picker.sh'
    "
    [ "$status" -eq 0 ]
    run grep -qxF "$short" "$QUEUE_FILE"
    [ "$status" -ne 0 ]
    grep -qxF "$long" "$QUEUE_FILE" || false
}
```

- [ ] Step 2 (run test, observe FAIL):

```
bats test/picker.bats
```

Expected: the 7 tests of today print `ok`. `ctrl-x removes the line, then starts fzf again on the new queue`, `ctrl-d still deletes, and the popup stays open too`, `the loop ends when the queue is empty` and `Enter after a delete jumps and ends the loop` print `not ok` (fzf runs one time only). `Esc ends the loop and keeps the queue` prints `ok`. The updated `test/notification-line.bats` test also prints `ok` already: today's picker calls fzf once, which is all this test needs. [inferred]

- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/notification-picker.sh`, replace everything from `selected=$(fzf --reverse \` to the end of the file with:

```bash
# fzf runs in a loop, so the popup stays open after a delete: ctrl-x (and
# ctrl-d, the key of 4.x) takes the line out, then fzf starts again on the new
# queue, with the cursor on the first line. A shell loop, not a fzf reload
# bind: it works with every fzf version, and the test stub can drive it.
# Enter jumps and ends the popup; Esc ends it; an empty queue ends it.
while [ -s "$NOTIFY_FILE" ]; do
    selected=$(fzf --reverse \
        --header="Enter=jump  Ctrl-X=delete  Esc=close" \
        --expect=ctrl-x,ctrl-d \
        < "$NOTIFY_FILE")

    # fzf exits 130 on Esc/ctrl-c
    [ -z "$selected" ] && exit 0

    key=$(head -1 <<< "$selected")
    line=$(tail -1 <<< "$selected")

    [ -z "$line" ] && exit 0

    case "$key" in
        ctrl-x|ctrl-d)
            # A busy queue keeps the line: fzf shows it again, and the person
            # can press ctrl-x once more.
            "$CURRENT_DIR/notification-line.sh" remove "$line"
            ;;
        *)
            "$CURRENT_DIR/notification-line.sh" jump "$line"
            break
            ;;
    esac
done

# The popup always ends well, as prefix + m does: a line with no target or a
# busy queue must not leave an error line inside display-popup.
exit 0
```

- [ ] Step 4 (run test, observe PASS):

```
bats test/picker.bats
```

Expected: `1..12` and 12 `ok` lines.

- [ ] Step 5 (commit):

```
git add plugins/clux/scripts/notification-picker.sh test/stubs/fzf test/picker.bats test/notification-line.bats
git -c user.email=1195406+404pilo@users.noreply.github.com commit -m "feat(clux): ctrl-x deletes in the prefix + M popup and keeps it open" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Verification:**

- `bats test/picker.bats test/jump.bats test/notification-line.bats` prints no `not ok`.
- `grep -c 'Ctrl-X=delete' plugins/clux/scripts/notification-picker.sh` prints `1`.

---

## Task 5: The status bar shows the filter mark

**Goal:** `scripts/session-bar-refresh.sh` puts `@clux-filter-mark` (default `⊘ filtered`), in the badge colors, before the text of `@clux_status` when the repo of the active pane has a valid rule.

**Files touched:**
- Modify: `plugins/clux/scripts/session-bar-refresh.sh`
- Test: `test/session-bar-refresh.bats`

**Steps:**

- [ ] Step 1 (failing test): Add these helpers and tests at the end of `test/session-bar-refresh.bats` (they use the `_stage` helper of that file):

```bash
# ---------------------------------------------------------------------------
# 5.2.0 — the filter mark. When the repo of the active pane has a valid
# filter rule, @clux_status starts with @clux-filter-mark in the colors of
# the notification badge.
# ---------------------------------------------------------------------------

MARK='#[bg=#EBCB8B,fg=#2E3440] ⊘ filtered #[default]'

# _write_mark_tmux_stub — answers the reads of the mark. display-message -p
# '#{pane_current_path}' prints $MARK_DISPLAY_PATH. list-clients prints two
# clients: pid 222 in /nowhere, then pid 111 in $MARK_CLIENT_PATH. show-option
# of @clux-filter-mark prints $MARK_OPT, and fails as real tmux does when
# MARK_OPT is not set. Every call is logged.
_write_mark_tmux_stub() {
    cat > "$BATS_TEST_TMPDIR/stubs/tmux" <<'STUBEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${STUB_LOG:-/dev/null}"
case "$1" in
    display-message)
        case "$*" in
            *'#{pane_current_path}') printf '%s\n' "${MARK_DISPLAY_PATH:-}" ;;
        esac
        ;;
    list-clients)
        printf '222\356\200\201%s\n' /nowhere
        printf '111\356\200\201%s\n' "${MARK_CLIENT_PATH:-}"
        ;;
    show-option)
        case "$*" in
            *@clux-filter-mark*)
                if [ -z "${MARK_OPT+set}" ]; then
                    echo "invalid option: @clux-filter-mark" >&2
                    exit 1
                fi
                printf '%s\n' "$MARK_OPT"
                ;;
        esac
        ;;
esac
exit 0
STUBEOF
    chmod +x "$BATS_TEST_TMPDIR/stubs/tmux"
}

# _stage_mark <status-output> RULE... — a staged copy (see _stage) with
# notify-filter.sh beside it, and a git repo at $MARK_REPO whose filter file
# holds one line for each RULE. With no RULE, the repo has no filter file.
_stage_mark() {
    local status_text="$1"; shift
    _stage 0 'BAR' 0 "$status_text"
    cp "$SCRIPTS_DIR/notify-filter.sh" "$STAGED_DIR/"
    MARK_REPO="$BATS_TEST_TMPDIR/repo"
    git init -q "$MARK_REPO"
    if [ "$#" -gt 0 ]; then
        mkdir -p "$MARK_REPO/.claude"
        printf '%s\n' "$@" > "$MARK_REPO/.claude/clux-filters.local"
    fi
}

# _run_mark ARGS... — run the staged script with a clean environment: the
# badge colors and MARK_OPT come only from the test ($MARK_ENV).
_run_mark() {
    run bash -c "
        export PATH='$BATS_TEST_TMPDIR/stubs:$PATH'
        export HOME='$BATS_TEST_TMPDIR/home'
        export STUB_LOG='$BATS_TEST_TMPDIR/stub.log'
        unset CLUX_NOTIFY_BG CLUX_NOTIFY_FG
        $MARK_ENV
        '$STAGED_DIR/session-bar-refresh.sh' $*
    "
}

@test "session-bar-refresh: the filter mark leads @clux_status when the repo of the active pane has a rule" {
    _write_mark_tmux_stub
    _stage_mark 'NOTIF' 'deny wip'
    MARK_ENV="unset MARK_OPT; export MARK_DISPLAY_PATH='$MARK_REPO'"
    _run_mark
    [ "$status" -eq 0 ]
    grep -qxF "tmux set-option -g @clux_status ${MARK}NOTIF" "$BATS_TEST_TMPDIR/stub.log"
}

@test "session-bar-refresh: the filter mark shows also with no notification" {
    _write_mark_tmux_stub
    _stage_mark '' 'deny wip'
    MARK_ENV="unset MARK_OPT; export MARK_DISPLAY_PATH='$MARK_REPO'"
    _run_mark
    [ "$status" -eq 0 ]
    grep -qxF "tmux set-option -g @clux_status ${MARK}" "$BATS_TEST_TMPDIR/stub.log"
}

@test "session-bar-refresh: no filter file, no mark" {
    _write_mark_tmux_stub
    _stage_mark 'NOTIF'
    MARK_ENV="unset MARK_OPT; export MARK_DISPLAY_PATH='$MARK_REPO'"
    _run_mark
    [ "$status" -eq 0 ]
    grep -qxF 'tmux set-option -g @clux_status NOTIF' "$BATS_TEST_TMPDIR/stub.log"
}

@test "session-bar-refresh: a file with no valid rule gives no mark" {
    _write_mark_tmux_stub
    _stage_mark 'NOTIF' '# only a comment' 'deny ('
    MARK_ENV="unset MARK_OPT; export MARK_DISPLAY_PATH='$MARK_REPO'"
    _run_mark
    [ "$status" -eq 0 ]
    grep -qxF 'tmux set-option -g @clux_status NOTIF' "$BATS_TEST_TMPDIR/stub.log"
}

@test "session-bar-refresh: an empty @clux-filter-mark turns the mark off" {
    _write_mark_tmux_stub
    _stage_mark 'NOTIF' 'deny wip'
    MARK_ENV="export MARK_OPT=''; export MARK_DISPLAY_PATH='$MARK_REPO'"
    _run_mark
    [ "$status" -eq 0 ]
    grep -qxF 'tmux set-option -g @clux_status NOTIF' "$BATS_TEST_TMPDIR/stub.log"
}

@test "session-bar-refresh: @clux-filter-mark sets the text, with each # doubled" {
    _write_mark_tmux_stub
    _stage_mark 'NOTIF' 'deny wip'
    MARK_ENV="export MARK_OPT='#hidden'; export MARK_DISPLAY_PATH='$MARK_REPO'"
    _run_mark
    [ "$status" -eq 0 ]
    grep -qxF 'tmux set-option -g @clux_status #[bg=#EBCB8B,fg=#2E3440] ##hidden #[default]NOTIF' "$BATS_TEST_TMPDIR/stub.log"
}

@test "session-bar-refresh: on the quiet path the mark follows the pane of the client in argument 2" {
    _write_mark_tmux_stub
    _stage_mark 'NOTIF' 'deny wip'
    # display-message points nowhere: only list-clients knows the repo.
    MARK_ENV="unset MARK_OPT; export MARK_DISPLAY_PATH=/nowhere MARK_CLIENT_PATH='$MARK_REPO'"
    _run_mark quiet 111
    [ "$status" -eq 0 ]
    grep -qxF "tmux set-option -g @clux_status ${MARK}NOTIF" "$BATS_TEST_TMPDIR/stub.log"
}

@test "session-bar-refresh: on the quiet path another client's pane gives no mark" {
    _write_mark_tmux_stub
    _stage_mark 'NOTIF' 'deny wip'
    MARK_ENV="unset MARK_OPT; export MARK_DISPLAY_PATH='$MARK_REPO' MARK_CLIENT_PATH='$MARK_REPO'"
    _run_mark quiet 222
    [ "$status" -eq 0 ]
    grep -qxF 'tmux set-option -g @clux_status NOTIF' "$BATS_TEST_TMPDIR/stub.log"
}
```

- [ ] Step 2 (run test, observe FAIL):

```
bats -f 'mark' test/session-bar-refresh.bats
```

The filter `mark` selects the 8 new tests only: no test of today has "mark" in its name. Expected: `not ok` for `the filter mark leads @clux_status ...`, `the filter mark shows also with no notification`, `@clux-filter-mark sets the text, with each # doubled` and `on the quiet path the mark follows the pane of the client in argument 2` (no mark is written). The 4 tests that expect no mark print `ok`: they guard the behavior of today.

- [ ] Step 3 (minimal implementation): In `plugins/clux/scripts/session-bar-refresh.sh`, replace these lines:

```bash
# show-notification.sh is not part of the throttle above — see the header
# comment. It runs on every path, including a cheap animation tick.
if status_out=$("$CURRENT_DIR/show-notification.sh"); then
    tmux set-option -g @clux_status "$status_out"
fi
```

with:

```bash
# --- The filter mark (5.2.0) ------------------------------------------------
# When the repo of the active pane has a filter file with one or more valid
# rules (notify-filter.sh active), @clux_status starts with a mark, so the
# person knows that some notifications of that repo are hidden. The text is
# @clux-filter-mark (default "⊘ filtered"; an empty value turns the mark off),
# in the colors of the notification badge. It runs on every path, with no
# cache: one tmux read and one git call for each run.
#
# The pane: on the quiet path with a client id, the active pane of the client
# that draws this status line. Argument 2 is the pid of that client, and
# `display-message -c` takes a client name, not a pid, so list-clients finds
# it. On the hook path, and on a quiet path with no client id, the pane that
# `display-message -p` picks.
_filter_mark() {
    local path="" pid p mark
    if [ -n "$client_id" ]; then
        while IFS="$SEP" read -r pid p; do
            if [ "$pid" = "$client_id" ]; then
                path="$p"
                break
            fi
        done <<EOF
$(tmux list-clients -F "#{client_pid}${SEP}#{pane_current_path}" 2>/dev/null)
EOF
    else
        path=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)
    fi
    [ -n "$path" ] || return 0
    "$CURRENT_DIR/notify-filter.sh" active "$path" 2>/dev/null || return 0
    # show-option without -q exits 1 for an option that is not set: then the
    # default. A value that is set but empty turns the mark off.
    mark=$(tmux show-option -gv @clux-filter-mark 2>/dev/null) || mark='⊘ filtered'
    [ -n "$mark" ] || return 0
    printf '#[bg=%s,fg=%s] %s #[default]' \
        "${CLUX_NOTIFY_BG:-#EBCB8B}" "${CLUX_NOTIFY_FG:-#2E3440}" "${mark//#/##}"
}

# show-notification.sh is not part of the throttle above — see the header
# comment. It runs on every path, including a cheap animation tick. The
# filter mark goes before its text, also when that text is empty.
mark_out=$(_filter_mark)
if status_out=$("$CURRENT_DIR/show-notification.sh"); then
    tmux set-option -g @clux_status "${mark_out}${status_out}"
fi
```

The default colors are the defaults of `show-notification.sh` (`#EBCB8B` on `#2E3440`). `SEP` (U+E001) and `client_id` are the ones the script sets at its top.

- [ ] Step 4 (run test, observe PASS):

```
bats test/session-bar-refresh.bats
```

Expected: `1..34` and 34 `ok` lines (26 tests of today, among them the real-server three-tick test, and the 8 new tests).

- [ ] Step 5 (commit):

```
git add plugins/clux/scripts/session-bar-refresh.sh test/session-bar-refresh.bats
git -c user.email=1195406+404pilo@users.noreply.github.com commit -m "feat(clux): the status bar marks a repo that has notification filters" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Verification:**

- `bats test/session-bar-refresh.bats test/deploy-manifest.bats` prints no `not ok`.
- `grep -c '@clux-filter-mark' plugins/clux/scripts/session-bar-refresh.sh` prints a number of 1 or more.

---

## Task 6: The mod types and the pure filter helpers

**Goal:** `types/index.d.ts` has the `filters` atom type, and `hooks/notifications/filters.ts` parses the `list` output, draws the row text and splits the rule box text.

**Files touched:**
- Modify: `plugins/clux/types/index.d.ts`
- Create: `plugins/clux/hooks/notifications/filters.ts`
- Modify: `CONTRIBUTING.md`
- Test: `plugins/clux/tests/notifications-filters.test.ts` (new)

**Steps:**

- [ ] Step 1 (failing test): Create `plugins/clux/tests/notifications-filters.test.ts` with this content:

```ts
import { describe, expect, test } from 'claude-code/testing'

import { editValue, parseList, rowText, splitRule, validCount } from '../hooks/notifications/filters'

describe('parseList', () => {
  test('one row for each line, in file order', () => {
    expect(parseList('3\tallow\t^feat-\n4\tdeny\twip\n')).toEqual([
      { n: 3, kind: 'allow', text: '^feat-' },
      { n: 4, kind: 'deny', text: 'wip' },
    ])
  })

  test('an invalid row keeps the raw line, tabs and all', () => {
    expect(parseList('5\tinvalid\tblock\tfoo\n')).toEqual([
      { n: 5, kind: 'invalid', text: 'block\tfoo' },
    ])
  })

  test('empty output is no rows, and a line of another shape is skipped', () => {
    expect(parseList('')).toEqual([])
    expect(parseList('x\tallow\ta\n0\tdeny\tb\n2\tmaybe\tc\n7\tdeny\n')).toEqual([])
  })
})

describe('validCount', () => {
  test('counts the rows that are not invalid', () => {
    expect(validCount(parseList('1\tallow\ta\n2\tinvalid\tdeny (\n3\tdeny\tb\n'))).toBe(2)
  })
})

describe('rowText and editValue', () => {
  test('a rule reads as the kind, then the regex in one column', () => {
    expect(rowText({ n: 1, kind: 'allow', text: '^feat-' })).toBe('allow  ^feat-')
    expect(rowText({ n: 2, kind: 'deny', text: 'wip' })).toBe('deny   wip')
  })

  test('an invalid row reads as the raw line', () => {
    expect(rowText({ n: 3, kind: 'invalid', text: 'block foo' })).toBe('block foo')
  })

  test('the box opens with "<kind> <regex>", or the raw line of an invalid row', () => {
    expect(editValue({ n: 1, kind: 'deny', text: 'wip' })).toBe('deny wip')
    expect(editValue({ n: 3, kind: 'invalid', text: 'deny (' })).toBe('deny (')
  })
})

describe('splitRule', () => {
  test('the first word is the kind, the rest is the regex', () => {
    expect(splitRule('deny wip')).toEqual({ kind: 'deny', regex: 'wip' })
    expect(splitRule('  allow   ^feat- x  ')).toEqual({ kind: 'allow', regex: '^feat- x' })
  })

  test('a kind with no regex gives an empty regex', () => {
    expect(splitRule('deny ')).toEqual({ kind: 'deny', regex: '' })
  })

  test('a first word that is not allow or deny is no rule', () => {
    expect(splitRule('block wip')).toBeNull()
    expect(splitRule('')).toBeNull()
    expect(splitRule('Deny wip')).toBeNull()
  })
})
```

- [ ] Step 2 (run test, observe FAIL):

```
claude plugin test plugins/clux
```

Expected: the run exits 1. `tests/notifications-filters.test.ts` reports an error, because the module `../hooks/notifications/filters` does not exist. The other test files print `(pass)` lines.

- [ ] Step 3 (minimal implementation): In `plugins/clux/types/index.d.ts`, replace the `declare module 'claude-code'` block:

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

with:

```ts
// One line of the repo filter file, as `notify-filter.sh list` prints it.
// `n` is the line number in the file, the argument of `set` and `remove`.
// `text` is the regex, or the raw line for an `invalid` row.
export type FilterRow = {
  n: number
  kind: 'allow' | 'deny' | 'invalid'
  text: string
}

// The rule box under the list: closed, adding a rule, or replacing line `n`.
// `value` is the text the box shows; after a refused rule it holds what the
// person typed, so a redraw does not lose it.
export type FilterEditing = null | { mode: 'add'; value: string } | { mode: 'set'; n: number; value: string }

// The Filters view of the notifications pane. `file` is the filter file path,
// or '' when the session cwd is not in a git repo.
export type FiltersState = {
  view: 'notifications' | 'filters'
  file: string
  rules: FilterRow[]
  editing: FilterEditing
}

declare module 'claude-code' {
  interface PluginState {
    'clux': {
      sessions: BgSession[]
      notifications: NotifRow[]
      filters: FiltersState
    }
  }
}
```

Create `plugins/clux/hooks/notifications/filters.ts` with this content:

```ts
// Pure helpers: the output of `notify-filter.sh list` as rows, and the text
// of the rule box as a rule. No `$` here, so the tests can call these
// directly.
//
// There is deliberately NO regex check here. scripts/notify-filter.sh owns
// the parse of the file and the regex type (grep -E); a second copy in
// TypeScript is the copy that disagrees with the hook (for example on \d).

import type { FilterRow } from '../../types'

// One row for each "<n>\t<kind>\t<text>" line, in file order. The text is the
// rest of the line, tabs and all. A line of another shape is skipped.
export function parseList(stdout: string): FilterRow[] {
  return stdout.split('\n').flatMap(line => {
    const first = line.indexOf('\t')
    const second = first === -1 ? -1 : line.indexOf('\t', first + 1)
    if (second === -1) return []
    const n = Number(line.slice(0, first))
    const kind = line.slice(first + 1, second)
    if (!Number.isInteger(n) || n < 1) return []
    if (kind !== 'allow' && kind !== 'deny' && kind !== 'invalid') return []
    return [{ n, kind, text: line.slice(second + 1) }]
  })
}

// The rules that count: an invalid line hides nothing.
export function validCount(rows: FilterRow[]): number {
  return rows.filter(row => row.kind !== 'invalid').length
}

// What a row reads: "allow  ^feat-", the regexes in one column. An invalid
// row reads as the raw line.
export function rowText(row: FilterRow): string {
  return row.kind === 'invalid' ? row.text : `${row.kind.padEnd(5)}  ${row.text}`
}

// The text the rule box opens with for `e`: "<kind> <regex>", or the raw line
// of an invalid row, so the person can mend it.
export function editValue(row: FilterRow): string {
  return row.kind === 'invalid' ? row.text : `${row.kind} ${row.text}`
}

// The rule box text as a rule: the first word, then the rest, with the spaces
// at the start and the end removed. Null when the first word is not allow or
// deny. An empty regex is still a rule here: the script refuses it, and says
// why.
export function splitRule(text: string): { kind: 'allow' | 'deny'; regex: string } | null {
  const trimmed = text.trim()
  const space = trimmed.search(/\s/)
  const word = space === -1 ? trimmed : trimmed.slice(0, space)
  const regex = space === -1 ? '' : trimmed.slice(space).trim()
  if (word !== 'allow' && word !== 'deny') return null
  return { kind: word, regex }
}
```

In `CONTRIBUTING.md`, in the `plugins/clux/` tree, replace:

```
│   │   └── lines.ts             #   Pure helpers: the queue text as rows
```

with:

```
│   │   ├── lines.ts             #   Pure helpers: the queue text as rows
│   │   └── filters.ts           #   Pure helpers: the filter list as rows
```

- [ ] Step 4 (run test, observe PASS):

```
claude plugin test plugins/clux
tsc -p plugins/clux
```

Expected: the summary reads `72 pass` and `0 fail` (`Ran 72 tests across 5 files`). `tsc` prints nothing and exits 0.

- [ ] Step 5 (commit):

```
git add plugins/clux/types/index.d.ts plugins/clux/hooks/notifications/filters.ts plugins/clux/tests/notifications-filters.test.ts CONTRIBUTING.md
git -c user.email=1195406+404pilo@users.noreply.github.com commit -m "feat(clux): the filter rows and the rule box helpers of the notifications pane" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Verification:**

- `claude plugin test plugins/clux` ends with `0 fail`.
- `tsc -p plugins/clux; echo $?` prints `0`.
- `grep -c 'filters: FiltersState' plugins/clux/types/index.d.ts` prints `1`.

---

## Task 7: The Filters view shows the rules

**Goal:** The notifications pane polls `notify-filter.sh list`, shows `Notifications · <N>  |  Filters · <R>`, switches views with `f` and `n`, and draws the file path, the rule rows (an invalid row in red), `No filters. a: add a rule.` or `Not in a git repo.`.

**Files touched:**
- Modify: `plugins/clux/hooks/notifications/register.tsx`
- Test: `plugins/clux/tests/notifications.test.tsx`
- Test: `plugins/clux/tests/sessions.test.tsx`

**Steps:**

- [ ] Step 1 (failing test): Make these changes in `plugins/clux/tests/notifications.test.tsx`.

1a. After the line `const THIRD = 'main:tests 8/8 green|||$sess1:@win5'`, add:

```ts
const FILTER_FILE = `${ROOT}/.claude/clux-filters.local`
```

1b. After the line `type Queue = { text: string | null }`, add:

```ts

// How notify-filter.sh answers. `file` null is a cwd outside git: `path` and
// `list` exit 1. `list` is the stdout of `list`. `exits` and `stderr` set the
// answer of `add`, `set` and `remove`; by default they exit 0.
type Filter = {
  file: string | null
  list: string
  exits: Record<string, number>
  stderr: Record<string, string>
}
```

1c. In `world`, after the line `const script = { exits: {} as Record<string, number>, rejects: new Set<string>() }`, add:

```ts
  const filter: Filter = { file: FILTER_FILE, list: '', exits: {}, stderr: {} }
```

1d. In the `process.run` hook of `world`, replace:

```ts
    if (e.argv[0] === 'git') return { value: out('') }
    const verb = e.argv[1] ?? ''
```

with:

```ts
    if (e.argv[0] === 'git') return { value: out('') }
    const verb = e.argv[1] ?? ''
    if ((e.argv[0] ?? '').endsWith('/scripts/notify-filter.sh')) {
      if (verb === 'path') return { value: filter.file === null ? out('', 1) : out(`${filter.file}\n`) }
      if (verb === 'list') return { value: filter.file === null ? out('', 1) : out(filter.list) }
      return { value: { ...out('', filter.exits[verb] ?? 0), stderr: filter.stderr[verb] ?? '' } }
    }
```

1e. Replace `  return { clock, ran, toasts, logs, closes, focuses, panes, queue, reads, script }` with:

```ts
  return { clock, ran, toasts, logs, closes, focuses, panes, queue, reads, script, filter }
```

1f. Add these helpers and tests at the end of the file:

```tsx

// --- The Filters view -------------------------------------------------------

const ruleLabels = async (ui: Awaited<ReturnType<typeof mountPane>>) =>
  (await ui.findAll({ type: 'Button' }))
    .filter(button => (button.key ?? '').startsWith('rule:'))
    .map(button => String(button.props.label))

const allText = async (ui: Awaited<ReturnType<typeof mountPane>>) =>
  (await ui.findAll({ type: 'Text' })).map(t => t.text).join('\n')

test('the header names both views, and f and n change the view', async ($, on) => {
  const { filter } = world(on, { text: `${WINDOW}\n` })
  filter.list = '3\tallow\t^feat-\n4\tinvalid\tdeny (\n'
  await start($)
  const ui = await mountPane($, true)

  expect(await allText(ui)).toContain('Notifications · 1')
  // An invalid line hides nothing, so it is not counted.
  expect(await allText(ui)).toContain('Filters · 1')
  expect((await ui.find({ key: 'view-filters' }))?.props.hotkey).toBe('f')
  expect(await ui.find({ key: 'rule-add' })).toBeUndefined()

  await ui.press({ key: 'view-filters' })
  expect(await rowLabels(ui)).toEqual([])
  expect(await ruleLabels(ui)).toEqual(['allow  ^feat-', 'deny ('])
  expect(await allText(ui)).toContain(FILTER_FILE)
  // Only the keys of the view that shows.
  expect(await ui.find({ key: 'row-remove' })).toBeUndefined()
  expect((await ui.find({ key: 'view-notifications' }))?.props.hotkey).toBe('n')
  expect((await ui.find({ key: 'close-notifications' }))?.props.hotkey).toBe('q')

  await ui.press({ key: 'view-notifications' })
  expect(await rowLabels(ui)).toEqual(['main:editor Task done'])
  expect(await ruleLabels(ui)).toEqual([])
  await ui.unmount()
})

test('an invalid row is marked in red before its raw line', async ($, on) => {
  const { filter } = world(on, { text: null })
  filter.list = '4\tinvalid\tdeny (\n'
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })

  const mark = (await ui.findAll({ type: 'Text' })).find(t => t.text === 'invalid ')
  expect(mark?.props.color).toBe('red')
  await ui.unmount()
})

test('with no rules the view says how to add one', async ($, on) => {
  world(on, { text: null })
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })

  expect(await allText(ui)).toContain('No filters. a: add a rule.')
  expect(await allText(ui)).toContain('Filters · 0')
  await ui.unmount()
})

test('outside git the view says so, and only n and q work', async ($, on) => {
  const { ran, filter } = world(on, { text: null })
  filter.file = null
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })

  expect(await allText(ui)).toContain('Not in a git repo.')
  expect(await ui.find({ key: 'rule-add' })).toBeUndefined()
  expect(await ui.find({ key: 'view-notifications' })).toBeDefined()
  // No repo, no list to poll.
  expect(ran.filter(argv => (argv[0] ?? '').endsWith('/scripts/notify-filter.sh') && argv[1] === 'list')).toEqual([])
  await ui.unmount()
})

test('the poll reads the list on the session cwd in both views', async ($, on) => {
  const { ran, clock, filter } = world(on, { text: null })
  await start($)
  const ui = await mountPane($, true)

  filter.list = '1\tdeny\twip\n'
  await clock.advance(2000)
  await clock.settle()
  expect(await allText(ui)).toContain('Filters · 1')
  expect(ran.some(argv => (argv[0] ?? '').endsWith('/scripts/notify-filter.sh') && argv[1] === 'list' && argv[2] === ROOT)).toBe(true)
  await ui.unmount()
})

test('back in Notifications, x acts on the first row again', async ($, on) => {
  const { ran, queue } = world(on, { text: `${WINDOW}\n${AGENT}\n` })
  await start($)
  const ui = await mountPane($, true)

  await raiseFocus($, 'row:1')
  await ui.press({ key: 'view-filters' })
  await ui.press({ key: 'view-notifications' })
  queue.text = `${AGENT}\n`
  await ui.press({ key: 'row-remove' })

  expect(lineRuns(ran)).toEqual([['remove', WINDOW]])
  await ui.unmount()
})
```

1g. In `plugins/clux/tests/sessions.test.tsx`, the test `a new question raises no toast and plays no sound` counts each process that the session starts. The session start now also runs `notify-filter.sh path`. Replace:

```ts
  // Only git and tmux run: no audio player.
  expect(ran.filter(argv => argv[0] !== 'git' && argv[0] !== 'tmux' && !((argv[0] ?? '').endsWith('/scripts/notification-line.sh') && argv[1] === 'path'))).toEqual([])
```

with:

```ts
  // Only git, tmux and the two path reads of the notifications pane run: no
  // audio player.
  const isPathRead = (argv: string[]) =>
    ['/scripts/notification-line.sh', '/scripts/notify-filter.sh'].some(name => (argv[0] ?? '').endsWith(name))
    && argv[1] === 'path'
  expect(ran.filter(argv => argv[0] !== 'git' && argv[0] !== 'tmux' && !isPathRead(argv))).toEqual([])
```

- [ ] Step 2 (run test, observe FAIL):

```
claude plugin test plugins/clux
```

Expected: `(fail)` for the 6 new tests (`the header names both views, and f and n change the view`, `an invalid row is marked in red before its raw line`, `with no rules the view says how to add one`, `outside git the view says so, and only n and q work`, `the poll reads the list on the session cwd in both views`, `back in Notifications, x acts on the first row again`). The summary reads `72 pass` and `6 fail`.

- [ ] Step 3 (minimal implementation): Make these changes in `plugins/clux/hooks/notifications/register.tsx`.

3a. Replace:

```ts
import type { NotifRow } from '../../types'
import { toRows } from './lines'
```

with:

```ts
import type { NotifRow } from '../../types'
import { parseList, rowText, validCount } from './filters'
import { toRows } from './lines'
```

3b. Replace:

```ts
const notifications = atom({ plugin: 'clux', key: 'notifications' } as const, [])
```

with:

```ts
const notifications = atom({ plugin: 'clux', key: 'notifications' } as const, [])
// The Filters view: which view shows, the filter file of the session's repo,
// its rules, and the rule box. The notifications atom does not change.
const filters = atom({ plugin: 'clux', key: 'filters' } as const, {
  view: 'notifications',
  file: '',
  rules: [],
  editing: null,
})
```

3c. Replace:

```ts
const script = ($: EngineInterface) => `${$.plugin.root}/scripts/notification-line.sh`
```

with:

```ts
const script = ($: EngineInterface) => `${$.plugin.root}/scripts/notification-line.sh`
// The filter file has one owner, as the queue line has: the hook, the status
// bar and this pane all run notify-filter.sh, so the pane parses no rule and
// checks no regex itself.
const filterScript = ($: EngineInterface) => `${$.plugin.root}/scripts/notify-filter.sh`
```

3d. Replace:

```ts
// One poll at a time, so a slow poll and the next tick never overlap.
async function tick($: EngineInterface) {
  if (loop.isPolling) return
  loop.isPolling = true
  try {
    await poll($)
```

with:

```ts
// One verb of notify-filter.sh on the session cwd. A script that cannot
// start, or that overruns RUN_MS, resolves to undefined; the reason goes to
// the debug log.
async function runFilter($: EngineInterface, verb: string, args: string[] = []) {
  const cwd = await $.session.cwd()
  return $.process.run([filterScript($), verb, cwd, ...args], { timeoutMs: RUN_MS }).catch(error => {
    $.ui.log(`clux notifications: filter ${verb} failed: ${String(error)}`, { to: 'debug' })
    return undefined
  })
}

// The filter file path, read one time at the start. '' when the cwd is not in
// a git repo: then the pane polls no list.
async function filterPath($: EngineInterface): Promise<string> {
  const answer = await runFilter($, 'path')
  return answer?.exitCode === 0 ? answer.stdout.trim() : ''
}

// The rules, in both views: the header counts them. A list that fails keeps
// the rows the last poll drew.
async function pollFilters($: EngineInterface) {
  const state = await read($, filters)
  if (state.file === '') return
  const answer = await runFilter($, 'list')
  if (answer?.exitCode !== 0) return
  const rules = parseList(answer.stdout)
  if (JSON.stringify(rules) !== JSON.stringify(state.rules)) {
    await update($, filters, s => ({ ...s, rules }))
  }
}

// One poll at a time, so a slow poll and the next tick never overlap.
async function tick($: EngineInterface) {
  if (loop.isPolling) return
  loop.isPolling = true
  try {
    await poll($)
    await pollFilters($)
```

`RUN_MS` is declared lower in the file; `runFilter` reads it only when it runs, after the module has loaded.

3e. Replace the `focusRow` block and its comment:

```ts
// Move the ring. The pane may not hold the keys, and then the engine refuses
// the move: the person sees nothing, `focused` keeps its value, and the
// reason goes to the debug log. `j`, `k` and `x` all follow this rule.
//
// A move that lands sets `focused` here. The engine does not give a plugin's
// own `$.ui.focus` to that plugin's `ui.focus` hook (the debug log says
// "ui.focus skipped: re-entry"), so the hook below never sees it.
async function focusRow($: EngineInterface, index: number) {
  const key = `row:${index}`
  const moved = await $.ui
    .focus({ requestId: PANE, key })
    .catch(error => ({ deny: String(error) }))
  if (moved.deny) {
    $.ui.log(`clux notifications: the ring stayed off ${key}: ${moved.deny}`, { to: 'debug' })
    return
  }
  focused = index
}
```

with:

```ts
// Move the ring. The pane may not hold the keys, and then the engine refuses
// the move: the person sees nothing, the index keeps its value, and the
// reason goes to the debug log. `j`, `k` and `x` all follow this rule, in
// both views.
//
// A move that lands sets the index there. The engine does not give a
// plugin's own `$.ui.focus` to that plugin's `ui.focus` hook (the debug log
// says "ui.focus skipped: re-entry"), so the hook below never sees it.
async function askFocus($: EngineInterface, key: string): Promise<boolean> {
  const moved = await $.ui
    .focus({ requestId: PANE, key })
    .catch(error => ({ deny: String(error) }))
  if (moved.deny) {
    $.ui.log(`clux notifications: the ring stayed off ${key}: ${moved.deny}`, { to: 'debug' })
    return false
  }
  return true
}

async function focusRow($: EngineInterface, index: number) {
  if (await askFocus($, `row:${index}`)) focused = index
}
```

3f. Replace the line `export const register: Register = on => {` with:

```ts
// --- The Filters view -------------------------------------------------------

// The row the ring sits on in the Filters view: its own index and its own
// key prefix, `rule:<i>`, so the two views never move each other's ring.
let ruleFocused = 0

// `f` and `n`. A view opens with its ring on its first row, and the rule box
// closes.
async function showView($: EngineInterface, view: 'notifications' | 'filters') {
  await update($, filters, s => ({ ...s, view, editing: null }))
  if (view === 'filters') {
    ruleFocused = 0
    if ((await read($, filters)).rules.length > 0) await askFocus($, 'rule:0')
  } else {
    focused = 0
    if ((await read($, notifications)).length > 0) await askFocus($, 'row:0')
  }
}

async function focusRule($: EngineInterface, index: number) {
  if (await askFocus($, `rule:${index}`)) ruleFocused = index
}

// `j` and `k` in the Filters view, limited to the rows the last poll wrote.
async function moveRule($: EngineInterface, by: number) {
  const { rules } = await read($, filters)
  if (rules.length === 0) return
  await focusRule($, Math.min(rules.length - 1, Math.max(0, ruleFocused + by)))
}

export const register: Register = on => {
```

3g. In the `session.start` hook, replace:

```ts
      loop.queue = await queuePath($)
      await tick($)
```

with:

```ts
      loop.queue = await queuePath($)
      const file = await filterPath($)
      await update($, filters, s => ({ ...s, file }))
      await tick($)
```

3h. In the `ui.focus` hook, replace:

```ts
    if (key.startsWith('row:')) {
      const index = Number(key.slice(4))
      if (Number.isInteger(index) && index >= 0) focused = index
    }
```

with:

```ts
    if (key.startsWith('row:')) {
      const index = Number(key.slice(4))
      if (Number.isInteger(index) && index >= 0) focused = index
    }
    if (key.startsWith('rule:')) {
      const index = Number(key.slice(5))
      if (Number.isInteger(index) && index >= 0) ruleFocused = index
    }
```

3i. Replace the whole `on('ui.render', { component: 'Pane', requestId: PANE }, ...)` hook (from that line to its closing `})`, before the comment `// No band: one label at the end of the prompt footer`) with:

```tsx
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, notifications)
    const state = await read($, filters)
    const isFilters = state.view === 'filters'
    const hasRepo = state.file !== ''
    // The row text is cut to the pane, so one long notification cannot
    // reflow the list.
    const width = Math.max(8, e.props.bodyColumns - 1)

    return (
      <Box flexDirection="column">
        <Box>
          {/* The two views, the one that shows in bold. */}
          <Text bold={!isFilters}>{TITLE} · {list.length}</Text>
          <Text>  |  </Text>
          <Text bold={isFilters}>Filters · {validCount(state.rules)} </Text>
          {/* Over the footer's label: the chord closes an open pane, and `q`
              closes it while the pane has the keys. Plain, so it reads
              "q: hide", as the other keys do. Both views draw it. */}
          <Button
            key="close-notifications"
            plain
            hotkey="q"
            label="hide"
            action={TOGGLE_ACTION}
            onPress={() => $.ui.close({ id: PANE })}
          />
          {/* Only the keys of the view that shows: a hotkey of the other
              view would act on rows the person cannot see. */}
          {!isFilters && (
            <Box key="notification-keys">
              <Text> </Text>
              {/* Claude Code draws a plain Button with a hotkey as "j: down". */}
              <Button key="nav-down" plain hotkey="j" label="down" onPress={() => move($, 1)} />
              <Text> </Text>
              <Button key="nav-up" plain hotkey="k" label="up" onPress={() => move($, -1)} />
              <Text> </Text>
              <Button key="row-remove" plain hotkey="x" label="remove" onPress={() => removeRow($)} />
              <Text> </Text>
              <Button key="view-filters" plain hotkey="f" label="filters" onPress={() => showView($, 'filters')} />
            </Box>
          )}
          {isFilters && (
            <Box key="filter-keys">
              <Text> </Text>
              <Button key="view-notifications" plain hotkey="n" label="notifications" onPress={() => showView($, 'notifications')} />
              {hasRepo && (
                <Box key="rule-keys">
                  <Text> </Text>
                  <Button key="rule-down" plain hotkey="j" label="down" onPress={() => moveRule($, 1)} />
                  <Text> </Text>
                  <Button key="rule-up" plain hotkey="k" label="up" onPress={() => moveRule($, -1)} />
                </Box>
              )}
            </Box>
          )}
        </Box>
        {/* Claude Code opens a pane without the keys while the message box
            has a draft, and a mod cannot take them: the person moves in. */}
        {!e.props.isFocused && !isFilters && list.length > 0 && (
          <Text dimColor>ctrl+x tab: move into the list</Text>
        )}
        {!isFilters && list.length === 0 && <Text dimColor>No notifications.</Text>}
        {!isFilters && list.map((row, i) => (
          <Button
            key={`row:${i}`}
            autoFocus={i === 0 ? true : undefined}
            plain
            label={row.text.slice(0, width)}
            onPress={() => jumpTo($, row)}
          />
        ))}
        {isFilters && !hasRepo && <Text dimColor>Not in a git repo.</Text>}
        {isFilters && hasRepo && <Text dimColor>{state.file.slice(0, width)}</Text>}
        {isFilters && hasRepo && state.rules.length === 0 && (
          <Text dimColor>No filters. a: add a rule.</Text>
        )}
        {/* A Button draws no color of its own, so an invalid row is a red
            word before its raw line. */}
        {isFilters && hasRepo && state.rules.map((row, i) => (
          <Box key={`rule-line:${i}`}>
            {row.kind === 'invalid' && <Text color="red">invalid </Text>}
            <Button
              key={`rule:${i}`}
              autoFocus={i === 0 ? true : undefined}
              plain
              label={rowText(row).slice(0, width)}
              onPress={() => focusRule($, i)}
            />
          </Box>
        ))}
      </Box>
    )
  })
```

In this task, Enter on a rule row only puts the ring on it; Task 8 makes it edit the rule.

- [ ] Step 4 (run test, observe PASS):

```
claude plugin test plugins/clux
tsc -p plugins/clux
```

Expected: `78 pass` and `0 fail` (`Ran 78 tests across 5 files`); the tests of today, for example `the pane draws one row for each line of the queue` and `x takes the focused row out and polls again`, still pass. `tsc` prints nothing and exits 0.

- [ ] Step 5 (commit):

```
git add plugins/clux/hooks/notifications/register.tsx plugins/clux/tests/notifications.test.tsx plugins/clux/tests/sessions.test.tsx
git -c user.email=1195406+404pilo@users.noreply.github.com commit -m "feat(clux): the notifications pane has a Filters view" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Verification:**

- `claude plugin test plugins/clux` ends with `0 fail`.
- `tsc -p plugins/clux; echo $?` prints `0`.
- `grep -c "notify-filter.sh" plugins/clux/hooks/notifications/register.tsx` prints a number of 1 or more.

---

## Task 8: The Filters view edits the rules

**Goal:** In the Filters view, `a` adds, `e` and Enter on a row edit, `t` changes allow to deny or deny to allow, and `x` removes, through `notify-filter.sh`; a refused rule shows a toast and keeps the rule box, a stale line reads the list again, and a ring that leaves the box closes it.

**Files touched:**
- Modify: `plugins/clux/hooks/notifications/register.tsx`
- Test: `plugins/clux/tests/notifications.test.tsx`

**Steps:**

- [ ] Step 1 (failing test): Add these helpers and tests at the end of `plugins/clux/tests/notifications.test.tsx`:

```tsx

// The verb and the arguments after the cwd of each notify-filter.sh write, in
// order. The `path` and `list` reads are left out.
const filterRuns = (ran: string[][]) =>
  ran
    .filter(argv => (argv[0] ?? '').endsWith('/scripts/notify-filter.sh') && !['path', 'list'].includes(argv[1] ?? ''))
    .map(argv => [argv[1], ...argv.slice(3)])

test('a and Enter run add with the kind and the regex, then close the box', async ($, on) => {
  const { ran, filter } = world(on, { text: null })
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })

  await ui.press({ key: 'rule-add' })
  expect((await ui.find({ key: 'filter-input' }))?.props.value).toBe('deny ')

  filter.list = '2\tdeny\twip\n'
  await ui.input({ key: 'filter-input', text: ' deny   wip ' })
  expect(filterRuns(ran)).toEqual([['add', 'deny', 'wip']])
  expect(await ui.find({ key: 'filter-input' })).toBeUndefined()
  expect(await ruleLabels(ui)).toEqual(['deny   wip'])
  await ui.unmount()
})

test('e and Enter on a row run set on the line number of the focused rule', async ($, on) => {
  const { ran, filter } = world(on, { text: null })
  filter.list = '3\tallow\t^feat-\n5\tdeny\twip\n'
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })

  await raiseFocus($, 'rule:1')
  await ui.press({ key: 'rule-edit' })
  expect((await ui.find({ key: 'filter-input' }))?.props.value).toBe('deny wip')
  await ui.input({ key: 'filter-input', text: 'deny wip|tmp' })

  // Enter on a row edits that row.
  await ui.press({ key: 'rule:0' })
  expect((await ui.find({ key: 'filter-input' }))?.props.value).toBe('allow ^feat-')
  await ui.input({ key: 'filter-input', text: 'allow ^fix-' })

  expect(filterRuns(ran)).toEqual([['set', '5', 'deny', 'wip|tmp'], ['set', '3', 'allow', '^fix-']])
  await ui.unmount()
})

test('t changes allow to deny with the same regex, and x removes the focused line', async ($, on) => {
  const { ran, filter } = world(on, { text: null })
  filter.list = '3\tallow\t^feat-\n5\tdeny\twip\n6\tinvalid\tdeny (\n'
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })

  await ui.press({ key: 'rule-toggle' })
  await raiseFocus($, 'rule:1')
  await ui.press({ key: 'rule-toggle' })
  // An invalid row has no kind to change.
  await raiseFocus($, 'rule:2')
  await ui.press({ key: 'rule-toggle' })
  await ui.press({ key: 'rule-remove' })

  expect(filterRuns(ran)).toEqual([
    ['set', '3', 'deny', '^feat-'],
    ['set', '5', 'allow', 'wip'],
    ['remove', '6'],
  ])
  await ui.unmount()
})

test('a refused regex shows the first line of stderr and keeps the box with the text', async ($, on) => {
  const { toasts, filter } = world(on, { text: null })
  filter.exits.add = 2
  filter.stderr.add = 'grep: Unmatched ( or \\(\nmore\n'
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })
  await ui.press({ key: 'rule-add' })

  await ui.input({ key: 'filter-input', text: 'deny (' })
  expect(toasts).toEqual(['grep: Unmatched ( or \\('])
  expect((await ui.find({ key: 'filter-input' }))?.props.value).toBe('deny (')
  await ui.unmount()
})

test('a first word that is not allow or deny runs nothing and keeps the box', async ($, on) => {
  const { ran, toasts } = world(on, { text: null })
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })
  await ui.press({ key: 'rule-add' })

  await ui.input({ key: 'filter-input', text: 'block wip' })
  expect(filterRuns(ran)).toEqual([])
  expect(toasts).toEqual(['A rule starts with allow or deny.'])
  expect((await ui.find({ key: 'filter-input' }))?.props.value).toBe('block wip')
  await ui.unmount()
})

test('a stale line number reads the list again and says the file changed', async ($, on) => {
  const { ran, toasts, filter } = world(on, { text: null })
  filter.list = '3\tdeny\twip\n'
  filter.exits.remove = 3
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })

  const listsBefore = ran.filter(argv => argv[1] === 'list').length
  filter.list = '4\tdeny\twip\n'
  await ui.press({ key: 'rule-remove' })

  expect(toasts).toEqual(['The file changed. Try again.'])
  expect(ran.filter(argv => argv[1] === 'list').length).toBe(listsBefore + 1)
  expect(await ruleLabels(ui)).toEqual(['deny   wip'])
  await ui.unmount()
})

test('a ring that leaves the box closes it with no change', async ($, on) => {
  const { ran, filter } = world(on, { text: null })
  filter.list = '3\tdeny\twip\n'
  await start($)
  const ui = await mountPane($, true)
  await ui.press({ key: 'view-filters' })
  await ui.press({ key: 'rule-add' })
  expect(await ui.find({ key: 'filter-input' })).toBeDefined()

  // Esc gives the keys back to the ring, which lands on a row.
  await raiseFocus($, 'rule:0')
  expect(await ui.find({ key: 'filter-input' })).toBeUndefined()
  expect(filterRuns(ran)).toEqual([])
  await ui.unmount()
})
```

- [ ] Step 2 (run test, observe FAIL):

```
claude plugin test plugins/clux
```

Expected: `(fail)` for the 7 new tests (there is no `rule-add`, `rule-edit`, `rule-toggle`, `rule-remove` Button and no `filter-input` Input). The summary reads `78 pass` and `7 fail`.

- [ ] Step 3 (minimal implementation): Make these changes in `plugins/clux/hooks/notifications/register.tsx` (the Task 7 version).

3a. Replace:

```ts
import type { NotifRow } from '../../types'
import { parseList, rowText, validCount } from './filters'
```

with:

```ts
import type { FilterEditing, FilterRow, NotifRow } from '../../types'
import { editValue, parseList, rowText, splitRule, validCount } from './filters'
```

3b. Replace:

```ts
let ruleFocused = 0

```

(the line and the blank line after it) with:

```ts
let ruleFocused = 0

// The key of the rule box, and the toasts of a rule the pane refuses.
const INPUT_KEY = 'filter-input'
const BAD_KIND = 'A rule starts with allow or deny.'
const STALE = 'The file changed. Try again.'

```

3c. Replace:

```ts
  await focusRule($, Math.min(rules.length - 1, Math.max(0, ruleFocused + by)))
}

export const register: Register = on => {
```

with:

```ts
  await focusRule($, Math.min(rules.length - 1, Math.max(0, ruleFocused + by)))
}

// The focused rule, limited to the list the last poll wrote.
async function focusedRule($: EngineInterface): Promise<FilterRow | undefined> {
  const { rules } = await read($, filters)
  if (rules.length === 0) return undefined
  return rules[Math.min(ruleFocused, rules.length - 1)]
}

// What an answer of add, set or remove means for the person. 0: the file
// changed, so the list is read again. 2: the script refused the rule, and the
// first line of its stderr says why. 3: the line moved under the pane, so the
// list is read again. True only for 0.
async function settle($: EngineInterface, answer: Awaited<ReturnType<typeof runFilter>>): Promise<boolean> {
  if (answer?.exitCode === 0) {
    await pollFilters($)
    return true
  }
  if (answer?.exitCode === 3) {
    await pollFilters($)
    $.ui.toast(STALE)
    return false
  }
  if (answer?.exitCode === 2) {
    $.ui.toast(answer.stderr.split('\n')[0]?.trim() || 'The rule was not saved.')
    return false
  }
  $.ui.toast('The filter file did not change.')
  return false
}

// The rule box takes the keys. In a test, and while the pane does not hold
// the keys, the engine refuses: the box is drawn all the same.
async function openBox($: EngineInterface, editing: NonNullable<FilterEditing>) {
  await update($, filters, s => ({ ...s, editing }))
  await askFocus($, INPUT_KEY)
}

// `a`: a new rule, `deny ` ready in the box.
async function addRule($: EngineInterface) {
  await openBox($, { mode: 'add', value: 'deny ' })
}

// `e`, or Enter on a row: the box holds the rule, to replace its line.
async function editRule($: EngineInterface, index?: number) {
  if (index !== undefined) ruleFocused = index
  const row = await focusedRule($)
  if (!row) return
  await openBox($, { mode: 'set', n: row.n, value: editValue(row) })
}

// Enter in the box. A refused rule keeps the box open with what the person
// typed; a stale line closes it, because its line number is no longer true.
async function submitRule($: EngineInterface, value: string) {
  const { editing } = await read($, filters)
  if (!editing) return
  const keep = () => update($, filters, s => ({ ...s, editing: { ...editing, value } }))
  const rule = splitRule(value)
  if (!rule) {
    $.ui.toast(BAD_KIND)
    await keep()
    return
  }
  const answer = editing.mode === 'add'
    ? await runFilter($, 'add', [rule.kind, rule.regex])
    : await runFilter($, 'set', [String(editing.n), rule.kind, rule.regex])
  if (await settle($, answer) || answer?.exitCode === 3) {
    await update($, filters, s => ({ ...s, editing: null }))
    return
  }
  await keep()
}

// `t`: allow becomes deny and deny becomes allow, with the same regex. An
// invalid row has no kind to change: `e` mends it.
async function toggleRule($: EngineInterface) {
  const row = await focusedRule($)
  if (!row || row.kind === 'invalid') return
  await settle($, await runFilter($, 'set', [String(row.n), row.kind === 'allow' ? 'deny' : 'allow', row.text]))
}

// `x`: the focused line goes. The ring stays at the same place, so taking
// the last row out moves it up one.
async function removeRule($: EngineInterface) {
  const row = await focusedRule($)
  if (!row) return
  if (!(await settle($, await runFilter($, 'remove', [String(row.n)])))) return
  const { rules } = await read($, filters)
  if (rules.length > 0) await focusRule($, Math.min(ruleFocused, rules.length - 1))
}

export const register: Register = on => {
```

3d. Replace:

```ts
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
```

with:

```ts
  //
  // The rule box closes when the ring leaves it: Esc gives the keys back to
  // the ring, and a box the person left holds no edit they can see through.
  on('ui.focus', { requestId: PANE }, async ($, e, next) => {
```

3e. In the `ui.focus` hook, replace:

```ts
    if (key.startsWith('rule:')) {
      const index = Number(key.slice(5))
      if (Number.isInteger(index) && index >= 0) ruleFocused = index
    }
```

with:

```ts
    if (key.startsWith('rule:')) {
      const index = Number(key.slice(5))
      if (Number.isInteger(index) && index >= 0) ruleFocused = index
    }
    if (key !== INPUT_KEY && (await read($, filters)).editing) {
      await update($, filters, s => ({ ...s, editing: null }))
    }
```

3f. In the Pane render hook, replace:

```tsx
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, notifications)
    const state = await read($, filters)
```

with:

```tsx
    const elements = $.ui.resolve(e)
    const { Box, Text, Button } = elements
    // The mobile surface draws no Input: there the rule box is not drawn,
    // and the rules are read only.
    const Input = 'Input' in elements ? elements.Input : undefined
    const list = await read($, notifications)
    const state = await read($, filters)
```

3g. Replace:

```tsx
                  <Button key="rule-up" plain hotkey="k" label="up" onPress={() => moveRule($, -1)} />
```

with:

```tsx
                  <Button key="rule-up" plain hotkey="k" label="up" onPress={() => moveRule($, -1)} />
                  <Text> </Text>
                  <Button key="rule-add" plain hotkey="a" label="add" onPress={() => addRule($)} />
                  <Text> </Text>
                  <Button key="rule-edit" plain hotkey="e" label="edit" onPress={() => editRule($)} />
                  <Text> </Text>
                  <Button key="rule-toggle" plain hotkey="t" label="allow/deny" onPress={() => toggleRule($)} />
                  <Text> </Text>
                  <Button key="rule-remove" plain hotkey="x" label="remove" onPress={() => removeRule($)} />
```

3h. Replace the rule rows block, from the comment to the end of the render return:

```tsx
        {/* A Button draws no color of its own, so an invalid row is a red
            word before its raw line. */}
        {isFilters && hasRepo && state.rules.map((row, i) => (
          <Box key={`rule-line:${i}`}>
            {row.kind === 'invalid' && <Text color="red">invalid </Text>}
            <Button
              key={`rule:${i}`}
              autoFocus={i === 0 ? true : undefined}
              plain
              label={rowText(row).slice(0, width)}
              onPress={() => focusRule($, i)}
            />
          </Box>
        ))}
      </Box>
    )
  })
```

with:

```tsx
        {/* A Button draws no color of its own, so an invalid row is a red
            word before its raw line. Enter on a row edits it. */}
        {isFilters && hasRepo && state.rules.map((row, i) => (
          <Box key={`rule-line:${i}`}>
            {row.kind === 'invalid' && <Text color="red">invalid </Text>}
            <Button
              key={`rule:${i}`}
              autoFocus={i === 0 && !state.editing ? true : undefined}
              plain
              label={rowText(row).slice(0, width)}
              onPress={() => editRule($, i)}
            />
          </Box>
        ))}
        {isFilters && hasRepo && state.editing && Input && (
          <Input
            key={INPUT_KEY}
            label={state.editing.mode === 'add' ? 'new rule: ' : `line ${state.editing.n}: `}
            placeholder="allow|deny <regex>"
            value={state.editing.value}
            submitLabel="save"
            onSubmit={(value: string) => submitRule($, value)}
          />
        )}
      </Box>
    )
  })
```

- [ ] Step 4 (run test, observe PASS):

```
claude plugin test plugins/clux
tsc -p plugins/clux
```

Expected: `85 pass` and `0 fail` (`Ran 85 tests across 5 files`). `tsc` prints nothing and exits 0.

- [ ] Step 5 (commit):

```
git add plugins/clux/hooks/notifications/register.tsx plugins/clux/tests/notifications.test.tsx
git -c user.email=1195406+404pilo@users.noreply.github.com commit -m "feat(clux): add, edit, toggle and remove filter rules in the pane" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Verification:**

- `claude plugin test plugins/clux` ends with `85 pass` and `0 fail`.
- `tsc -p plugins/clux; echo $?` prints `0`.
- `claude plugin validate plugins/clux` reports no error.

---

## Task 9: Version 5.2.0, the docs and the last checks

**Goal:** clux is 5.2.0, and the CHANGELOG, the README, the reference and the setup skill tell the person about Ctrl-X, the filter file, the Filters view and `@clux-filter-mark`.

**Files touched:**
- Modify: `plugins/clux/.claude-plugin/plugin.json`
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `docs/reference.md`
- Modify: `plugins/clux/skills/configuring-tmux/SKILL.md`
- Test: `test/setup-skill.bats`

**Steps:**

- [ ] Step 1 (failing test): In `test/setup-skill.bats`, in the test `setup-skill: the skill still carries every load-bearing part of the procedure`, add `'@clux-filter-mark' \` to the `for part in` list, after the line `'@clux-agent-glyph-busy-frames' \`:

```bash
                '@clux-agent-glyph-busy-frames' \
                '@clux-filter-mark' \
                'throttle.sh'; do
```

- [ ] Step 2 (run test, observe FAIL):

```
bats test/setup-skill.bats
```

Expected: `not ok` for `setup-skill: the skill still carries every load-bearing part of the procedure`, with the line `the skill lost: [@clux-filter-mark]`.

- [ ] Step 3 (minimal implementation):

3a. In `plugins/clux/.claude-plugin/plugin.json`, replace `"version": "5.1.0",` with `"version": "5.2.0",`. The marketplace entry has no plugin version; do not change `.claude-plugin/marketplace.json`.

3b. In `plugins/clux/skills/configuring-tmux/SKILL.md`, after the paragraph that starts with ``@clux-agent-glyph-busy-frames` has no flag on purpose`` (it ends with `A user who wants it sets it in their own file.`), add this paragraph:

```markdown
`@clux-filter-mark` (default `⊘ filtered`) has no flag either. It is the text that the status bar shows before the notification when the repo of the active pane has notification filters (`<main repo root>/.claude/clux-filters.local`, written by the Filters view of the notifications pane). Detection cannot read it off an old bar. The mark shows in the current status line with no new token, so setup writes nothing for it. A user who wants another text, or an empty value to turn the mark off, sets it in their own file.
```

3c. In `docs/reference.md`, in the `## Configuration` table, add this row after the `@claude-notify-<type>-sound-file` row:

```markdown
| `@clux-filter-mark` | `⊘ filtered` | The status-bar mark when the repo of the active pane has notification filters. An empty value turns it off |
```

3d. In `README.md`, in the `## Notifications pane` section, replace the example block:

````markdown
```
Notifications · 3 q: hide  j: down  k: up  x: remove
main:editor Task done
⚡ agents / pr-flow needs you
main:tests 8/8 green
```
````

with:

````markdown
```
Notifications · 3  |  Filters · 2 q: hide  j: down  k: up  x: remove  f: filters
main:editor Task done
⚡ agents / pr-flow needs you
main:tests 8/8 green
```
````

Then, in the same section, after the bullet that starts with `- Enter works also when Claude Code itself does not run in tmux`, add:

```markdown
- In the `prefix + M` popup, Ctrl-X deletes the selected notification, and the popup stays open. Enter goes to the notification, and Esc closes the popup.
```

Then, before the line `## Companion terminal`, add this section:

````markdown
### Notification filters

A file in a repo can hide some clux notifications. clux reads `<main repo root>/.claude/clux-filters.local`. All the worktrees of the repo use the same file. Each line is one rule:

```
# clux notification filters. Regex type: grep -E, case-sensitive.
allow ^feat-
deny  wip
```

- The regex (`grep -E`, case-sensitive) matches the Claude session name, the name that the sessions pane shows. When a session has no name, the name is the folder name.
- `deny` hides the notifications of the sessions that match. `allow` lets only the sessions that match notify. When the file has an `allow` rule, the name must match one `allow` rule and no `deny` rule. The order of the lines has no effect.
- A hidden notification makes no sound, no desktop banner, no queue line and no bell. A new rule does not remove the lines that are already in the queue.
- clux ignores blank lines and lines that start with `#`. It also ignores a line that is not a rule, and the Filters view shows that line in red.
- When git does not ignore the file, clux adds it to `.git/info/exclude`.

In the notifications pane, `f` opens the Filters view and `n` goes back. The view shows the file path and one row for each rule:

```
Notifications · 3  |  Filters · 2 q: hide  n: notifications  j: down  k: up  a: add  e: edit  t: allow/deny  x: remove
/code/app/.claude/clux-filters.local
allow  ^feat-
deny   wip
```

- `a` opens a box with `deny `. Type the rule, then push Enter. `e`, or Enter on a row, edits the focused rule. `t` changes allow to deny, or deny to allow. `x` removes the focused rule. Esc closes the box with no change.
- When grep refuses the regex, the pane shows the grep error, and the box stays open with your text.
- Outside a git repo, the view shows `Not in a git repo.`

When the repo of the active tmux pane has one or more valid rules, the status bar shows `⊘ filtered` before the notification. To change the text, set `@clux-filter-mark`. An empty value turns the mark off:

```
set -g @clux-filter-mark 'filters on'
```
````

3e. In `CHANGELOG.md`, add this entry above `## [5.1.0]`:

```markdown
## [5.2.0]

### Added

- **Notification filters.** A file in a repo, `<main repo root>/.claude/clux-filters.local`, hides some clux notifications. Each line is `allow <regex>` or `deny <regex>`. The regex (`grep -E`, case-sensitive) matches the Claude session name. `deny` hides the notifications of the sessions that match. `allow` lets only the sessions that match notify. All the worktrees of the repo use the same file
- A hidden notification makes no sound, no desktop banner, no queue line and no bell, for a Claude in a tmux pane and for a background agent. The lines that are already in the queue stay
- `scripts/notify-filter.sh` owns the file: the hook, the status bar and the notifications pane all run it. Its verbs are `path`, `check`, `active`, `list`, `add`, `set` and `remove`. When git does not ignore the file, `add` writes it to `.git/info/exclude`
- The notifications pane has a Filters view. `f` opens it and `n` goes back. `a` adds a rule, `e` (or Enter on a row) edits one, `t` changes allow to deny or deny to allow, and `x` removes one. The header shows `Notifications · <N>  |  Filters · <R>`
- The status bar shows `⊘ filtered` when the repo of the active pane has a valid rule. `@clux-filter-mark` sets the text; an empty value turns the mark off. The current status line shows the mark with no `/clux:setup` run

### Changed

- **Ctrl-X in the `prefix + M` popup deletes the selected notification, and the popup stays open.** fzf starts again on the new queue, with the cursor on the first line. Ctrl-D does the same. The popup closes on Enter, on Esc, and when the queue is empty

```

- [ ] Step 4 (run test, observe PASS):

```
bats test/setup-skill.bats
```

Expected: every test prints `ok`.

- [ ] Step 5 (commit):

```
git add plugins/clux/.claude-plugin/plugin.json CHANGELOG.md README.md docs/reference.md plugins/clux/skills/configuring-tmux/SKILL.md test/setup-skill.bats
git -c user.email=1195406+404pilo@users.noreply.github.com commit -m "docs(clux): notification filters and ctrl-x delete (5.2.0)" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Verification:**

- `grep '"version"' plugins/clux/.claude-plugin/plugin.json` prints `  "version": "5.2.0",`.
- `grep -c '^## \[5.2.0\]' CHANGELOG.md` prints `1`.
- `bats test/notify-filter.bats test/notify-tmux.bats test/picker.bats test/session-bar-refresh.bats test/deploy-manifest.bats test/docs-tree.bats test/setup-skill.bats test/notification-line.bats test/jump.bats test/clef-names.bats` prints no `not ok`.
- `claude plugin test plugins/clux` ends with `85 pass` and `0 fail`; `tsc -p plugins/clux; echo $?` prints `0`; `claude plugin validate plugins/clux` reports no error.
- `bats test/` (more than 15 minutes) prints `not ok` only for the known failures named in the Overview (`box:` tests of `new-workspace-prompt.bats`, the 503 retry test of `clef-client.bats`, the Laya/Python tests of `terminal.bats`), the same set as on `main`.
- Live check, Esc in the rule box [inferred behavior]: start `claude --plugin-dir plugins/clux` in a git repo, run `/clux:notifications`, push `f`, then `a`. The box shows `deny `. Push Esc. Expected: the box goes away, and the file does not change (`cat "$(plugins/clux/scripts/notify-filter.sh path .)"` shows the same lines as before). If the box stays, note it in the PR: the `ui.focus` hook did not see the ring leave the box.
- Live check, the popup: put two lines in the queue, open `prefix + M`, push Ctrl-X on the first line. Expected: the popup stays open and shows only the second line. The status bar shows `⊘ filtered` while the active pane is in a repo whose filter file has a valid rule.
