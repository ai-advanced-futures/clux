#!/usr/bin/env bats
# docs-tree.bats — CONTRIBUTING.md carries a file tree of the plugin. Nothing
# checked it, so it drifted: by 3.3.0 it still listed two scripts that no longer
# exist and omitted fourteen that do, including every session-surface script and
# both libraries. The CHANGELOG had to record the staleness as a known issue.
#
# A tree a contributor cannot trust is worse than no tree, because it reads as
# authoritative. These tests check it against the real directories in both
# directions, so neither a new script nor a deleted one can slip past it.

load test_helper

DOC="$REPO_ROOT/CONTRIBUTING.md"
PLUGIN_DIR="$REPO_ROOT/plugins/clux"

# The fenced tree block: from the `plugins/clux/` root line to the closing fence.
# Keyed on the root line rather than "the first fence in the file", so an
# unrelated code block added above it does not silently become the subject.
_tree_block() {
    awk '/^plugins\/clux\/$/ { inb = 1 }
         inb && /^```/ { exit }
         inb { print }' "$DOC"
}

# Every shell file a contributor could be looking for. Both directories are
# shipped, and both hold files the tree claims to describe.
_real_files() {
    for path in "$PLUGIN_DIR"/scripts/*.sh "$PLUGIN_DIR"/hooks/*.sh; do
        [ -f "$path" ] && printf '%s\n' "${path##*/}"
    done
}

@test "docs-tree: the tree block is present and non-empty" {
    [ -f "$DOC" ]
    local n
    n=$(_tree_block | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] || { echo "no 'plugins/clux/' file tree found in CONTRIBUTING.md"; false; }
}

@test "docs-tree: every script and hook on disk appears in the tree" {
    local tree missing=""
    tree="$(_tree_block)"
    local base
    for base in $(_real_files); do
        printf '%s\n' "$tree" | grep -qF "$base" || missing="$missing $base"
    done
    [ -z "$missing" ] || {
        echo "on disk but missing from the CONTRIBUTING.md tree:$missing"
        false
    }
}

@test "docs-tree: every script the tree names exists on disk" {
    # The direction that caught the 3.3.0 staleness: configure-tmux.sh and
    # validate-setup.sh were still listed after being deleted.
    local absent="" base
    for base in $(_tree_block | grep -oE '[a-zA-Z0-9_.-]+\.sh' | sort -u); do
        [ -f "$PLUGIN_DIR/scripts/$base" ] || [ -f "$PLUGIN_DIR/hooks/$base" ] \
            || absent="$absent $base"
    done
    [ -z "$absent" ] || {
        echo "named in the CONTRIBUTING.md tree but absent from the plugin:$absent"
        false
    }
}
