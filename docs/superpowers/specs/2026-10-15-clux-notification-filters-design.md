# clux notification filters — design

Date: 2026-10-15. Status: design approved in the brainstorm of 2026-10-15; the written spec waits for review. Target version: 5.2.0 (now 5.1.0).

## 1. Goal

This change has three parts:

1. In the tmux popup (prefix + M), ctrl+x deletes the selected notification. The popup stays open.
2. A file in a repo hides some clux notifications. Each rule is a regex on the Claude session name. A `deny` rule hides the notifications of the matching sessions. An `allow` rule lets only the matching sessions notify. The rules apply only to the sessions of that repo.
3. The person edits the file in the notifications pane in Claude Code, in a new Filters view. The tmux status bar shows a mark when the repo of the active pane has filters.

## 2. Decisions

| Decision | Choice | Reason |
|---|---|---|
| Name that a rule matches | The Claude session name, from `resolve_agent_name`. When the session has no custom title, this name is the basename of the cwd. | The user's choice. The sessions pane shows the same name. |
| File place | `<main repo root>/.claude/clux-filters.local`. All the worktrees of the repo use the same file. | The user's choice. The `.local` name is the Claude Code habit for personal files. |
| Allow and deny together | If the file has an `allow` rule, the name must match one. Then, if a `deny` rule matches, the notification is hidden. The order of the lines has no effect. | The user's choice. |
| Status bar mark | A fixed mark when the repo of the active pane has one or more valid rules. There is no count of hidden notifications. | The user's choice. |
| Owner of the file | One shell script, `scripts/notify-filter.sh`. The hook, the status bar and the mod all call it. | Approach A. One parser and one regex type (`grep -E`). A second parser in TypeScript can disagree with the hook (for example on `\d`). The mod already calls `notification-line.sh` in the same way. |
| ctrl+x in the popup | Delete, then start fzf again on the new queue. Ctrl-D does the same. | The user approved the popup staying open. A shell loop works with all fzf versions, and the fzf test stub can drive it. fzf `reload` binds cannot be tested with the stub. |
| Keys to change the view in the pane | `f` goes to Filters, `n` goes to Notifications. | Approved by the user. Tab moves the focus ring, so it is not free. |
| What a hidden notification does | Nothing: no sound, no desktop banner, no queue line and no bell. | "Skip the notification" means all of it. |
| Lines already in the queue | A new rule does not remove them. | The rules apply to new notifications only. This is simpler, and the person can delete old lines with ctrl+x or `x`. |

## 3. Facts

| Fact | Source |
|---|---|
| The popup runs `fzf --expect=ctrl-d` once, then removes or jumps, then exits. | `scripts/notification-picker.sh` lines 34-51. |
| `notification-line.sh remove "<line>"` removes the lines that are exactly equal to the argument, with the queue locks. | `scripts/notification-line.sh` lines 64-80. |
| The hook knows `$TYPE`, `$CWD`, `$SESSION_ID` and `$TRANSCRIPT_PATH` after line 75, before the sound at line 102. The agent path and the interactive path both come after that point. | `hooks/notify-tmux.sh`. |
| `resolve_agent_name <session_id> <cwd> <transcript>` gives the custom title of the session. If there is none, it gives the cwd basename. | `scripts/helpers.sh` line 496. |
| `@clux_status` is written by `session-bar-refresh.sh` from the output of `show-notification.sh`. The status line shows it with `#{@clux_status}`. | `scripts/session-bar-refresh.sh` lines 273-277. |
| The notifications pane is one view with `Button` hotkeys `q`, `j`, `k`, `x`. It polls the queue every 2 s. | `hooks/notifications/register.tsx`. |
| The mod API has a one-line `Input` (`key`, `label`, `placeholder`, `value`, `onInput`, `onSubmit`). While it has the focus, it gets all the printable keys. Esc gives the keys back. | Claude Code module types, `InputProps`. |
| A `.local` file name does not make git ignore a file. | git behavior. |

## 4. Design

### 4.1 The filter file

Path: `$(git -C <cwd> rev-parse --path-format=absolute --git-common-dir)/..` + `/.claude/clux-filters.local`. The common dir is the `.git` folder of the main checkout, so all the worktrees find the same file. `--path-format` needs git 2.31 or later. If `<cwd>` is not in a git repo, there is no filter file, and nothing is hidden.

