#!/usr/bin/env bash
# plugin-version.sh — which clux versions this machine has, and which is the
# latest. /clux:upgrade runs it first. It changes nothing.
#
# It prints one key=value line each:
#
#   loaded=<version>          the copy Claude Code loaded (CLAUDE_PLUGIN_ROOT),
#                              or "unknown" when the variable is not set
#   installed=<version>       the installed clux (user scope first)
#   installed_root=<path>     the plugin tree of that version
#   marketplace=<name>        the marketplace that version came from
#   latest=<version>          the version the marketplace offers now, or
#                              "unknown" (no jq, no network, a source it
#                              cannot read)
#   status=<status>           one of:
#       update-available       latest is newer than installed
#       restart-needed         installed is newer than loaded: the update ran,
#                              and Claude Code did not restart
#       current                installed is the latest
#       unknown                the latest version could not be read
#
# The installed version comes from "claude plugin list --json". Without the
# claude CLI, it is the highest version in the plugin cache. The CLI does not
# give the latest version, so that comes from the clux entry of the
# marketplace:
#   - a relative source ("./plugins/clux"): the plugin.json in the marketplace
#     checkout
#   - a GitHub source (github, git-subdir, url or git on github.com): the
#     plugin.json on the default branch, read with curl from
#     raw.githubusercontent.com
#
# Environment, for tests: CLUX_PLUGINS_DIR (default ~/.claude/plugins).

set -uo pipefail

PLUGINS_DIR="${CLUX_PLUGINS_DIR:-$HOME/.claude/plugins}"

# The "version" of the plugin.json on stdin, or nothing.
_version() {
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# 0 when $1 is a higher version than $2.
_newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -V | tail -1)" = "$1" ]
}

LOADED=""
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" ] \
    && LOADED=$(_version < "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json")

# "<version><TAB><install path>" of the installed clux.
best=""
if command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    best=$(claude plugin list --json 2>/dev/null | jq -r '
        [.[] | select(.id | startswith("clux@"))]
        | (map(select(.scope == "user")) + .)[0] // empty
        | "\(.version)\t\(.installPath)"' 2>/dev/null)
fi
if [ -z "$best" ]; then
    best=$(find "$PLUGINS_DIR/cache" -mindepth 5 -maxdepth 5 -type f \
        -path '*/clux/*/.claude-plugin/plugin.json' 2>/dev/null \
        | while IFS= read -r f; do
            printf '%s\t%s\n' "$(_version < "$f")" "${f%/.claude-plugin/plugin.json}"
        done | LC_ALL=C sort -V -k1,1 | tail -1)
fi
INSTALLED=""; INSTALLED_ROOT=""; MARKETPLACE=""
if [ -n "$best" ]; then
    IFS=$'\t' read -r INSTALLED INSTALLED_ROOT <<< "$best"
    # .../cache/<marketplace>/clux/<version>
    MARKETPLACE="${INSTALLED_ROOT%/clux/*}"
    MARKETPLACE="${MARKETPLACE##*/}"
fi

LATEST=""
MJ="$PLUGINS_DIR/marketplaces/$MARKETPLACE/.claude-plugin/marketplace.json"
if [ -n "$MARKETPLACE" ] && [ -f "$MJ" ] && command -v jq >/dev/null 2>&1; then
    # Four lines: source type, url or repo, path, ref. A plain string source
    # gives "relative" and the path.
    {
        read -r kind; read -r where; read -r sub; read -r ref
    } <<EOF
$(jq -r '(.plugins[] | select(.name == "clux") | .source) as $s
    | if ($s | type) == "string" then "relative", "", $s, ""
      else ($s.source // ""), ($s.url // $s.repo // ""), ($s.path // ""), ($s.ref // "") end' "$MJ" 2>/dev/null)
EOF
    sub="${sub#./}"; sub="${sub%/}"
    case "$kind" in
        relative)
            f="$PLUGINS_DIR/marketplaces/$MARKETPLACE/$sub/.claude-plugin/plugin.json"
            [ -f "$f" ] && LATEST=$(_version < "$f")
            ;;
        github|git-subdir|url|git)
            # owner/repo from "owner/repo", https://github.com/owner/repo(.git)
            # or git@github.com:owner/repo(.git).
            repo=""
            case "$where" in
                *github.com[:/]*) repo="${where#*github.com[:/]}" ;;
                */*) [ "$kind" = github ] && repo="$where" ;;
            esac
            repo="${repo%.git}"; repo="${repo%/}"
            if [ -n "$repo" ] && command -v curl >/dev/null 2>&1; then
                LATEST=$(curl -fsSL --max-time 5 \
                    "https://raw.githubusercontent.com/$repo/${ref:-HEAD}/${sub:+$sub/}.claude-plugin/plugin.json" \
                    2>/dev/null | _version)
            fi
            ;;
    esac
fi

: "${LOADED:=unknown}" "${INSTALLED:=unknown}" "${LATEST:=unknown}"

if [ "$LATEST" != unknown ] && [ "$INSTALLED" != unknown ] && _newer "$LATEST" "$INSTALLED"; then
    STATUS=update-available
elif [ "$LOADED" != unknown ] && [ "$INSTALLED" != unknown ] && _newer "$INSTALLED" "$LOADED"; then
    STATUS=restart-needed
elif [ "$LATEST" = unknown ]; then
    STATUS=unknown
else
    STATUS=current
fi

printf 'loaded=%s\n' "$LOADED"
printf 'installed=%s\n' "$INSTALLED"
printf 'installed_root=%s\n' "$INSTALLED_ROOT"
printf 'marketplace=%s\n' "$MARKETPLACE"
printf 'latest=%s\n' "$LATEST"
printf 'status=%s\n' "$STATUS"
