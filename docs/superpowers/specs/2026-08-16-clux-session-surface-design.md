# clux session surface — full session workflow, installed by /clux:setup

Date: 2026-08-16
Status: design agreed, not yet implemented

clux is a way to work with many Claude Code instances in tmux. Until now it
only decorated a bar the user had to build. This design makes clux own the
whole session surface: show the sessions, order them, move between them, pick
them, and create new Claude workspaces. `/clux:setup` installs all of it.

The goal, in the user's words:

- On a machine with a bare tmux setup, `/clux:setup` produces a complete
  working environment — sessions and windows visible, navigation working,
  agent state showing.
- On a machine with an existing tmux setup, `/clux:setup` evolves that setup
  until all clux shortcuts and visualizations work, and changes nothing else.

## Prior decisions this design builds on

- `2026-08-10-clux-config-updater-skill-design.md` — the ownership rule.
  clux writes one file it owns (`~/.config/clux/clux.tmux.conf`), adds one
  `source-file -q` line to the user's tmux.conf, and puts tokens (not shell
  calls) into the user's status line. That spec is agreed but not built.
  Building it is part of this work.
- `2026-08-16-clux-detached-agent-state-design.md` — shipped as 3.2.0. The
  agent glyph column this bar renders.

## Part 1 — What clux ships

Eight scripts move into `plugins/clux/scripts/` and deploy to
`~/.config/clux/scripts/` like the rest. They come from the user's own
config repo (`404pilo/config`, `tmux/scripts/`), generalized as Part 3
describes.

```
session-order.sh          resolve the display order (single source of truth)
├── session-list.sh       render the bar string; joins agent-query.sh
├── session-reorder.sh    move the current session left/right in the bar
└── switch-session.sh     go to the next/previous session in bar order
session-bar-refresh.sh    render into @clux_session_bar and @clux_status, then redraw
session-picker.sh         picker with pane preview (fzf when present)
new-workspace.sh          create a Claude workspace (editor + agents windows)
new-workspace-prompt.sh   ask for name and folder, then create
```

`session-order.sh` is the one source of truth. The renderer, the reorder
keys, and the switch keys all read it, so they can never disagree.
`session-order.sh` keeps its comma delimiter between session names. A
session name containing a comma splits into fragments that match no live
session, so `session-order.sh` skips them and the real session reappears
through its creation-order fallback — benign and self-correcting. The
delimiter stays comma because the migrated value already uses it and
because the option must stay hand-editable.