Format: one rule on each line.

```
# clux notification filters. Regex type: grep -E, case-sensitive.
allow ^feat-
deny  wip
```

- A rule is `allow` or `deny`, one or more spaces, then the regex. The regex is the remaining part of the line, with the spaces at the start and at the end removed.
- Blank lines and lines that start with `#` are ignored.
- A line that is not a rule (an unknown word, or a regex that `grep -E` refuses) is ignored by `check` and by `active`. `list` reports it as `invalid`.

### 4.2 `scripts/notify-filter.sh`

One script with subcommands. `<cwd>` can be any folder in the repo or in one of its worktrees.

| Subcommand | Result |
|---|---|
| `path <cwd>` | Prints the file path. Exit 1 if `<cwd>` is not in a git repo. |
| `check <cwd> <name>` | Exit 0: show the notification. Exit 1: hide it. With no file, or with no valid rule, exit 0. |
| `active <cwd>` | Exit 0 if the file has one or more valid rules, else exit 1. |
| `list <cwd>` | One line for each line of the file that is not blank and not a comment: `<n>\t<kind>\t<regex>`. `<n>` is the line number in the file. `<kind>` is `allow`, `deny` or `invalid`. For `invalid`, the third field is the raw line. |
| `add <cwd> allow\|deny <regex>` | Checks the regex, then adds the rule at the end. If there is no file, it makes the `.claude` folder and the file with the comment header. If git does not ignore the file (`git check-ignore`), it adds the path to `<common dir>/info/exclude`. |
| `set <cwd> <n> allow\|deny <regex>` | Checks the regex, then replaces line `<n>`. |
| `remove <cwd> <n>` | Removes line `<n>`. The file stays, also when it has no rules. |

- **Regex check:** `printf '' | grep -E -- "$regex"`. Exit 2 means a bad regex. On a bad regex, `add` and `set` print the grep error on stderr and exit 2. They do not change the file.
- **Line numbers:** `set` and `remove` take the line number from `list`. If the line is not a rule line, or the file changed so that line `<n>` does not exist, they exit 3 and do not change the file. The mod then reads the list again.
- **Writes:** each write goes to a temporary file in the same folder, then `mv` puts it in place. Two writes at the same time cannot leave a half-written file. The last write wins.
- **Match:** `printf '%s\n' "$name" | grep -Eq -- "$regex"`.

### 4.3 The hook

In `hooks/notify-tmux.sh`, right after `[ -z "$TYPE" ] && exit 0` (line 75), and before the default message and the sound:

1. Find the filter file with `notify-filter.sh path "$CWD"`. If there is no file, continue as today.
2. If there is a file, `NAME=$(resolve_agent_name "$SESSION_ID" "$CWD" "$TRANSCRIPT_PATH")`.
3. If `notify-filter.sh check "$CWD" "$NAME"` exits 1, `exit 0`.

The check applies to all types, on the agent path and on the interactive path. A repo with no filter file pays one `git` call for each hook event. The name lookup runs only when the file exists.

### 4.4 ctrl+x in the popup

In `scripts/notification-picker.sh`:

- The header is `Enter=jump  Ctrl-X=delete  Esc=close`.
- The flag is `--expect=ctrl-x,ctrl-d`.
- The script runs fzf in a loop. On ctrl-x or ctrl-d, it removes the line, then starts fzf again on the new queue. When the queue is empty, the script exits. On Enter, it jumps and exits. On Esc, it exits.
- fzf starts again with the cursor on the first line. This is a known cost of the loop.

### 4.5 The Filters view in the pane

Files: `hooks/notifications/register.tsx`, a new `hooks/notifications/filters.ts` (pure helpers: parse the `list` output, make the row text), and `types/index.d.ts`.

**State.** The `notifications` atom gets a sibling key `filters` with these fields:
- `view: 'notifications' | 'filters'`
- `file: string` (the path, or `''` when the cwd is not in a git repo)
- `rules: FilterRow[]`, where `FilterRow = { n: number, kind: 'allow' | 'deny' | 'invalid', text: string }`
- `editing: null | { mode: 'add' } | { mode: 'set', n: number }`

The session cwd comes from `$.session.cwd()`, as in the sessions pane. The 2 s poll also runs `notify-filter.sh list <session cwd>` while the pane is open on the Filters view. It reads `path` once when the view opens.

