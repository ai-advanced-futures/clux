# clux notifications pane — design

Date: 2026-10-08. Status: written for user review. Target version: 4.6.0 (minor: a new capability; the tmux keys and the fzf popup do the same as before).

Base design: the background sessions pane (4.5.0, `hooks/sessions/register.tsx`). This pane uses the same pattern.

## 1. Goal

Today, the person sees the clux notifications in two places only: the top notification in the tmux status bar, and the fzf popup (`notification-picker.sh`). Both are in tmux. In Claude Code, the person cannot see the list.

After this change, `/clux:notifications` opens a pane in Claude Code that lists all the notifications in the queue. In the pane:

| Key | Action |
|---|---|
| `j` | Move the focus one row down. |
| `k` | Move the focus one row up. |
| Down arrow, Up arrow, Tab | Move the focus. Claude Code does this for all panes. |
| Enter | Jump to the tmux window (or the agents pane) of the focused row, remove the row, and close the pane. |
| `x` | Remove the focused row from the queue. The pane stays open. |
| Esc | Give the keys back to the prompt. |

## 2. Decisions

These decisions come from the brainstorm of 2026-10-08.

| Decision | Choice | Reason |
|---|---|---|
| Surface | A Claude Code pane (a mod). | The person asked for a clux mod. The fzf popup stays as it is. |
| Relation to the sessions pane | A separate pane, with its own command and its own footer label. | The two lists have different data and different actions. |
| Enter | Jump, remove the row, then close the pane. | After the jump, tmux shows a different window. A pane that stays open shows old data. |
| Chord | None. | The sessions pane already uses `app:cycleDiffBase` (`ctrl+x b`). We know of no other engine action that is safe to use. The person did not ask for a chord. |
| Parse of a queue line | Only in one shell script, `scripts/notification-line.sh`. | Today two scripts parse a line (`jump-to-notification.sh`, `notification-picker.sh`). A third parse in TypeScript would be one more copy that can go out of step. |

## 3. Facts

| Fact | Source |
|---|---|
| The queue is one text file. One line is one notification. New lines go at the end. | `hooks/notify-tmux.sh` lines 206 and 251. |
| An interactive line is `<session>:<window> <message>\|\|\|<session_id>:<window_id>`. | `hooks/notify-tmux.sh` line 251. |
| An agent line is `<marker> <text>\|\|\|agent:<SID>@@<TMUXSID>:<WID>:<PID>@@<CWD>`. A legacy agent line is `<marker> <text>\|\|\|agent:<SID>`. | `hooks/notify-tmux.sh` line 206, `scripts/jump-to-notification.sh`. |
| A very old line uses `\|ID:<session_id>:<window_id>`, or has no ID part. | `scripts/jump-to-notification.sh`. |
| The text that the person sees is the part before `\|\|\|` (or before `\|ID:`). | `scripts/show-notification.sh`. |
| The queue path has three tiers: `CLUX_NOTIFY_FILE`, then the sidecar `~/.config/clux/notify-file-path`, then `~/.config/tmux/claude_notification`. | `resolve_notify_file` in `scripts/path.sh`. |
| A script that changes the queue takes the lock `<queue>.lock` with `mkdir`. `show-notification.sh` also takes it, because it can remove the top line. The mod only reads in its poll, so the poll takes no lock. The picker replaces the file with `mv`, but `show-notification.sh` and `dismiss-notification.sh` write with `echo >`, which first makes the file empty. So a poll can read an empty or part list for a moment. The next poll, 2 seconds later, shows the correct list. `remove` in the new script uses `mv`. | `scripts/dismiss-notification.sh`, `scripts/show-notification.sh`, `scripts/notification-picker.sh`. |
| The status bar removes the top line when its window is the current window. It does not look at the other lines. | `scripts/show-notification.sh`. |
| A pane `Button` can have one `hotkey` (one digit or one lowercase letter). The hotkey presses the button while the pane has the keys. | `ButtonProps.hotkey` in the Claude Code types (2.1.294). |
| `$.ui.focus({ requestId, key })` moves the focus ring onto an element of the pane while the pane has the keys. | `ui.focus` in the Claude Code types (2.1.294). |
| The `ui.focus` event gives `element`, the key of the element that gets the focus. A hook on it can record the focused row. | `UiFocusInput` in the Claude Code types (2.1.294). |
| A pane that opens with `focus: true` gets the keys. Tab and the arrows move the ring, and Enter presses the focused button. | `reference.md` of the plugin-authoring skill (2.1.294). |

## 4. Design

### 4.1 Files

