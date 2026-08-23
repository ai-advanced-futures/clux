# Animated busy glyph and throttled status jobs

**Date:** 2026-08-23
**Status:** approved design, not implemented
**Builds on:** `2026-08-16-clux-session-surface-design.md` (the precomputed bar)

## Goal

A session whose Claude is `busy` shows a glyph that moves, so a user can tell
"working" from "hung" at a glance. The glyph must draw every frame in order,
the bar must not get slower, and clux must not change settings it does not
own.

## What the prototypes showed

Three ways to animate were compared; two were run on the live server.

| approach | result |
|---|---|
| Frame from the wall clock, sampled by the periodic `#()` job | Works, but **skips frames**. tmux re-runs a `#()` job only when its cached result is older than `status-interval`, checked at redraw time, so samples land at e.g. t=1.99 then t=3.01 and the frame for t=2 is never drawn. |
| Ticker daemon + `#{E:@clux_session_bar}` re-expansion in `status-format` | Rejected. `E:` re-expansion corrupted the precomputed bar (duplicated entries), needs an edit to the one line clux promised not to touch, and any config reload undid it. |
| Frame **counter** in a tmux option, advanced once per periodic tick, substituted into a **cached bar template** | Works. No skipped frames. A tick costs 46 ms instead of 110 ms. **Chosen.** |

Two measurements drive the rest of the design:

- On tmux 3.7b, `refresh-client -S` **re-runs every `#()` job on the line**
  (10 forced redraws in 2 s → 10 extra job runs at `status-interval 2`).
  There is no way to repaint one segment faster than the others. Animation
  speed is therefore bounded by `status-interval`, and tmux's minimum is 1 s.
- The bar's cost per tick on the author's machine: clux bar 110 ms,
  `git.sh` 28 ms, node and python checks 16 ms each. The clux bar is the
  heaviest job on its own bar.

## Design

### 1. Frames, not a clock

`session-bar-refresh.sh` keeps a frame index in the runtime option
`@clux_frame_idx`.

- **Periodic path** (`session-bar-refresh.sh quiet`, the `#()` job on the
  status line): advance the index by exactly one, modulo the frame count,
  then render that frame.
- **Hook path** (every other caller: session/window hooks, `agent-state.sh`
  through `@clux-agent-refresh-command`, `session-reorder.sh`, config load):
  render the **current** frame, never advance.

So every frame is drawn, in order, and a burst of hooks cannot fast-forward
the animation. The cadence is whatever tmux delivers: one frame per
`status-interval`, with tmux's own jitter but no skips — **per client**.

tmux runs a `#()` job once per attached client rendering that status line,
not once per server. With two clients attached to the same server, the
periodic literal fires twice per interval; a single shared
`@clux_frame_idx` would then advance twice as fast, and the two
read-modify-write cycles race (both can read N and write N+1). So the
periodic literal in the user's `status-format` passes the rendering client's
id through: `#(session-bar-refresh.sh quiet #{client_pid})`. The script uses
that id, when given, to key the counter as `@clux_frame_idx_<pid>` instead of
the shared name, so each client owns and advances only its own counter, at
its own `status-interval` cadence. The cached template stays a single shared
`@clux_bar_tpl` — only the frame substituted into it is per client. A client
that supplies no id (a manual invocation, a test) falls back to the shared
`@clux_frame_idx` name.

### 2. Cached template

A full render (`session-list.sh`) costs ~110 ms and is only needed when the
bar's *content* changes. Animation only changes one glyph. So:

- `session-list.sh` is the renderer that actually builds `@clux_session_bar`,
  and it deliberately does not source `helpers.sh` — it is the hot path and
  reads every option through one batched `tmux display-message -p` call,
  including `@clux-agent-glyph-busy` (with its own inline default, `*`, when
  the option is unset). So the sentinel cannot be wired through
  `get_agent_glyph_busy()`'s `CLUX_AGENT_GLYPH_BUSY` env override alone —
  that function is called by `agent-bar.sh` only, never by `session-list.sh`.
  `session-list.sh` gains the same override applied to its own field, right
  after the batched read: `glyph_busy="${CLUX_AGENT_GLYPH_BUSY:-${glyph_busy:-*}}"`.
  Its output format is unchanged; the file itself is changed to receive the
  sentinel. `helpers.sh`'s `get_agent_glyph_busy()` gains the same env
  override, purely so `agent-bar.sh` can be driven the same way if it is ever
  asked to render a sentinel — it draws it from the tmux option today and
  keeps doing so unless `CLUX_AGENT_GLYPH_BUSY` is set.
