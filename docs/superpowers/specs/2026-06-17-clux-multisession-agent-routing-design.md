# clux Multi-Session Agent Routing — Design + Validation Spec

**Date:** 2026-06-17
**Feature:** Multi-session routing for the clux agent-view jump (`prefix+m`)
**Status:** Approved (brainstormed, user-approved, validated by 6 sandboxed prototypes — all confirmed, none refuted)
**Scope:** working tree only (`plugins/clux/scripts/helpers.sh`, `plugins/clux/hooks/notify-tmux.sh`, `plugins/clux/scripts/jump-to-notification.sh`, `test/helpers.bats`). Builds ON the uncommitted v3 base already in the working tree.

---

## 1. Problem

The clux agent-view jump (`prefix+m` → `jump-to-notification.sh` → `agent_jump`) lands the user on *a* `claude agents` dashboard, but it cannot route to **the specific dashboard that owns the waiting agent** when more than one tmux session is running a `claude agents` view.

Current behavior (v3 base, uncommitted):

- The detached agent branch of `notify-tmux.sh` appends a queue line `⚡ agents / <name>|||agent:<sid>`. The id field carries only the Claude **session id** — no tmux coordinates.
- `agent_jump` (no args) finds the *first* agents pane on the whole server: primary signal = a pane whose `pane_start_command` or `pane_title` matches `*claude agents*`; fallback = a window literally named `agents`; else `new-window`.
- With multiple sessions each hosting a `claude agents` dashboard, `head -1` first-wins picks an arbitrary one. The user jumps to the wrong dashboard.

We need the queue entry to carry enough routing information to land on the **owning** dashboard's pane, while remaining backward compatible with legacy entries and keeping the status-bar display text unchanged.

---

## 2. Approved Design

### 2.1 Routing model — tagged session/window

- The agents window has a **constant name** across all sessions, read from tmux option `@clux-agent-window` (default `"agents"`, via `get_agent_window`). **Session names vary**; the window-name tag is the stable anchor.
- The window-name tag is the **PRIMARY** identification signal.
- The `*claude agents*` command/title match is kept **ONLY as a SECONDARY** signal. On Linux it is unreliable: `pane_start_command` is `/bin/bash` (not `claude agents`) and `pane_title` is the claude custom-title, not a fixed string. The tag is what we trust.

### 2.2 Pane selection within a matched window

- A matched agents window may be **split**: a `claude` pane plus a `bash` pane. Target the pane whose `pane_current_command` is `claude`.
- Send the nav key (`@clux-agent-nav-key`, default `Left`) to **that pane id**, not the window.

### 2.3 Entry format (queue line)

```
MARKER SPACE agents / NAME |||agent:SID@@TMUXSID:WID:PID@@CWD
```

- **Display text** is everything BEFORE `|||` (`MARKER agents / NAME`). The status-bar strip `line%%|||*` is therefore **unchanged** — all routing data lives AFTER the triple-pipe.
- After `agent:`, there are exactly **three `@@`-delimited segments**:
  - **seg1 = SID** — the display/Claude session id (what the old end-anchored entry carried; also the remove key).
  - **seg2 = `TMUXSID:WID:PID`** — tmux coordinates of the owning dashboard's claude pane (colon-delimited).
  - **seg3 = CWD** — the agent's working directory; the **self-healing fallback key** for re-resolution.

### 2.4 No-dashboard / no-server case

When no dashboard is open (or no tmux server is reachable) at ping time, embed:

```
|||agent:SID@@@@CWD
```

i.e. **seg2 EMPTY** (`@@@@` = empty middle field). The parser always sees three segments. An empty seg2 means: **skip the fast-path, re-resolve by CWD.**

### 2.5 Write side — `notify-tmux.sh` agent branch

- Runs **DETACHED** with the `TMUX` env var unset (the existing agent path; `_agent_handle_event` runs when `[ -z "$TMUX" ]`).
- Prototype **P1** confirmed a detached shell can still query tmux over the default socket (no `$TMUX` needed).
- At ping time:
  1. Resolve the owning dashboard by **longest-prefix match** of the agent's `.cwd` against each agents-window pane's `pane_current_path`.
  2. Within the winning window, **pick the `claude` pane**.
  3. Embed seg1 (`SID`) / seg2 (`TMUXSID:WID:PID`) / seg3 (`CWD`).
  - If resolution yields nothing (no server / no agents window), embed seg2 empty per §2.4.

### 2.6 Jump side — `agent_jump` in `helpers.sh`

`agent_jump` gains **optional** args carrying the parsed target and cwd. **Called with NO args it MUST keep current v3 behavior** (backward compatible).

Order of attempts:

