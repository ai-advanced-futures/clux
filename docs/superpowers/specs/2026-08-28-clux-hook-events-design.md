# clux — more Claude Code hook events reach the user (3.8.0)

## Problem

clux registered four Claude Code hooks (`UserPromptSubmit`, `Stop`,
`Notification`, `SessionEnd`) but only one of them ever produced a
notification the user could see:

- `Stop` was dropped twice. In a `claude agents` workspace,
  `notify-tmux.sh`'s detached branch handled only `Notification`, so the
  bar's green `v` appeared with no entry behind it. In a tmux pane the entry
  was written, but `@claude-notify-stop-visual` defaults to `off`.
- `Notification` sub-types the agents dashboard emits — `agent_needs_input`,
  `agent_completed`, `elicitation_dialog`, `elicitation_url_dialog`,
  `quota_auto_resume_*` — were treated as ineligible and dropped by both
  hooks.
- `StopFailure` (the turn ended on an API error) and `TeammateIdle` were not
  registered at all. A rate-limited agent kept its busy glyph forever.
- A Claude restarted in a pane whose last session died without `SessionEnd`
  kept the dead session's glyph until the first prompt.

## Design

### One type per thing the user is asked about

`map_event_to_type <event> [<notification_type>]` (helpers.sh) maps every
hook fire to one clux notification type, and that type names the
`@claude-notify-<type>-visual` / `-sound` options. One option governs both
the pane path and the agents path of `notify-tmux.sh`.

| Type | Event / sub-type | Queue text | State written | Default |
|---|---|---|---|---|
| `notification` | `Notification`: `permission_prompt`, `idle_prompt`, `agent_needs_input`, `elicitation_dialog`, `elicitation_url_dialog`, no type | payload message | needs-you | on / on |
| `stop` | `Stop`; `Notification`: `agent_completed` | Task complete | finished | off / off |
| `failure` | `StopFailure` | Stopped: `<error_type>` | **failed** | on / on |
| `quota` | `Notification`: `quota_auto_resume_stale` / `_disabled` | Paused on usage quota | needs-you | on / on |
| `quota` | `Notification`: `quota_auto_resume_fired` | Resumed after quota | (none) | on / on |
| `teammate` | `TeammateIdle` | Teammate idle: `<name>` | (none) | off / off |
| `prompt` | `UserPromptSubmit` | — | busy | off / off |
| `sessionend` | `SessionEnd` | — | remove | off / off |
| (empty) | `Notification`: `auth_success`, `elicitation_complete`, `elicitation_response`, unknown | nothing — not even the sound | (none) | — |

`SessionStart` (matcher `startup|resume|clear`) runs `agent-state.sh remove`
only. `compact` is excluded: it fires mid-turn and would blank a busy glyph.

### The fourth state

`failed` ranks above `needs-you` in `agent-query.sh`'s roll-up: both want
the user, but a needs-you is met the moment the user goes to the session,
while a failed agent is one the user does not know has stopped. Glyph
`@clux-agent-glyph-fail` (`x`), colour `@clux-agent-fail-color` (`red`).
`agent-clear.sh` clears it on view exactly like `finished` — both are
terminal states, and looking at the pane is the acknowledgement.
`session-list.sh`'s batched read grows to eighteen fields, the two new ones
last so a sixteen-field stub still splits as before.

### Queue markers on the agents path

`⚡` needs you (and teammate), `✓` finished, `✗` failed, `⏳` quota. Failure,
quota and teammate entries append the message after the label — the marker
cannot say which error or which teammate. Needs-you and finished keep the
3.7.0 short form. A newer event replaces an older entry for the same
session (dedup-on-add already did this).

### Setup

`/clux:setup` §3.6 asks one AskUserQuestion per type, in the table's order,
offering a live value back as the first option. Only an answer that differs
from the helpers.sh default is passed to `render-clux-conf.sh --notify-visual
TYPE on|off` / `--notify-sound TYPE on|off`, which refuses a type outside
the closed set or a value other than on/off before writing anything. The
preferences land in `clux.tmux.conf`, the one file clux owns — the previous
text sent them to "the user's clux markers", a second file the one-file rule
forbids. `--notify-bg` / `--notify-fg`, `--agent-fail-color` and
`--agent-glyph-fail` are theming flags like the others.

### Not done, on purpose

- `stop_hook_active` is not consulted. It marks the Stop that follows another
  hook's "continue", which is a real stop; skipping it would hide the finish.
- `PermissionRequest` duplicates `Notification: permission_prompt`.
  `SubagentStop`, `TaskCompleted`, `PostToolUse*`, `PreCompact` and the rest
  fire many times per turn or carry no user action.
- User hooks on `StopFailure` and `TeammateIdle` in `settings.json` are
  reported, never removed — they usually do real work, not a sound.

### Open

Which session — the dashboard or the agent — fires `agent_completed` has not
been observed live. Both paths handle it (the interactive path writes the
dashboard pane's file, the detached path the agent's); the display is the
same either way through the dashboard roll-up.
