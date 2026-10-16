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

@test "notify-filter: add and set refuse \\d, which grep -E reads as a plain d" {
    _repo
    run "$FILTER" add "$REPO" deny 'x\d'
    [ "$status" -eq 2 ]
    [ "$output" = 'grep -E reads \d as a plain d: use [0-9]' ]
    [ ! -e "$RULES" ]
    # An escaped backslash before a d is not \d.
    run "$FILTER" add "$REPO" deny 'x\\d'
    [ "$status" -eq 0 ]
    run "$FILTER" set "$REPO" 2 deny 'x\D'
    [ "$status" -eq 2 ]
    [ "$(tail -1 "$RULES")" = 'deny x\\d' ]
}

@test "notify-filter: a \\d line already in the file stays valid" {
    _repo
    _rules 'deny x\d'
    run "$FILTER" list "$REPO"
    [ "$output" = "$(printf '1\tdeny\tx\\d')" ]
}