1. **Fast-path:** if the embedded pane id still exists AND is in an agents-tagged window → `switch-client` + `select-window` + `send-keys <nav-key>` to that pane id.
2. **Re-resolve:** else, if an embedded CWD is present → `resolve_agents_pane_by_cwd "$cwd"` (longest-prefix) and route to the resulting claude pane.
3. **v3 fallback:** else → current v3 behavior (first agents pane via primary tag + secondary signal; else `new-window` `claude agents`).

### 2.7 Shared resolver

The "longest-prefix-cwd + pick-claude-pane" logic is needed by **both** the write side and the jump side. Factor it into **one** helper in `helpers.sh`:

```
resolve_agents_pane_by_cwd <cwd>   # echoes "sid wid pid" (space-separated), or nothing
```

- Enumerate candidate agents panes by **window-name tag** (`get_agent_window`) **plus** the secondary `*claude agents*` command/title signal.
- Among candidates, pick the one whose `pane_current_path` is the **longest prefix** of `<cwd>`.
- Within the winning window, select the pane whose `pane_current_command` is `claude`.
- Both the write side (§2.5) and jump re-resolve (§2.6 step 2) call this single helper.

---

## 3. Validated Entry Format — Worked Example

Inputs at ping time:

- `SID` = `abc-123` (Claude session id)
- Owning dashboard claude pane tmux coords: session `$sess1`, window `@win2`, pane `%pane3` → seg2 = `$sess1:@win2:%pane3`
- Agent cwd = `/home/jazz/dev/proj` → seg3
- Display name (resolved) = `sdlc-84-review` → `NAME`

**Queue line written:**

```
⚡ agents / sdlc-84-review|||agent:abc-123@@$sess1:@win2:%pane3@@/home/jazz/dev/proj
```

- Status-bar display (`line%%|||*`): `⚡ agents / sdlc-84-review` — **unchanged** from v3.
- Remove key (seg1): `abc-123`.

**No-dashboard variant (seg2 empty):**

```
⚡ agents / sdlc-84-review|||agent:abc-123@@@@/home/jazz/dev/proj
```

- seg1=`abc-123`, seg2=`` (empty → skip fast-path, re-resolve by seg3), seg3=`/home/jazz/dev/proj`.

**Legacy variant (still supported):**

```
⚡ agents / sdlc-84-review|||agent:abc-123
```

- No `@@` → seg1=`abc-123`, seg2 absent, seg3 absent → must still clear (§5) and still jump via v3 fallback (§4.2).

---

## 4. Algorithms

### 4.1 Shared resolver — `resolve_agents_pane_by_cwd`

```
resolve_agents_pane_by_cwd(cwd):
    candidates = agents panes, identified by:
        window_name == get_agent_window  (PRIMARY tag)
        OR pane matches *claude agents* in start_command/title (SECONDARY)
      each candidate yields: session_id, window_id, pane_id, pane_current_path, pane_current_command
    best = none; best_len = -1
    for c in candidates:
        if cwd starts with c.pane_current_path AND len(c.pane_current_path) > best_len:
            best = c.window; best_len = len(c.pane_current_path)
    if best is none: return ""           # caller decides (empty seg2 / v3 fallback)
    # within the winning window, prefer the pane whose current command is `claude`
    claude_pane = first pane in best.window with pane_current_command == claude
                  (fallback: best's first pane if none reports claude — see Known Limitation 6)
    echo "best.session_id best.window_id claude_pane.pane_id"
```

Tie-break when two windows share an identical longest-prefix path: `head -1`, **first-wins** (Known Limitation 3).

### 4.2 Write side — `_agent_handle_event` (Notification branch)

After resolving `NAME`/`LABEL`/`MSG` (unchanged), before the append:

```
read sid wid pid from: resolve_agents_pane_by_cwd "$CWD"   # may be empty
if resolver produced coords:
    seg2 = "${sid}:${wid}:${pid}"
else:
    seg2 = ""                                               # empty middle field
entry_id = "agent:${SESSION_ID}@@${seg2}@@${CWD}"
_agent_remove_entry "$SESSION_ID"                           # dedup by seg1 (widened regex, §5)
acquire_lock
printf '%s %s|||%s\n' "$MARKER" "$LABEL" "$entry_id" >> "$NOTIFY_FILE"
release_lock
```

- The detached shell already has `TMUX` unset; the resolver's tmux calls work over the default socket (P1).
- The `terminalSequence` JSON on stdout and the desktop ping are unchanged.

### 4.3 Jump-side parse — `jump-to-notification.sh` (P6 CORRECTION)

The agent branch (`[[ "$FIRST" == *"|||agent:"* ]]`) must parse the **three-segment** id and pass `target` + `cwd` to `agent_jump`.

