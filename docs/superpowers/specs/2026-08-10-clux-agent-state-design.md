# Agent state on the tmux status bar

Date: 2026-08-10
Status: design agreed, not yet implemented

Show which Claude Code agents are busy, which need the user, and which have
finished, on the tmux status bar.

clux today answers one question: *something needs you, somewhere*. The queue
names the window, but it cannot say that an agent is working, and it cannot say
that one finished. This design adds live per-agent state, without touching the
queue.

---

## The governing principle

**State lives in files. Hooks write those files. The bar only reads.**

The renderer is a pure function of the state on disk. Running it a thousand
times changes nothing.

Every rule below follows from this. Two earlier proposals were dropped because
they broke it:

- tmux pane options as the store. They are tmux state, not files, and the bar
  would read from the same system it draws into.
- the renderer clearing a mark when the user looks at a session. That is the
  renderer writing.

---

## What the user sees

```
    alpha   * beta   ! gamma   v delta     epsilon
  ^         ^        ^         ^         ^
  blank     busy     needs     finished  blank
                     you
```

One column is always reserved before each session name, blank when idle. The
width never changes, so the bar never reflows and names never jump sideways when
an agent starts or stops.

| State | Meaning |
|---|---|
| idle | nothing running |
| busy | the agent is working |
| needs-you | the agent is blocked on the user |
| finished | it completed a turn since the user last looked |

---

## Findings that drive the design

1. **A window name is not a reliable key.** On one machine surveyed, eight panes
   ran `claude` but only six sat in a window named `claude`. The other two used
   project names.

2. **The convention cannot be fixed by discipline.** A common tmux binding
   creates a worktree window named after the worktree. Such a binding can never
   produce a window named `claude`, so a name-based key fails exactly when the
   user fans agents out.

3. **clux already learned this.** Commit `1a40bff`, "detect agents dashboards by
   process, not window name (3.0.7)", made the same move for the agents
   dashboard.

4. **Hooks know their own pane.** A live `claude` process carries `TMUX_PANE`
   and `TMUX` in its environment. Hook subprocesses inherit the environment, so
   every hook knows its exact pane with no convention at all.

   The official documentation does not state this. It was confirmed by reading
   `/proc/<pid>/environ` of a running `claude` process.

5. **`Stop` does not fire on interrupt.** The documentation is explicit: "Stop
   hooks ... do not fire on user interrupts. API errors trigger StopFailure
   instead." This is the one real hole in the state machine.

6. **The transcript file must not be parsed.** The documentation says direct
   parsing of the JSONL under `~/.claude/projects/` "may lead to breakage with
   future Claude Code versions". This rules out the obvious file-based route.

7. **A forced redraw re-runs every shell job in the status format.** Measured on
   a throwaway socket: 30 `refresh-client -S` calls produced 29 job runs, while
   30 `set -g` calls produced 1.

8. **`status-interval` takes whole seconds only.** `set -g status-interval 0.2`
   fails with "value is invalid: 0.2".

9. **clux already registers the four events needed.** `hooks/hooks.json`
   registers `UserPromptSubmit`, `Notification`, `Stop` and `SessionEnd`.

Findings 7 and 8 together rule out animation. See "Rejected" below.

---

## Architecture

Three parts, one direction of flow.

```
Claude Code hook          tmux hook               the bar
      |                       |                      |
      v                       v                      |
  write file             clear file                  |
      |                       |                      |
      +------> state directory <---------------------+  read only
```

### The state store

One file per pane. The file name is the tmux pane ID. The content is one word.

```
$XDG_STATE_HOME/clux/agents/%147   ->  busy
$XDG_STATE_HOME/clux/agents/%203   ->  needs-you
```

**Why one file per pane and not one shared file: no locking is needed.** Each
pane owns its own file, and a write is a temp file followed by a rename, which
is atomic. clux's existing notification queue is a shared file and needs a lock;
this needs none.

The directory must be configurable, following the pattern already used for the
notification file.

### The state machine

| Event | Written by | New state |
|---|---|---|
| `UserPromptSubmit` | Claude hook | busy |
| `Notification` | Claude hook | needs-you |
| `Stop` | Claude hook | finished |
| `SessionEnd` | Claude hook | file removed |
| `after-select-window`, `client-session-changed` | tmux hook | finished removed for that window |

Every transition is a real event. Nothing decays. Nothing polls. There is no
timer anywhere in this design.

### Why `Stop` means finished, though it fires every turn

`Stop` fires at the end of every assistant turn, not at the end of a task. That
is why its visual default is `off` for the queue: it would flood a list, which
accumulates entries.

