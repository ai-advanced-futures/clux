#!/usr/bin/env bats
# clef-names.bats — 5.0.0 renamed Laya to Clef (spec section 10). The
# changelog and the dated design documents keep the old name; each other file
# must not. docs/reference.md keeps one sentence that names the 4.x venv
# path on disk (~/.local/share/clux/laya), which is not a name of clux.
# test/terminal.bats keeps one sentence of CHANGELOG.md quoted in a test, for
# the 4.0.0 release, which also keeps the old name.

load test_helper

@test "clef-names: no laya name is left outside the changelog and the designs" {
    run bash -c "cd '$REPO_ROOT' && grep -rniI laya . \
        --exclude-dir=.git --exclude-dir=.acpx-prompts --exclude-dir=plans \
        --exclude-dir=superpowers --exclude=CHANGELOG.md --exclude=clef-names.bats \
        --exclude=reference.md --exclude=terminal.bats || true"
    [ -z "$output" ] || { echo "$output"; false; }
}

@test "clef-names: the client, the policies and the fixtures have their new names" {
    [ -f "$REPO_ROOT/plugins/clux/scripts/clef_client.py" ]
    [ -d "$REPO_ROOT/plugins/clux/config/clef" ]
    [ -f "$REPO_ROOT/test/fixtures/fake-clef.py" ]
    [ -d "$REPO_ROOT/test/fixtures/clef-wire" ]
    [ ! -e "$REPO_ROOT/plugins/clux/scripts/laya_client.py" ]
    [ ! -e "$REPO_ROOT/plugins/clux/config/laya" ]
}
