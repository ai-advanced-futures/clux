#!/usr/bin/env bats
# deploy-manifest.bats — plugins/clux/config/deploy-manifest.txt is the single
# list of scripts /clux:setup deploys into ~/.config/clux/scripts/.
#
# The manifest exists to stop the drift CHANGELOG 3.0.9 records: path.sh sat in
# one hand-written list and not the other, and installs shipped without a
# library they needed. Its own header says "/clux:setup, /clux:validate and the
# bats tests all read THIS file" — until this file existed, the tests did not,
# so the drift the manifest was added to prevent still had no automated guard.
#
# These tests are that guard. They check the manifest against the scripts on
# disk in both directions, so neither a new script nor a deleted one can slip
# past it.

load test_helper

MANIFEST="$REPO_ROOT/plugins/clux/config/deploy-manifest.txt"

# The reader the manifest's own header prescribes: skip blank lines and
# comments. Every consumer must use exactly this rule.
_manifest_entries() {
    grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$'
}

# Runs at setup time only, from the plugin tree, and deliberately not deployed
# — the manifest header explains why. Keep this list in step with that note.
SETUP_ONLY="render-clux-conf.sh verify-tmux-conf.sh"

# Sourced, never executed. They must be readable; the executable bit on them
# means nothing. path.sh does not carry it and helpers.sh does, which is
# untidy but harmless — asserting +x on either would be asserting an accident.
LIBRARIES="helpers.sh path.sh"

@test "deploy-manifest: exists and lists at least one script" {
    [ -f "$MANIFEST" ]
    local n
    n=$(_manifest_entries | wc -l | tr -d ' ')
    [ "$n" -gt 0 ]
}

@test "deploy-manifest: every listed script exists in the plugin scripts directory" {
    local missing=""
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        [ -f "$SCRIPTS_DIR/$entry" ] || missing="$missing $entry"
    done <<EOF
$(_manifest_entries)
EOF
    [ -z "$missing" ] || { echo "listed in the manifest but absent from scripts/:$missing"; false; }
}

@test "deploy-manifest: every listed script is executable, and every library readable" {
    local notexec="" notread=""
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case " $LIBRARIES " in
            *" $entry "*)
                [ -r "$SCRIPTS_DIR/$entry" ] || notread="$notread $entry"
                continue
                ;;
        esac
        [ -x "$SCRIPTS_DIR/$entry" ] || notexec="$notexec $entry"
    done <<EOF
$(_manifest_entries)
EOF
    [ -z "$notexec" ] || { echo "listed but not executable:$notexec"; false; }
    [ -z "$notread" ] || { echo "library listed but not readable:$notread"; false; }
}

@test "deploy-manifest: every runtime script on disk is listed — the 3.0.9 drift guard" {
    # The direction that actually caught the original bug. A new script added
    # to scripts/ and forgotten here ships an install missing that file.
    local unlisted=""
    local listed
    listed="$(_manifest_entries)"
    for path in "$SCRIPTS_DIR"/*.sh; do
        local base="${path##*/}"
        case " $SETUP_ONLY " in
            *" $base "*) continue ;;
        esac
        printf '%s\n' "$listed" | grep -qxF "$base" || unlisted="$unlisted $base"
    done
    [ -z "$unlisted" ] || {
        echo "present in scripts/ but missing from the manifest:$unlisted"
        echo "add it to the manifest, or to SETUP_ONLY here if it is deliberately not deployed"
        false
    }
}

@test "deploy-manifest: every script a listed script sources is itself listed" {
    # The 3.0.9 bug in its original form: path.sh was left out of a deploy list
    # even though helpers.sh and show-notification.sh both source it. The
    # install then held scripts that source a file that is not there — the
    # source failed, NOTIFY_FILE resolved empty, and the bar drew nothing. A
    # missing library is silent, so only a closure check finds it.
    #
    # This test replaces test/configure-deploy.bats, which asserted the same
    # closure over the `local scripts=( … )` array inside configure-tmux.sh.
    # That script is gone, and the manifest is the list now.
    local listed
    listed="$(_manifest_entries)"
    local missing=""
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        [ -f "$SCRIPTS_DIR/$entry" ] || continue
        local dep
        for dep in $(grep -E '^[[:space:]]*source ' "$SCRIPTS_DIR/$entry" 2>/dev/null \
                     | grep -oE '[a-zA-Z0-9_-]+\.sh'); do
            printf '%s\n' "$listed" | grep -qxF "$dep" \
                || missing="$missing ${entry}->${dep}"
        done
    done <<EOF
$listed
EOF
    [ -z "$missing" ] || { echo "sourced but not deployed:$missing"; false; }
}

@test "deploy-manifest: the setup-only scripts are deliberately absent from it" {
    local listed
    listed="$(_manifest_entries)"
    for base in $SETUP_ONLY; do
        [ -f "$SCRIPTS_DIR/$base" ] || { echo "$base no longer exists — update SETUP_ONLY"; false; }
        printf '%s\n' "$listed" | grep -qxF "$base" && {
            echo "$base is setup-only and must not be deployed, but the manifest lists it"
            false
        }
    done
    return 0
}

@test "deploy-manifest: contains no duplicate entries" {
    local dupes
    dupes=$(_manifest_entries | sort | uniq -d)
    [ -z "$dupes" ] || { echo "duplicate manifest entries: $dupes"; false; }
}

@test "deploy-manifest: commands/setup.md and commands/validate.md both read it" {
    # The manifest only prevents drift if the consumers actually use it
    # instead of carrying a fourth and fifth hand-written copy.
    grep -q 'deploy-manifest' "$REPO_ROOT/plugins/clux/commands/setup.md" \
        || { echo "commands/setup.md does not reference the manifest"; false; }
    grep -q 'deploy-manifest' "$REPO_ROOT/plugins/clux/commands/validate.md" \
        || { echo "commands/validate.md does not reference the manifest"; false; }
}
