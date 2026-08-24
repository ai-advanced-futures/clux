#!/usr/bin/env bats
# setup-skill.bats — holds the boundary between commands/setup.md and
# skills/configuring-tmux/SKILL.md.
#
# The design's "Entry point" section put the judgement-heavy configuration work
# in a skill and left /clux:setup as the entry point. 3.3.0 shipped with all of
# it still inline in the command, recorded as a known issue. This file is what
# keeps it from sliding back.
#
# The boundary is worth a test because of what it is for: every rule has exactly
# one copy. Restating a rule in the command creates a second copy to drift from
# the first, which is the fault this repository has already paid for twice — two
# deploy lists that disagreed about path.sh (CHANGELOG 3.0.9), and a CONTRIBUTING
# file tree nothing checked. Both were silent until someone read them.

load test_helper

COMMAND="$REPO_ROOT/plugins/clux/commands/setup.md"
SKILL="$REPO_ROOT/plugins/clux/skills/configuring-tmux/SKILL.md"

@test "setup-skill: the skill exists with a name and a description in its frontmatter" {
    [ -f "$SKILL" ] || { echo "missing: $SKILL"; false; }
    # Frontmatter must be the first thing in the file, or the harness does not
    # read it as frontmatter at all.
    [ "$(head -1 "$SKILL")" = "---" ] || { echo "first line is not a --- fence"; false; }
    grep -q '^name: configuring-tmux$' "$SKILL" \
        || { echo "frontmatter has no 'name: configuring-tmux'"; false; }
    grep -q '^description: .' "$SKILL" \
        || { echo "frontmatter has no non-empty description"; false; }
}

@test "setup-skill: the command names the skill" {
    grep -qF 'clux:configuring-tmux' "$COMMAND" \
        || { echo "commands/setup.md does not name the skill it must invoke"; false; }
}

@test "setup-skill: the command stays an entry point and carries no procedure" {
    # Each of these is a marker of the procedure itself. Any one of them in the
    # command means a rule now has two homes.
    local leaked="" marker
    for marker in '## Phase' 'CRITICAL RULES' 'render-clux-conf.sh' 'deploy-manifest.txt' \
                  'Snippet S1' 'CLAUDE_PLUGIN_ROOT' 'status-format'; do
        grep -qF "$marker" "$COMMAND" && leaked="$leaked [$marker]"
    done
    [ -z "$leaked" ] || {
        echo "procedure leaked back into commands/setup.md:$leaked"
        echo "it belongs in skills/configuring-tmux/SKILL.md, and in only one of the two"
        false
    }
}

@test "setup-skill: the command is short enough to be read whole" {
    # Not a style rule. The command's whole job is to hand off, and a long one
    # is the shape the procedure grows back into.
    local n
    n=$(wc -l < "$COMMAND" | tr -d ' ')
    [ "$n" -le 80 ] || { echo "commands/setup.md is $n lines — too long for a hand-off"; false; }
}

@test "setup-skill: the skill still carries every load-bearing part of the procedure" {
    # The move was verbatim. This is the guard that it stayed that way: each
    # string below is a rule whose loss would be silent at setup time and
    # expensive afterwards.
    local missing="" part
    for part in 'CRITICAL RULES' \
                'CLAUDE_PLUGIN_ROOT' \
                'deploy-manifest.txt' \
                '#{@clux_session_bar}#(' \
                'byte-identical' \
                'tmux/scripts/' \
                'render-clux-conf.sh' \
                'verify-tmux-conf.sh' \
                'AskUserQuestion' \
                '@clux-agent-glyph-busy-frames' \
                'throttle.sh'; do
        grep -qF "$part" "$SKILL" || missing="$missing [$part]"
    done
    [ -z "$missing" ] || { echo "the skill lost:$missing"; false; }
}

@test "setup-skill: the ASCII-glyph-default rationale is unchanged and not caveated by the animation" {
    # The animated-busy-glyph design (2026-08-23) is explicit: the shipped
    # default stays ASCII, so this language does not change and does not
    # grow a caveat. Losing either string silently is exactly the kind of
    # drift this file exists to catch.
    local missing="" part
    for part in 'plain ASCII on purpose' \
                'owns the reflow'; do
        grep -qF "$part" "$SKILL" || missing="$missing [$part]"
    done
    [ -z "$missing" ] || { echo "the skill lost:$missing"; false; }
}

@test "setup-skill: the skill still carries all eight phases, in order" {
    local got
    got="$(grep -oE '^## Phase [1-8]' "$SKILL" | grep -oE '[1-8]' | tr -d '\n')"
    [ "$got" = "12345678" ] || {
        echo "expected phases 1-8 in order, found: $got"
        false
    }
}
