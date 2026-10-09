# clux notifications pane — design

Date: 2026-10-08. Status: approved for implementation (2026-10-08). Target version: 4.6.0, in PR #32 with the sessions pane changes (one PR, one release). The tmux keys and the fzf popup keep their keys and actions. The popup now jumps to an interactive line by id, not by name (see 4.2).

Base design: the background sessions pane (`hooks/sessions/register.tsx`) as PR #32 leaves it: no needs-input sound and no toast, Enter inserts `@name`, no attach, and a `ctrl+x tab` hint when the pane opens without the keys. This pane uses the same pattern.

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
| `$.ui.open({ focus: true })` is a request. Claude Code refuses it while the message box has text: the pane opens without the keys, and a mod cannot take them. `ctrl+x tab` moves the keys into the pane. | `PaneOpenArgs.focus` in the Claude Code types (2.1.294). Seen live in the sessions pane on 2026-10-08. |
| The `ui.focus` event gives `element`, the key of the element that gets the focus. A hook on it can record the focused row. | `UiFocusInput` in the Claude Code types (2.1.294). |
| A pane that opens with `focus: true` gets the keys. Tab and the arrows move the ring, and Enter presses the focused button. | `reference.md` of the plugin-authoring skill (2.1.294). |

## 4. Design

### 4.1 Files

| File | Change |
|---|---|
| `plugins/clux/scripts/notification-line.sh` | New. Three verbs: `path`, `jump`, `remove`. See 4.2. |
| `plugins/clux/scripts/jump-to-notification.sh` | Calls `notification-line.sh jump "<top line>"`. Its parse code moves into the new script. It always exits 0, as before. |
| `plugins/clux/scripts/notification-picker.sh` | Enter calls `notification-line.sh jump "<line>"`. Ctrl-D calls `notification-line.sh remove "<line>"`. Its parse and lock code moves into the new script. It also keeps exiting 0, as `jump-to-notification.sh` does. [inferred] |
| `plugins/clux/config/deploy-manifest.txt` | Adds `notification-line.sh`. |
| `plugins/clux/hooks/notifications/lines.ts` | New. Pure functions, with no `$`: `toRows(text)` and `displayText(line)`. See 4.3. |
| `plugins/clux/hooks/notifications/register.tsx` | New. The pane, the command, the footer label, the poll and the keys. See 4.4. |
| `plugins/clux/hooks/hooks.json` | Sets `modules` to `["./register.tsx"]`. `claude plugin validate` refuses a second `modules` entry, so this is the first fallback of 6.0. |
| `plugins/clux/hooks/register.tsx` | New. Calls the notifications `register`, then the sessions `register`. The notifications hooks are the outermost in the chain, so the notifications label is drawn after the sessions label. |
| `plugins/clux/tests/sessions.test.tsx` | One line only: the "no audio player" assertion also lets through `notification-line.sh path`, which the composed module runs at the session start. The person allowed this change on 2026-10-08. |
| `plugins/clux/commands/notifications.md` | New. The fallback text for a Claude Code that did not load the module, the same as `commands/sessions.md`. The front matter has `description: Show the clux notification queue in a pane` and `argument-hint: "[on|off]"`, with no chord in the description, because this pane has no chord. [inferred] |
| `plugins/clux/types/index.d.ts` | Adds the `NotifRow` type, next to `BgSession`, and the `notifications` key to the `clux` plugin state. |
| `plugins/clux/.claude-plugin/plugin.json` | No change: PR #32 already sets 4.6.0. |
| `CHANGELOG.md`, `README.md`, `CONTRIBUTING.md` | An `Added` part in the existing `[4.6.0]` entry, a `Changed` line for the two behavior changes of 4.2 (the popup jumps by id; the queue path has three tiers), a "Notifications pane" section, and the new files in the file tree. [inferred] |
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
  1. An `agent:` line: parse the three `@@` segments, call `agent_jump`, then `_agent_remove_entry`, then `tmux refresh-client -S 2>/dev/null`, so the status bar redraws at once. Only this branch runs the refresh, as `jump-to-notification.sh:58` and `notification-picker.sh:97` do today. [inferred] This is the same as today.
  2. A `|||<session_id>:<window_id>` line: `tmux select-window`, then `tmux switch-client`. The picker has no such branch today and parses an interactive line by name, so the popup now jumps by id too. A session renamed since the notification arrived now jumps correctly. [inferred]
  3. A `|ID:` line: the same, with the legacy marker.
  4. Any other line: the name-based parse `<session>:<window> `.

  Exit 0 when tmux switched (or `agent_jump` ran). Exit 1 when the line has no target or tmux failed.
