#!/usr/bin/env bats
# validate-hooks.bats — each hook command in hooks.json has a check in
# /clux:validate (Agent C, check 1) that fails when the command is missing.
#
# The tests run the real check block from commands/validate.md, so a new hook
# command with no check fails here: 4.1.0 added `terminal.sh session-env
# --hook` to SessionStart and no check named it.

load test_helper

VALIDATE_MD="$REPO_ROOT/plugins/clux/commands/validate.md"
HOOKS_JSON="$REPO_ROOT/plugins/clux/hooks/hooks.json"

# hooks_check_block — the bash block of "1. **Plugin hooks.json**".
hooks_check_block() {
    awk '/^1\. \*\*Plugin hooks\.json\*\*/ { found = 1; next }
         found && /^ *```bash/ { inblock = 1; next }
         inblock && /^ *```/ { exit }
         inblock { print }' "$VALIDATE_MD"
}

# run_hooks_check HOOKS_JSON — run the block against a plugin tree that holds
# HOOKS_JSON.
run_hooks_check() {
    local root="$BATS_TEST_TMPDIR/plugin"
    mkdir -p "$root/hooks"
    cp "$1" "$root/hooks/hooks.json"
    hooks_check_block > "$BATS_TEST_TMPDIR/check.sh"
    run env PLUGIN_ROOT="$root" bash "$BATS_TEST_TMPDIR/check.sh"
}

# hook_commands — each different hook command in hooks.json, one a line.
hook_commands() {
    python3 -c 'import json, sys
seen = []
for groups in json.load(open(sys.argv[1]))["hooks"].values():
    for group in groups:
        for hook in group["hooks"]:
            if hook["command"] not in seen:
                seen.append(hook["command"])
print("\n".join(seen))' "$HOOKS_JSON"
}

@test "the hooks check block is found in validate.md" {
    hooks_check_block > "$BATS_TEST_TMPDIR/check.sh"
    grep -q 'HOOKS_FILE=' "$BATS_TEST_TMPDIR/check.sh"
    bash -n "$BATS_TEST_TMPDIR/check.sh"
}

@test "the hooks check gives no FAIL for the hooks.json of the plugin" {
    run_hooks_check "$HOOKS_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *'OK  hooks.json found'* ]] || false
    ! grep -q '^FAIL' <<< "$output" || { echo "$output"; false; }
}

@test "the hooks check gives a FAIL when any one hook command is missing" {
    local cmd missed=
    [ -n "$(hook_commands)" ]
    while IFS= read -r cmd; do
        python3 -c 'import json, sys
data = json.load(open(sys.argv[1]))
for event, groups in list(data["hooks"].items()):
    for group in groups:
        group["hooks"] = [h for h in group["hooks"] if h["command"] != sys.argv[2]]
    data["hooks"][event] = [g for g in groups if g["hooks"]]
    if not data["hooks"][event]:
        del data["hooks"][event]
json.dump(data, open(sys.argv[3], "w"), indent=2)' "$HOOKS_JSON" "$cmd" "$BATS_TEST_TMPDIR/less.json"
        ! grep -qF "\"$cmd\"" "$BATS_TEST_TMPDIR/less.json"
        run_hooks_check "$BATS_TEST_TMPDIR/less.json"
        grep -q '^FAIL' <<< "$output" || missed="$missed$cmd"$'\n'
    done < <(hook_commands)
    [ -z "$missed" ] || { printf 'no check fails without:\n%s' "$missed"; false; }
}