**CRITICAL — the pane id lives in the SECOND `@@`-segment, NOT the first.**
Naive `rest%%@@*` captures **seg1 (the display SID)**, not the tmux coords. Parse like this:

```
rest = FIRST after the last "|||agent:"          # "SID@@SEG2@@CWD"  (or legacy "SID")
# Split rest on @@ into seg1, seg2, seg3:
seg1 = rest up to first @@        (= SID, the remove key)
after1 = rest after first @@      # "SEG2@@CWD"  (empty for legacy)
seg2 = after1 up to next @@       (= "TMUXSID:WID:PID", or empty)
seg3 = after1 after that @@       (= CWD, or empty)

remove_key = seg1                 # used by _agent_remove_entry (clear-on-jump)

if seg2 is non-empty:
    # seg2 = TMUXSID:WID:PID — split on ':', the LAST colon token is the pane id
    pane_id = seg2 after the last ':'
    sid     = seg2 up to first ':'
    wid     = middle token
    target  = "sid wid pane_id"
else:
    target = ""                   # empty seg2 → skip fast-path

agent_jump "$target" "$seg3"      # pass coords + cwd; both may be empty
_agent_remove_entry "$remove_key"
tmux refresh-client -S
```

Backward compatibility: a legacy line `...|||agent:abc-123` has no `@@`, so seg1=`abc-123`, seg2=``, seg3=``. `agent_jump "" ""` → v3 fallback. `remove_key`=`abc-123` still clears.

### 4.4 Jump-side routing — `agent_jump [target] [cwd]`

```
agent_jump(target="", cwd=""):
    # target = "sid wid pane_id" (fast-path coords) | "" 
    if target non-empty:
        read sid wid pane_id <<< target
        if pane_id still exists AND its window is agents-tagged:
            switch-client -t sid; select-window -t wid; send-keys -t pane_id <nav-key>
            return
    if cwd non-empty:
        coords = resolve_agents_pane_by_cwd cwd
        if coords non-empty:
            read sid wid pane_id <<< coords
            switch-client; select-window; send-keys -t pane_id <nav-key>
            return
    # v3 fallback (UNCHANGED): primary tag/secondary signal → first agents pane;
    # else new-window "claude agents". No-arg callers land here directly.
    <existing v3 agent_jump body>
```

- "pane_id still exists AND in an agents-tagged window": verify with a targeted `tmux list-panes`/`display-message` filtered by the pane id and the window-name tag. If the pane is gone or its window is no longer tagged, drop to re-resolve.
- The nav-key gate is preserved: empty `@clux-agent-nav-key` → no `send-keys` (existing tests 9c/10b).

---

## 5. Remove-regex Widening — `_agent_remove_entry`

The current grep is end-anchored: `|||agent:SID$`. The new format follows `SID` with `@@`, so the end anchor no longer matches new entries. **Widen** to match BOTH:

- Prototype **P4** validated the pattern: `grep -v -E` with
  ```
  [|][|][|]agent:SID([@]{2}|$)
  ```
  This removes both legacy (`...agent:SID` end-of-line) and new (`...agent:SID@@...`) entries for `SID`, and leaves entries for **other** session ids intact (including longer ids like `SID-extra`, because the alternation requires either `@@` or end-of-line immediately after `SID`).
- `SID` must be regex-safe in practice (Claude session ids are `[a-z0-9-]`); no metacharacters expected.
- **Keep** the existing empty-`$1` guard (`[ -z "$1" ] && return 0`) and the **unconditional `mv`** (no `&& mv` — grep -v exits 1 when every line matches; gating would leave stale duplicates; guarded by existing tests 6 / 6b).
- Keep `acquire_lock` / `release_lock` around the filter+mv.

---

## 6. TDD Test Plan (`test/helpers.bats`)

**Methodology:** red → green. Write FAILING bats tests first, then implement. Reuse the existing tmux-stub pattern (a stub script on `PATH` that logs every `tmux …` call to `$STUB_LOG` and emits canned output per subcommand). Run with:

```
npx --yes bats test/helpers.bats
```

All existing tests (Cases 1–10b) MUST continue to pass unchanged — they pin backward compatibility (legacy remove, no-arg `agent_jump`, nav-key gating, pane-detection v3).

### New / updated cases

**Remove-regex widening (`_agent_remove_entry`):**

- **R1 — new-format removal:** queue line `⚡ agents / x|||agent:abc-123@@$s:@w:%p@@/c` + an unrelated line; `_agent_remove_entry abc-123` removes the new-format line, leaves the other.
- **R2 — mixed legacy+new for same SID:** both `...|||agent:abc-123` and `...|||agent:abc-123@@...` present; removing `abc-123` clears BOTH.
- **R3 — no over-match on longer id:** `...|||agent:abc-123@@...` and `...|||agent:abc-123-extra@@...`; removing `abc-123` clears only the first (`@@`/`$` boundary).
- (Existing Cases 3–6b remain as legacy guards.)