- **`remove`** takes the lock (`mkdir <queue>.lock`, 5 tries at 100 ms, with the same stale-lock cleanup as `dismiss-notification.sh`). It then removes each line that is equal to the argument (`grep -vxF`), and deletes the queue file if it is empty. Exit 0 when the line is gone (also when it was not there). Exit 1 when the lock stays busy. A missing or empty queue file is exit 0, and no lock is taken: the `grep` exit code is not the exit code of the script. [inferred]

  Today the picker uses `grep -vF`, which also removes a longer line that contains the selected line. `-x` removes only an equal line. This is the correct behavior, and the current picker tests remove only equal lines.

The script sources `helpers.sh` only on the `agent:` branch, as the picker does today. It keeps the fix that restores `NOTIFY_FILE` after `helpers.sh` is sourced, and then calls `recompute_lock_target`, as both callers do today, so `_agent_remove_entry` locks the resolved queue. [inferred] All three verbs resolve the queue with `resolve_notify_file` from `scripts/path.sh`, one time at the top of the script, and the agent branch restores that value after it sources `helpers.sh`. [inferred] `path.sh` is already in `deploy-manifest.txt`. [inferred] The two old callers used two tiers and no sidecar, so with only the sidecar set they now touch the sidecar file. This is a correction. [inferred] `jump-to-notification.sh` and `notification-picker.sh` also resolve their own read of the queue with `resolve_notify_file`, in place of the two-tier expression at `jump-to-notification.sh:6` and `notification-picker.sh:5`, as `show-notification.sh` does. [inferred]

### 4.3 `hooks/notifications/lines.ts`

```ts
import type { NotifRow } from '../../types'   // { line: string; text: string; kind: 'agent' | 'window' }, declared in types/index.d.ts

displayText(line: string): string   // the part before "|||" or "|ID:"
toRows(text: string): NotifRow[]      // one row for each line that is not empty, in file order
```

`kind` is `agent` when the line has `|||agent:`, otherwise `window`. The pane does not draw `kind`: the text of an agent line already starts with its marker, and the row label is the row text alone. `kind` stays in the type for the tests and for later use. [inferred] The pane does not parse a target. The script does that.

### 4.4 `hooks/notifications/register.tsx`

**Start (`session.start`, interactive only).** Run `notification-line.sh path` one time and keep the path. If the run fails, use `$HOME/.config/tmux/claude_notification`. The mod runs `${$.plugin.root}/scripts/notification-line.sh`, so the pane works from `--plugin-dir` with no `/clux:setup`. [inferred] Do one poll, then poll every 2 seconds with `$.clock.every`. One poll at a time, as in the sessions pane.

**Poll.** Read the queue with `$.fs.read`. A missing file is an empty list. Give the text to `toRows`. Write the rows to the `notifications` atom only when they changed.

**Command (`command.run`, `clux:notifications`).** No argument toggles the pane. `on` opens it and `off` closes it, the same as `/clux:sessions`. To open, do one poll, then `$.ui.open({ id: 'notifications', title: 'Notifications', focus: true })`.

**Pane (`ui.render`, `Pane`, `notifications`).**
- Header: `Notifications · N`, then three plain buttons with the labels `down`, `up` and `remove` and the hotkeys `j`, `k` and `x`. Claude Code draws them as `j: down`, `k: up` and `x: remove`.
- While the pane does not have the keys (`e.props.isFocused` is false) and the list is not empty, a dim line under the header says `ctrl+x tab: move into the list`, the same as the sessions pane.
- One row for each notification: a plain `Button` with key `row:<i>` and the row text as its label. The text is cut at the pane width. The first row has `autoFocus`. Its `onPress` is the jump (see Enter below).
- An empty list shows `No notifications.`

