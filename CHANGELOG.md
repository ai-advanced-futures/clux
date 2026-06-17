# Changelog

All notable changes to clux are documented here.

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
