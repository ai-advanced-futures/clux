# Changelog

All notable changes to clux are documented here.

## [3.3.0]

### Added

- **clux now owns the whole session surface, not just the notification bar.** `/clux:setup` can render the session list itself: sessions and their windows in the bar, one agent-state column per session, keys to move between sessions and reorder them, a session picker with a live pane preview, and a key to create a new Claude workspace (an editor window plus a `claude agents` window). Design: `docs/superpowers/specs/2026-08-16-clux-session-surface-design.md`
- Eight new scripts in `scripts/`, all deployed via the new `config/deploy-manifest.txt` (the single list `/clux:setup`, `/clux:validate`, and the tests all read — CHANGELOG 3.0.9 recorded the cost of two hand-written lists drifting apart):
  - `session-order.sh` — the one source of truth for display order (custom order from `@clux-session-order`, else creation order)
  - `session-list.sh` — renders the bar string; reads every `@clux-bar-*` option in one batched `display-message -p` call, joined on `\037` and split on `\037` (never a literal newline through `awk -v` — the exact fault that emptied the bar on 2026-08-16)
  - `session-reorder.sh` — moves the current session left/right in the bar (`prefix + {` / `}`)
  - `switch-session.sh` — jumps to the next/previous session in bar order (`prefix + N` / `P`)
  - `session-bar-refresh.sh` — the single refresh entry point: computes `@clux_session_bar` and `@clux_status` in one invocation, then one `refresh-client -S`. Each token is set only when its renderer exits 0 and prints something, so a renderer that dies leaves the previous value in place instead of blanking the bar
  - `session-picker.sh` — session picker with pane preview (`prefix + g`); `fzf-tmux -p`, else `fzf` inside a popup, else `choose-tree -Zs`, degrading independently of the `@clux-picker` option at run time
  - `new-workspace.sh` / `new-workspace-prompt.sh` — creates a Claude workspace (`prefix + A`): an editor window (`---`) and an agents window (`claude`), addressed by window ID so index/renumbering bugs can't happen
  - Two setup-time-only scripts, deliberately **not** in the deploy manifest since no key, hook, or status line ever calls them: `render-clux-conf.sh` (writes `~/.config/clux/clux.tmux.conf` whole, every run) and `verify-tmux-conf.sh` (parses a candidate config for real on a throwaway `tmux -L` server)
- New key bindings, all in clux's own file: `N` / `P` (next/previous session), `{` / `}` (move session in the bar), `g` (session picker), `A` (new Claude workspace)
- New `@clux-*` options: `@clux-dir-resolver` (`autojump` | `zoxide` | `path`), `@clux-editor`, `@clux-agents-command`, `@clux-picker` (`fzf` | `choose-tree`), `@clux-session-order`, and ten `@clux-bar-*` theming options (`-name-attached-style`, `-name-detached-style`, `-window-active-style`, `-window-inactive-style`, `-bracket-style`, `-separator-style`, `-window-open`, `-window-close`, `-separator`, `-name-length`). `/clux:setup` fills the bar options from the palette it already extracts during detection, and writes a line only for a value it actually found
- `~/.config/clux/clux.tmux.conf`: the one file clux owns outright, rewritten whole on every `/clux:setup` run and every `prefix + r`. Holds the Part 3 answers, the theming lines, the ten key bindings, the refresh hooks (index band 90–99, reserved for clux), and a closing `agent-clear.sh --reap` + `session-bar-refresh.sh` to seed the bar clean. The user's own tmux.conf gets exactly one `source-file -q` line plus two token strings (`#{@clux_session_bar}#(…/session-bar-refresh.sh quiet)` and `#{@clux_status}`) and nothing else
- `get_tmux_option()` and the `@clux-agent-glyph-*` / `@clux-agent-*-color` getters moved down into `path.sh` so `session-list.sh`'s hot path (one render per window switch) never pays `helpers.sh`'s five source-time option reads

### Changed

