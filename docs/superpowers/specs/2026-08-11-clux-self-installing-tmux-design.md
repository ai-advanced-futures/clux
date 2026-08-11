# Self-installing tmux wiring for clux

Date: 2026-08-11
Status: design agreed, not yet implemented

Make clux install everything it needs on the tmux side by itself, so
`/clux:setup` is never required and no line is ever added to the user's
`tmux.conf` by hand or by a skill.

This replaces the tmux-editing half of
`2026-08-10-clux-config-updater-skill-design.md`. That design still needed one
line added to the user's file, and a skill run to add it. This design needs
neither.

---

## Why this is needed

`2026-08-10-clux-agent-state-design.md` shipped as clux 3.1.0, merged in PR
#13. Getting it to actually render on one real machine took a long manual
session: copying scripts by hand, registering two tmux hooks with raw `tmux
set-hook` commands, and adding lines to `tmux.conf` and to
`~/.claude/settings.json` by hand. None of that should have been necessary.

Four causes, each confirmed directly on that machine this session, not
assumed:

1. **`/clux:setup` refuses to redeploy.** `configure-tmux.sh` calls
   `is_already_configured()`, which greps `tmux.conf` for
   `show-notification.sh`. On an already-configured machine this matches, so
   setup prints "already configured" and returns before `deploy_scripts()`
   ever runs. A version bump changes nothing until the user re-runs a setup
   that will not re-run.

2. **`~/.claude/settings.json` is not durable on a busy machine.** With many
   Claude Code sessions open, some concurrent session repeatedly serialized
   its own stale in-memory copy over the file, silently deleting hook
   registrations written moments earlier. Verified three times in one
   session: a hand-added `SessionStart` hook, and later four more hooks,
   vanished within minutes each time. See `claude-settings-json-clobbered.md`
   for the general finding. Nothing that must persist should be written
   there.

3. **The installed plugin is a version-pinned copy, not the git checkout.**
   `${CLAUDE_PLUGIN_ROOT}` resolves to
   `~/.claude/plugins/cache/.../clux/<version>/`. Hand-editing files there
   works until the next `claude plugin update`, which replaces the directory
   outright. Only a real release fixes a machine permanently.

4. **The bar itself may not be reachable by any file-based install.** On this
   machine, `status-left` and `status-right` are both empty; the entire bar is
   `status-format[0]`, set to `#{@session_bar}`, an option that a separate
   script rebuilds from scratch on every refresh. Nothing written to
   `status-right` would ever be seen. This is a real ceiling on automatic
   installation, not a bug to fix — see "What cannot be automatic" below.

Causes 1–3 are fully fixable. Cause 4 sets the honest boundary of this
design.

---

## Principle

**Every install action runs from a hook that already fires unconditionally,
against the live tmux server, and never touches a file the user owns.**

Claude Code hooks are registered in the plugin's own `hooks.json`, which ships
inside the plugin and needs no entry in the user's `tmux.conf` or
`settings.json` — clux already gets this for free, for every session, on
every machine. That existing, unconditional firing is the install trigger.
Nothing new needs to run on a schedule or a login, because something in this
family already runs on every prompt, every notification, and every stop.

---

## What self-installs, and how

### The tmux-side hooks

`after-select-window` and `client-session-changed`, which clear a `finished`
mark when the user looks at a window. Today these are added by hand with
`tmux set-hook -g ...[90] ...`, or documented as a `tmux.conf` addition.

Instead: every time a clux Claude-side hook fires (`agent-state.sh`, already
running on every `UserPromptSubmit` / `Notification` / `Stop` /
`SessionEnd`), it first calls `clux_ensure_installed`, a new function in
`path.sh`:

```sh
clux_ensure_installed() {
    [ -n "$TMUX" ] || return 0   # no live server, nothing to install into
    local have; have=$(tmux show-option -gqv @clux-installed 2>/dev/null)
    [ "$have" = "$CLUX_VERSION" ] && return 0   # already current, skip the rest

    tmux set-hook -g 'after-select-window[90]'    "run-shell \"$SELF_DIR/agent-clear.sh '#{window_id}'\""
    tmux set-hook -g 'client-session-changed[90]' "run-shell \"$SELF_DIR/agent-clear.sh '#{window_id}'\""
    _clux_install_bar_segment   # see below
    tmux set-option -g @clux-installed "$CLUX_VERSION"
}
```

`$SELF_DIR` is the running plugin's own directory
(`${CLAUDE_PLUGIN_ROOT}/scripts`), resolved once, so the hook commands always
point at whatever version is currently installed — no copying, no drift.

**Cost.** One `tmux show-option` per hook fire, a few milliseconds, and it
short-circuits on every fire after the first. The four `set-*` calls run once
per plugin version, not once per fire.

