# clux

tmux status bar notifications for Claude Code. See when a task finishes or needs you.

## Quick start

Start Claude Code inside tmux. Run:

```
/plugin marketplace add ai-advanced-futures/clux
/plugin install clux@clux
```

Restart Claude Code. Run:

```
/clux:setup
```

`/clux:setup` asks a few short questions and shows each change before it writes it. To check the result, run `/clux:validate`. It changes nothing.

After a plugin update, run `/clux:upgrade`. It keeps your setup answers and asks no questions. When a newer clux is available, it gives the commands to update the plugin.

## Requirements

tmux and bash ≥ 4.0. jq and flock are recommended. Python ≥ 3.10 and perl are only for the companion terminal (macOS and most Linux systems have perl). Without perl, `terminal.sh` gives exit code 2 and `clux terminal needs perl`.

## Mirror mode

`/clux:follow on` makes all terminals that are attached to tmux show the same session. When you change session in one terminal, the others go with it. `/clux:follow off` stops it.

## Background sessions pane

`/clux:sessions` opens one pane for the background sessions of the current repository. `/clux:sessions` again closes it. `ctrl+x b` does the same from anywhere, also while you write a message. Your draft stays in the composer.

```
Background sessions · 3                      [ Hide ]
1: tenant-registry-p1   ● needs input  choose: YAML crosswalk or SQL table?
2: ce-db-roster         ● working      #41 Running the migration tests
3: mods-research        ● done         #28 #29 10 daily uses + gh-account mod
```

- Each row shows the name, the status (needs input, working, unknown, done, failed, stopped), the PRs as links, and the description. The description is the question of a session that needs input, else what the session does now or the result it gave.
- The first row has the focus when the pane opens. The Up and Down arrows (or Tab) move the focus. Enter, or the number of a row (`1` to `9`), puts the `@name` of that session in the message box at the cursor, and closes the pane. Then you can write, for example, `ask @fabric-giants for its status`. When the message box has a draft, Claude Code opens the pane without the keyboard. The pane then says `ctrl+x tab: move into the list`. Press `ctrl+x tab` to move into it. Esc gives the keyboard back to the prompt.
- clux draws nothing above the prompt. At the right end of the prompt footer, a dim `sessions` label opens the pane. When a session needs input, the label changes to the count, for example `1 needs input`.
- When a session writes `needs input:`, the footer label counts it. The pane shows no toast and plays no sound.
- A session counts when its folder or its worktree is in the repository, also a worktree that `git worktree list` names. The session that shows the pane is not in the list. A working session that has not written its state for 30 minutes shows as unknown.

The pane is a function-hooks mod (`hooks/sessions/`). It needs Claude Code 2.1.291 or later. `ctrl+x b` is the chord of the `app:cycleDiffBase` action, which Claude Code uses only in the diff panel. To use a different chord, bind it to `app:cycleDiffBase` in `~/.claude/keybindings.json` (context `Global`).

## Companion terminal

The `clux:terminal` skill gives Claude one tmux pane that you can see. Claude runs commands in it. A local model, Laya, examines each command before it runs. A dangerous command waits for your `y`. Install Laya one time. Claude asks you before it runs the install:

```bash
<plugin>/scripts/terminal.sh laya install
```

**Background sessions.** A Claude Code session with no tmux pane (`claude --bg`, or a session that a `claude agents` dashboard starts) also gets a companion. It opens as a new window, `clux-terminal <id>`, in the tmux session of the dashboard. With no dashboard, it opens on a private tmux server, and Claude gives you the line to attach to it. The companion closes when the session ends, also after a crash.

For more detail, read the [reference](docs/reference.md).

## More

- [Options, themes, agent view, Laya details, manual and TPM setup, troubleshooting](docs/reference.md)
- [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md)

MIT license.
