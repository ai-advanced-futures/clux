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

## Notifications pane

`/clux:notifications` opens one pane for the clux notification queue — the list the tmux status bar and the `prefix + M` popup show. Each tmux server has its own queue, so a server shows only the notifications of its own sessions (see the [reference](docs/reference.md#one-queue-for-each-tmux-server)). `/clux:notifications` again closes it. `ctrl+x n` does the same from anywhere, also while you write a message, after you bind it (see below).

```
Notifications · 3  |  Filters · 2 q: hide  j: down  k: up  x: remove  f: filters
main:editor Task done
⚡ agents / pr-flow needs you
main:tests 8/8 green
```

- `j` and `k` move the focus, and so do the Down and Up arrows and Tab. Enter goes to the tmux window of the focused row (or to the agents pane of an agent row), takes the row out of the queue, and closes the pane. `x` takes the focused row out and keeps the pane open. `q` closes the pane. Esc gives the keyboard back to the prompt and keeps the pane open.
- The keys work only while the pane has the keyboard. When the message box has a draft, Claude Code opens the pane without it, and the pane says `ctrl+x tab: move into the list`. Press `ctrl+x tab` to move in.
- At the right end of the prompt footer, a dim `notifs` label opens the pane. When the queue is not empty, the label shows the count, for example `3 notifs`.
- clux reads the queue file every 2 seconds. The tmux status bar shows a new notification sooner, because tmux runs its own job on its own interval.
- Enter works also when Claude Code itself does not run in tmux (for example a background session): tmux moves its attached client to the window. With no tmux server, Enter says it could not jump, and `x` still works.
- The `prefix + M` popup shows the short text of each notification, without the ids after `|||`. In the popup, Ctrl-X deletes the selected notification, and the popup stays open. Enter goes to the notification, and Esc closes the popup.

The pane is a function-hooks mod (`hooks/notifications/`). It needs Claude Code 2.1.291 or later. The keys of this pane and the keys of the `prefix + M` popup both run `scripts/notification-line.sh`, so a jump means the same thing in both.

`ctrl+x n` needs one line in `~/.claude/keybindings.json`, because Claude Code gives a plugin no default key. Add it to the `Global` context:

```json
{ "context": "Global", "bindings": { "ctrl+x n": "app:toggleDiffPreSession" } }
```

The pane borrows the `app:toggleDiffPreSession` action, which Claude Code uses only for the diff view. While the diff view is open, the key can act on the diff view instead of the pane. To use a different key, bind that key to `app:toggleDiffPreSession`.

### Notification filters

A file in a repo can hide some clux notifications. clux reads `<main repo root>/.claude/clux-filters.local`. All the worktrees of the repo use the same file. Each line is one rule:

```
# clux notification filters. Regex type: grep -E, case-sensitive.
allow ^feat-
deny  wip
```

- The regex (`grep -E`, case-sensitive) matches the Claude session name, the name that the sessions pane shows. When a session has no name, the name is the folder name.
- `deny` hides the notifications of the sessions that match. `allow` lets only the sessions that match notify. When the file has an `allow` rule, the name must match one `allow` rule and no `deny` rule. The order of the lines has no effect.
- A hidden notification makes no sound, no desktop banner, no queue line and no bell. A new rule does not remove the lines that are already in the queue.
- clux ignores blank lines and lines that start with `#`. It also ignores a line that is not a rule, and the Filters view shows that line in red.
- When git does not ignore the file, clux adds it to `.git/info/exclude`.

In the notifications pane, `f` opens the Filters view and `n` goes back. The view shows the file path and one row for each rule:

```
Notifications · 3  |  Filters · 2
q: hide n: notifications j: down k: up a: add e: edit t: allow/deny x: remove
/code/app/.claude/clux-filters.local
allow  ^feat-
deny   wip
```

- `a` opens a box with `allow `. Type the rule, then push Enter. `e`, or Enter on a row, edits the focused rule. `t` changes allow to deny, or deny to allow. `x` removes the focused rule. Esc closes the box with no change.
- When grep refuses the regex, the pane shows the grep error, and the box stays open with your text.
- `grep -E` has no `\d`: GNU grep reads `\d` as a plain `d`. The pane refuses a new rule with `\d`. Use `[0-9]`.
- Outside a git repo, the view shows `Not in a git repo.`

In the clux session bar, a session with a window whose active pane is in a repo with one or more valid rules shows `⊘` after the session name. To change the text, set `@clux-filter-mark`. An empty value turns the mark off:

```
set -g @clux-filter-mark 'filters on'
```

## Companion terminal

The `clux:terminal` skill gives Claude one tmux pane that you can see. Claude runs commands in it. A Clef model examines each command before it runs. A dangerous command waits for your `y`. You run one Clef server and name it with `CLUX_CLEF_URL`:

```bash
export CLUX_CLEF_URL=http://127.0.0.1:8765
```

The [reference](docs/reference.md) gives the server command, the Tailscale setup for more than one machine, and `CLUX_CLEF_KEY`.

**Background sessions.** A Claude Code session with no tmux pane (`claude --bg`, or a session that a `claude agents` dashboard starts) also gets a companion. It opens as a new window, `clux-terminal <id>`, in the tmux session of the dashboard. With no dashboard, it opens on a private tmux server, and Claude gives you the line to attach to it. The companion closes when the session ends, also after a crash.

For more detail, read the [reference](docs/reference.md).

## More

- [Options, themes, agent view, Clef details, manual and TPM setup, troubleshooting](docs/reference.md)
- [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md)

MIT license.
