# Changelog

All notable changes to clux are documented here.

## [3.2.0]

### Added

- **Self-installing tmux wiring.** The two indexed hooks (`after-select-window[90]`, `client-session-changed[90]`) and the `#{@clux-agent-bar}` status-right segment are now registered against the live tmux server on the first Claude Code hook fire of each version — `/clux:setup` and hand-edited `tmux.conf` lines are no longer required for agent state. Zero bytes are written to any file the user owns; everything is live-server runtime state, gone on a server restart and reinstalled on the next prompt
- New options: `@clux-installed` (version marker that forces a reinstall after an update) and `@clux-agent-bar-unreachable` (set once per version when the segment cannot be reached — see Known limits)
- `@clux-agent-bar` now holds the rendered bar string, so the bar costs one option read per redraw instead of a `#(...)` shell job

### Changed

- `claude-notify.tmux` no longer registers the two hooks itself — one installer (`clux_ensure_installed` in `scripts/path.sh`) owns hook index `[90]`, so a tpm checkout and a plugin install can never point the same index at two different directories

### Fixed

- **A `#` in a session name no longer injects styling into the bar.** `agent-bar.sh`'s roll-up mode now escapes it as `##`, the single correct escape for both the `#(...)` job path (re-expanded once) and the precomputed-option draw path
- **The documented `set -g status-right "#(agent-bar.sh) #{status-right}"` snippet was broken.** tmux expands an option reference exactly one level, so `#{status-right}` was drawn as literal text on the bar. Replaced with `set -ag status-right " #{@clux-agent-bar}"`, labelled for manual/non-plugin installs only
- **The Tier B warning's own `#{@clux-agent-bar}` token was being eaten.** `tmux display-message` expands `#{...}` in its own argument, so the one actionable word in the only warning the user gets was silently deleted. Now escaped as `##{@clux-agent-bar}`
- **The bar segment could be truncated away while install reported success.** The self-install now raises `status-right-length` to fit the segment (never shrinking a value already set larger) instead of leaving the tmux default of 40 in place
- **The `run-shell` hook commands were not shell-quoted.** A plugin path containing a space (a real shape for `${CLAUDE_PLUGIN_ROOT}`) made both indexed hooks exit 127 on every window switch. The installed path is now single-quoted for `sh`
- **`@clux-agent-bar-unreachable` no longer latches for the life of the server.** It is now recorded as the plugin version that hit the obstruction, not a bare `1`, so a version bump re-checks the bar instead of leaving the segment permanently disabled once the obstruction is gone
- **Tier B detection no longer mistakes `status-right-style`/`status-right-length` for a real reference to `status-right`.** The bare substring `status-right` also matches those two sibling options, so a bar built only from them was misclassified as Tier A and the segment was appended to a `status-right` that is never drawn, with install reporting silent success. Detection now matches `status-right}` (the option name immediately followed by the closing format brace), which the sibling options can never contain
- **`/clux:validate`'s self-install checks (`@clux-installed`, `@clux-agent-bar-unreachable`) now find the plugin's own `path.sh` on a real marketplace install.** The lookup pattern assumed `.../clux/scripts/path.sh`, but the marketplace cache nests a version directory in between (`.../clux/clux/<version>/scripts/path.sh`), so it always matched nothing — every healthy install was reported as a stale marker, and the one actionable Tier B warning was silently downgraded to an INFO. The pattern now allows that directory and picks the highest version when more than one cached copy is present

### Known limits

- The segment cannot reach a bar whose `status-format[0]` never references `status-right` — clux says so once per version (via `tmux display-message` and a version-scoped `@clux-agent-bar-unreachable`) instead of silently reporting success

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