- The renderer draws the busy glyph as a **sentinel** (U+E000, a private-use
  code point that cannot appear in a session name, a window name, or a
  style). The renderer stays a pure function of its inputs; the sentinel is
  passed in through the environment variable `CLUX_AGENT_GLYPH_BUSY`.
- `session-bar-refresh.sh` stores the epoch and that output together in one
  option, `@clux_bar_tpl` (`<epoch>\t<template>`), so a quiet tick can never
  read a template and a timestamp that were written by two different
  renders. It reads that option and the per-client frame counter (§1) in one
  batched `tmux display-message -p` call — the same shape
  `session-list.sh:50` already uses — then writes `@clux_session_bar` with
  the sentinel replaced by the current frame. The replacement is a bash
  string substitution, **not** a tmux format re-expansion — that is what
  broke the rejected approach.
- On the periodic path, staleness is checked first, busy or idle: when
  `@clux_bar_tpl`'s epoch is younger than `FULL_EVERY` (5 s), skip the full
  render; when it is missing or older, do a full render (this is the
  existing "periodic safety net" behaviour, unchanged). Only inside the
  fresh-template branch does the sentinel matter: if the template holds the
  sentinel, substitute the current frame and write `@clux_session_bar`; if it
  holds no sentinel (no session is busy), skip that write too. Either way,
  the periodic path **always** runs `show-notification.sh` and writes
  `@clux_status` — that half of `session-bar-refresh.sh` is not part of the
  throttle at all. `show-notification.sh` is the only path that recomputes
  `@clux_status`; `notify-tmux.sh` raises a badge by appending to the queue
  and calling `tmux refresh-client -S`, which redraws but — per
  `path.sh:353`'s own comment — "is NOT enough when the bar is a precomputed
  tmux option": a redraw re-reads the option without rebuilding it. Skipping
  `show-notification.sh` on the periodic path would mean a plain
  notification badge only ever updates when an unrelated hook happens to
  fire, and its auto-dismiss loop would stop ticking.
- On the hook path it always does a full render. Agent state changes
  (`busy` → `needs-you` → `finished`) arrive through the hook path via
  `agent-state.sh`, so they show at once, as today.
- A fresh, idle tick (the common case) costs: one batched read (`@clux_bar_tpl`
  plus the per-client `@clux_frame_idx_<pid>`, one `tmux display-message`),
  one counter write, and `show-notification.sh`'s own read/write pair — not
  the four-round-trip "counter bump plus two `show-option` calls" a naive
  reading suggests, and not free either. Amortised over `FULL_EVERY`, that is
  four cheap ticks and one full render per 5 s while a session is busy;
  identical to today's cost while nothing is busy, since `FULL_EVERY` staleness
  already forces the same full render the un-animated bar does now.

`FULL_EVERY` keeps the existing "periodic safety net" role of the `#()` job
(sessions created by something that fires no hook) at 5 s instead of every
interval.

### 3. Glyph set

New option `@clux-agent-glyph-busy-frames`, a space-separated list.
Default: `'- \ | /'` (single-quoted — see below). Four frames read as slow
rotation at one frame per second; two frames read as blinking and were
rejected.

