# clux × Claude Code agent view — design spec

**Date:** 2026-05-26
**Status:** Draft (pending prototype gate)
**Branch:** feat/word-aware-title-truncation (design only; implementation on its own branch)

## Problem

clux delivers tmux notifications when a Claude Code session finishes or needs input. It works for **interactive** sessions because its hook (`notify-tmux.sh`) runs inside a process that has `$TMUX`/`$TMUX_PANE`, lets it map the event to a tmux pane, write a queue entry, and ring the bell.

Claude Code's **agent view** (`claude agents`, research preview, v2.1.139+, observed v2.1.150) breaks that assumption. Each row is a **background session** hosted by a per-user supervisor process, **detached from any terminal**. When such a session needs attention, its hook still fires — but in a process with **no `$TMUX`**, so clux's current script bails at `[ -n "$TMUX" ] || exit 0` (`notify-tmux.sh:41`) and nothing is shown. There is also no tmux window to "arrive at," so auto-dismiss-on-arrival never triggers.

Root cause is the **delivery/navigation mechanism**, not the hook choice — `Notification` is the correct event for "needs attention." Official docs confirm "Hooks run without a controlling terminal, so writing escape sequences directly to `/dev/tty` fails," which is exactly why the new `terminalSequence` hook-output field exists.

## Goal

Surface agent-view background sessions that need attention in clux's existing notification stream — visual (status bar) + sound + an instant desktop ping — and let the user jump to their running `claude agents` dashboard, while clearing each notification precisely when its session is attended to.

Non-goal (v1): replacing or duplicating agent view's own UI; tracking working/completed states; pinpointing a specific row inside the dashboard.

## Verified facts (sources)

- Agent view: `claude agents`, research preview, requires v2.1.139+. Background sessions run under a per-user supervisor, "a full Claude Code conversation with its skills, hooks, MCPs, permissions," detached from the terminal. — https://code.claude.com/docs/en/agent-view
- Dashboard sets its terminal title to e.g. `2 awaiting input · claude agents` (user-confirmed real value: `2 awaiting input · claude agents │ 2.1.150`). — agent-view docs + user observation
- `Notification` hook matches notification types `permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`, `elicitation_complete`, `elicitation_response`. — https://code.claude.com/docs/en/hooks
- `terminalSequence` hook-output field (v2.1.141+): "return the escape sequence … and Claude Code emits it for you through its own terminal write path. This is race-free, works inside tmux and GNU screen, and works on Windows." Allowed: OSC `0/1/2` (titles), OSC `9` (iTerm2/ConEmu/Windows Terminal/WezTerm), OSC `99` (Kitty), OSC `777` (urxvt/Ghostty/Warp), bare BEL. — hooks docs
- `session_id` is a common input field on all hook events (enables clear-by-id). — hooks docs
- Dashboard filter `s:blocked` shows "everything waiting on you" (noted; not used in v1). — agent-view docs

## Design

### Principle: one hook, two branches, one shared queue

The existing `notify-tmux.sh` continues to handle every event, branching on `$TMUX`:

```
Claude hook fires (Notification / Stop / UserPromptSubmit / SessionEnd)
        │
        ├─ $TMUX set  → INTERACTIVE PATH  (unchanged)
        │                 queue line:  SESSION:WINDOW msg|||session_id:window_id
        │
        └─ $TMUX unset → AGENT PATH  (new)
                          on Notification(permission_prompt|idle_prompt):
                              emit terminalSequence (one desktop-notif OSC + BEL)
                              append queue line:  ⚡ <label> <msg>|||agent:<claude_session_id>
                          on UserPromptSubmit | Stop | SessionEnd:
                              remove queue line matching |||agent:<claude_session_id>
```

Both paths append to the **same** queue file (`~/.config/tmux/claude_notification`) — a plain file write, valid without tmux. The status bar (which has tmux context) renders the mixed queue.

### 1. Trigger

