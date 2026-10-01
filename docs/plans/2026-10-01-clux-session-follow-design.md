# clux Mirror Mode (`/clux:follow`) Design

**Goal:** Let two or more terminals that are attached to one tmux server always show the same session. When one terminal changes session, the others go with it.

**Use case:** Two computers connect with SSH to one remote machine and attach to the same tmux server. tmux already mirrors the windows inside one session. It does not mirror a session change: `switch-client` moves only the client that ran it.

**Tech stack:** Bash 3.2, tmux 3.2+, Bats 1.5+.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Mode | Mirror: no leader | The request is "both always see the same screen". Claude cannot know which client the user typed in, so a leader needs a selection step |
| Control | `/clux:follow [on\|off\|status]` | The user turns it on and off from Claude Code. With no argument the command shows the sessions and the clients and asks |
| State | The hook `client-session-changed[92]` is the state | `on` sets it, `off` removes it. No option can disagree with the hook, and mirror mode costs nothing while it is off |
| Setup | No change to `render-clux-conf.sh` or to `/clux:setup` | The hook is runtime state. A new tmux server starts with mirror mode off |
| Default | Off | A user with two sessions in two terminals does not expect them to move together |
| Control-mode clients | They follow | An exclusion is possible later with `#{client_control_mode}` |

## Parts

- `plugins/clux/scripts/session-follow.sh`: `status`, `on`, `off`, `sync <client>`. It is in the deploy manifest.
- `plugins/clux/commands/follow.md`: the command. It finds the script (the deployed copy first) and runs it.
- `test/session-follow.bats`: real tmux on a private socket, with control-mode clients.

## The two tmux facts that make a loop

Both were seen on tmux 3.5a with a first version, a one-line hook.

1. `client-session-changed` also fires when a client switches to the session that it is on already. A hook that switches all clients fires again for each of them, with no end.
2. A format in the hook line (`#{session_name}`) gives the old session for a client that the hook moved. The clients then go back and forth.

`sync` avoids both. It reads the session of the client when it runs (`display-message -p -c <client>`), and it moves only the clients that are on a different session. The second pass finds nothing to move.

## Rules that came from review

- **Session ids, not names.** `sync` reads, compares and targets `#{session_id}`. tmux reads the name `a.c` as window `a` pane `c`, `a:c` as session `a` window `c`, and `%2` and `$9` as ids.
- **The hook line quotes the script path three times:** for sh (single quotes), for `run-shell` (`#` becomes `##`) and for the tmux parser (`\`, `"` and `$` get a backslash). `set-hook` takes the command as one string, so no layer can be left out.
- **The hook has a full lifecycle.** `on` sets it, `off` removes it, and it removes itself when its script is gone.

## Behaviour to know

- An attach is a session change for tmux. A terminal that attaches to session `x` moves the others to `x`.
- `on` brings the clients to the session of the client that was used last (`#{client_activity}`).
- Terminals of different sizes: tmux uses the size of the client that was used last (`window-size latest`).

## Verification

- `bats test/session-follow.bats` on tmux 3.7b (macOS).
- The loop test fails when the difference test is removed from `sync`.
- A run of the same steps on tmux 3.5a (Linux), the version of the remote machine in the use case.
