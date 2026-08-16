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
session-bar-refresh.sh    render into @clux_session_bar, then redraw
session-picker.sh         picker with pane preview (fzf when present)
new-workspace.sh          create a Claude workspace (editor + agents windows)
new-workspace-prompt.sh   ask for name and folder, then create
```

`session-order.sh` is the one source of truth. The renderer, the reorder
keys, and the switch keys all read it, so they can never disagree.

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

The user's tmux.conf gets **one line and two tokens**, and nothing else:

```tmux
source-file -q ~/.config/clux/clux.tmux.conf     # the one line

#{@clux_session_bar}    # where the session list renders
#{@clux_status}         # where the notification renders
```

Two tokens, not one, because a bar can put the session list and the
notification in different zones (the user's puts them left and centre).

The refresh hooks live in clux's file at hook index band **90–99**, which
clux reserves. An unindexed user hook writes index 0, so clux can never
drop it, and the user can never drop clux's. The hooks are the six the
user's config already proved out: `client-session-changed`,
`after-select-window`, `session-created`, `session-closed`,
`window-linked`, `window-unlinked`, plus one run at load to seed the bar
and one `--reap` for dead pane state.

Option names get the clux prefix: `@session_order` becomes
`@clux-session-order`, `@session_bar` becomes `@clux_session_bar`.
Migration copies a live `@session_order` value across, so the user's
custom order survives the switch.

The `@clux-agent-refresh-command` escape hatch is retired for installs
that use clux's bar: clux owns the refresh path, so the default is right.
The option stays for users who keep a bar of their own.

### Bare machine

clux writes a small tmux.conf: the source line, a `status-format[0]`
holding the two tokens, and only the status settings the bar needs
(`status-interval`, `status-left-length`, `monitor-bell`, `bell-action`).
The result is stock tmux plus a working clux bar and working session keys.
Prefix stays `C-b`. Pane keys stay stock.

### Existing machine

clux adds the one line, inserts the two tokens where the status line
really renders (`status-format[0]` preferred, `status-left` as the
fallback), and writes nothing it does not own. For a shared setting it
wants but does not own, it reports and leaves the value alone:

```
clux works best with status-interval at 1 or 2. Yours is 2. No change needed.
```

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

| Question | Detection | Options offered |
|---|---|---|
| How should folder names resolve to directories? | `autojump` / `zoxide` on PATH; existing config uses autojump | detected tool (default) · the other tool if present · plain path with `~` expansion |
| Which editor opens in the workspace's first window? | `$EDITOR`, else `nvim`/`vim`/other on PATH | detected editor (default) · no editor window |
| What command runs in the workspace's `claude` window? | existing config's command, including any flags it carries | detected command (default) · `claude agents --cwd "$PWD"` · custom |
| How should the session picker work? | `fzf` / `fzf-tmux` on PATH | fzf with pane preview (default when present) · native `choose-tree -Zs` |

The answers become `@clux-*` options in clux's own file:
`@clux-dir-resolver`, `@clux-editor`, `@clux-agents-command`,
`@clux-picker`. Changing a choice later means re-running `/clux:setup`
or editing the option — never editing a script.

One note the setup must voice, once, when the detected agents command
carries `--allow-dangerously-skip-permissions`: it repeats the flag back
and asks the user to confirm keeping it. Detection makes it the default;
confirmation makes it a choice.

The workspace shape itself — window `---` at index 0 with the editor,
window `claude` at index 1 with the agents dashboard, both names pinned —
ships as the one default shape. That layout is the clux workspace.

## Part 4 — Theming

Colors and glyphs in the bar become `@clux-*` options. `/clux:setup`
already extracts a color palette in its detection phase; it fills the bar
options from that palette, so the bar matches the user's theme. On a bare
machine, readable generic defaults apply. The user's Nord values are what
detection finds on their machine, not what clux ships.

The renderer keeps the `##` escaping, the `#{=24:...}` truncation
decision, and the `\037` row transport for agent state — the fix for the
newline-in-`awk -v` fault found on 2026-08-16. That fault class is why
the renderer must live in clux, tested, and not in each user's config.

## Part 5 — Migration on the author's machine

`/clux:setup` detects the hand-authored versions in
`~/.config/tmux/scripts/` and the wiring in their tmux.conf. It shows a
diff and offers, in one confirmed step:

1. Set the Part 3 options so behavior stays identical (autojump, nvim,
   the detected agents command, fzf).
2. Write `~/.config/clux/clux.tmux.conf` with bindings, hooks, options.
3. Edit tmux.conf: add the source line, replace the session-bar hook
   block and the clux marker block with the two tokens, remove the
   replaced bindings.
4. Copy `@session_order` to `@clux-session-order`.
5. Delete the eight superseded scripts from `~/.config/tmux/scripts/`
   (backup first): session-order, session-list, session-reorder,
   switch-session, session-bar-refresh, fzf-session-switch, new-session,
   new-session-prompt.

The config repo copy (`404pilo/config`) is not touched; committing the
slimmed tmux.conf there stays the user's own step.

## Testing

- The eight scripts are deterministic: bats, with the existing tmux/ps
  stub pattern. Renderer tests include multi-line agent-state input —
  the case that emptied the bar on 2026-08-16.
- The setup skill is not deterministic: test the invariant, per the
  config-updater spec's corpus method — every line clux did not add is
  byte-identical, the source line and each token appear exactly once,
  running setup twice changes nothing, the result parses on a throwaway
  server.
- Live verification on the author's machine after migration: bar renders,
  all keys work, agent glyphs update, order survives a reorder.

## Rollout

Version 3.3.0. The changelog names the new scripts, the new options, the
option renames, and the migration.
