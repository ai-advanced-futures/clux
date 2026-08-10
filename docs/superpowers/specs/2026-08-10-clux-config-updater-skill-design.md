# Safe tmux.conf setup, driven by a skill

Date: 2026-08-10
Status: design agreed, not yet implemented

Make clux able to install and update itself in any user's `tmux.conf` without
disturbing anything else in that file.

This is a prerequisite for
`2026-08-10-clux-agent-state-design.md`, which adds tmux hooks to the user's
configuration. The current setup script cannot add them safely.

---

## Why the current approach fails

`scripts/setup-tmux-conf.sh` edits `tmux.conf` with bash pattern matching, in
three branches: file `missing`, file `has-status-left`, file `exists`. Five
problems, all verified by reading the script.

**1. It understands only `status-left`.** A user whose bar is built from
`status-format[0]` gets their `set -g status-left ""` line matched and modified.
The result renders nothing, because `status-format` overrides `status-left`.
The install reports success and the user sees no change.

**2. The `exists` branch overwrites settings it does not own.** It appends
`status-interval 1`, `monitor-bell on` and `bell-action any` unconditionally. A
user who chose a different interval loses it silently.

**3. Nothing records what clux added.** There are no markers, so nothing can
update or remove clux's changes later. The `exists` branch has no idempotency
guard, so running setup twice appends twice.

**4. Verification does nothing.** In `verify_config`:

```bash
if ! tmux -f "$tmpfile" source-file "$tmpfile" 2>&1 | grep -q "no server running"; then
    :
fi
success "Configuration verified"
```

Both branches of the inner test are empty and the result is discarded. The
function always reports success. It has never verified a configuration.

**5. Pattern matching cannot survive real configuration files** — values that
span lines, mixed quoting, or `#{...}` expressions containing quotes.

Problems 1, 2 and 5 have the same root cause. Deciding where a status line is
actually rendered, and which settings belong to the user, is a judgement, and
bash cannot make it.

---

## Premise

clux is a Claude Code plugin and nothing else. The name is Claude Code plus
tmux. Claude Code is therefore already present whenever clux is installed, and
requiring it to perform the setup adds no new dependency.

This closes the obvious objection to a skill-driven installer. There is no
population of users who have clux but not Claude Code.

---

## Principles

1. **Claude Code is the engine.** The skill reads the configuration,
   understands it, plans the smallest correct change, and explains it. Bash
   keeps only mechanical work.
2. **clux owns its own file.** Anything clux fully controls lives in a file
   clux writes wholesale.
3. **One line in the user's file.** That is the entire footprint.
4. **clux never sets what it does not own.** Shared settings are reported to
   the user, never written.
5. **Nothing is written without showing the change first.**

---

## Three tiers, by ownership

### Tier 1 — a file clux owns

```
~/.config/clux/clux.tmux.conf
```

Holds clux's key bindings, its tmux hooks and its `@clux-*` options. clux
rewrites this file completely on every update, because it owns all of it. No
markers are needed inside it.

Other tools may rewrite the user's `tmux.conf` freely without affecting clux,
and clux never has to parse its own previous output.

### Tier 2 — one line in the user's `tmux.conf`

```tmux
source-file -q ~/.config/clux/clux.tmux.conf
```

`-q` means no error if the file is absent, so removing clux cannot break the
user's tmux.

This is the only line clux adds. It is also the only line clux must find again
on a later run, which it does by matching the path.

### Tier 3 — one token inside the user's status line

The status segment cannot move to clux's file, because it must sit inside a
line the user owns and arranges.

Rather than a shell call, clux inserts an option reference:

```tmux
#{@clux_status}
```

clux sets that option from its hooks. Three consequences:

- The user's `tmux.conf` is edited **once, ever**. clux can later change what it
  renders, add states or change colours without touching that file again.
- No shell process runs on redraw. Measured on tmux 3.4: 30 `refresh-client -S`
  calls re-ran a status-line shell job 29 times, while 30 `set -g` calls re-ran
  it once. A status line with several such jobs pays that cost on every redraw.