**Self-healing.** A tmux server restart clears every `set-hook` and
`set-option`, including `@clux-installed`. The very next Claude Code event —
which needs no tmux state to fire — sees the option missing and reinstalls.
There is a gap between a tmux restart and the next prompt, during which a
window switch will not clear a stale `finished` mark. That gap closes itself
on the next prompt, same shape as the interrupt hole already accepted in the
agent-state design.

**Version bumps.** Bumping `CLUX_VERSION` in `plugin.json` is what forces a
reinstall after an update — `@clux-installed` no longer matches, so the next
hook fire reapplies everything, including any new hook lines a future version
adds.

### The bar segment

Two tiers, tried in order, because one tmux server cannot be assumed to have
either kind of bar.

**Tier A — append to `status-right`, at runtime, never to a file.**

```sh
_clux_install_bar_segment() {
    case "$(tmux show-option -gv status-right 2>/dev/null)" in
        *'#{@clux_agent_bar}'*) return 0 ;;   # already present, idempotent
    esac
    tmux set-option -g status-right "#{status-right} #{@clux_agent_bar}"
}
```

`@clux_agent_bar` is the option the writer hooks already set to the rendered
string (`agent-state.sh` / `agent-clear.sh` already call `refresh_agent_bar`
after every write; this makes them also refresh the option's *content*, not
just ask tmux to redraw). Reading it costs nothing on redraw — no `#(...)`
job, just an option lookup, same characteristic tmux already optimizes for.

This is a genuine runtime edit of a live server's option, not a `tmux.conf`
line. It is lost on server restart, exactly like the hooks above, and
reinstalled the same way.

**Tier B — a precomputed, self-rebuilding bar.** If `status-format[0]` is
already something other than the default and does not contain
`status-right`'s tokens — the pattern this machine's config repo uses — Tier A
is silently invisible: the owning script overwrites the whole bar string on
every refresh, `status-right` included. `clux_ensure_installed` detects this
case (`status-format[0]` set to a bare option reference, not built from
`status-left`/`status-right`) and does **not** claim success. It sets
`@clux-installed` anyway, so it does not retry every hook fire, but it also
sets `@clux-agent-bar-unreachable 1` and prints one line to
`agent-clear.sh`'s stderr the first time, pointing at `agent-query.sh` /
`agent-bar.sh` and this document's next section.

### The Claude-side hooks

Already self-sufficient today. `hooks.json` ships inside the plugin and is
read by Claude Code with no entry required in `~/.claude/settings.json`. The
only reason a hand-written `settings.json` entry appeared during this
session's manual testing was to point at an unreleased worktree build; a
released version needs nothing there. This design changes nothing about that
path — it is already correct, and cause 2 above is a reason to keep it that
way, not a bug in it.

### Script deployment

`/clux:setup`'s `deploy_scripts()` step, and `configure-tmux.sh`'s
`is_already_configured()` short-circuit, stop mattering for this feature: no
script is copied anywhere. Every command above runs the plugin's own files in
place, from `${CLAUDE_PLUGIN_ROOT}`. This sidesteps cause 1 and cause 3
entirely, rather than fixing `is_already_configured()` — fixing it is still
worth doing for the notification queue's existing copy-based install, but it
is out of scope here.

---

## What cannot be automatic

A bar built entirely from a precomputed, self-rebuilding option
(`status-format[0]` = `#{@some_option}`, rebuilt wholesale by the user's own
script) cannot be joined by appending to `status-right` — not a limitation of
this design, a property of how tmux renders `status-format`. The owning
script must itself read `agent-query.sh` and fold a glyph into what it
builds. `scripts/session-list.sh` in the user's own config repo already does
this by hand, added in this session's earlier work (commit `8a726f0`), and is
the reference example this document points users at.

`clux_ensure_installed` detects this case and says so once, rather than
reporting success where nothing rendered — which is exactly the silent-success
failure mode `2026-08-10-clux-config-updater-skill-design.md` documented for
the old `setup-tmux-conf.sh`. This design does not repeat it.

---

## Relationship to the config-updater skill design

`2026-08-10-clux-config-updater-skill-design.md` proposed a Claude-driven
skill to add one `source-file` line plus one `#{@clux_status}` token to the
user's `tmux.conf`, because bash pattern-matching could not safely find where
a status line is really rendered.

