---
description: Interactively configure tmux for the clux session surface and notifications
allowed-tools: Skill, Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Task
---

# clux Setup

Install the clux session surface into the user's tmux: the session list and
agent-state columns in the bar, the session keys, the workspace key, and the
notification wiring.

## What to do

Invoke the `clux:configuring-tmux` skill and follow it exactly.

That skill holds the whole procedure — the three detection agents, the report,
the prerequisite questions, the two install modes, the migration diff, the
confirm gate, the apply steps, the verification, and the summary — together with
every rule that governs them.

**If the skill cannot be loaded, stop and say so.** Do not configure anything
from what you remember of the procedure. A half-applied edit to a tmux.conf is
the one outcome this command exists to prevent, and the rules that prevent it
live in the skill, not here.

## Why this file states no rules

Every rule has exactly one copy, in the skill. Restating any of them here would
create a second copy to drift from the first — the fault this codebase has
already paid for twice: two deploy lists that disagreed about `path.sh`
(CHANGELOG 3.0.9), and a CONTRIBUTING file tree that drifted to two scripts
that no longer existed and fourteen missing ones.

`test/setup-skill.bats` holds this boundary: it fails if the procedure creeps
back into this file, and it fails if this file stops naming the skill.