| File | Change |
|---|---|
| `plugins/clux/scripts/notification-line.sh` | New. Three verbs: `path`, `jump`, `remove`. See 4.2. |
| `plugins/clux/scripts/jump-to-notification.sh` | Calls `notification-line.sh jump "<top line>"`. Its parse code moves into the new script. It always exits 0, as before. |
| `plugins/clux/scripts/notification-picker.sh` | Enter calls `notification-line.sh jump "<line>"`. Ctrl-D calls `notification-line.sh remove "<line>"`. Its parse and lock code moves into the new script. |
| `plugins/clux/config/deploy-manifest.txt` | Adds `notification-line.sh`. |
| `plugins/clux/hooks/notifications/lines.ts` | New. Pure functions, with no `$`: `toRows(text)` and `displayText(line)`. See 4.3. |
| `plugins/clux/hooks/notifications/register.tsx` | New. The pane, the command, the footer label, the poll and the keys. See 4.4. |
| `plugins/clux/hooks/hooks.json` | Adds `./notifications/register.tsx` to `modules`. |
| `plugins/clux/commands/notifications.md` | New. The fallback text for a Claude Code that did not load the module, the same as `commands/sessions.md`. |
| `plugins/clux/types/index.d.ts` | Adds the `NotifRow` type and the `notifications` key to the `clux` plugin state. |
| `plugins/clux/.claude-plugin/plugin.json` | Version 4.5.0 → 4.6.0. |
| `CHANGELOG.md`, `README.md`, `CONTRIBUTING.md` | A `[4.6.0]` entry, a "Notifications pane" section, and the new files in the file tree. |
| `test/notification-line.bats` | New. See 6. |
| `plugins/clux/tests/notifications-lines.test.ts`, `plugins/clux/tests/notifications.test.tsx` | New. See 6. |

### 4.2 `scripts/notification-line.sh`

```
notification-line.sh path
notification-line.sh jump "<line>"
notification-line.sh remove "<line>"
```

- **`path`** prints the queue path from `resolve_notify_file`. The mod calls it one time at the session start, so the path has one source.
- **`jump`** does the routing that `jump-to-notification.sh` does today, for any line and not only the top line:
  1. An `agent:` line: parse the three `@@` segments, call `agent_jump`, then `_agent_remove_entry`. This is the same as today.
  2. A `|||<session_id>:<window_id>` line: `tmux select-window`, then `tmux switch-client`.
  3. A `|ID:` line: the same, with the legacy marker.
  4. Any other line: the name-based parse `<session>:<window> `.

  Exit 0 when tmux switched (or `agent_jump` ran). Exit 1 when the line has no target or tmux failed.
- **`remove`** takes the lock (`mkdir <queue>.lock`, 5 tries at 100 ms, with the same stale-lock cleanup as `dismiss-notification.sh`). It then removes each line that is equal to the argument (`grep -vxF`), and deletes the queue file if it is empty. Exit 0 when the line is gone (also when it was not there). Exit 1 when the lock stays busy.

  Today the picker uses `grep -vF`, which also removes a longer line that contains the selected line. `-x` removes only an equal line. This is the correct behavior, and the current picker tests remove only equal lines.

The script sources `helpers.sh` only on the `agent:` branch, as the picker does today. It keeps the fix that restores `NOTIFY_FILE` after `helpers.sh` is sourced.

### 4.3 `hooks/notifications/lines.ts`

```ts
type NotifRow = { line: string; text: string; kind: 'agent' | 'window' }

displayText(line: string): string   // the part before "|||" or "|ID:"
toRows(text: string): NotifRow[]      // one row for each line that is not empty, in file order
```

`kind` is `agent` when the line has `|||agent:`, otherwise `window`. The pane uses `kind` only to select a mark. The pane does not parse a target. The script does that.

### 4.4 `hooks/notifications/register.tsx`

**Start (`session.start`, interactive only).** Run `notification-line.sh path` one time and keep the path. If the run fails, use `$HOME/.config/tmux/claude_notification`. Do one poll, then poll every 2 seconds with `$.clock.every`. One poll at a time, as in the sessions pane.

**Poll.** Read the queue with `$.fs.read`. A missing file is an empty list. Give the text to `toRows`. Write the rows to the `notifications` atom only when they changed.

**Command (`command.run`, `clux:notifications`).** No argument toggles the pane. `on` opens it and `off` closes it, the same as `/clux:sessions`. To open, do one poll, then `$.ui.open({ id: 'notifications', title: 'Notifications', focus: true })`.