`session-bar-refresh.sh` is the single refresh entry point for both
tokens: it computes `@clux_session_bar` from `session-list.sh` and
`@clux_status` from `show-notification.sh` in one invocation, then issues
one `refresh-client -S`. It keeps the `quiet` argument, which skips the
redraw. `@clux-agent-refresh-command` (Part 3's escape hatch) points here
by default, so a Claude hook write reaches both tokens on the same path.
It sets each option only when the script that computes it exits 0 and
prints something; a renderer that dies leaves the previous value in
place rather than blanking the bar. Because `tmux set-option` is atomic,
the six hooks firing at once need no lock.

`session-picker.sh` emits `<raw name>\t<display line>` per session, runs
fzf with `--delimiter='\t' --with-nth=2..`, previews with
`tmux capture-pane -t {1} -p -e`, and extracts the chosen session with
`cut -f1`. It lists sessions in `session-order.sh` order, excluding the
current session, and keeps the original's "No other sessions" message.
This replaces the original's `sed 's/:.*//'` extraction, which is wrong
for any session name containing ": " — tmux forbids `.` and `:` in a
session name only for target syntax, not in the name itself, so that
extraction was a live bug. A TAB cannot occur in a session name, so it is
a lossless key for `cut`.

`new-workspace.sh` derives its socket from `$TMUX` when set
(`-S "${TMUX%%,*}"`) and runs on the plain `tmux` socket otherwise, so it
also runs with no attached client — from a plain shell, or under bats.
`TMUX="" tmux … new-session -d` stays, to keep the new session detached
from the caller's session. The closing `switch-client -t` runs only when
`$TMUX` is set; with no `$TMUX` the script prints the session name to
stdout and exits 0. Before creating, it runs `tmux has-session -t "=$name"`
— the leading `=` is required for exact matching, since `has-session -t foo`
without it also matches `foobar`, a live bug in the original. On a hit it
switches to the existing session (or prints it) instead of failing.

`new-workspace-prompt.sh` validates the session name and rejects one
containing a quote, backslash, semicolon, `#`, or a newline, with a
`display-message`. It stores an accepted name in the transient global
option `@clux-new-workspace-name`, then issues the second
`command-prompt -I "<name>/" -p "Folder name:"` whose command passes only
`%1` (the folder) to `new-workspace.sh`, which reads the name back from
the option and unsets it. The trailing slash in the prefill is kept: it
makes the folder field an autojump-friendly prefix the user completes.
Only one user-supplied value ever reaches a tmux command string this
way — the higher-risk one travels through an option, which tmux never
re-parses.

Default key bindings, all in clux's own file:

| Key | Action |
|---|---|
| `N` / `P` | next / previous session, in bar order |
| `{` / `}` | move the current session left / right in the bar |
| `g` | session picker with pane preview |
| `A` | new Claude workspace (name, then folder) |
| `m` | jump to the notifying agent (existing) |
| `M` | notification picker (existing) |
| `` ` `` / `DC` | dismiss notification (existing) |

**clux does not own:** the prefix key, pane navigation, splits, copy mode,
the clipboard, popups, resurrect, or any color outside its own bar. Those
stay with the user.

**Noted, out of scope:** the user's `W` binding (`claude --worktree` in a
new window) was not confirmed into this scope. It can join later.

## Part 2 — How it lands in tmux.conf

Everything clux writes goes into **one file clux owns**:
`~/.config/clux/clux.tmux.conf`. clux rewrites that file whole on every
update. It holds the bindings above, the refresh hooks, and every `@clux-*`
option. No markers are needed inside it, because clux owns all of it.

The user's tmux.conf gets **one line and two token strings**, and nothing
else:

```tmux
source-file -q ~/.config/clux/clux.tmux.conf     # the one line

#{@clux_session_bar}#(~/.config/clux/scripts/session-bar-refresh.sh quiet)
                         # where the session list renders
#{@clux_status}         # where the notification renders
```

Two token strings, not one, because a bar can put the session list and
the notification in different zones (the user's puts them left and
centre). The session-bar token string is the contiguous text
`#{@clux_session_bar}#(~/.config/clux/scripts/session-bar-refresh.sh quiet)`,
not `#{@clux_session_bar}` alone. tmux does not re-expand a `#()` found
inside an option value, so the periodic safety net that keeps the bar
fresh between hook-covered events cannot live in clux's own file — it has
to be literal text in the rendered status line. It renders zero
characters (the `quiet` argument skips the redraw) and is inserted in the
same single edit as the token. The corpus invariant (see Testing) counts
`#{@clux_session_bar}` once, `#{@clux_status}` once, and
`session-bar-refresh.sh quiet` once — not the token strings as opaque
units.

Every `@clux-*` option name follows one rule: hyphens for a configuration
input the user or setup sets (`@clux-dir-resolver`, `@clux-editor`,
`@clux-agents-command`, `@clux-picker`, `@clux-session-order`, every
`@clux-bar-*` and `@clux-agent-*` option); underscores for the two
runtime-rendered strings only, `@clux_session_bar` and `@clux_status`.
This rule applies to every theming option too, not just the ones named
here.

The refresh hooks live in clux's file at hook index band **90–99**, which
clux reserves. An unindexed user hook writes index 0, so clux can never
drop it, and the user can never drop clux's. `agent-clear.sh` stays at
`[90]` on `after-select-window` and `client-session-changed` — that index
is already shipped and live in the author's tmux.conf, so moving it would
orphan existing installs. `session-bar-refresh.sh` goes at `[91]` on all
six events the user's config already proved out: `client-session-changed`,
`after-select-window`, `session-created`, `session-closed`,
`window-linked`, `window-unlinked`. tmux runs hooks in ascending index
order within one event, so `agent-clear.sh` clears a finished mark at
`[90]` before `session-bar-refresh.sh` renders at `[91]`, and the cleared
state reaches the bar in the same pass instead of one event later.
`92`–`99` stay reserved and documented as such. clux.tmux.conf's closing
section also runs `agent-clear.sh --reap` once and
`session-bar-refresh.sh` once at load, to seed the bar and clear dead pane
state (see the file layout below).

If tpm also loads `claude-notify.tmux`, it sets the same `[90]` hooks
pointing at a different script path (the tpm plugin cache, not
`~/.config/clux/scripts/`), possibly a different version. clux.tmux.conf
always writes the `[90]` hooks pointing at
`~/.config/clux/scripts/`. `/clux:setup` reports when it detects a tpm
load of `claude-notify.tmux` and recommends removing that line, but never
removes it itself — the tpm line lives in the user's file, not clux's.
The commands are functionally identical, so whichever loads last is
correct either way; the reported hazard is version skew, not breakage.

Option names get the clux prefix: `@session_order` becomes
`@clux-session-order`, `@session_bar` becomes `@clux_session_bar`.
Migration copies a live `@session_order` value across, so the user's
custom order survives the switch. `clux.tmux.conf` itself never contains
a `set -g @clux-session-order` line — see the file layout below.

Migrating `@session_order` reads it from the live server first, before
any file is rewritten: `tmux show-option -gqv @session_order`. If it is
non-empty and `@clux-session-order` is empty, `/clux:setup` runs
`tmux set-option -g @clux-session-order "$value"` immediately — nothing
is written to any file. `@session_order` itself is left set and reported
as a leftover, never unset, since it exists only in server memory (only
`session-reorder.sh` ever wrote it) and unsetting it would be clux
writing an option it does not own. Gating on an empty destination means a
second `/clux:setup` run can never clobber an order the user has since
changed. If no server is running, setup reports "no order to migrate" and
continues. At run time, `session-order.sh` reads only
`@clux-session-order` — there is no legacy fallback to `@session_order`.

The `@clux-agent-refresh-command` escape hatch is retired for installs
that use clux's bar: clux owns the refresh path, so the default is right.
The option stays for users who keep a bar of their own. Which install a
machine is a setup branch, not an option: Part 3 gains a fifth
question, "Let clux render the session list?", default yes. Yes: setup
inserts the session-bar token string and writes
`@clux-agent-refresh-command` as
`run-shell -b ~/.config/clux/scripts/session-bar-refresh.sh`. No: setup
inserts only the notification token and writes no
`@clux-agent-refresh-command` line, leaving whatever the user has.

**`~/.config/clux/clux.tmux.conf`, line by line.** Six sections, in this
order:

1. Header comment — generated by `/clux:setup`, a version stamp, "do not
   edit, rewritten whole", the hyphen/underscore rule, and the 90–99
   hook reservation.
2. `set -g` for the Part 3 answers (`@clux-dir-resolver`, `@clux-editor`,
   `@clux-agents-command`, `@clux-picker`) and `@clux-agent-refresh-command`.
3. `set -g` for the theming options (Part 4), emitted only for values
   detection actually found.
4. The seven bind-key lines: `N` `P` `{` `}` `g` `A`, plus the existing
   `m` `` ` `` `DC` `M`.
5. The hooks (the 90–99 band above).
6. `run-shell agent-clear.sh --reap` then `run-shell session-bar-refresh.sh`,
   last, so the bar it seeds carries no marks left over from a previous
   server.

No shared tmux setting (`status-interval` and the like) appears anywhere
in this file, and no line sets `@clux-session-order`, `@clux_session_bar`,
or `@clux_status` — those are runtime server state, not config clux
writes on every rewrite. `clux.tmux.conf` is rewritten whole and
re-sourced on every update and on every `prefix + r`; a `set -g` line for
any of the three would reset live state to whatever value was current at
setup time on every reload, which for `@clux-session-order` is exactly
the failure the reorder keys exist to prevent. An empty
`@clux-session-order` already means "creation order", the correct
default.

### Bare machine

clux writes `${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf` — the XDG
path, not `~/.tmux.conf`, matching where clux already looks first and
where tmux 3.x prefers. It contains exactly:

- a header comment saying clux owns only the source-file line
- `status-interval 2` — the bar is event-driven, so the interval is only
  a safety net; `1` would cost a fork per second per client for no gain
- `status-left-length 150`
- `monitor-bell on`
- `bell-action any`
- one `status-format[0]`:
  `#[align=left] #{@clux_session_bar}#[align=centre]#{@clux_status}#[align=right]#(~/.config/clux/scripts/session-bar-refresh.sh quiet) `
- `source-file -q ~/.config/clux/clux.tmux.conf`, last, so clux's hooks
  register after the status settings they redraw

The result is stock tmux plus a working clux bar and working session keys.
Prefix stays `C-b`. Pane keys stay stock.

### Existing machine

clux adds the one line, inserts the two token strings where the status
line really renders, and writes nothing it does not own. For a shared
setting it wants but does not own, it reports and leaves the value alone:

```
clux works best with status-interval at 1 or 2. Yours is 2. No change needed.
```

**Finding where the status line renders.** Setup probes; it does not
parse. If a server is running, it reads the live `status-format[0]` and
`status-left`. Otherwise it starts a throwaway server on the user's file
(`tmux -L clux-probe -f <conf> new-session -d`), reads the same options,
and kills it. It also starts a second throwaway server with `-f /dev/null`
to read tmux's built-in default for `status-format[0]`. If the user's
`status-format[0]` differs from that default, it is the render site; else
if `status-left` is non-empty, `status-left` is the render site; else
`status-left` is the render site by default. Comparing against a default
read from a stock server at run time is version-proof and needs no
hardcoded default string — it is also the only way to tell "the user set
`status-format[0]`" from "tmux populated it". Setup then maps the chosen
live value back to exactly one line of the config-file set, by matching
the option name and the value; zero or more than one candidate line means
refuse.

**Where the tokens go inside that value.** The session-bar token string
goes immediately after the first `#[align=left…]` segment's leading
field, or at the start of the value when there is none. The notification
token goes immediately before the first `#[align=right]`, prefixed with
`#[align=centre]`, or appended to the end when there is none. This is
exactly where the currently shipped setup puts `#(show-notification.sh)`,
and where the author's own bar puts both, so the migration is a
substitution in place and the live result is visually unchanged.

The safety rules from the config-updater spec all apply: show the diff
first, back up with a timestamp, verify on a throwaway tmux server
(`tmux -L clux-verify -f <file> new-session -d`), refuse when the status
line cannot be located with confidence, restore the backup when
verification fails.

## Part 3 — Prerequisites are questions, not defaults

The moved scripts carry tool choices (autojump, nvim, fzf, a permission
flag). clux does not hard-code any of them. **`/clux:setup` asks about
each one, and the default answer is what it detects on the machine.** On
the author's machine, detection finds the current setup, so "keep what
you have" is always the first option. On a bare machine, detection finds
what is installed and offers that.

| Question | Detection | Options offered | Default when detection finds nothing |
|---|---|---|---|
| How should folder names resolve to directories? | `autojump` / `zoxide` on PATH; existing config uses autojump | detected tool (default) · the other tool if present · plain path with `~` expansion | `path` |
| Which editor opens in the workspace's first window? | `$EDITOR`, else `nvim`/`vim`/other on PATH | detected editor (default) · no editor window | `none` |
| What command runs in the workspace's `claude` window? | existing config's command, including any flags it carries | detected command (default) · `claude agents --cwd "$PWD"` · custom | `claude agents --cwd "$PWD"` when `claude` is on PATH, else `none` |
| How should the session picker work? | `fzf` / `fzf-tmux` on PATH | fzf with pane preview (default when present) · native `choose-tree -Zs` | `choose-tree` |
| Let clux render the session list? | n/a | yes · no (Part 2) | yes |

The answers become `@clux-*` options in clux's own file:
`@clux-dir-resolver`, `@clux-editor`, `@clux-agents-command`,
`@clux-picker`. Changing a choice later means re-running `/clux:setup`
or editing the option — never editing a script. Every fallback above
still produces a working environment with no extra binary — the bare-
machine goal. The agents command is sent with `send-keys … Enter` into a
shell, never run as `new-window "<cmd>"`: launched as the window's
command, the window would close (and take its scrollback with it) when
the dashboard exits, and `send-keys` is also what lets `$PWD` expand in
the target shell.

One note the setup must voice, once, when the detected agents command
carries `--allow-dangerously-skip-permissions`: it repeats the flag back
and asks the user to confirm keeping it. Detection makes it the default;
confirmation makes it a choice.

**`@clux-dir-resolver`** takes `autojump`, `zoxide`, or `path`; default
`path`. In every mode, an input that already names an existing directory
(absolute, `~`-prefixed, or relative to the invoking pane's path) wins
before the resolver is consulted. `autojump` mode keeps
`AUTOJUMP_SOURCED=1` and its comment; `zoxide` mode uses
`zoxide query -- "$folder"`. A missing resolver binary falls back to
`path` mode with one `display-message`. An unresolvable folder emits
`clux: no directory for '<folder>'` and exits 1, creating nothing — a
session with a window in the wrong directory is worse than no session.

**`@clux-editor`**, **`@clux-agents-command`**, and
**`@clux-dir-resolver`** alike use the sentinel string `none`, never the
empty string, to mean "no value" — `get_tmux_option()` collapses an
empty value to its default, so an empty string cannot express "off".
`none` on the editor means the `---` window is still created and pinned
but nothing is sent to it, so the user lands in a shell; the window is
still created because the workspace shape (below) is the one default
layout regardless of the editor choice. When `@clux-editor` is unset
entirely, the ladder is `$EDITOR`, then `nvim`, then `vim`, then `none`,
resolved by one shared `get_clux_editor()` helper used by both setup and
run time. `$EDITOR` is read at setup time only, never at run time —
reading it at run time would make the workspace differ per client
environment.

**`@clux-picker`** takes `fzf` or `choose-tree`; default `fzf` when
`fzf-tmux` or `fzf` is on PATH at setup, else `choose-tree`. At run time
`session-picker.sh` degrades independently of the option, because the
binary is a per-machine fact that can change after setup: `choose-tree`
runs `tmux choose-tree -Zs`; `fzf` prefers `fzf-tmux -p` and falls back
to running `fzf` inside `tmux display-popup -E` when only `fzf` is
present; when neither binary is on PATH it runs `choose-tree -Zs` and
emits one `display-message "clux: fzf not found, using choose-tree"`.
This always leaves the user a working `g` key, which a blank popup or a
silent no-op does not.

The workspace shape itself — window `---` at index 0 with the editor,
window `claude` at index 1 with the agents dashboard, both names pinned —
ships as the one default shape. That layout is the clux workspace.
`new-workspace.sh` keeps the original's base-index-1 window dance (create
at 1, move 1 to 0, the claude window lands at 1) exactly, but addresses
every window by the window ID returned from
`new-session -P -F '#{window_id}'` and `new-window -P -F '#{window_id}'`,
and reads `base-index` rather than hardcoding it. The `move-window` to
index 0 runs only when `base-index` is greater than 0, which keeps the
author's `---` window literally at index 0 on their base-index-1 server
while also working correctly on a base-index-0 server. Names are pinned
with an explicit `set-option -w -t <window_id> automatic-rename off`.
Window IDs remove the whole class of index and renumbering bugs while the
observable result — editor window first, claude window second — stays
identical either way.

## Part 4 — Theming

Colors and glyphs in the bar become `@clux-*` options. `/clux:setup`
already extracts a color palette in its detection phase; it fills the bar
options from that palette, so the bar matches the user's theme. On a bare
machine, readable generic defaults apply. The user's Nord values are what
detection finds on their machine, not what clux ships. Detection writes a
line only for a value it actually found; anything else is left to the
default, so clux's file stays honest about what it inferred.

The `@clux-bar-*` options and their defaults, replacing the original's
hardcoded Nord values:

| Option | Default |
|---|---|
| `@clux-bar-name-attached-style` | `bg=magenta,fg=black,bold` |
| `@clux-bar-name-detached-style` | `fg=magenta` |
| `@clux-bar-window-active-style` | `bg=blue,fg=white,bold` |
| `@clux-bar-window-inactive-style` | `bg=brightblack,fg=white` |
| `@clux-bar-bracket-style` | `fg=magenta` |
| `@clux-bar-separator-style` | `fg=brightblack` |
| `@clux-bar-window-open` | `❰` |
| `@clux-bar-window-close` | `❱` |
| `@clux-bar-separator` | `│` |
| `@clux-bar-name-length` | `24` |

The defaults use tmux named colours, matching the existing
`@clux-agent-*-color` precedent, so both an 8-colour terminal and an
unthemed machine render readably.

The renderer keeps the `##` escaping, the `#{=24:...}` truncation
decision, and the `\037` row transport for agent state — the fix for the
newline-in-`awk -v` fault found on 2026-08-16. That fault class is why
the renderer must live in clux, tested, and not in each user's config.
`@clux-bar-name-length` reaches the truncation as an option without
breaking the house rule that truncation is tmux's job: `session-list.sh`
builds the `tmux list-sessions -F` and `list-windows -F` format strings
in bash, as `#{=N:session_name}` / `#{=N:window_name}` with `N` filled in
from the option, after reading it — awk still never calls `substr()`.
The `##` escape is still applied after tmux has truncated, so the
visible width is exact. This preserves the platform-correct truncation
the original's comment justifies: mawk's byte-oriented `substr()` versus
BWK awk's character-oriented one, and mawk slicing a multibyte character
in half.

**Hot-path option reads.** `session-list.sh` runs on every window switch
and needs about twelve `@clux-bar-*` option reads per render, but
`helpers.sh` cannot be sourced from a hot path (it costs five
`get_tmux_option` calls at source time). `get_tmux_option()` and the
`@clux-agent-glyph-*` / `@clux-agent-*-color` getters move down into
`path.sh` as definitions only — `path.sh` keeps its zero-side-effect
guarantee, and `helpers.sh` keeps sourcing `path.sh`, so nothing else
changes. `session-list.sh` sources `path.sh` and reads every bar option
in one `tmux display-message -p` call whose format is the option
references joined by `\037`, then splits on `"\037"` — one fork per
render instead of twelve. The `\037` join is mandatory, not stylistic:
the values arrive multi-line-capable, and a literal newline inside
`awk -v` is the exact fault that emptied the bar on 2026-08-16. Reusing
the existing `@clux-agent-*` getters, rather than inventing bar-specific
twins, keeps `agent-bar.sh` and `session-list.sh` from ever disagreeing
about a glyph.

## Part 5 — Migration on the author's machine

`/clux:setup` detects the hand-authored versions in
`~/.config/tmux/scripts/` and the wiring in their tmux.conf. It shows a
diff and offers, in one confirmed step:

1. Set the Part 3 options so behavior stays identical (autojump, nvim,
   the detected agents command, fzf).
2. Write `~/.config/clux/clux.tmux.conf` with bindings, hooks, options.
3. Edit tmux.conf: add the source line, replace the session-bar hook
   block and the clux marker block with the two token strings, remove
   the replaced bindings. Only a line whose command text references one
   of the superseded script paths (`switch-session.sh`,
   `session-reorder.sh`, `fzf-session-switch.sh`, `new-session-prompt.sh`,
   `session-bar-refresh.sh`, and the six session-bar hooks) is removed —
   never a binding by key name alone. Path matching is the same
   technique the config-updater spec uses to find the notification
   segment wherever the user moved it, and it is the only rule that
   cannot delete something clux did not write. A user binding on `N`,
   `P`, `{`, `}`, `g`, or `A` that points somewhere else is left alone
   and reported as a conflict, along with where the source-file line
   sits, so the user can see which one wins. `bind-key s` / `C-x
   choose-tree` and `bind-key W` are untouched — both are outside clux's
   ownership.
4. Copy `@session_order` to `@clux-session-order`, using the live-server
   read-and-set described in Part 2 — nothing is written to a file, and
   `@session_order` is left set and reported as a leftover.
5. Delete the eight superseded scripts from `~/.config/tmux/scripts/`:
   session-order, session-list, session-reorder, switch-session,
   session-bar-refresh, fzf-session-switch, new-session,
   new-session-prompt. First back up to
   `~/.config/clux/backups/tmux-scripts-<timestamp>/`, reusing the
   existing backup root and its 5-generation prune. Then re-scan the
   rewritten tmux.conf and refuse to delete any script it still
   references, reporting the refusal — the cheapest possible guard
   against the worst outcome of this step: a half-applied edit that
   leaves a live reference to a file the same run just deleted.

The config repo copy (`404pilo/config`) is not touched; committing the
slimmed tmux.conf there stays the user's own step.

## Deploy manifest

`/clux:setup` and `/clux:validate` currently carry two hand-written
deploy lists that already differ, and this work adds eight more scripts
to both — the exact shape of the bug CHANGELOG 3.0.9 already recorded
once (`path.sh` missing from a manifest). Instead,
`plugins/clux/config/deploy-manifest.txt` holds one script per line, and
`/clux:setup`, `/clux:validate`, and the tests all read it. Neither
command carries a literal list of its own.

## Entry point

`/clux:setup` stays the entry point, in `commands/setup.md`. The
judgement-heavy configuration work — detection, the Part 3 questions,
the migration diff — moves into
`plugins/clux/skills/configuring-tmux/SKILL.md`, which the command
invokes. `/clux:validate` stays a command and gains checks for the two
token strings, the source-file line, `clux.tmux.conf`'s presence and
parseability, the eight new scripts (against the deploy manifest), and
the `@clux-*` options. The skill boundary is where the non-deterministic
work sits, which is also where the two testing strategies below split.

## Testing

- The eight scripts are deterministic: one bats file per script,
  extending the existing `test/stubs/tmux` (not forking it) with
  `list-windows`, `display-message -p`, and `show-option` responses.
  `session-list.bats` must include an agent-query fixture with real
  newlines and a session name containing `#` — the regression tests for
  the 2026-08-16 bar-emptying fault and for the `##` escaping the
  renderer must never drop.
- The setup skill is not deterministic: test the invariant, per the
  config-updater spec's corpus method, over `test/corpus/*.conf` holding
  the six shapes from the config-updater spec plus the author's real
  tmux.conf as a seventh case — the only corpus entry that exercises
  `status-format[0]` with nested `#[...]` escapes, `if-shell`, and
  indexed hooks together, the combination the migration actually has to
  survive. Asserted for each: every line clux did not add is
  byte-identical, each token string appears exactly once, running setup
  twice changes nothing, and the result parses on a throwaway server.
- Live verification on the author's machine after migration: bar renders,
  all keys work, agent glyphs update, order survives a reorder.

## Rollout

Version 3.3.0. The changelog names the new scripts, the new options, the
option renames, and the migration.