- The default stays plain ASCII, one column each, matching the existing
  invariant in `helpers.sh` (the glyph defaults are ASCII "so the width is
  guaranteed in every terminal and every font") and in
  `configuring-tmux/SKILL.md` ("A user who sets a wide glyph owns the
  reflow."). Neither statement needs to change: this spec does not retire
  that invariant, so a user who never sets `@clux-agent-glyph-busy-frames`
  sees no shape change on upgrade. A moon rotation (`◐ ◓ ◑ ◒`) is documented
  as an opt-in example next to the option, not shipped as the default,
  because those glyphs are Unicode "ambiguous width": one cell in every
  common terminal, two cells under a CJK locale.
- The default value must be written **single**-quoted, both in the SKILL doc
  and anywhere clux itself might emit it. Verified on tmux 3.7b: a
  double-quoted config line, `set -g @x "- \ | /"`, loses the backslash —
  tmux's double-quote parser eats it, so the value comes back as `- | /`,
  three frames instead of four. `render-clux-conf.sh` writes every option
  double-quoted (`printf 'set -g "%s" "%s"\n'`); if it ever emits this option
  it must special-case it to single quotes (see the Files table entry
  below). The frame list must also be split with `read -r -a` (or
  `set -f; set -- $frames`) — a bare `read -a` (no `-r`) eats the backslash a
  second time in bash.
- `@clux-agent-glyph-busy` stays, as a one-frame list. If the user sets it
  and leaves `-frames` unset, the frames list is that single glyph and the
  glyph does not move. Existing configs keep their current look.
- Each frame is parsed with `#` doubled (`s/#/##/`) before it is ever
  substituted into the finished bar string. The substitution in §2 happens
  downstream of `session-list.sh`'s own `esc()` (which already doubles `#` in
  session and window names for the same reason, since tmux would otherwise
  interpret a literal `#` in the rendered bar as a format or style), so a
  user-supplied frame containing `#` would otherwise bypass that protection
  and inject a style or swallow the following characters.
- `agent-bar.sh` takes an optional leading `--frame N` pair, shifted off
  before its existing "two modes, chosen by argument count alone" dispatch
  runs — so `agent-bar.sh --frame 2` still selects roll-up mode (zero
  arguments after the shift) and `agent-bar.sh --frame 2 my-session` still
  selects one-column mode for `my-session`. `--frame N` renders frame N from
  `@clux-agent-glyph-busy-frames`. Without `--frame`, `agent-bar.sh` renders
  `@clux-agent-glyph-busy` exactly as it does today, unchanged and static —
  the frames list is a bar-only concept `agent-bar.sh` does not read on its
  own, so the standalone-glyph installs described in the SKILL's §3.7 keep
  their current look with no code path that would freeze them on a single
  animation frame. It never reads the counter, so its tests stay
  deterministic.

### 4. `throttle.sh` — memoize any `#()` job

Because every redraw re-runs every `#()` job, a faster `status-interval`
makes the *user's* jobs pay too. clux gives them the same treatment its own
bar gets:

```
#(~/.config/clux/scripts/throttle.sh 10 ~/.config/tmux/scripts/git.sh "#{pane_current_path}")
```

`throttle.sh <seconds> <command> [args…]`:

- Cache directory `${XDG_CACHE_HOME:-$HOME/.cache}/clux/throttle/`.
- Cache key: `cksum` of the full argv, so a job that takes
  `#{pane_current_path}` as an argument caches per path.
- Cache file holds `<epoch>\n<output>`. No `stat -f` / `stat -c` — the
  timestamp inside the file is portable between macOS and Linux. Getting the
  current epoch is itself a `date +%s` fork on this repo's bash (3.2 on
  macOS has neither `$EPOCHSECONDS` nor `printf '%(%s)T'`) — the same
  pattern `show-notification.sh` already pays for, and part of the ~5 ms
  budget below, not on top of it.
- Younger than N seconds: print the cached output and exit 0 (one bash
  start, ~5 ms). Older or missing: run the command, write the file
  atomically (`mv` of a temp file), print the output. A command that fails
  leaves the previous cache's **output** in place and prints it, so a
  transient failure does not blank the segment — but the cache file's epoch
  is still refreshed (the failed run re-stamps the existing output rather
  than leaving the old epoch behind). Otherwise a command that fails every
  time is never younger than N seconds and re-runs on every redraw — a
  stampede exactly when the command is slow-and-failing, which is what
  throttling exists to stop.
- On a miss, before writing the new cache file, sweep the cache directory
  for entries whose epoch is older than one day and delete them. The cache
  key is the full argv (e.g. one file per distinct `#{pane_current_path}`
  seen), so without a sweep the directory grows one file per distinct
  argument set forever.
- stderr of the command is dropped; tmux would draw it in the bar.

It ships in the deploy manifest like every other script. It is a tool the
user opts into by editing their own status line; setup does not rewrite
their jobs.

### 5. What clux does NOT change

- **`status-interval`.** The CRITICAL RULE in `configuring-tmux/SKILL.md`
  stands: report, never write. Setup's report line becomes: "the busy glyph
  advances one frame per status-interval — set 1 for a 1 fps pulse; with
  throttle.sh around slow jobs, 1 costs about 30 ms per second". The SKILL
  text that calls `1` "a fork per second for no gain" is updated, since
  there is now a gain.
- The user's `status-format` / `status-left` line. Same two tokens as
  before.
- `session-list.sh`'s **output format** and `agent-query.sh`'s contract.
  (`session-list.sh`'s code does change — see §2 and the Files table — to
  receive the sentinel; what it draws for every other column, and the shape
  of what it draws, does not.)

## Files

