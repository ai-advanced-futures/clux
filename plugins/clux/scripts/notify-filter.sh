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
RULE_RE='^[[:space:]]*(allow|deny)[[:space:]]+(.*[^[:space:]])[[:space:]]*$'
SKIP_RE='^[[:space:]]*(#|$)'

COMMON=""
ROOT=""
FILE=""

# The main repo root is not always the folder above the common dir: a
# submodule keeps its git dir in <super>/.git/modules/<name>, and
# --separate-git-dir puts it anywhere. So: the top level of the work tree,
# and for a linked worktree the first entry of `git worktree list`, which is
# the main worktree.
_locate() {
    local out gitdir
    [ -n "$CWD" ] || return 1
    out=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir --git-dir --show-toplevel 2>/dev/null) || return 1
    { IFS= read -r COMMON; IFS= read -r gitdir; IFS= read -r ROOT; } <<EOF
$out
EOF
    [ -n "$COMMON" ] && [ -n "$ROOT" ] || return 1
    if [ "$gitdir" != "$COMMON" ]; then
        ROOT=$(git -C "$CWD" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
        [ -n "$ROOT" ] || return 1
    fi
    FILE="$ROOT/.claude/clux-filters.local"
}

_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Sets KIND and REGEX for a rule line; returns 1 for a blank line or a
# comment. A line that is not "allow|deny <regex>", or whose regex grep -E
# refuses, is KIND=invalid with the raw line as REGEX.
_parse() {
    [[ "$1" =~ $SKIP_RE ]] && return 1
    KIND=invalid
    REGEX="$1"
    if [[ "$1" =~ $RULE_RE ]] && _check_regex "${BASH_REMATCH[2]}" 2>/dev/null; then
        KIND="${BASH_REMATCH[1]}"
        REGEX="${BASH_REMATCH[2]}"
    fi
    return 0
}

# _match NAME -e REGEX... — 0 when one of the regexes matches NAME.
_match() {
    local name="$1"; shift
    printf '%s\n' "$name" | grep -Eq "$@" 2>/dev/null
}

# The one read loop of the file: "<n>\t<kind>\t<regex>" for each rule line.
_list() {
    local n=0 line
    [ -f "$FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        _parse "$line" || continue
        printf '%s\t%s\t%s\n' "$n" "$KIND" "$REGEX"
    done < "$FILE"
}

# One grep for the allow rules and one for the deny rules, not one for each
# rule: _list gives only regexes that grep -E takes.
_check() {
    local name="$1" kind regex
    local -a allow=() deny=()
    while IFS=$'\t' read -r _ kind regex; do
        case "$kind" in
            allow) allow+=(-e "$regex") ;;
            deny)  deny+=(-e "$regex") ;;
        esac
    done < <(_list)
    if [ "${#allow[@]}" -gt 0 ] && ! _match "$name" "${allow[@]}"; then
        return 1
    fi
    if [ "${#deny[@]}" -gt 0 ] && _match "$name" "${deny[@]}"; then
        return 1
    fi
    return 0
}

_active() {
    _list | cut -f2 | grep -qvx invalid
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

# A write refuses \d and \D: grep -E has no digit class, so GNU grep reads
# \d as a plain "d", and "deny x\d" would hide "xd" but not "x5". A file line
# with \d stays valid, so a rule the person already has keeps its meaning.
_check_digit() {
    local rest="${1//\\\\/}"
    case "$rest" in
        *'\d'*|*'\D'*)
            printf 'grep -E reads \\d as a plain d: use [0-9]\n' >&2
            return 2 ;;
    esac
    return 0
}

# The checks of every rule that a write puts in the file.
_check_rule() {
    _check_kind "$1" && _check_regex "$2" && _check_digit "$2"
}

_check_n() {
    case "$1" in
        ''|0*|*[!0-9]*) printf 'not a line number: "%s"\n' "$1" >&2; return 2 ;;
    esac
    return 0
}

# A last line with no newline must not join the next line that goes in.
_ends_open() {
    [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]
}

# Line <n> is a line that list prints: not blank, not a comment, not past
# the end. An invalid line counts, so the person can mend or remove it.
_is_rule_line() {
    [ -f "$FILE" ] || return 1
    _parse "$(sed -n "${1}p" "$FILE")"
}

# _write CMD ARGS... — the output of CMD goes to a temporary file in the same
# folder, then mv puts it in place: a reader never sees a half-written file.
# The last write wins. A CMD that fails (a file it cannot read) changes
# nothing, so a failed read cannot empty the file. The temporary file takes
# the mode of the file that is there, because mktemp makes it 0600.
_write() {
    local tmp
    tmp=$(mktemp "${FILE}.XXXXXX") || return 1
    [ -f "$FILE" ] && cp -p "$FILE" "$tmp" 2>/dev/null
    if "$@" > "$tmp" && mv "$tmp" "$FILE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Line <n> becomes TEXT, or goes when DROP is set. The values go through
# ENVIRON, not awk -v: -v reads backslash escapes, and a regex keeps its
# backslashes.
_rewritten() {
    N="$1" TEXT="${2:-}" DROP="${3:-}" awk '
        NR == ENVIRON["N"] + 0 { if (ENVIRON["DROP"] == "") print ENVIRON["TEXT"]; next }
        { print }' "$FILE"
}

_rewrite() {
    _write _rewritten "$@"
}

# A ".local" name does not make git ignore a file. The line goes in the
# info/exclude of the common dir, so it holds for every worktree and changes
# no file of the repo. check-ignore sees the line after, so it goes in once.
# check-ignore cannot run in a bare main repo (a bare clone with linked
# worktrees), so the line in the file is also a stop.
_exclude() {
    local exclude="$COMMON/info/exclude" line='/.claude/clux-filters.local'
    git -C "$ROOT" check-ignore -q -- .claude/clux-filters.local 2>/dev/null && return 0
    grep -qxF -- "$line" "$exclude" 2>/dev/null && return 0
    mkdir -p "$COMMON/info" 2>/dev/null || return 0
    _ends_open "$exclude" && printf '\n' >> "$exclude"
    printf '%s\n' "$line" >> "$exclude"
}

# The file with one more rule at the end, or the header and the rule.
_added() {
    if [ -f "$FILE" ]; then
        cat "$FILE" || return 1
        _ends_open "$FILE" && printf '\n'
    else
        printf '%s\n' "$HEADER"
    fi
    printf '%s %s\n' "$1" "$2"
}

_add() {
    local kind="$1" regex
    regex=$(_trim "$2")
    _check_rule "$kind" "$regex" || return 2
    mkdir -p "$ROOT/.claude" || return 1
    _write _added "$kind" "$regex" || return 1
    _exclude
    return 0
}

_set() {
    local n="$1" kind="$2" regex
    regex=$(_trim "$3")
    _check_n "$n" || return 2
    _check_rule "$kind" "$regex" || return 2
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
