# clux: agent-state marks for detached `claude agents` sessions

Date: 2026-08-16
Status: approved (brainstormed in session; placement, scope, and roll-up rule
confirmed by the user)
Builds on: `2026-08-10-clux-agent-state-design.md` (the pane-keyed store)

## Problem

The agent-state bar draws one mark per tmux session, from state files keyed by
tmux pane id. A `claude agents` dashboard does its real work in detached
background sessions. Those sessions have no tmux pane, so `hooks/agent-state.sh`
exits at its `TMUX_PANE` guard and the dashboard's session column stays blank
while its agents work.

The notification path already covers these agents (`notify-tmux.sh`'s detached
branch, label `agents / <name>`). Only the state bar cannot represent them.

## Decisions (user-confirmed)

1. **Placement** — the mark lands on the session column of the tmux session
   that holds the `claude agents` dashboard. No new bar segment.
2. **Scope** — detached agents owned by a `claude agents` dashboard only. A
   headless run with no dashboard (cron, bare `claude -p`) has no column to
   draw in and stays out. A `claude -p` child started inside a pane inherits
   `TMUX_PANE` and keeps today's behaviour.
3. **Roll-up rule** — a dashboard column shows `needs-you` if any of its
   agents needs you, else `busy` if any is busy, else `finished` when all are
   finished. This is the max-rank roll-up `agent-query.sh` already computes.

## Design

### Store layout — one file per agent, filed under its dashboard pane

```
$STATE_DIR/
  %26                       # interactive pane file — unchanged
  agents/
    %47~<session_id>        # one file per detached agent; content one word:
    %47~<session_id>        # busy | needs-you | finished
```

The file name carries both keys: the owning dashboard's pane id (before `~`)
and the agent's Claude session id (after). `~` cannot appear in either. The
`agents/` subdirectory is deliberate: an out-of-date deployed script skips it
(`[ -f ]` drops the directory entry in the flat reap loop; the flat reader
looks up exact pane names), so a half-updated `~/.config/clux/scripts/`
install shows the old behaviour instead of breaking.

### Writer — `hooks/agent-state.sh`

The interactive path is unchanged. The two guards become a fork:

- `TMUX` and `TMUX_PANE` both set → key is `$TMUX_PANE` (today's path).
- otherwise → detached path, key from the payload:
  1. Read `session_id` with pure bash parameter expansion (a UUID — hex and
     dashes only, verified). No id → exit 0.
  2. Cache lookup: glob `$STATE_DIR/agents/*~<session_id>`. A hit gives the
     pane back from the file name. No `ps`, no tmux.
  3. On a miss, read `cwd` from the payload (jq, sed fallback — the same
     shape `notify-tmux.sh` uses) and call `resolve_agents_pane_by_cwd`. No
     dashboard found → no column to draw in → exit 0.

`remove`/`end` never resolves: it deletes the cached file if one exists and
exits otherwise. The word table (`busy`/`needs-you` eligibility/`finished`)
is shared with the interactive path and is evaluated before any key work, so
unknown arguments and ineligible notification types cost nothing.

The expensive `ps -A` scan therefore runs once per agent session, not once
per event. tmux calls on the detached path go over the default socket — the
same precedent `notify-tmux.sh`'s detached branch already set.

### Reader — `scripts/agent-query.sh`

The pane loop is unchanged. A second pass walks `$STATE_DIR/agents/*`,
extracts the pane id from each file name (`${base%%~*}`), maps the state word
to the same rank, resolves the pane to its session name from the `PANES`
listing already in hand, and appends `<session>\t<rank>` rows. The existing
max-rank roll-up then computes the confirmed rule with no change. An agent
file whose pane is not in the listing is skipped — the same rule the pane
loop applies. The reader stays read-only and adds no tmux and no `ps` call.

`agent-bar.sh` is untouched.

### Resolver placement

`resolve_agents_pane_by_cwd()` and `_clux_canon_path()` move from
`helpers.sh` to `path.sh`, because sourcing `helpers.sh` costs five
`get_tmux_option` calls at source time and the writer must stay cheap.
`path.sh`'s header gains them as declared impure-when-called functions.
`helpers.sh` sources `path.sh`, so `notify-tmux.sh` and the jump path see no
change.

### Lifecycle

- **Reap** — `reap_agent_state_dir()` gains a second loop over
  `$STATE_DIR/agents/*` with the same live-pane test on the file name's pane
  part. A closed dashboard pane sweeps its agent files. The empty-listing
  wipe guard covers both loops.
- **Cache invalidation is the reap, free** — after a tmux restart the cached
  pane in a file name can be stale. The writer writes to it anyway; the reap
  that already runs after every write deletes it (pane not live), and the
  next event re-resolves. Self-healing in one event, no tmux call added to
  the hot path.
- **Clear-on-view** — `agent-clear.sh <window>` additionally globs
  `$STATE_DIR/agents/<pane>~*` for each pane in the window and deletes the
  files holding `finished`. Looking at the dashboard's window clears its `v`,
  same as for interactive panes.

### Known holes

| case | outcome |
|---|---|
| agent killed with no `SessionEnd` | its file stays (typically `busy`) until the dashboard pane closes. Not covered — no cheap liveness test exists for a detached session. |
| pane id reused after tmux server restart | same residual as the pane-keyed store; for agent files it self-heals on the agent's next event (stale-cache write + reap, then re-resolve). |
| dashboard closed and reopened elsewhere | files reaped with the old pane; the next agent event re-resolves to the new pane. Covered. |

## Testing

`test/agent-state.bats`, existing stub style plus a `ps` stub and a
resolver-format answer in the tmux stub:

- writer detached: resolve-and-write, cache hit skips `ps` (STUB_LOG),
  no dashboard → no file, `remove` deletes cached / no-ops without one,
  no `session_id` → silent exit, stale-cache self-heal via reap.
- reader: the confirmed roll-up rule (`needs-you` > `busy` > all-`finished`),
  mixed interactive + agent files in one listing, orphan agent file skipped.
- reap: dead dashboard pane sweeps its agent files; live ones survive.
- clear: `finished` agent files clear on window view; `busy` survives.

## Rollout

Version 3.2.0 (a new capability — minor bump, per repo precedent; the
in-chat draft said 3.1.2). Files: `path.sh`, `helpers.sh`,
`hooks/agent-state.sh`, `agent-query.sh`, `agent-clear.sh`, this spec,
CHANGELOG. `agent-bar.sh`, `hooks.json`, and the user's tmux.conf: zero
changes. Deploy = the same copy step to `~/.config/clux/scripts/`.
