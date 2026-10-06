#!/usr/bin/env bats
# plugin-version.bats — plugin-version.sh compares the loaded, the installed
# and the latest clux, from a fake plugin directory.

load test_helper

PV="$SCRIPTS_DIR/plugin-version.sh"

# _install VERSION — a cache copy of clux in marketplace "mp".
_install() {
    local d="$CLUX_PLUGINS_DIR/cache/mp/clux/$1/.claude-plugin"
    mkdir -p "$d"
    printf '{\n  "name": "clux",\n  "version": "%s"\n}\n' "$1" > "$d/plugin.json"
}

# _marketplace SOURCE_JSON [VERSION] — the marketplace entry; with a VERSION,
# a relative source gets that plugin.json in the checkout.
_marketplace() {
    local m="$CLUX_PLUGINS_DIR/marketplaces/mp"
    mkdir -p "$m/.claude-plugin"
    printf '{"name":"mp","plugins":[{"name":"other","source":"./x"},{"name":"clux","source":%s}]}\n' "$1" \
        > "$m/.claude-plugin/marketplace.json"
    if [ -n "${2:-}" ]; then
        mkdir -p "$m/plugins/clux/.claude-plugin"
        printf '{"version": "%s"}\n' "$2" > "$m/plugins/clux/.claude-plugin/plugin.json"
    fi
}

setup() {
    install_stubs
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export CLUX_PLUGINS_DIR="$BATS_TEST_TMPDIR/plugins"
    unset CLAUDE_PLUGIN_ROOT
    # No claude CLI by default, so the cache gives the installed version.
    printf '#!/bin/sh\nexit 127\n' > "$BATS_TEST_TMPDIR/stubs/claude"
    chmod +x "$BATS_TEST_TMPDIR/stubs/claude"
}

@test "plugin-version: the claude CLI gives the installed version, user scope first" {
    _install 4.2.0
    _install 4.3.0
    _marketplace '"./plugins/clux"' 4.3.0
    cat > "$BATS_TEST_TMPDIR/stubs/claude" <<STUB
#!/bin/sh
cat <<'JSON'
[{"id":"other@mp","version":"9.9.9","scope":"user","installPath":"/x"},
 {"id":"clux@mp","version":"4.3.0","scope":"project","installPath":"$CLUX_PLUGINS_DIR/cache/mp/clux/4.3.0"},
 {"id":"clux@mp","version":"4.2.0","scope":"user","installPath":"$CLUX_PLUGINS_DIR/cache/mp/clux/4.2.0"}]
JSON
STUB
    run "$PV"
    [[ "$output" == *"installed=4.2.0"* ]]
    [[ "$output" == *"installed_root=$CLUX_PLUGINS_DIR/cache/mp/clux/4.2.0"* ]]
    [[ "$output" == *"marketplace=mp"* ]]
    [[ "$output" == *"status=update-available"* ]]
}

@test "plugin-version: a newer marketplace version is update-available" {
    _install 4.2.0
    _install 4.10.0
    _marketplace '"./plugins/clux"' 4.11.0
    run "$PV"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed=4.10.0"* ]]
    [[ "$output" == *"installed_root=$CLUX_PLUGINS_DIR/cache/mp/clux/4.10.0"* ]]
    [[ "$output" == *"marketplace=mp"* ]]
    [[ "$output" == *"latest=4.11.0"* ]]
    [[ "$output" == *"status=update-available"* ]]
}

@test "plugin-version: the same version is current" {
    _install 4.3.0
    _marketplace '"./plugins/clux"' 4.3.0
    run "$PV"
    [[ "$output" == *"status=current"* ]]
}

@test "plugin-version: an installed copy newer than the loaded one is restart-needed" {
    _install 4.2.0
    _install 4.3.0
    _marketplace '"./plugins/clux"' 4.3.0
    CLAUDE_PLUGIN_ROOT="$CLUX_PLUGINS_DIR/cache/mp/clux/4.2.0" run "$PV"
    [[ "$output" == *"loaded=4.2.0"* ]]
    [[ "$output" == *"status=restart-needed"* ]]
}

@test "plugin-version: a GitHub source is read from raw.githubusercontent.com" {
    _install 4.3.0
    _marketplace '{"source":"git-subdir","url":"https://github.com/acme/clux","path":"plugins/clux"}'
    cat > "$BATS_TEST_TMPDIR/stubs/curl" <<'STUB'
#!/bin/sh
for a; do url="$a"; done
echo "$url" > "$BATS_TEST_TMPDIR/curl.url"
printf '{\n  "version": "4.4.0"\n}\n'
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/curl"
    run "$PV"
    [[ "$output" == *"latest=4.4.0"* ]]
    [[ "$output" == *"status=update-available"* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/curl.url")" = "https://raw.githubusercontent.com/acme/clux/HEAD/plugins/clux/.claude-plugin/plugin.json" ]
}

@test "plugin-version: with no network the latest is unknown" {
    _install 4.3.0
    _marketplace '{"source":"github","repo":"acme/clux"}'
    printf '#!/bin/sh\nexit 6\n' > "$BATS_TEST_TMPDIR/stubs/curl"
    chmod +x "$BATS_TEST_TMPDIR/stubs/curl"
    run "$PV"
    [[ "$output" == *"latest=unknown"* ]]
    [[ "$output" == *"status=unknown"* ]]
}

@test "plugin-version: with no install it reports unknown and does not fail" {
    run "$PV"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed=unknown"* ]]
    [[ "$output" == *"status=unknown"* ]]
}