| file | change |
|---|---|
| `plugins/clux/scripts/session-bar-refresh.sh` | per-client counter, single `<epoch>\t<template>` option, `FULL_EVERY` staleness-first ordering, batched read, sentinel substitution; `@clux_status` write stays unconditional on every path |
| `plugins/clux/scripts/session-list.sh` | receives the sentinel: `glyph_busy="${CLUX_AGENT_GLYPH_BUSY:-${glyph_busy:-*}}"` right after its existing batched read (line 50/80). Output format unchanged |
| `plugins/clux/scripts/helpers.sh` | `get_agent_glyph_busy_frames()`; `CLUX_AGENT_GLYPH_BUSY` env override in `get_agent_glyph_busy()`, for `agent-bar.sh`'s benefit |
| `plugins/clux/scripts/agent-bar.sh` | optional leading `--frame N`, shifted off before the existing argument-count dispatch; no `--frame` renders `@clux-agent-glyph-busy` exactly as today |
| `plugins/clux/scripts/throttle.sh` | new |
| `plugins/clux/scripts/render-clux-conf.sh` | unset the runtime options this feature adds or reuses — `@clux_frame_idx` (and any per-client `@clux_frame_idx_<pid>` left behind by a prior server) and `@clux_bar_tpl` (now the single `<epoch>\t<template>` option, so unsetting it drops both the old template and its timestamp in one call; `@clux_bar_tpl_at` from an earlier design pass no longer exists as a separate option) — above the file's closing seed-render call to `session-bar-refresh.sh`, so the seed render is the first thing to repopulate them. Does not emit `@clux-agent-glyph-busy-frames`: this script only ever emits an option when the caller passed the matching setup flag, and this change adds no new flag, so the option stays undeclared in the generated conf and defaults through `helpers.sh` like every other `@clux-agent-*` option |
| `plugins/clux/skills/configuring-tmux/SKILL.md` | option table row for `@clux-agent-glyph-busy-frames` (default the single-quoted four-character ASCII spinner named in §3), the moon-rotation opt-in example, status-interval report text, throttle.sh section. The existing ASCII-default / "user who sets a wide glyph owns the reflow" language is unchanged, not caveated, since the shipped default stays ASCII |
| `README.md` (repo root), `CHANGELOG.md` | 3.5.0 |
| `plugins/clux/.claude-plugin/plugin.json` | version bump to 3.5.0 (the stamp `render-clux-conf.sh` reads and writes into the generated conf) |
| `plugins/clux/commands/validate.md` | add `@clux-agent-glyph-busy-frames` to the option enumeration around line 554/679 that lists `@clux-agent-glyph-*` defaults |
| `CONTRIBUTING.md` | add `throttle.sh` to the `scripts/` tree block, next to `agent-bar.sh` |
| deploy manifest (`plugins/clux/config/deploy-manifest.txt`) | `throttle.sh` |
| `test/session-bar-refresh.bats` | frame sequence on quiet path; hook path does not advance; template reuse under `FULL_EVERY`; full render after; idle writes nothing; sentinel never reaches `@clux_session_bar`; two counter bumps between renders with two distinct client ids do not collide; `session-bar-refresh.sh quiet` with a fresh template still writes `@clux_status` |
| `test/throttle.bats` | hit, miss, expiry, per-argv key, failed command re-stamps the epoch but keeps the cached output, cache prune on a miss, atomic write |
| `test/agent-bar.bats` | `--frame N`, `--frame` combined with a session-name argument, no `--frame` unchanged |
| `test/helpers.bats` | frames parsing, single-glyph fallback, env override, a frame containing a backslash (`read -r -a` survives it), a frame containing `#` (doubled before substitution) |

## Error handling

- `@clux_frame_idx` (or the per-client `@clux_frame_idx_<pid>`, §1) missing
  or not a number → treated as 0.
- Frame list empty after parsing → one frame, the `@clux-agent-glyph-busy`
  value (default `*`).
- Full render fails → previous `@clux_session_bar` and template stay, as
  today (`session-list.sh` empty is never a real answer).
- The sentinel must never reach the screen. If substitution finds no
  frames, it substitutes the single busy glyph.

## Testing

bats, as for every other script. `test/e2e-agent-lifecycle.bats` is not
touched: it stubs `tmux` on `PATH` to log and exit 0, starts no real server,
and has no busy pane or `@clux_session_bar` assertions to extend. The
three-quiet-ticks assertion — "after three quiet ticks with one busy pane,
`@clux_session_bar` has shown three different frames and no U+E000" — lives
in `test/session-bar-refresh.bats` instead, alongside the rest of that
script's coverage, in the shape of the real-server harness
`test/agent-state-server-scope.bats` already uses.

## Out of scope

- Animation faster than 1 fps. Needs a ticker plus forced redraws; possible
  once the user's jobs are throttled, but a separate decision.
- Animating `needs-you` or `finished`. Those states want to be steady.
- Rewriting the user's existing `#()` jobs to use `throttle.sh`.
