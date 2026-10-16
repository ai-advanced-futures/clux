---
name: verify
description: Run clux scripts, hooks, the fzf popup, the status bar and the Claude Code panes in an isolated tmux server to see a change work.
---

# Verify clux at its surfaces

Use a private tmux server (`tmux -L vf -f /dev/null`) and a `mktemp -d` folder. Do not touch the default server or the real queue.

## Setup

- Copy the plugin: `cp -r plugins/clux $T/plug`. Replace `$T/plug/scripts/notify-sound.sh` with a script that writes `sound $1` to a log. Then the hook makes no real sound, and you can see if it ran.
- The shell `grep` of this machine is a ugrep function. The scripts use GNU grep. To see what a script sees, use `/usr/bin/grep`.

## Surfaces

- **Scripts** (`scripts/*.sh`): run them directly against a temp git repo (`git init`, `git worktree add`).
- **Hook** (`hooks/notify-tmux.sh`): pipe a JSON payload on stdin.
  - Interactive path: `TMUX="$(tmux -L vf display -p '#{socket_path}'),1,0" TMUX_PANE=<pane id>`. Set `@claude-notify-file` on the server. `Stop` writes no queue line by default, so use `Notification` + `permission_prompt`. The hook skips a second line for the same window: clear the queue before each event.
  - Agent path: `env -u TMUX CLUX_NOTIFY_FILE=...`.
- **Popup** (`scripts/notification-picker.sh`): run it in a window of the private server with `CLUX_NOTIFY_FILE`, then `send-keys C-x / Enter / Escape` and `capture-pane -p`.
- **Status bar** (`scripts/session-bar-refresh.sh`): `tmux -L vf run-shell "<script> [quiet <client_pid>]"`, then `show -gv @clux_status`. For a real client: a second server (`tmux -L vfo`) runs `env -u TMUX tmux -L vf attach`. Set `status-right '#{@clux_status}'` and capture the outer pane.
- **Claude Code panes** (`hooks/*/register.tsx`): in a window of the private server, run `claude --plugin-dir $T/plug` in the temp repo. Resize to 230x45. Accept the trust prompt (Down, Enter). Type `/clux:notifications` and press Enter. The pane reads the REAL queue of the user: do not press `x` or Enter on its rows.