- **`@session_order` renamed to `@clux-session-order`.** `/clux:setup` migrates a live value with a direct server read-and-set (`tmux show-option -gqv @session_order` → `tmux set-option -g @clux-session-order`, gated on the destination being empty so a second run can never clobber a since-changed order) — nothing is written to any file, and the old option is left set in server memory and reported as a leftover, never unset. At run time `session-order.sh` reads only `@clux-session-order`; there is no legacy fallback
- **`@session_bar` renamed to `@clux_session_bar`** (runtime-rendered string; underscored per the hyphens-for-config / underscores-for-runtime-state rule that now applies to every `@clux-*` option)
- **`setup-tmux-conf.sh` is retired**, replaced by `render-clux-conf.sh` (writes the owned file whole) and `verify-tmux-conf.sh` (verifies it on a throwaway server). `CONTRIBUTING.md`'s file tree updated to match
- `/clux:setup`'s judgement-heavy work (detection, the Part 3 questions, the migration diff) stays inline in `commands/setup.md` for this release rather than moving into a `skills/configuring-tmux/SKILL.md` as the design's Entry Point section describes — see Known issues

### Known issues

- **The setup skill split described in the design's "Entry point" section did not land.** `commands/setup.md` still carries all detection and migration logic inline rather than delegating to `plugins/clux/skills/configuring-tmux/SKILL.md`. Behavior is unaffected; a future pass should extract the skill
- **No bats coverage yet for the eight new scripts.** The design's Testing section calls for one bats file per script plus a `session-list.bats` fixture with real newlines and a `#` in a session name, regression-testing the 2026-08-16 bar-emptying fault. None of that exists yet — the scripts were verified by hand against a throwaway `tmux -L` server, not by an automated suite
- **`configure-tmux.sh` and `validate-setup.sh` are now orphaned.** Neither `commands/setup.md` nor `commands/validate.md` calls them anymore — both commands do their own checks inline — but the two scripts are still shipped in `scripts/` (outside the deploy manifest, so never deployed). They should be deleted or explicitly repurposed in a follow-up
- **`CONTRIBUTING.md`'s file tree is stale beyond the `setup-tmux-conf.sh` → `render-clux-conf.sh`/`verify-tmux-conf.sh` swap.** It still omits `path.sh`, `truncate-title.sh`, `agent-query.sh`, `agent-bar.sh`, `agent-clear.sh`, `config/deploy-manifest.txt`, and all eight new session-surface scripts

## [3.2.0]

### Added

- **Detached `claude agents` sessions now mark the bar.** A dashboard's real work runs in background sessions with no tmux pane, so `hooks/agent-state.sh` used to exit at its `TMUX_PANE` guard and the dashboard's session column stayed blank while its agents worked. The writer now has a second key: with `TMUX`/`TMUX_PANE` unset it reads `session_id` from the hook payload, resolves the owning dashboard pane by `cwd` (`resolve_agents_pane_by_cwd` — the same resolver `prefix+m` trusts), and writes `agents/<pane_id>~<session_id>` under the state dir, one file per agent. The reader joins those files into the dashboard's session, so its column shows `needs-you` if any agent needs you, else `busy` if any is busy, else `finished` when all are finished — the same max-rank roll-up interactive panes use. Design: `docs/superpowers/specs/2026-08-16-clux-detached-agent-state-design.md`
- The expensive `ps -A` dashboard scan runs once per agent session, not once per event: after the first resolve, the pane comes back from the state file's own name. A stale cached pane (tmux restarted) self-heals — the reap that already runs after every write deletes it, and the next event re-resolves
- `resolve_agents_pane_by_cwd()` and `_clux_canon_path()` moved from `helpers.sh` to `path.sh` so the state writer can call them without paying `helpers.sh`'s source-time `get_tmux_option` calls. `helpers.sh` sources `path.sh`, so `notify-tmux.sh` and the jump path are unchanged
- `reap_agent_state_dir()` sweeps `agents/` files whose dashboard pane closed; `agent-clear.sh` clears an agent's `finished` mark when you look at the dashboard's window. `agent-bar.sh`, `hooks.json`, and existing tmux.conf wiring: zero changes

### Known issues

- **An agent killed with no `SessionEnd` leaves its mark** (typically `busy`) until its dashboard pane closes. There is no cheap liveness test for a detached session
- **A fully headless run stays unmarked.** No dashboard means no tmux pane, and the bar has no column to draw it in. This is the feature's designed scope, not a gap the code can close

## [3.1.1]

### Fixed