**Focus.** A `ui.focus` hook on this pane records the index from `row:<i>` in a module variable `focused`, and then returns `next(e)`. A `ui.focus` hook that does not call `next` keeps the ring where it was, so Tab, the arrows, `j`, `k` and `x` would move nothing (`index.d.ts:4029-4031`). `focused` starts at 0 and the `openPane` helper sets it to 0 before `$.ui.open`, so the command and the footer click share one reset, so `j`, `k` and `x` act on the first row until a `ui.focus` says otherwise. [inferred] Another element (a header button) does not change `focused`. A `ui.focus` with no `element` (the close mark) also leaves `focused` as it was, so `x` can still act after the ring moved to the close mark. [inferred] A `{ deny }` from `$.ui.focus` is ignored, with no toast, because the pane may not hold the keys. `focused` keeps its value, and `j`, `k` and `x` all follow this rule. [inferred]

**`j` / `k`.** Compute `focused + 1` or `focused − 1`, limited to the list. Call `$.ui.focus({ requestId: 'notifications', key: 'row:<i>' })`.

**Enter (row press).** Run `notification-line.sh jump "<line>"`. On exit 0: run `notification-line.sh remove "<line>"`, close the pane, and poll again. The remove is necessary because the status bar removes only the top line. For an agent line, the jump already removed the line, so the remove finds nothing and exits 0. On exit 1, or when Claude Code does not run in tmux (no `TMUX`): show the toast `Could not jump to <text>.`, keep the pane open, and keep the row.

**`x`.** Take the row at `min(focused, count − 1)` of the list the last poll wrote, the same limit that `j` and `k` use, because a poll can make the list shorter with no key press. Run `notification-line.sh remove "<line>"`, then poll again. Move the focus to `row:<min(focused, count − 1)>`, with `count` as the row count after the poll, so the focus stays at the same position and removing the last row moves it up one. When `count` is 0 after the poll, call no `$.ui.focus`, because the pane then draws `No notifications.` and has no row key. [inferred] On exit 1, show the toast `The queue is busy. Try again.` When the list is empty, `x` does nothing.

**Footer (`ui.render`, `SessionMode`).** Draw `next(e)` first, so the sessions label stays on the left, then a plain `Button`: `notifs` (dim) when the count is 0, otherwise `N notifs`. Draw the ` & ` separator before the button with no condition, because the sessions hook always draws its label, so `next(e)` is never empty. [inferred] A click opens the pane. It has no `action`, because there is no chord.

**Errors.** The `command.run` hook catches its errors and writes them with `$.ui.log(..., { to: 'debug' })`, as `sessions/register.tsx:167` does. The two `ui.render` hooks have no `.catch`, as in `sessions/register.tsx:172` and `:225`: when the footer hook fails, the engine runs `next(e)` and the sessions label stays. A failed poll keeps the last list. When `$.process.run` rejects in the Enter or `x` `onPress` (the script cannot start, or it times out), the pane treats it as exit 1: it shows the same toast, the pane stays open, the row stays, and the reason goes to `$.ui.log(..., { to: 'debug' })`. [inferred]

## 5. Limits

- The `j`, `k` and `x` keys work only while the pane has the keys: after `/clux:notifications` with an empty message box, a click in the pane, or `ctrl+x tab`. In the prompt box, `j` types the letter "j".
- A jump calls `tmux switch-client` with no `-c`. With two tmux clients on the same session, tmux can move the other client. The live check (6.3) tests the usual case of one client. If this fails, a later change can give the client with `-c`.
- A `{ deny }` from `$.ui.focus` is ignored, so `j` can look dead while the ring sits on the close mark. [inferred]
- The row key is the row index. When the status bar removes the top line, the rows move up and the ring stays on the same index, so `x` and Enter act on the row that the list now shows there. The next poll draws the new list. [inferred]
- `x` with no `ui.focus` before it removes the first row, before the person has seen a ring on it. [inferred]
- The pane runs the plugin copy of `notification-line.sh`, and the tmux keys run the copy in `~/.config/clux/scripts/`. After a plugin update, the two can run different versions until `/clux:upgrade`. [inferred]
- Outside tmux, the pane shows the list and `x` works, but Enter shows the toast.
- A poll every 2 seconds is one file read. The status bar of tmux shows a new notification sooner, because tmux runs `show-notification.sh` on its own interval.