**Shared resolver (`resolve_agents_pane_by_cwd`):**

- **RS1 — longest-prefix wins:** stub `list-panes` emits two agents panes with paths `/home/jazz/dev` and `/home/jazz/dev/proj`; resolver with cwd `/home/jazz/dev/proj/sub` echoes the coords of the `/home/jazz/dev/proj` pane.
- **RS2 — pick the claude pane:** winning window has two panes (`claude` + `bash`); resolver returns the `claude` pane's id.
- **RS3 — no candidate:** stub emits no agents panes; resolver echoes empty (caller will use empty seg2 / v3 fallback).
- **RS4 — tag is primary:** candidate identified by window-name tag even though `pane_start_command` is `/bin/bash` (Linux reality); resolver still returns it.

**Jump-side parse (P6 correction) — exercised via `agent_jump` + stub log:**

- **J1 — pane id from seg2, not seg1:** drive the parse with `agent:abc-123@@$s:@w:%pane3@@/c`; assert the value sent to `send-keys -t` is `%pane3` (seg2's last colon token), **never** `abc-123`. This is the falsifiable P6 guard — it FAILS against a naive `rest%%@@*` parse.
- **J2 — fast-path hit:** embedded pane exists and is agents-tagged → `switch-client` + `select-window` + `send-keys` to the embedded pane id; no `new-window`.
- **J3 — fast-path miss → re-resolve:** embedded pane absent; seg3 cwd present → `resolve_agents_pane_by_cwd` is consulted and routes to the resolved pane.
- **J4 — empty seg2 → re-resolve:** `agent:abc-123@@@@/c` parses seg2 empty, seg3=`/c`; skips fast-path, calls resolver.
- **J5 — legacy entry → v3 fallback:** `agent:abc-123` (no `@@`) → `agent_jump "" ""` → v3 path (`new-window` when no dashboard); `remove_key`=`abc-123` clears.
- **J6 — backward-compat no-arg:** `agent_jump` with NO args still hits v3 exactly as Cases 9/9d/10 assert (re-run / keep those).

**Write side (`_agent_handle_event`, detached):** if directly testable under the stub harness, assert the appended line matches the three-segment shape and that empty-resolver input yields the `@@@@` (empty seg2) form. Otherwise cover the write-side shape via the resolver + parse tests above and a focused string-assembly test.

---

## 7. Known Limitations

Documented for transparency; **inconclusive from prototyping, NOT blocking**.

1. **Background-agent cwd is inferential.** No `isSidechain` transcripts exist on the host to confirm directly, but the same `.cwd` hook field feeds both interactive and background agent sessions, so the resolver keys off a field known to be populated for both.
2. **Sibling git-worktrees OUTSIDE the project dir** would break longest-prefix matching. The CWD fallback mitigates, and no such worktrees exist on the host — but a worktree whose path is not a descendant of any dashboard pane's `pane_current_path` would fail to match.
3. **Tie-break for identical paths is undefined.** When two agents-windows share an identical `pane_current_path`, selection is `head -1` (first-wins). No deterministic ordering guarantee.
4. **macOS cross-platform tag consistency untested.** The window-name tag approach is validated on Linux; macOS tag behavior (and whether the secondary `*claude agents*` signal fires differently there) was not re-probed in this round.
5. **Concurrent detached writers** rely on the existing `flock`/`mkdir` lock (`acquire_lock`/`release_lock`). No new locking is introduced; correctness under heavy concurrent pings is bounded by that existing mechanism.
6. **Cold-start timing is unprobed.** A freshly spawned `claude agents` window may not yet report `pane_current_command == claude` at the moment of resolution. The resolver falls back to the window's first pane in that case, but the exact timing window was not measured.

---

## 8. Constraints (carried into implementation)

- **TDD red→green:** failing bats first, then implement. Reuse the tmux-stub-logs-to-file pattern.
- **Backward compatibility:** legacy queue entries (no `@@`) must still clear (widened regex) and still jump (no embedded cwd → v3 fallback). Display strip `line%%|||*` must still show only the human text.
- **No git worktree** (would lose the uncommitted v3 base). Edit the working tree directly.
- **Do NOT modify deployed copies** (`~/.config/clux`, `~/.claude/plugins/cache`); do NOT commit or push.
- **Match existing shell style:** bash, shellcheck-clean, same comment density and helper conventions.
- **One shared resolver** called from both write and jump sides — no duplicated longest-prefix logic.