- **The agent-state bar was always empty.** `scripts/agent-query.sh` required `#{pane_current_command}` to equal the literal string `claude`, but the Claude binary reports its own version string (e.g. `2.1.233`) on many installs, never `claude` — so the guard discarded every pane clux's own hook had just written state for. The reader no longer consults `pane_current_command` at all: the state file is the authoritative signal — it exists only because `hooks/agent-state.sh` wrote it from a real Claude pane, and dead panes are reaped by `reap_agent_state_dir()`
- **`/clux:setup` and `/clux:validate` could not find their own plugin source.** The `find ~/.claude -path "*/clux/scripts/..."` glob never matches the real cache layout `~/.claude/plugins/cache/<marketplace>/clux/<version>/scripts/`. Both commands now prefer `$CLAUDE_PLUGIN_ROOT` and otherwise pick the highest installed version deterministically
- Plugin-source discovery searches `~/.claude/plugins/cache` on its own before the rest of `~/.claude/plugins`. A marketplace source checkout at `marketplaces/<mp>/plugins/clux/` matches the same glob and sorts after `cache`, so one combined search returned that git tree rather than the version Claude Code had loaded — `/clux:validate` then reported false out-of-sync lines and `/clux:setup` deployed from it
- `HOOKS_FILE` is now tested for existence. It is derived from a plugin root resolved through `scripts/show-notification.sh`, so a tree carrying the scripts but not the hooks reported `OK hooks.json found` for a file that was not there, then failed all eight content checks
- README pointed at `~/.claude/plugins/cache/ai-advanced-futures/clux/…`. That path does not exist: the cache segment is the marketplace name (`clux`), not the owner. The four references now use `cache/*/clux/`

### Known issues

- **A reused tmux pane id can show a phantom mark.** State is machine-global, so it outlives a tmux server restart, and `--reap` keeps a file whose id the new server has already handed to a different pane. The bar then marks a pane holding no Claude, and a `busy` or `needs-you` mark clears only when that pane closes. Dropping the `pane_current_command` filter widened this — the filter was never a real guard, but on a colliding id it would have suppressed the phantom when the new pane ran a shell. Stamping the tmux server pid into the state file would close it

## [3.1.0]

### Added

- **Agent state on the tmux status bar.** State lives in files, hooks write those files, the bar only reads. One file per pane under `${XDG_STATE_HOME:-~/.local/state}/clux/agents/`, named for the tmux pane id, holding one word: `busy`, `needs-you` or `finished`. Written by the new `hooks/agent-state.sh` on the four events clux already owns (`UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`) — no new hook event, and no payload parsing except one grep on `Notification`. Per-session roll-up precedence is needs-you > busy > finished > idle
- New scripts: `scripts/agent-query.sh` (prints `session<TAB>state`, for a customised status line), `scripts/agent-bar.sh` (renderer: one reserved column per session, or a compact roll-up), `scripts/agent-clear.sh` (clears `finished` marks for a window, driven by tmux hooks)
- New options, all `@clux-agent-*`: `-state-dir`, `-glyph-busy` (`*`), `-glyph-needs` (`!`), `-glyph-done` (`v`), `-busy-color` (`cyan`), `-needs-color` (`yellow`), `-done-color` (`green`), `-refresh-command` (`refresh-client -S`). Glyph defaults are ASCII because the reserved slot is one column wide and a two-column glyph reflows the bar. There is no idle glyph option — idle is a literal space
- `claude-notify.tmux` registers `after-select-window[90]` and `client-session-changed[90]` so `finished` marks clear when you look at a window. Users who do not load it through tpm must add the two `set-hook` lines by hand (see `/clux:setup`); without them everything still works but `finished` marks never clear on their own
- Nothing in this feature reads or writes the notification queue

### Known issues

- **`needs-you` persists until the end of the turn after you approve a permission.** clux deliberately does not hook `PreToolUse` — it fires on every single tool call, and the cost was not measurable here. Between approving a permission and the turn ending, the bar says needs-you when the agent is in fact busy. It self-heals at the next `Stop` (finished) or the next prompt (busy)

## [3.0.8]

### Fixed

