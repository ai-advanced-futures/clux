# Changelog

All notable changes to clux are documented here.

## [2.0.8] — Unreleased

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