This design needs no line added at all, so it does not depend on that skill.
What survives from it is narrower: **detecting the Tier B case** — deciding
whether a `status-format[0]` entry is a self-rebuilding precomputed option —
is the same judgement call that document assigned to a skill, because a
generic bash heuristic cannot safely tell "user's precomputed bar" apart from
"tmux default built from `status-left`". `clux_ensure_installed`'s Tier B
detection is deliberately conservative: it only has to decide *whether to
warn*, never to edit anything, so a bash heuristic that is allowed to
under-detect (warn when it isn't sure) is acceptable in a way that a bash
heuristic that edits files never was.

The `2026-08-10` design remains relevant only if a future feature needs to
write into the user's `tmux.conf` for real. Nothing in this design does.

---

## What ships

| File | Change |
|---|---|
| `scripts/path.sh` | add `clux_ensure_installed()`, `_clux_install_bar_segment()`, Tier B detection |
| `hooks/agent-state.sh` | call `clux_ensure_installed` before the existing write |
| `scripts/agent-clear.sh` | call `clux_ensure_installed` before the existing clear |
| `scripts/agent-state.sh` / `agent-clear.sh` writers | also set `@clux_agent_bar` to the rendered string, not only trigger a redraw |
| `scripts/agent-bar.sh` | fix: escape `#` in a session name before printing it into `@clux_agent_bar` (found while designing this; a `#` in a session name currently injects styling into the bar) |
| `plugin.json` | `CLUX_VERSION` becomes the value written to `@clux-installed`; minor bump |
| `test/agent-state.bats` | idempotency (`@clux-installed` skip path), Tier A append, Tier B detection, the `#` escaping fix |
| `commands/setup.md`, `commands/validate.md` | describe self-install; `/clux:validate` reports `@clux-installed` and the Tier B warning if set |

Nothing is removed from `hooks/hooks.json` or `configure-tmux.sh` — existing
users of the notification queue's file-copy install are unaffected. This
design only removes the *requirement* to run that install for agent state.

---

## Cost

| Measure | Value |
|---|---|
| extra work per hook fire, already-installed case | one `tmux show-option`, ~a few ms |
| extra work per hook fire, first fire after an update | four `tmux set-*` calls, ~tens of ms, once |
| files written outside the plugin's own state directory | none |
| lines added to any file the user owns | zero |

---

## Rejected, and why

**A tmux hook that runs at server start.** tmux has no such hook. The nearest
substitute, a line in `tmux.conf`, is exactly the footprint this design
removes.

**Writing the bar segment into `tmux.conf` via `source-file`, per the
`2026-08-10` config-updater design.** Strictly more footprint than Tier A for
the common case, and no more capable in the Tier B case — a sourced file
still cannot out-render a script that rebuilds `status-format[0]` from
scratch afterward.

**Detecting Tier B by trying to render and diffing the result.** Considered,
to make the detection empirical instead of heuristic. Rejected: it would mean
writing to the live option and reading it back, which risks a visible flicker
on the user's real bar during every version's first hook fire. The
declarative check (does `status-format[0]` reference `status-right`'s
content) costs nothing and never touches the live bar to find out.

**Retrying the Tier B warning on every hook fire.** Rejected as noisy —
`@clux-agent-bar-unreachable` is set once alongside `@clux-installed`, so the
warning prints once per plugin version, not once per prompt.

---

## Still to decide

1. **Where `_clux_install_bar_segment` looks for an existing clux segment**,
   if the user has already hand-added `#{@clux_agent_bar}` to `status-right`
   or a custom `status-format` entry themselves (as happened on this machine
   before this design existed). The idempotency check above already covers
   this for `status-right`; it does not yet cover a hand-edited
   `status-format[N]`.
2. **Whether `@clux-installed` should be per-session-group or global.** tmux
   options set with `-g` are server-wide, so one install currently covers
   every session on the server. A user running two independent tmux servers
   (two sockets) installs into each separately, which matches how `TMUX`
   scoping already works elsewhere in clux.
3. **An explicit `/clux:uninstall`.** Clearing `@clux-installed` alone does
   not remove the two `set-hook` entries or the `status-right` append; a
   restart-then-never-fire-again path leaves both in place harmlessly, but a
   clean removal command has not been designed.

---

## Out of scope

- Fixing `is_already_configured()` for the notification queue's own
  file-copy install. A real bug, orthogonal to this design.
- A generic `tmux.conf` editor for settings clux does not own. Covered, if
  still needed for something else, by `2026-08-10-clux-config-updater-skill-design.md`.
- Multiple tmux servers on one machine getting a shared, deduplicated install.
  See "Still to decide," item 2.

---

## Related

- `docs/superpowers/specs/2026-08-10-clux-agent-state-design.md` — shipped as
  3.1.0 (PR #13); this design removes the manual install step that shipping it
  required in practice.
- `docs/superpowers/specs/2026-08-10-clux-config-updater-skill-design.md` —
  superseded for the tmux-hooks and bar-segment footprint; still relevant only
  if a future feature needs to write into the user's `tmux.conf` for real.
