# Changelog

All notable changes to clux are documented here.

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