- It matches the pattern used elsewhere for precomputed status strings.

**Trade-off accepted.** An option can go stale if an event that should update it
is missed, whereas a shell call always reads fresh. The hooks already fire on
the events that matter, and a stale string is a display fault, not a data fault.

---

## Ordering, and the rule that makes it not matter

A sourced file takes effect where the `source-file` line sits. If clux set a
shared option, whether clux or the user won would depend on that position, and
would change if the user moved the line.

Principle 4 removes the problem. clux's file contains only options no one else
sets. Where clux needs a particular value of a shared setting, it **reports**:

```
clux works best with status-interval at 1 or 2. Yours is 5.
Change it yourself if you want faster updates.
```

This is problem 2 from the current script, closed permanently.

---

## What the skill does

1. **Read.** Load the user's `tmux.conf` and any files it sources. Determine
   where the status line is really rendered — `status-left`, `status-right`, or
   a `status-format[N]` entry — and whether clux is already installed.
2. **Plan.** Decide the smallest change. Usually two things: add the
   `source-file` line, and insert `#{@clux_status}` at a sensible point in the
   status line. Often only one, or none.
3. **Show.** Present the change as a diff, and state anything it will not do,
   such as a shared setting it recommends but will not write.
4. **Confirm.** Never write without approval.
5. **Back up.** Copy the file with a timestamp before writing.
6. **Write.** Apply the change, and write clux's own file wholesale.
7. **Verify.** Parse the result for real, on a throwaway server:

   ```sh
   tmux -L clux-verify -f <file> new-session -d
   tmux -L clux-verify kill-server
   ```

   A throwaway socket cannot disturb the user's running sessions. This replaces
   the check that never ran.
8. **Report.** State exactly what changed, where the backup is, and what was
   deliberately left alone.

### When it must refuse

- The status line cannot be located with confidence.
- The configuration is generated by another tool.
- Verification fails. Restore the backup and say so.

Refusing and explaining is a correct outcome. Guessing is not.

---

## What bash keeps

Mechanical work only, where there is no judgement:

- copy scripts into `~/.config/clux/scripts/`
- check they are present and executable
- report the installed version

No configuration editing at all. `setup-tmux-conf.sh` is retired.

---

## Migration

Existing installs have `#(.../show-notification.sh)` in their status line. On
finding it, the skill offers to replace it with `#{@clux_status}`, and explains
the benefit. It never migrates without asking.

Installs where the user has moved clux's segment by hand are the normal case,
not an edge case. The segment is located by its script path, wherever it sits.

---

## Testing

A skill is not deterministic, so the existing bats pattern cannot test it
directly. Test the **invariant** instead, which is also the actual requirement.

Given a corpus of sample `tmux.conf` files — empty, plain `status-left`,
`status-format[N]`, already installed, installed then hand-modified, generated
by another tool — assert after the skill runs:

1. `source-file` line present exactly once
2. `#{@clux_status}` present exactly once, inside the rendered status line
3. `clux.tmux.conf` written and parseable
4. **Every other line byte-identical to the input**
5. Running again changes nothing
6. The result parses on a throwaway tmux server

Assertion 4 is the whole requirement, expressed as a test.

The corpus is the deliverable that makes this testable. Build it first.

---

## Still to decide

1. **Where clux's own file lives.** `~/.config/clux/clux.tmux.conf` groups it
   with the deployed scripts. `~/.config/tmux/clux.conf` groups it with tmux.
   The first is proposed.
2. **Whether the skill is invoked by `/clux:setup` or replaces it.** clux
   already has `commands/setup.md` and `commands/validate.md`, both
   Claude-driven, so there is precedent either way.
3. **Whether `/clux:validate` also becomes a skill.** It checks the same
   configuration and has the same judgement problem.

---

## Related

- `docs/superpowers/specs/2026-08-10-clux-agent-state-design.md`, which depends
  on this
- `docs/superpowers/specs/2026-05-26-clux-agent-view-design.md`
- `docs/superpowers/specs/2026-06-17-clux-multisession-agent-routing-design.md`
