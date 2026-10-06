# clux-control-room

A Claude Code mod. It gives one pane for all the background sessions of the current repository.

```
Background sessions · 3
● needs input  tenant-registry-p1   12 min [ Open ]
   "choose: YAML crosswalk or SQL table?"
● working      ce-db-roster         38 min
   "turn 41"
● result       mods-research          done [ Read ]
   "10 daily uses + gh-account mod, 8/8 tests"
```

## What it does

- **The pane** (`/control-room`) shows each background session: its status, its name, its age, and its last line. The age of a working session is the time since it started. The age of each other session is the time since its last change. A session that needs input shows its question. A session that is done shows its `result:` line.
- **The band** above the prompt shows the counts (`1 needs input · 2 working`) while a session works or needs you. **Show** opens the pane.
- **The alert.** When a session writes `needs input:`, the mod shows a toast and plays a sound. It alerts one time for each new question. The first check after start does not alert.
- **Open** opens the session. In tmux, it opens a new window that runs `claude attach <id>`. Outside tmux, it copies that command.
- **Read** shows the full result line. **Hide** makes it short again.

## Which sessions it shows

The mod reads the job folders that Claude Code keeps for background sessions (`~/.claude/jobs/*/state.json`, or `$CLAUDE_CONFIG_DIR/jobs`). It shows a session when its folder or its worktree is in the current repository. It finds the root of the main working tree, so a session in any worktree under that root counts, and a session in a subfolder counts too. The session that runs the mod is not in the list.

Finished sessions (result, failed, stopped) stay in the list for 3 days. The mod reads the folders every 5 seconds.

## Sound

On macOS the mod plays `sounds/needs-input.wav` with Claude Code's own player. On Linux Claude Code has no player, so the mod runs the first of `pw-play`, `paplay` or `aplay` that works.

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