- **`prefix+m` no longer jumps to the wrong project's dashboard.** Three defects compounded into a single symptom: with the agents view open, the jump landed in an unrelated tmux session.
  - **Process snapshot selected the wrong processes on macOS.** 3.0.7 used `ps -eo pid=,ppid=,args=` and described it as portable. It is not: on Linux `-A` and `-e` are synonyms ("`-A`  Select all processes.  Identical to `-e`"), but on BSD/macOS `-e` means *display the environment as well* and only `-A` selects every process. On macOS the resolver therefore saw just the caller's own terminal-attached processes — with environment variables appended to the args column, which the `--cwd` scrape can mis-read. Now `ps -A -ww`. `-ww` additionally disables column truncation: BSD `ps` clips args to 80 columns when stdout is not a tty (i.e. inside a hook), which lands mid-path on a real `claude agents --cwd …` line and leaves the dashboard root a partial directory. Both flags are no-ops on Linux
  - **Dashboard roots were compared as raw strings.** `--cwd` is scraped verbatim from the process args, so `/p/.`, `/p/`, and a symlinked route to `/p` all failed to match `/p` — the longest-prefix match missed and routing fell through to the fallback. Paths are now canonicalized (symlinks resolved when the directory exists, trailing `/` and `/.` stripped otherwise) on both sides of the comparison
  - **A failed match silently guessed.** When re-resolution missed, `agent_jump` dropped into a server-wide `tmux list-panes -a … | head -1`, jumping to whichever dashboard tmux happened to list first. With more than one agents view open that is an arbitrary project, and it is indistinguishable from a correct jump until you have typed into it. A miss *with a known cwd* now reports `clux: no agents view for <dir>` and stays put. Callers with no cwd (bare `prefix+m`) still use the fallback, where guessing is the only option

## [3.0.7]

### Fixed