## 6. Tests

### 6.0 First task: a key spike

`j` and `k` depend on one thing that a mock test cannot prove: that `$.ui.focus` called from the `onPress` of a hotkey button moves the ring. A mock records the call and moves nothing. So the first task of the plan is a short spike. Load a 3-row dummy pane with `--plugin-dir`, press `j`, `k`, `x` and Enter, and watch the ring.

If `$.ui.focus` gives `{ deny }` after a hotkey press, stop and tell the person before the work continues. The fallback is `autoFocus` and the arrows only, with no `j` and `k`. The spike code is not kept.

The spike also loads both modules from `hooks.json` with `--plugin-dir` and checks two things. First, that both footer labels draw. Second, that the engine raises no repeat error, because both modules register `session.start` with no matcher and `ui.render` on `SessionMode` (`index.d.ts:6723-6725`). If only the first module loads, the fallback is one `register.tsx` that calls both `register` functions. If the engine raises a repeat error, that fallback does not help, because it makes the same registrations. The fallback is then one module with one hook of each kind: one poll start, and one footer that draws the sessions label and the notifications label. That fallback changes the file list of 4.1, the Start and Footer paragraphs of 4.4, the two test files of 6.2, `hooks/sessions/register.tsx` and `tests/sessions.test.tsx`, so stop and tell the person before the work continues. [inferred]

### 6.1 bats (`test/notification-line.bats`)

- `path` prints `CLUX_NOTIFY_FILE` when it is set, and the sidecar value when only the sidecar exists.
- `remove` removes the line from the sidecar queue when only the sidecar is set. The picker lists the sidecar queue and removes from it, with Ctrl-D, in the same way. [inferred]
- `jump` on a `|||$1:@2` line calls `tmux select-window -t $1:@2` and `switch-client -t $1` (tmux stub). Exit 0.
- `jump` on a new-format agent line fast-paths to the embedded pane and removes the line. This is the same case as the regression test in `picker.bats`. The tmux stub accepts `refresh-client`, and the test asserts that it ran. [inferred]
- `jump` on a line with no target exits 1.
- `remove` removes an equal line and keeps a longer line that contains it.
- `remove` deletes the queue file when the last line goes.
- `remove` on a missing queue file exits 0. [inferred]
- `remove` exits 1 when the lock is held by a new lock directory.
- All tests in `jump.bats` still pass, with no change to their assertions. All tests in `picker.bats` still pass, except case 3: its assertion changes from `select-window -t main:editor` to the id form, as a deliberate behavior change. [inferred]

### 6.2 `claude plugin test plugins/clux`

- `notifications-lines.test.ts`: `displayText` and `toRows` for each line type, an empty file, and a file with a blank line.
- `notifications.test.tsx`, with a mocked `fs.read`, `process.run` and clock:
  - The pane draws one row for each line, and `No notifications.` for no file.
  - Enter runs `jump` then `remove` with the full line, and closes the pane.
  - A failed `jump` shows the toast and runs no `remove`.
  - A `process.run` that rejects on Enter or `x` shows the same toast as exit 1, keeps the pane open and the row, and logs the reason to debug. [inferred]
  - `x` on the focused row runs `remove` with that line. `x` with no prior `ui.focus` runs `remove` with the first line. [inferred]
  - `j` after the focus is on `row:0` calls `ui.focus` with `row:1`. `k` on `row:0` stays on `row:0`.
  - The `ui.focus` hook returns `next(e)` with the `element` unchanged, for a row element, a header button and the close mark.
  - `x` after a poll made the list shorter than `focused` removes the last row.
  - The footer shows `3 notifs` for three lines, and a dim `notifs` for none.
  - The footer still draws the sessions label (both hooks on `SessionMode`), with the sessions label on the left, then ` & `, then the notifications label. [inferred]

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