A per-session state does not accumulate. It is one flag, overwritten in place,
cleared when the user looks. Two hours away with four agents doing six turns
each gives four marked sessions, not twenty-four queue entries.

Same event, opposite verdict, because the container changed from a list to a
flag.

---

## Keeping the dependency on Claude Code small

Each event registers with its own argument, so the hook script parses no JSON.

```json
"UserPromptSubmit": [{ "matcher": "", "hooks": [
  { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/agent-state.sh busy" }
]}],
"Stop": [{ "matcher": "", "hooks": [
  { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/agent-state.sh finished" }
]}]
```

The whole dependency is four event **names**. No payload fields, no schema, no
`jq`. If Claude Code adds, renames or reorders payload fields, nothing here
breaks.

This matters because `notify-tmux.sh` reads six payload fields and carries a
`grep` fallback for when `jq` fails. The new hook needs neither.

**One exception.** `Notification` also fires for `auth_success`, which does not
mean the agent needs the user. That handler reads standard input and greps for
`permission_prompt` or `idle_prompt`. That is one field, matched by one `grep`,
and it is the only payload dependency in the design.

This runs as a second hook beside the existing `notify-tmux.sh`. Hooks for one
event run in parallel, so the two never interfere.

---

## The read path

One tmux query and one directory scan.

```sh
tmux list-panes -a -F '#{pane_id}|#{session_name}'
```

Join that against the state directory, then **drop** any entry where:

- the pane no longer exists.

`#{pane_current_command}` is intentionally not queried — the Claude binary's
own name is a version string on many installs. The state file is the
authoritative signal.

Then roll up per session, with this precedence:

```
needs-you  >  busy  >  finished  >  idle
```

Needs-you wins because it is the only state that asks something of the user.

### Stale files, and why the reader never cleans them

Files outlive their panes. A killed pane, a crash or a tmux server restart can
leave a file behind. The reader **ignores** such a file. It never trusts it, and
it never deletes it, because the reader does not write.

Reaping is a writer's job, done opportunistically by the next hook run.

### The interrupt hole

If the user presses Escape while the model is generating, no event fires and the
mark stays on busy.

| Case | Covered by |
|---|---|
| Escape while a tool runs | `PostToolUseFailure` carries `is_interrupt` |
| API error mid-turn | `StopFailure` fires instead of `Stop` |
| Claude exits, pane lives | `SessionEnd` fires `agent-state.sh remove`, which deletes the file |
| Pane killed | reader drops it, the pane is gone |
| Escape during output, then the user walks away | **not covered** |
| Claude killed hard enough that `SessionEnd` never fires, pane lives | **not covered** — the mark survives until the pane closes and the next reap runs |

The last row is the honest residual. It self-heals on the next prompt, and it is
the one case where the user is at the machine and caused it themselves.

---

## What ships

| File | Purpose |
|---|---|
| `hooks/agent-state.sh` | write one state file, reap stale ones |
| `hooks/hooks.json` | four extra entries, beside the existing ones |
| `scripts/agent-query.sh` | the query. Reads state, prints `session<TAB>state` |
| `scripts/agent-bar.sh` | a default bar segment for a plain status line |
| `scripts/agent-clear.sh` | remove finished marks for a window, called by a tmux hook |
| `scripts/configure-tmux.sh` | register the three new scripts in `deploy_scripts()` |
| `commands/setup.md` | list the new events and the new script count |
| `commands/validate.md` | same, or `/clux:validate` reports clux's own hooks as wrong |
| `test/agent-state.bats` | tests |
| `plugin.json`, `CHANGELOG.md` | minor version bump. New options mean minor |

### Two surfaces, not one

`agent-bar.sh` renders a status segment for users with a plain status line.

`agent-query.sh` prints the rolled-up state as plain text, one session per line.

The query is what makes this usable by a customised status line. A bar that does
its own session ordering, or expands only the attached session, cannot use a
shipped renderer — it needs the data. Shipping only a renderer would force such
users to reimplement the read path, including the stale-file rule, which is the
part most likely to be got wrong.

### Decoupling from the consuming bar

clux must not call a user's scripts by name. After writing state, the hook runs
the command named in `@clux-agent-refresh-command`, and falls back to
`refresh-client -S` when that option is not set.

A user with a precomputed bar points that option at their own refresh script. A
user with a plain bar sets nothing and gets the fallback.

---

## Cost

