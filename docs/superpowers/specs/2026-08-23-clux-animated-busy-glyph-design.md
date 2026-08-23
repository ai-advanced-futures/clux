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
`status-interval`, with tmux's own jitter but no skips.

### 2. Cached template

A full render (`session-list.sh`) costs ~110 ms and is only needed when the
bar's *content* changes. Animation only changes one glyph. So:

- The renderer draws the busy glyph as a **sentinel** (U+E000, a private-use
  code point that cannot appear in a session name, a window name, or a
  style). The renderer stays a pure function of its inputs; the sentinel is
  passed in through the environment variable `CLUX_AGENT_GLYPH_BUSY`, which
  `get_agent_glyph_busy()` honours over the tmux option.
- `session-bar-refresh.sh` stores that output in `@clux_bar_tpl` and the
  time of the render in `@clux_bar_tpl_at`, then writes `@clux_session_bar`
  with the sentinel replaced by the current frame. The replacement is a bash
  string substitution, **not** a tmux format re-expansion — that is what
  broke the rejected approach.
- On the periodic path, when a template exists and is younger than
  `FULL_EVERY` (5 s), the script substitutes the new frame into the cached
  template and exits. Otherwise it does a full render.
- On the hook path it always does a full render. Agent state changes
  (`busy` → `needs-you` → `finished`) arrive through the hook path via
  `agent-state.sh`, so they show at once, as today.
- When the template holds no sentinel (no session is busy) the periodic
  path writes nothing and exits. An idle bar costs a counter bump and two
  `tmux show-option` calls per tick.

`FULL_EVERY` keeps the existing "periodic safety net" role of the `#()` job
(sessions created by something that fires no hook) at 5 s instead of every
interval.

### 3. Glyph set

New option `@clux-agent-glyph-busy-frames`, a space-separated list.
Default: `◐ ◓ ◑ ◒`. Four frames read as slow rotation at one frame per
second; two frames read as blinking and were rejected.

- `@clux-agent-glyph-busy` stays, as a one-frame list. If the user sets it
  and leaves `-frames` unset, the frames list is that single glyph and the
  glyph does not move. Existing configs keep their current look.
- The moon glyphs are Unicode "ambiguous width": one cell in every common
  terminal, two cells under a CJK locale. The `configuring-tmux` SKILL's
  note on glyph width gains this caveat and the ASCII fallback
  `@clux-agent-glyph-busy-frames "- \ | /"`.
- `agent-bar.sh` (the standalone renderer for custom status lines) takes
  `--frame N` and renders frame N. Without it, frame 0. It never reads the
  counter, so its tests stay deterministic.

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
  timestamp inside the file is portable between macOS and Linux.
- Younger than N seconds: print the cached output and exit 0 (one bash
  start, ~5 ms). Older or missing: run the command, write the file
  atomically (`mv` of a temp file), print the output. A command that fails
  leaves the previous cache in place and prints it, so a transient failure
  does not blank the segment.
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
- `session-list.sh` output format and `agent-query.sh` contract.

## Files

| file | change |
|---|---|
| `plugins/clux/scripts/session-bar-refresh.sh` | counter, template, `FULL_EVERY`, sentinel substitution |
| `plugins/clux/scripts/helpers.sh` | `get_agent_glyph_busy_frames()`; `CLUX_AGENT_GLYPH_BUSY` env override in `get_agent_glyph_busy()` |
| `plugins/clux/scripts/agent-bar.sh` | `--frame N` |
| `plugins/clux/scripts/throttle.sh` | new |
| `plugins/clux/scripts/render-clux-conf.sh` | emit the new option with its default; unset the three runtime options at load |
| `plugins/clux/skills/configuring-tmux/SKILL.md` | option table row, width caveat, status-interval report text, throttle.sh section |
| `plugins/clux/README.md`, `CHANGELOG.md` | 3.5.0 |
| deploy manifest | `throttle.sh` |
| `test/session-bar-refresh.bats` | frame sequence on quiet path; hook path does not advance; template reuse under `FULL_EVERY`; full render after; idle writes nothing; sentinel never reaches `@clux_session_bar` |
| `test/throttle.bats` | hit, miss, expiry, per-argv key, failed command keeps cache, atomic write |
| `test/agent-bar.bats` | `--frame` |
| `test/helpers.bats` | frames parsing, single-glyph fallback, env override |

## Error handling

- `@clux_frame_idx` missing or not a number → treated as 0.
- Frame list empty after parsing → one frame, the `@clux-agent-glyph-busy`
  value (default `*`).
- Full render fails → previous `@clux_session_bar` and template stay, as
  today (`session-list.sh` empty is never a real answer).
- The sentinel must never reach the screen. If substitution finds no
  frames, it substitutes the single busy glyph.

## Testing

bats, as for every other script. The e2e lifecycle test gains one assertion:
after three quiet ticks with one busy pane, `@clux_session_bar` has shown
three different frames and no U+E000.

## Out of scope

- Animation faster than 1 fps. Needs a ticker plus forced redraws; possible
  once the user's jobs are throttled, but a separate decision.
- Animating `needs-you` or `finished`. Those states want to be steady.
- Rewriting the user's existing `#()` jobs to use `throttle.sh`.