- **Multi-session routing now detects dashboards by process, not window name.** The 3.0.6 routing only recognized a `claude agents` dashboard if its tmux window was literally named `agents` or its pane advertised the string `claude agents`. On real setups neither holds — dashboards run in project-named windows (`marina`, `vpn`, …) and tmux's `#{pane_current_command}` only ever reports `claude` (never the args). So every jump found no target and fell through to opening a useless new window while the queue entry was cleared. `resolve_agents_pane_by_cwd` now identifies dashboards from the process table (`claude … agents` processes, mapped to their tmux pane via the parent-pid → `pane_pid` chain) and routes the agent's cwd to the longest-prefix dashboard root (its `--cwd`, or the owning pane's path). Window/session names are no longer used for detection. Uses a single portable `ps -eo pid=,ppid=,args=` (no `/proc`, works on Linux and macOS)
- `agent_jump` fast-path no longer requires the embedded pane to be in an `agents`-named window — it routes to the recorded pane id whenever it still exists, otherwise re-resolves by cwd

## [3.0.6]

### Added

- **Multi-session agent-view routing** — `prefix+m` now jumps to the *correct* `claude agents` dashboard when several are open across tmux sessions. The pinging agent's `.cwd` is matched (longest-prefix) against each agents-window pane's `pane_current_path`, then the pane actually running `claude` is targeted. The agents window is identified by its constant name (`@clux-agent-window`, default `agents`) so it works regardless of session name or `automatic-rename` settings. Queue entries gain two `@@`-delimited routing segments after the `|||agent:<session_id>` id (`@@<tmux-session>:<window>:<pane>@@<cwd>`); the status-bar display before `|||` is unchanged. `agent_jump` fast-paths to the embedded pane, re-resolves by cwd if it moved, and falls back to the previous single-window behavior when no routing info is present

### Fixed

- `_agent_remove_entry` now clears both legacy (`|||agent:<id>`) and new routed (`|||agent:<id>@@…`) queue entries; `notification-picker.sh` parses the routed format so picking an entry from the picker jumps and clears correctly

## [3.0.5]

### Fixed

- Repair stale-lock cleanup on Linux: `stat -f` means `--file-system` on GNU stat and "succeeds" with garbage instead of failing, so lock-age detection in `show-notification.sh` and `dismiss-notification.sh` now tries GNU `stat -c %Y` first and falls back to BSD/macOS `stat -f %m`

## [3.0.4]

### Added

- **Agent-view notifications** — clux now surfaces Claude Code "agent view" (`claude agents`) background sessions in the tmux status bar. Detached background sessions (no `$TMUX`) are reached via a direct desktop ping, bridged by a `~/.config/clux/notify-file-path` sidecar so detached hooks can resolve the notify-file path. Queue entries use the `⚡ <label>|||agent:<session_id>` format; `prefix+m` jumps to the agents-view window (configurable via `@clux-agent-window`, default `agents`) and clears the entry on arrival
- `SessionEnd` is now a clux-managed hook — clears agent-view queue entries when a session ends

### Fixed

- `configure-tmux.sh` now deploys `path.sh`. It was missing from the `deploy_scripts()` list even though `show-notification.sh` and `helpers.sh` both `source` it for notify-file resolution, so `/clux:setup` deployed scripts that sourced an absent file — the failed source left `NOTIFY_FILE` empty and the status bar rendered blank. Added `test/configure-deploy.bats` to fail if any deployed script sources a file not in the deploy list

## [3.0.3]

### Added

- `/clux:validate` now reports audio playback readiness: detected player (`afplay`/`paplay`/`pw-play`/`aplay`/`play`/`ffplay`) and, for each sound-enabled notification type, whether the effective sound file exists — surfacing the silent-no-op path introduced in 3.0.2 so users can tell *why* a sound isn't playing

## [3.0.2]

### Fixed

- Cross-platform sound handling: `notify-sound.sh` now detects available players (`afplay` on macOS; `paplay`/`pw-play`/`aplay`/`play`/`ffplay` on Linux) and silently no-ops when none is installed or the configured sound file is missing, instead of flashing `clux: sound file not found: …` over the tmux status bar
- Default sound notifications to `off` on systems with no usable audio player so fresh Linux installs without PulseAudio don't attempt playback
- Provide Linux-appropriate default sound files (freedesktop stereo theme) instead of hardcoded `/System/Library/Sounds/*.aiff` paths

## [3.0.1]

### Added

- `truncate-title.sh` helper for word-aware truncation of window names in status-format strings. Usage: `#(~/.config/clux/scripts/truncate-title.sh 25 "#{window_name}")` — keeps whole words rather than cutting mid-word

## [3.0.0]

### Breaking Changes

- **Remove OpenAI verb-classifier hook** (`rename-window.sh`). Window naming is now handled natively by tmux via `automatic-rename-format '#{pane_title}'`, which picks up Claude Code's OSC-set terminal title. No API key or external service required.
- Remove `CLUX_OPENAI_API_KEY`, `CLUX_OPENAI_MODEL`, `CLUX_OPENAI_TIMEOUT` environment variables
- Remove `@claude-notify-smart-title` tmux option
- Remove `NOTIFY_SMART_TITLE` config variable from `helpers.sh`

### Added

- `configure-tmux.sh` now injects `automatic-rename` + `automatic-rename-format '#{pane_title}'` settings

### Migration

If upgrading from 2.x: remove `CLUX_OPENAI_API_KEY` from your environment and any `@claude-notify-smart-title` settings from tmux.conf. Window names will automatically track Claude Code's task descriptions.

## [2.0.8]

- Add comprehensive health check instructions for `/clux:setup`

## [2.0.7]

- Improve system hook cleanup during setup
- Fix stale hook entries on reinstall

## [2.0.6]

- Internal version bump

## [2.0.5]

- Interactive setup for notification preferences and keybindings

## [2.0.4]

- Route `UserPromptSubmit` events through `notify-tmux.sh` for sound and visual notifications
- Add `notify-sound.sh` for centralized per-notification sound control
- Add per-notification config getters in `helpers.sh`; remove global `play_sound`
- Enhance notification ID parsing logic

## [2.0.2] — [2.0.3]

- Adjust default `status-left-length` to 150 for better display

## [2.0.1]

- Prioritize `status-format[0]` in tmux config
- Change jump-to-notification keybinding from `N` to `m`

## [2.0.0]

- Rename plugin from `tclux` to `clux`
- Simplify session and window parsing in all scripts

## [1.1.1]

- Add verb validation and fallback for smart window renaming
- Refine tmux notification script output

## [1.1.0]

- Add `configure-tmux.sh` for autonomous tmux.conf detection and modification
- Integrate LLM-driven tmux configuration system
- Improve notification command syntax using `#()` in configs

## [1.0.10]

- Refine setup instructions
- Extract and include color palette info in tmux setup

## [1.0.0]

- Initial release: Claude Code hook integration for tmux status bar notifications
- `notify-tmux.sh` hook for `Stop` and `Notification` events
- `show-notification.sh` for tmux status bar display
- `/tclux:setup` autonomous setup command