| Measure | Value |
|---|---|
| processes at rest | none |
| shell jobs per second at rest | zero |
| work per state change | two tmux calls, about 8 ms |
| background daemons | none |
| polling | none |

---

## Rejected, and why

**Animation.** A spinner needs a forced redraw per frame, and a forced redraw
re-runs every shell job in the status format. A status line with five such jobs
would spawn about 25 shells a second at five frames a second. Driving it from
`status-interval` instead caps at one frame a second and doubles the standing
shell load whether or not any agent is working.

Animation becomes affordable only after those jobs are converted to precomputed
options. That is a status line refactor and a separate piece of work.

**Extending the notification queue instead.** Four properties of the queue make
it the wrong store for live state:

| Property | Why it blocks this |
|---|---|
| A duplicate entry for one window is silently dropped | A busy mark would suppress a later needs-you mark |
| Nothing removes an entry on `Stop` | There is no working to finished transition |
| One colour serves the whole segment | States could not be coloured apart |
| Five separate parsers read the queue grammar | A new line shape threads through all of them |

A separate per-pane store has none of these. The queue keeps working exactly as
it does now. Nothing in this design reads it, writes it, or changes its format.

**Parsing the transcript JSONL.** The documentation warns against it. Finding 6.

**A window named `claude` as the key.** Findings 1, 2 and 3.

**Screen scraping.** Ruled out at the start. The whole value of hook-driven state
is that it is reported by the agent rather than guessed from a screen.

**Timers of any kind.** No state in this design decays.

---

## Repository constraints

**The build loop is short.** clux scripts run from the deployed copies under
`~/.config/clux/scripts/`, not from the plugin cache. `/clux:setup` redeploys
them, so a change can be edited and tested at once. No release is needed to try
something. The version bump and the pull request come at the end.

**bats must be installed.** The suite is `bats-core` and there is no CI
workflow, so tests run locally or not at all.

**Two house rules are enforced by tooling.**

1. A new script must be listed in `deploy_scripts()` in `configure-tmux.sh`.
   `configure-deploy.bats` fails if it is not.
2. A new hook event must be added to `commands/setup.md` and
   `commands/validate.md`, or `/clux:validate` reports clux's own hook set as
   wrong. The 3.0.4 `SessionEnd` addition is the precedent.

**Follow the `@clux-*` option prefix.** The repository carries two families, the
older `@claude-notify-*` and the newer `@clux-*`. New options join `@clux-*`.
There is precedent for a configurable glyph: `@clux-agent-marker` defaults to
`⚡`.

**Test pattern.** Feed hook JSON on standard input, set or unset `TMUX` to pick
the branch, then assert on the state directory and the stub log. Stubs for `ps`
and `tmux` already exist, so the read path can be tested without a tmux server.
This is easier to test than the queue, because a state file holds one word and
needs no parsing.

---

## Still to decide

1. **Should needs-you fall back to busy after the user approves a permission?**
   Today it would stay on needs-you until the turn ends. Fixing it means hooking
   `PreToolUse`, which fires on every tool call. Measure the cost first.

2. **The exact glyphs.** Defaults must be one column wide. Nerd font icons need
   a width check first, because a two-column glyph breaks the reserved slot and
   reflows the bar.

3. **The state directory path**, and the option that configures it.

4. **The needs-you colour.** Reusing the queue's amber ties this feature to it.
   Note that the queue's colours are read from the environment variables
   `CLUX_NOTIFY_BG` and `CLUX_NOTIFY_FG`, set only by `claude-notify.tmux`.
   Where that file is not loaded, `@claude-notify-bg` has no effect and the
   colours fall back to hardcoded defaults. Any shared colour would inherit that
   behaviour.

---

## Out of scope

- Agents other than Claude Code. The file format is deliberately
  agent-agnostic — one file, one word — so another agent could write it later
  knowing nothing about tmux. This work covers Claude Code only.
- Any change to the notification queue.
- The status line refactor that animation would require.

---

## Depends on

`docs/superpowers/specs/2026-08-10-clux-config-updater-skill-design.md`.

This feature adds two tmux hooks to the user's configuration. The current setup
script cannot add them safely — it edits `tmux.conf` by pattern matching, it
understands only `status-left`, and its verification step never runs. The
config-updater skill must land first.

That design also moves clux's status segment from a shell call to the option
`#{@clux_status}`. This design should render through the same option rather than
adding a second segment, so the user's status line is edited once and never
again.

## Related

- `docs/superpowers/specs/2026-05-26-clux-agent-view-design.md`
- `docs/superpowers/specs/2026-06-17-clux-multisession-agent-routing-design.md`