- **Event:** `Notification`, types `permission_prompt` and `idle_prompt` only. Other types ignored in v1.
- **Instant ping:** the hook prints JSON `{ "terminalSequence": "<seq>" }` where `<seq>` is **one** desktop-notification OSC sequence carrying the message, plus a bare BEL. Default OSC code is `9` (broadest coverage: iTerm2/WezTerm/Windows Terminal/ConEmu), overridable via `@clux-agent-osc` for Kitty (`99`) or Ghostty/Warp/urxvt (`777`). Emitting a single code avoids double notifications on terminals that support several. The desktop OSC is gated by `@clux-agent-desktop`; the BEL by `@clux-agent-sound`.
- **Queue entry:** append `⚡ <label> <msg>|||agent:<claude_session_id>` with **dedup** on `agent:<session_id>` (same intent as today's per-context dedup) so one session can't stack duplicates.
- **`<label>` (v1):** the hook payload `message`, or the literal `needs input` when `message` is empty. Enriching the label with the session name via a one-shot `claude agents --json` lookup is a documented future enhancement, not v1.

### 2. Show

- `show-notification.sh` is effectively unchanged: it already renders `${line%%|||*}`, so `⚡ <label> <msg>` displays directly, and the `[1/N]` counter already spans the mixed queue.
- The auto-dismiss-on-arrival block only matches tmux `session_id:window_id`; `agent:` entries never match a focused window, so they persist until cleared by hook or manual dismiss. **No code change required there** beyond confirming `agent:` lines fall through the existing branches harmlessly.

### 3. Navigate

`jump-to-notification.sh` gains a branch when the top entry's id field begins with `agent:`:

```
win = tmux list-panes -a -F '#{window_id}\t#{pane_title}'
        | grep -F 'claude agents' | head -1 | cut field window_id
if win:  tmux select-window -t "$win"  && tmux switch-client to its session
else:    tmux new-window -n agents "claude agents"   # fallback: no dashboard open
```

No bulk clearing on jump (superseded by precise per-session clearing). Interactive entries keep their existing jump behavior.

### 4. Dismiss (precise, per session)

- **Add** on `Notification(permission_prompt|idle_prompt)` — agent path.
- **Remove** the entry whose id is `agent:<session_id>` on that session's `UserPromptSubmit`, `Stop`, or `SessionEnd` — agent path. In the agent path, `Stop` therefore **clears** rather than adding a "completed" entry (consistent with needs-input-only v1).
- **Manual fallback:** existing dismiss key and fzf picker `Ctrl-D` continue to remove any line, including `agent:` ones (needed for sessions that die without a clean hook).
- Removal matches the full `|||agent:<session_id>` token to avoid clearing the wrong line.

### 5. Config (new tmux options, optional, mirroring helpers.sh patterns)

| Option | Default | Meaning |
|---|---|---|
| `@clux-agent-visual` | `on` | show ⚡ entries in the status bar |
| `@clux-agent-sound` | `on` | emit BEL via terminalSequence |
| `@clux-agent-desktop` | `on` | include a desktop-notification OSC in terminalSequence |
| `@clux-agent-osc` | `9` | OSC code for the desktop notification (`9`, `99`, or `777`) |
| `@clux-agent-marker` | `⚡` | glyph prefixing agent entries |

Sound file selection reuses the existing per-type config in `helpers.sh`.

### Components touched

- `hooks/notify-tmux.sh` — add the `$TMUX`-unset agent branch (add on Notification; remove on UserPromptSubmit/Stop/SessionEnd; emit terminalSequence). Register `SessionEnd` in `hooks/hooks.json` if not present.
- `hooks/hooks.json` — ensure `SessionEnd` is wired (Notification/Stop/UserPromptSubmit already are).
- `scripts/jump-to-notification.sh` — add the `agent:` branch (dashboard window detection + fallback).
- `scripts/helpers.sh` — add `@clux-agent-*` option getters and an agent-entry dedup/remove helper keyed by `session_id`.
- `scripts/show-notification.sh` — confirm `agent:` lines render and fall through dismiss branches unharmed (likely no change).
- Docs (`README.md`, setup/validate) — document agent-view support and config.

### Error handling / edge cases

- **No `jq`:** existing grep fallback in `notify-tmux.sh` must also parse `session_id`; agent path degrades gracefully (skip dedup precision, still add/remove best-effort).
- **No dashboard window open at jump:** fall back to opening one.
- **Multiple `claude agents` panes:** pick the first match (prefer the current session if present); documented as best-effort.
- **`CLAUDE_CONFIG_DIR` set:** queue file path already derives from `$HOME`/config; confirm the hook in a bg session resolves the same path the status bar reads.
- **Session dies without UserPromptSubmit/Stop:** entry persists; cleared via manual dismiss / picker.

### Testing

- Unit-style: feed crafted hook JSON (Notification/UserPromptSubmit/Stop) on stdin to `notify-tmux.sh` with `$TMUX` unset; assert queue file add/remove and `terminalSequence` JSON on stdout.
- Dedup: two Notifications for the same `session_id` → one queue line.
- Remove: UserPromptSubmit for a queued `session_id` → line gone; for an unqueued id → no-op.
- Jump branch: stub `tmux list-panes` output containing/omitting `claude agents`; assert select-window vs new-window path.
- Manual end-to-end against a real `claude --bg` session for the prototype gate (below).

## Prototype gate (do this FIRST, before implementation)

These assumptions are load-bearing; the plan's first task is a throwaway probe:

- **A1 (critical):** a `Notification` hook fires in a detached agent-view/background session, and a `terminalSequence` OSC 777/9 desktop notification is actually perceivable while detached. Probe: register a logging Notification hook, `claude --bg` a task that triggers a permission/idle prompt, confirm the hook ran and the notification appeared.
- **A2:** the bg-session hook process has `$TMUX` unset. Probe: log `env | grep TMUX` from the hook in a bg session.
- **A3:** replying via the peek panel fires `UserPromptSubmit` in that bg session, and `Stop` fires when it proceeds. Probe: log these events from a bg session while replying in the dashboard.

**If A1 fails:** fall back to a `claude agents --json` poller (status-bar tick) as the trigger; sections 2–4 (show / navigate / dismiss) remain unchanged — only the *source* of add/remove changes from hooks to poll diff.

## Out of scope (v1 / YAGNI)

- Polling `claude agents --json` as the primary trigger (kept only as the A1 fallback).
- Attaching directly to a specific session, or driving the dashboard to a specific row / `s:blocked` filter.
- "Completed" / "working" agent entries.
- Managing Claude's native `preferredNotifChannel` setting.
- A separate/dedicated status-bar segment for agents (entries share the existing slot).
