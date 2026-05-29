#!/usr/bin/env bats
# configure-deploy.bats — guards the deploy_scripts() list in configure-tmux.sh
# against missing sourced dependencies.
#
# Regression: path.sh was omitted from the deploy list even though
# show-notification.sh and helpers.sh both `source` it for notify-file
# resolution. A fresh `/clux:setup` then deployed scripts that source a file
# that isn't there — the source failed, NOTIFY_FILE resolved empty, and the
# status bar rendered nothing (silent blank).

load test_helper

CONFIGURE="$SCRIPTS_DIR/configure-tmux.sh"

# Emit one deployed script name per line, parsed from the `local scripts=( … )`
# array literal in deploy_scripts(). Stays read-only — never sources the file.
deployed_scripts() {
    awk '/local scripts=\(/{f=1; next} f&&/\)/{f=0} f{gsub(/[[:space:]]/,""); if($0!="") print}' \
        "$CONFIGURE"
}

# Emit the basename of every .sh a given script `source`s (lines beginning with
# optional whitespace then `source `).
sourced_deps() {
    grep -E '^[[:space:]]*source ' "$1" 2>/dev/null | grep -oE '[a-zA-Z0-9_-]+\.sh'
}

@test "deploy list parses to a non-empty set" {
    run deployed_scripts
    [ "$status" -eq 0 ]
    [ -n "$output" ] || false
}

@test "deploy list includes path.sh (sourced by helpers.sh and show-notification.sh)" {
    run deployed_scripts
    [[ "$output" == *"path.sh"* ]] || false
}

@test "every script sourced by a deployed script is itself in the deploy list" {
    local deployed; deployed="$(deployed_scripts)"
    local missing=""
    for script in $deployed; do
        local file="$SCRIPTS_DIR/$script"
        [ -f "$file" ] || continue
        local dep
        for dep in $(sourced_deps "$file"); do
            if ! grep -qxF "$dep" <<< "$deployed"; then
                missing="$missing ${script}->${dep}"
            fi
        done
    done
    [ -z "$missing" ] || { echo "Sourced-but-not-deployed:$missing"; false; }
}

@test "every deployed script actually exists in the scripts dir" {
    local deployed; deployed="$(deployed_scripts)"
    local missing=""
    for script in $deployed; do
        [ -f "$SCRIPTS_DIR/$script" ] || missing="$missing $script"
    done
    [ -z "$missing" ] || { echo "Listed-but-absent:$missing"; false; }
}
