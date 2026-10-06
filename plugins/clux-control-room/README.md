# clux-control-room

A Claude Code mod. It gives one pane for all the background sessions of the current repository.

```
Background sessions · 3
1: tenant-registry-p1   ● needs input  choose: YAML crosswalk or SQL table?
2: ce-db-roster         ● working      #41 Running the migration tests
3: mods-research        ● done         #28 #29 10 daily uses + gh-account mod
```

## What it does

- **The pane** (`/control-room`) shows one row for each background session: its name, its status (needs input, working, unknown, done, failed, stopped), its PRs, and its description. The description is the question of a session that needs input, else what the session does now or the result it gave. A PR number is a link: click it to open the PR. A session is **unknown** when its state is one the mod does not know, or when it works but has not written its state for 30 minutes (it probably stopped without a last write).
- **Select a session** to open it. `/control-room` gives the pane the keyboard, so press the number of a row (`1` to `9`), or move with Tab and press Enter. In tmux, the mod opens a new window that runs `claude attach <id>`. Outside tmux, it copies that command. Esc gives the keyboard back to the prompt.
- **`/control-room off`** closes the pane.
- **The band** above the prompt shows the counts (`1 needs input · 2 working`) while a session works or needs you. **Show** opens the pane.
- **The alert.** When a session writes `needs input:`, the mod shows a toast and plays a sound. It alerts one time for each new question, also for a second question from the same session. The first check after start does not alert.

## Which sessions it shows

The mod reads the job folders that Claude Code keeps for background sessions (`~/.claude/jobs/*/state.json`, or `$CLAUDE_CONFIG_DIR/jobs`). It shows a session when its folder or its worktree is in the current repository. It finds the root of the main working tree, so a session in any worktree under that root counts, and a session in a subfolder counts too. A worktree outside the root counts when `git worktree list` names it. The mod reads that list again each minute. The session that runs the mod is not in the list.

Finished and unknown sessions stay in the list for 3 days after their last write. The mod reads the folders every 5 seconds.

## Sound

The mod plays `sounds/needs-input.wav` with the first of `afplay` (macOS), `paplay`, `pw-play`, `aplay` or `play` that works. It plays one time for each check, also when the check finds more than one new question.

## Install

```
/plugin install clux-control-room --marketplace ai-advanced-futures/clux
```

To run it from a working copy:

```
$ claude --plugin-dir plugins/clux-control-room
```

## Development

```
$ claude plugin validate plugins/clux-control-room
$ claude plugin test plugins/clux-control-room
$ tsc -p plugins/clux-control-room
```

`tsc` needs the types that Claude Code writes to `.claude-plugin/types/` when it loads the mod one time (for example with `--plugin-dir`).

Function hooks are early access in Claude Code. This mod was written for Claude Code 2.1.291.
