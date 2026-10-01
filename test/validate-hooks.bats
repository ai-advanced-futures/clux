#!/usr/bin/env bats
# validate-hooks.bats — each hook command in hooks.json has a check in
# /clux:validate (Agent C, check 1) that fails when the command is missing
# or is under the wrong event.
#
# The tests run the real check block from commands/validate.md, so a new hook
# command with no check fails here: 4.1.0 added `terminal.sh session-env
# --hook` to SessionStart and no check named it. A check that reads the event
# and the command in two separate greps passes a command under the wrong
# event, so the wrong-event tests move each command to another event.

load test_helper

VALIDATE_MD="$REPO_ROOT/plugins/clux/commands/validate.md"
HOOKS_JSON="$REPO_ROOT/plugins/clux/hooks/hooks.json"
# The start of each command in hooks.json, as text.
PREFIX='${CLAUDE_PLUGIN_ROOT}/'

# hooks_check_block — the bash block of "1. **Plugin hooks.json**", with the
# indent of its fence removed, as the agent runs it.
hooks_check_block() {
    awk '/^1\. \*\*Plugin hooks\.json\*\*/ { found = 1; next }
         found && /^ *```bash/ { inblock = 1; match($0, /^ */); indent = RLENGTH; next }
         inblock && /^ *```/ { exit }
         inblock { print substr($0, indent + 1) }' "$VALIDATE_MD"
}

# run_hooks_check HOOKS_JSON [PATH] — run the block against a plugin tree
# that holds HOOKS_JSON, with PATH when it is given.
run_hooks_check() {
    local root="$BATS_TEST_TMPDIR/plugin"
    mkdir -p "$root/hooks"
    cp "$1" "$root/hooks/hooks.json"
    hooks_check_block > "$BATS_TEST_TMPDIR/check.sh"
    run env PLUGIN_ROOT="$root" PATH="${2:-$PATH}" /bin/bash "$BATS_TEST_TMPDIR/check.sh"
}

# only_python — a PATH with python3 and no jq.
only_python() {
    local bin="$BATS_TEST_TMPDIR/pybin"
    mkdir -p "$bin"
    ln -sf "$(command -v python3)" "$bin/python3"
    printf '%s' "$bin"
}

# hook_entries — each "<event>\t<command>" of hooks.json, one a line.
hook_entries() {
    python3 -c 'import json, sys
for event, groups in json.load(open(sys.argv[1]))["hooks"].items():
    for group in groups:
        for hook in group["hooks"]:
            print(event + "\t" + hook["command"])' "$HOOKS_JSON"
}

# edit_hooks MODE EVENT COMMAND OUT — write hooks.json with COMMAND removed
# from each event (MODE remove), or with the COMMAND of EVENT moved to an
# event that does not run it (MODE move).
edit_hooks() {
    python3 -c 'import json, sys
mode, event, command, out = sys.argv[1:5]
data = json.load(open(sys.argv[5]))
hooks = data["hooks"]
def drop(ev):
    for group in hooks[ev]:
        group["hooks"] = [h for h in group["hooks"] if h["command"] != command]
    hooks[ev] = [g for g in hooks[ev] if g["hooks"]]
    if not hooks[ev]:
        del hooks[ev]
if mode == "remove":
    for ev in list(hooks):
        drop(ev)
else:
    drop(event)
    runs = lambda ev: any(h["command"] == command for g in hooks.get(ev, []) for h in g["hooks"])
    other = next(ev for ev in ["Stop", "TeammateIdle", "SessionStart", "SessionEnd"] if ev != event and not runs(ev))
    hooks.setdefault(other, []).append({"hooks": [{"type": "command", "command": command, "timeout": 5}]})
json.dump(data, open(out, "w"), indent=2)' "$1" "$2" "$3" "$4" "$HOOKS_JSON"
}