**Pane (`ui.render`, `Pane`, `notifications`).**
- Header: `Notifications · N`, then three plain buttons: `j: down`, `k: up`, `x: remove`. Each one has its `hotkey`.
- One row for each notification: a plain `Button` with key `row:<i>` and the row text as its label. The text is cut at the pane width. The first row has `autoFocus`. Its `onPress` is the jump (see Enter below).
- An empty list shows `No notifications.`

**Focus.** A `ui.focus` hook on this pane records the index from `row:<i>` in a module variable `focused`. Another element (a header button, the close mark) does not change `focused`.

**`j` / `k`.** Compute `focused + 1` or `focused − 1`, limited to the list. Call `$.ui.focus({ requestId: 'notifications', key: 'row:<i>' })`.

**Enter (row press).** Run `notification-line.sh jump "<line>"`. On exit 0: run `notification-line.sh remove "<line>"`, close the pane, and poll again. The remove is necessary because the status bar removes only the top line. For an agent line, the jump already removed the line, so the remove finds nothing and exits 0. On exit 1, or when Claude Code does not run in tmux (no `TMUX`): show the toast `Could not jump to <text>.`, keep the pane open, and keep the row.

**`x`.** Take the row at `focused`. Run `notification-line.sh remove "<line>"`, then poll again. Move the focus to `row:<min(focused, count − 1)>`, so the focus stays at the same position. On exit 1, show the toast `The queue is busy. Try again.` When the list is empty, `x` does nothing.

**Footer (`ui.render`, `SessionMode`).** Draw `next(e)` first, so the sessions label stays, then a plain `Button`: `notifs` (dim) when the count is 0, otherwise `N notifs`. A click opens the pane. It has no `action`, because there is no chord.

**Errors.** Each hook catches its errors and writes them with `$.ui.log(..., { to: 'debug' })`, as the sessions pane does. A failed poll keeps the last list.

## 5. Limits

- The `j`, `k` and `x` keys work only while the pane has the keys: after `/clux:notifications`, a click in the pane, or `ctrl+x tab`. In the prompt box, `j` types the letter "j".
- A jump calls `tmux switch-client` with no `-c`. With two tmux clients on the same session, tmux can move the other client. The live check (6.3) tests the usual case of one client. If this fails, a later change can give the client with `-c`.
- Outside tmux, the pane shows the list and `x` works, but Enter shows the toast.
- A poll every 2 seconds is one file read. The status bar of tmux shows a new notification sooner, because tmux runs `show-notification.sh` on its own interval.

## 6. Tests

### 6.1 bats (`test/notification-line.bats`)

- `path` prints `CLUX_NOTIFY_FILE` when it is set, and the sidecar value when only the sidecar exists.
- `jump` on a `|||$1:@2` line calls `tmux select-window -t $1:@2` and `switch-client -t $1` (tmux stub). Exit 0.
- `jump` on a new-format agent line fast-paths to the embedded pane and removes the line. This is the same case as the regression test in `picker.bats`.
- `jump` on a line with no target exits 1.
- `remove` removes an equal line and keeps a longer line that contains it.
- `remove` deletes the queue file when the last line goes.
- `remove` exits 1 when the lock is held by a new lock directory.
- All tests in `picker.bats` and `jump.bats` still pass, with no change to their assertions.

### 6.2 `claude plugin test plugins/clux`

- `notifications-lines.test.ts`: `displayText` and `toRows` for each line type, an empty file, and a file with a blank line.
- `notifications.test.tsx`, with a mocked `fs.read`, `process.run` and clock:
  - The pane draws one row for each line, and `No notifications.` for no file.
  - Enter runs `jump` then `remove` with the full line, and closes the pane.
  - A failed `jump` shows the toast and runs no `remove`.
  - `x` on the focused row runs `remove` with that line.
  - `j` after the focus is on `row:0` calls `ui.focus` with `row:1`. `k` on `row:0` stays on `row:0`.
  - The footer shows `3 notifs` for three lines, and a dim `notifs` for none.
  - The footer still draws the sessions label (both hooks on `SessionMode`).

### 6.3 Live check

In a real tmux session, with Claude Code 2.1.291 or later and the plugin loaded with `--plugin-dir`:

1. Make two notifications in two other windows (finish a turn in two Claude sessions).
2. Run `/clux:notifications`. Both rows show.
3. Press `j`, then `x`. The second row goes, and the queue file does not have it.
4. Press Enter. tmux shows the window of the first row, the pane closes, and the queue file is empty.
5. In the tmux popup, Enter and Ctrl-D still operate.

## 7. Out of scope

- Notifications from other places (background sessions, GitHub). The pane shows the clux queue only.
- A change to the fzf popup keys.
- A chord to open the pane.
- A sound or a toast when a notification arrives. The tmux status bar and `notify-sound.sh` already do this.
