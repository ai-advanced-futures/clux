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

## Requirements

tmux and bash ≥ 4.0. jq and flock are recommended. Python ≥ 3.10 and perl are only for the companion terminal (macOS and most Linux systems have perl). Without perl, `terminal.sh` gives exit code 2 and `clux terminal needs perl`.

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