@test "the hooks check block is found in validate.md" {
    hooks_check_block > "$BATS_TEST_TMPDIR/check.sh"
    grep -q 'HOOKS_FILE=' "$BATS_TEST_TMPDIR/check.sh"
    bash -n "$BATS_TEST_TMPDIR/check.sh"
}

@test "the hooks check gives no FAIL for the hooks.json of the plugin, with jq and with python3" {
    run_hooks_check "$HOOKS_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *'OK  hooks.json found'* ]] || false
    [[ "$output" == *'OK  hook: SessionStart → scripts/terminal.sh session-env --hook'* ]] || false
    ! grep -q '^FAIL' <<< "$output" || { echo "$output"; false; }
    run_hooks_check "$HOOKS_JSON" "$(only_python)"
    [[ "$output" == *'OK  hook: SessionEnd → scripts/terminal.sh close --hook'* ]] || false
    ! grep -q '^FAIL' <<< "$output" || { echo "$output"; false; }
}

@test "the hooks check fails closed when neither jq nor python3 is there" {
    mkdir -p "$BATS_TEST_TMPDIR/nobin"
    run_hooks_check "$HOOKS_JSON" "$BATS_TEST_TMPDIR/nobin"
    [[ "$output" == *'FAIL hook: SessionStart → scripts/terminal.sh session-env --hook not checked (install jq or python3)'* ]] \
        || { echo "$output"; false; }
}

@test "the hooks check gives a FAIL when any one hook command is missing" {
    local event cmd missed=
    [ -n "$(hook_entries)" ]
    while IFS=$'\t' read -r event cmd; do
        edit_hooks remove "$event" "$cmd" "$BATS_TEST_TMPDIR/less.json"
        ! grep -qF "\"$cmd\"" "$BATS_TEST_TMPDIR/less.json"
        run_hooks_check "$BATS_TEST_TMPDIR/less.json"
        grep -q '^FAIL' <<< "$output" || missed="$missed$cmd"$'\n'
    done < <(hook_entries)
    [ -z "$missed" ] || { printf 'no check fails without:\n%s' "$missed"; false; }
}

@test "the hooks check gives a FAIL when any one hook command is under the wrong event, with jq and with python3" {
    local event cmd missed= path
    for path in "$PATH" "$(only_python)"; do
        while IFS=$'\t' read -r event cmd; do
            edit_hooks move "$event" "$cmd" "$BATS_TEST_TMPDIR/moved.json"
            run_hooks_check "$BATS_TEST_TMPDIR/moved.json" "$path"
            grep -qF "FAIL hook: $event not wired to ${cmd#"$PREFIX"}" <<< "$output" \
                || missed="$missed$event $cmd ($path)"$'\n'
        done < <(hook_entries)
    done
    [ -z "$missed" ] || { printf 'no check fails when it moves from:\n%s' "$missed"; false; }
}

@test "the hooks check says that hooks.json is not valid JSON, with jq and with python3" {
    local path bad="$BATS_TEST_TMPDIR/bad.json"
    printf '{"hooks": {"Stop": [\n' > "$bad"
    for path in "$PATH" "$(only_python)"; do
        run_hooks_check "$bad" "$path"
        [[ "$output" == *'FAIL hooks.json is not valid JSON'* ]] || { echo "$output"; false; }
        ! grep -q 'not wired to' <<< "$output" || { echo "$output"; false; }
    done
}

@test "the hooks check gives a FAIL for a hook script of the same name in another directory" {
    local path other="$BATS_TEST_TMPDIR/other.json"
    sed 's#${CLAUDE_PLUGIN_ROOT}/hooks/notify-tmux.sh#/tmp/other/notify-tmux.sh#' "$HOOKS_JSON" > "$other"
    ! grep -q 'CLAUDE_PLUGIN_ROOT}/hooks/notify-tmux.sh' "$other"
    for path in "$PATH" "$(only_python)"; do
        run_hooks_check "$other" "$path"
        grep -q '^FAIL hook: Stop not wired to hooks/notify-tmux.sh' <<< "$output" || { echo "$output"; false; }
    done
}