**Header.** `Notifications · <N>  |  Filters · <R>`. The active view is bold. `q: hide` stays in both views.

**Keys in the Notifications view:** as today, plus `f: filters`.

**Keys in the Filters view:**

| Key | Action |
|---|---|
| `n` | Go to the Notifications view. |
| `j` / `k` | Move the focus down / up. |
| `a` | Add a rule. An `Input` opens under the list with the value `deny `. On Enter, the text is split into the first word and the rest, and the mod runs `add`. |
| `e`, or Enter on a row | Edit the focused rule. The `Input` opens with the value `<kind> <regex>`. On Enter, the mod runs `set`. |
| `t` | Change the focused rule from allow to deny, or from deny to allow (`set` with the same regex). |
| `x` | Remove the focused rule (`remove`). |
| Esc in the `Input` | Close the `Input` without a change. |

**Rows.** Under the header, the file path is shown in dim text. Then there is one row for each line from `list`: `allow  ^feat-`. An `invalid` row is red, with the raw line. If there are no rules, the view shows `No filters. a: add a rule.` If the session cwd is not in a git repo, the view shows `Not in a git repo.`, and only `n` and `q` work.

**Errors.** If `add` or `set` exits 2, a toast shows the first line of stderr. The `Input` stays open with the text the person typed. If the first word is not `allow` or `deny`, the mod shows the same toast and does not run the script. If the exit code is 3, the mod reads the list again and shows the toast `The file changed. Try again.`

### 4.6 The status bar mark

In `scripts/session-bar-refresh.sh`, beside the write of `@clux_status`:

1. Read `#{pane_current_path}` of the active pane of the client.
2. If `notify-filter.sh active <path>` exits 0, put the mark before the status text: `#[bg=<notify bg>,fg=<notify fg>] <mark> #[default]`. A `#` in the mark is written as `##`.
3. The mark text comes from a new config option, `@clux-filter-mark`. The default is `⊘ filtered`. An empty value turns the mark off.

There is no new status line token, so the mark shows in the current setups with no `/clux:setup` run. The `/clux:setup` skill and the docs list the new option.

### 4.7 Packaging

- Add `scripts/notify-filter.sh` to `config/deploy-manifest.txt`.
- Set the version to 5.2.0 in `plugins/clux/.claude-plugin/plugin.json`. The marketplace entry has no version.
- The README: one section for the filter file, the Filters view keys, the mark and `@clux-filter-mark`.

## 5. Tests

**bats** (`test/`):

- `notify-filter.bats` (new):
  - The parse: comments, blank lines, extra spaces, invalid lines.
  - The order: allow only, deny only, allow then deny, no valid rule.
  - The file is the same from a worktree and from the main checkout.
  - `add`, `set` and `remove` change the correct line. A bad regex gives exit 2 and no change. A stale line number gives exit 3.
  - `add` writes `info/exclude` once and only when git does not ignore the file.
  - A cwd outside git: `check` exits 0, `active` exits 1.
- `notify-tmux.bats`: a hidden notification gives no queue line and no sound call, on both paths. A repo with no file works as today.
- `picker.bats`: ctrl-x removes the line, then starts fzf again. The loop ends on Enter, on Esc and on an empty queue. The fzf stub gets a call counter, so a test can give a different key on each call.
- `session-bar-refresh.bats`: the mark shows with an active file, is absent without one, and is absent when `@clux-filter-mark` is empty.
- `deploy-manifest.bats`: the manifest lists the new script.

**mod** (`plugins/clux/tests/`):

- `notifications-filters.test.ts` (new): the parse of the `list` output, and the split of the `Input` text.
- `notifications.test.tsx`:
  - `f` and `n` change the view.
  - `a` and Enter run `add` with the correct arguments. `e`, `t` and `x` run `set` or `remove` with the focused line number.
  - Exit 2 shows a toast and keeps the `Input`. Exit 3 reads the list again.
  - Outside git, the view shows `Not in a git repo.`

## 6. Out of scope

- A live preview of the session names that a regex matches. Without a second regex engine, the mod would have to run the script once for each name on each keystroke.
- A count of hidden notifications.
- Case-insensitive matching. The person can write `[Ww]ip`.
- Removing queued lines when a rule is added.
