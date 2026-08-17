# Contributing to clux

Thank you for your interest in contributing to clux — Claude Code tmux notifications!

## How to Report Issues

- **Bugs:** Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) — include your tmux version, bash version, and the output of `/clux:validate`.
- **Feature requests:** Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md).
- **Questions:** Open a plain issue or start a Discussion.

## How to Submit a Pull Request

1. Fork the repository and create a branch from `main`.
2. Make your changes inside `plugins/clux/`. All plugin source files live there.
3. Test locally (see [Local Development](#local-development) below).
4. Open a pull request using the PR template. Keep PRs focused — one change per PR.
5. Describe what changed and why, and note any tmux.conf changes required.

## Local Development

### Plugin structure

```
plugins/clux/
├── .claude-plugin/plugin.json   # Plugin metadata
├── claude-notify.tmux           # tpm entry point
├── commands/                    # Claude Code slash commands
│   ├── setup.md                 # /clux:setup
│   └── validate.md              # /clux:validate
├── hooks/
│   ├── hooks.json               # Auto-registered hooks
│   ├── notify-tmux.sh           # Writes the notification queue
│   └── agent-state.sh           # Writes the per-pane agent-state file
├── scripts/
│   │                            # Libraries — sourced, never executed
│   ├── path.sh                  # Path resolution and the agents-pane resolver
│   ├── helpers.sh               # Shared utilities and config defaults
│   │                            # Notifications
│   ├── show-notification.sh     # Renders the notification token
│   ├── jump-to-notification.sh  # Jump to notifying window
│   ├── dismiss-notification.sh  # Dismiss top notification
│   ├── notification-picker.sh   # Interactive notification picker
│   ├── notify-sound.sh          # Sound playback per notification type
│   ├── truncate-title.sh        # Per-OS safe title truncation
│   │                            # Agent state — readers only, they never write
│   ├── agent-query.sh           # Reads one session's rolled-up agent state
│   ├── agent-bar.sh             # Renders the agent-state column or roll-up
│   ├── agent-clear.sh           # Clears a finished mark; --reap sweeps stale files
│   │                            # Session surface
│   ├── session-order.sh         # The one source of truth for display order
│   ├── session-list.sh          # Renders the bar string (hot path)
│   ├── session-bar-refresh.sh   # The single refresh entry point
│   ├── session-reorder.sh       # Moves a session in the bar
│   ├── switch-session.sh        # Next/previous session in bar order
│   ├── session-picker.sh        # Session picker with pane preview
│   ├── new-workspace.sh         # Creates an editor + agents window pair
│   ├── new-workspace-prompt.sh  # Reads both answers inside a popup
│   │                            # Setup time only — never deployed
│   ├── render-clux-conf.sh      # Writes ~/.config/clux/clux.tmux.conf whole
│   └── verify-tmux-conf.sh      # Parses a candidate config on a throwaway server
├── config/
│   ├── deploy-manifest.txt      # The single list of scripts setup deploys
│   └── tmux-config.yaml         # Default tmux configuration reference
├── docs/
│   ├── setup-guide.md           # User-facing setup guide
│   └── REFERENCE-tmux-setup-strategy.md  # Architecture reference
└── LICENSE
```

`config/deploy-manifest.txt` is the only list of what `/clux:setup` copies into
`~/.config/clux/scripts/`. `/clux:setup`, `/clux:validate`, and the tests all read
it. A new script needs a line there, or `test/deploy-manifest.bats` fails.

### Testing hooks locally

After making changes to hook scripts, test them without Claude Code running.

Hook scripts read JSON from stdin. To simulate a Stop event, write a JSON object with `hook_event_name` set to `"Stop"` and a `message` field, then pipe it to `plugins/clux/hooks/notify-tmux.sh`. Do the same with `"Notification"` for that event type.

After running, inspect the notification queue:

```bash
cat "$HOME/.config/tmux/claude_notification"
```

To check the overall setup, run `/clux:validate` inside Claude Code. It is read-only.

Run the test suite from the repository root:

```bash
bats test/
```

Enable debug logging by setting `CLUX_DEBUG=1` in your environment before invoking any script. Debug output goes to `/tmp/clux.log`.

### Testing show-notification.sh

Append a test entry to the notification queue file manually, then invoke `plugins/clux/scripts/show-notification.sh` to see what the tmux status bar would display. The queue file lives at `$HOME/.config/tmux/claude_notification`.

### Installing locally for end-to-end testing

```bash
# Install from local path (while developing)
claude plugin install ./plugins/clux --scope user

# Reinstall to pick up changes
claude plugin uninstall clux
claude plugin install ./plugins/clux --scope user
```

## Code Style

- Shell scripts use `#!/usr/bin/env bash`
- Prefer `$HOME` over `~` in scripts (more portable)
- Use `"$variable"` (double quotes) for variable expansion
- Keep functions small and single-purpose
- Add comments for non-obvious logic
- Test on both macOS (bash 3.2+) and Linux (bash 4+) where possible

## Version Bumping

Update `plugins/clux/.claude-plugin/plugin.json` version field for any functional change. Follow semver loosely:
- Patch (`2.0.x`): bug fixes, minor tweaks
- Minor (`2.x.0`): new features, new options
- Major (`x.0.0`): breaking changes to hooks, scripts, or config format

## License

By submitting a pull request, you agree that your contribution will be licensed under the [MIT License](plugins/clux/LICENSE).
