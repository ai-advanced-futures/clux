# Server-scoped agent state

**Date:** 2026-08-17
**Status:** implemented
**Supersedes the store layout in:** `2026-08-16-clux-detached-agent-state-design.md`

## The defect

A tmux pane id identifies a pane only **inside one server**. Every tmux server
numbers its panes from `%0`. The agent-state store is one directory per `$HOME`,
and until now a state file was named by pane id alone, so two servers shared one
namespace and collided in both directions.

Observed on tmux 3.7b with two servers, each holding one pane, both `%0`:

```
$ tmux -L A list-panes -a -F '#{pane_id}|#{session_name}'   ->  %0|alpha
$ tmux -L B list-panes -a -F '#{pane_id}|#{session_name}'   ->  %0|beta

# a Claude on server A goes busy
$ printf 'busy\n' > $STATE_DIR/%0

A bar : [#[fg=cyan]*#[default]alpha]      correct
B bar : [#[fg=cyan]*#[default]beta]       server B drew server A's agent
```

The second direction destroys data rather than inventing it. The reaper deletes
files whose pane is not live, and it judged every file against **its own**
server's pane listing:

```
A has %0..%5, a Claude waiting for you in %5.  B has only %0.
  store: [%5]     A bar: [#[fg=yellow]!#[default]alpha]

# any hook fires on server B — a prompt typed in the other tmux
  store: []       A bar: []       the waiting agent is now invisible
```

One server restarting had the same shape: the new server hands out `%0` again,
so it inherits the old server's files. The reaper's own header admitted this
("narrows the pane-id-reuse hole … It does not close it").

## The fix

Scope the store by server. Per-file names do not change.

```
$STATE_DIR/                    <- @clux-agent-state-dir, unchanged, now a ROOT
  90593-1786967585/            <- one directory per tmux server
    %0
    %5
    agents/
      %3~<session-id>
  91515-1786967601/            <- another server; collision impossible
    %0
```

`@clux-agent-state-dir` keeps its meaning, so a user who set it keeps the
location they chose. Only the layout inside it changed.

### The server key

`<pid>-<start_time>`, both from tmux's own formats.

The pid alone would repeat: the kernel recycles pids, which is the same class of
aliasing this change exists to remove. The start time makes a repeat impossible
in practice. The key also **changes when a server restarts on the same socket**,
which is what closes the reuse hole the reaper could previously only narrow.

`resolve_agent_server_key()` (`path.sh`) answers it with one `display-message`.
Callers that already run `tmux list-panes` must not call it — they ask for
`#{pid}-#{start_time}` in the format they were already fetching and pay nothing:

| caller | how it gets the key | added tmux calls |
|---|---|---|
| `agent-query.sh` (once per status redraw, per client — the hot path) | folded into its `list-panes -a` format | 0 |
| `agent-clear.sh` (window switch) | folded into its `list-panes -t` format | 0 |
| `reap_agent_state_dir()` | folded into its `list-panes -a` format | 0 |
| `hooks/agent-state.sh` (once per hook fire) | `resolve_agent_server_key()` | 1 |

The writer is the one place that pays, because it has to know the key **before**
it writes. Its reap does fetch a listing further down, so the call looks
hoistable — it is not. Six paths between the two can exit early (a failed
`mkdir`, an absent session id, an unresolved dashboard pane, a failed write), so
hoisting would pay for the listing on runs that never reach the reap, and
`list-panes -a` returns a row per pane across every session where
`display-message -p` returns one short string. The cheap call that always gets
used beats the expensive one that sometimes does. It already makes three tmux
calls between the reap and the refresh.

**No key means no store access, on both sides.** With no tmux server answering,
a state file would land outside any server directory — a file nobody could
attribute later. Writing nothing is right: the next event, from a session that
does have a server, writes it.

For a detached agent the key comes from the default socket, which is the same
server `resolve_agents_pane_by_cwd()` lists panes from, so the pane and the key
can never come from different servers.

### The reaper

Three jobs now.

1. **Dead panes of this server** — the previous logic, rooted one level deeper.
   It no longer reaches outside its own server, so the cross-server deletion
   that hid a waiting agent is structurally impossible rather than merely
   avoided.
2. **Directories of servers that have exited** — `kill -0` on the pid in the
   name. A live foreign server is left completely alone; the collector must not
   become the cross-server deletion it replaces. Should the kernel have handed
   that pid to something else, the start time cannot match, so the worst
   outcome is a directory that is never read again — never a glyph on the wrong
   pane. Only the file shapes the store owns are removed, then the emptied
   directories are dropped; anything unexpected inside is left where it is.
3. **Unscoped files from clux <= 3.3.0** — deleted.

### Why the migration deletes rather than moves

A legacy name records no server. Nothing in it, or beside it, says which server
wrote it. Moving those files into the current server's directory would claim
them for a server that may never have written them — which is exactly the false
glyph this change removes. Deleting is the only honest option, and it costs
nothing real: the next hook fire rewrites the state that is still true.

## Limits

- The key is a pid, so a store shared between machines over a network
  filesystem would alias again. `XDG_STATE_HOME` is per-machine and `path.sh`
  already documented the store as per-machine data; that comment is now
  load-bearing.
- A bar reads exactly one server's state. Another server's agents are that
  server's bar to draw, and its session names are not resolvable from here
  anyway.
- Detached agents are still resolved against the default socket only. A
  `claude agents` dashboard on a non-default socket is not found — unchanged by
  this work, and a separate question from aliasing.

## Tests

`test/agent-state-server-scope.bats` drives **two real tmux servers**. A stub
would only prove that the stub and the scripts agree about pane ids; the bug is
a fact about tmux itself, so the servers have to be real. Every script under
test calls bare `tmux`, so a one-line shim per server, first on `PATH`, is what
points a script at server A or server B.

All eight fail against the pre-change code, four of them by reproducing the
defect directly rather than by missing a path.

`test/agent-state.bats` keeps its stub. The stub prepends the server key to
each listing row rather than making each test carry it, so the fixtures stay
readable and say only what their test is about.
