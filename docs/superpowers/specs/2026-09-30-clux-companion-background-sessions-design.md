# clux companion terminal: background sessions — design

Date: 2026-09-30. Status: written for user review. Target version: 4.1.0 (minor: a new capability; the foreground path does not change).

Base designs: `2026-09-26-clux-companion-terminal-design.md` (3.9.0) and `2026-09-28-clux-companion-laya-guard-design.md` (4.0.0). This document gives only the changes to those designs.

## 1. Goal

Today the companion operates only when Claude Code runs in the foreground of a tmux pane. A background session (`claude --bg`, or a session that a `claude agents` dashboard starts) gets exit code 2 and `clux terminal must run inside tmux`.

After this change, `terminal.sh open` in a background session opens a companion that the user can see and answer. The Laya guard, the verbs, the exit codes and the foreground path stay the same.

## 2. Facts

These facts come from tests on this machine (2026-09-30, Claude Code 2.1.285, tmux 3.7b, macOS).

| Fact | How it was found |
|---|---|
| A background session has no `TMUX` and no `TMUX_PANE`, in its Bash calls and in its hooks. `TERM` is `tmux-256color`, so `TERM` is not a sign of tmux. | `env` in a Bash call of a background session. A probe session (`claude --bg --settings`) with SessionStart and SessionEnd hooks that wrote their environment to a file. |
| The Bash calls and the hooks get `CLAUDE_CODE_SESSION_ID` (a UUID) and `CLAUDE_PID`. The hook stdin `session_id` has the same value as `CLAUDE_CODE_SESSION_ID`. | The same probe. |
| `CLAUDE_PID` is the process of the session (`claude bg-spare …`, a spare process that the session claimed). The hook process is its child. | `ps -o pid,ppid,command`. |
| `SessionEnd` fires on `claude stop <id>`, with `reason: "other"`, the session ID and `CLAUDE_PID`. After the stop, the `CLAUDE_PID` process is gone. | The probe. |
| A background shell can start a private tmux server (`tmux -S <sock> -f /dev/null new-session -d`), type into it, and read it with `capture-pane`. No terminal is necessary. | A test in this session. |
| A background shell can reach the user's default tmux server (`/private/tmp/tmux-501/default`) with plain `tmux`. | `tmux list-sessions`. |
| clux already maps a background session to the pane of its `claude agents` dashboard. The agent-state store has `<state>/<server-key>/agents/%96~<session_id>` for this session, and `resolve_agents_pane_by_cwd` gives `$24 @61 %96` (tmux session `clux`). | `path.sh`, and the store on disk. Design: `2026-08-16-clux-detached-agent-state-design.md`. |
| On macOS, `$TMPDIR` is 49 bytes long. A private socket at `$ROOT/sessions/<full UUID>/sock` is 118 bytes, more than the limit of 100 bytes. With the first 8 characters of the session ID, it is 90 bytes. | Computation with the real `$TMPDIR`. |
| An in-process subagent gets the same `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID` as its parent. This is true in a foreground-style job and in a background session. | A subagent of this session, and a subagent of a probe background session. |
| `/clear` in a background session: `SessionEnd` fires with the old ID and `reason: clear`. Then `SessionStart` fires with a new ID and `source: clear`. The next Bash call gets the new ID. `CLAUDE_PID` does not change. | A probe background session, driven through `claude attach` in a private tmux server. |
| After `/clear`, the job ID (the ID that `claude agents` shows) stays the same, but the session ID changes. They are different values from then on. | The same probe: job `c388b8c3`, session `9a100cbc…`. |
| `claude stop`, then `claude attach`: `SessionEnd` fires (`reason: other`). The session resumes with `source: resume`, the same session ID and a new `CLAUDE_PID`. | The same probe. |
| `kill -9` of the session process (a crash): no `SessionEnd` fires. The dashboard shows `worker crashed … respawning`. | The same probe. |
| The `SessionStart` hook of a background session gets `CLAUDE_ENV_FILE`. A line `export CLUX_SESSION_ID=<id>` that the hook writes there reaches the Bash calls of the session and of its subagents. After `/clear`, the new hook run writes the new ID, and the Bash calls get it. | The same probe. |

## 3. Viability

**Verdict: viable, medium size.** All the blocks are about how the script identifies its owner and where it puts the pane. tmux itself has no block.

What stops the companion today (`plugins/clux/scripts/terminal.sh`):

1. `require_tmux` (line 67) needs `TMUX` and `TMUX_PANE`.
2. `terminal_init` (line 455) makes the private directory name from the tmux server key and `TMUX_PANE`. `--socket` mode also needs both.
3. `terminal_init` calls `resolve_agent_server_key`, which fails when no user tmux server answers.
4. `close --hook` (line 2724) does nothing when `TMUX` is not set, so the `SessionEnd` hook cannot close a background companion.
5. `companion_listing`, `kill_companion` (split arm), `_load_user_patterns` and `split-window -t "$TMUX_PANE"` use plain `tmux`. In a background session, plain `tmux` means the default socket, which can be a different server.
6. `laya status` and `list` look at the server only when `TMUX` is set.

The main risk is not tmux. It is a Laya server that stays after its session. Each server uses 1–2 GB of memory, and `kill -9`, a host crash or `claude daemon stop` gives no `SessionEnd`. Section 9 closes this risk.

Size: about 250 new or changed lines in `terminal.sh`, about 300 lines of tests, the skill, README, CONTRIBUTING and CHANGELOG. The foreground behavior does not change. The foreground tests pass when the test setup unsets the session variables (section 14). [inferred]

## 4. Decisions

The user did not confirm these decisions. They are recommendations.

- **Owner fork.** When `TMUX` and `TMUX_PANE` are both set, the owner is the pane, and all behavior is the same as in 4.0.0. Otherwise the owner is the Claude session, identified by `CLAUDE_CODE_SESSION_ID`. This is the same fork that `hooks/agent-state.sh` makes for detached agents.
- **Placement.** A background companion opens as a new window in the tmux session of the `claude agents` dashboard that owns the Claude session. When there is no dashboard, it opens on a private tmux server, as `--socket` does. `--socket` forces the private server.
- **Watchdog.** `open` starts a small watchdog process for a background companion. The watchdog closes the companion when the Claude session process ends.
- **Version.** 4.1.0.

Alternatives, not selected:

- *A split of the dashboard pane.* One dashboard holds many agents, so the splits would pile up and make the dashboard small.
- *Always a private server.* The user must know the attach line and cannot see the companion in the session bar. For a session that the user does not watch, this is the worst place for a `run? [y/N]` question.
- *A pane that the user names (`open --pane %N`).* Possible later. It needs the user to find a pane ID, and a background session has no normal way to ask.
- *Clean-up only in the `SessionStart` hook.* It helps only when a new session starts later, so a Laya server can stay for hours.

Note: the base design (section 11) put "a new window that attaches to the private socket for the user" out of scope. The window here is different: it is a window on the user's own server, with the companion shell in it. There is no nested attach.

## 5. Owner identity

- `require_tmux` becomes `require_owner`:
  - `TMUX` and `TMUX_PANE` set → pane owner (4.0.0 path).
  - Otherwise, `CLUX_SESSION_ID` or `CLAUDE_CODE_SESSION_ID` set → session owner. `CLUX_SESSION_ID` comes first.
  - Any Claude Code session outside tmux is a session owner, a foreground session in a plain terminal and a background session. [inferred] Before this change, the foreground session in a plain terminal got exit 2. [inferred] The skill and the README text of section 15 speak of both cases. [inferred]
  - `session-env --hook`, `watch` and `close --session` run before `require_owner` in `main()`, as `close --hook` does. [inferred] They find the owner from their own arguments and from `state`, not from `CLAUDE_PID`. [inferred]
  - Otherwise → exit 2, `clux terminal must run inside tmux or in a Claude Code session`.
- The session ID must be 36 characters of `0-9`, `a-f` and `-`, in the UUID form. Other text gives exit 2 and `invalid Claude session id`. The script uses the ID in a path only after this check.
- `CLAUDE_PID` must be a positive integer, and `ps -o lstart= -p "$CLAUDE_PID"` must give a start time. Otherwise exit 2, `cannot identify the Claude session process`.
- Where the ID comes from. `CLAUDE_CODE_SESSION_ID` is not in the Claude Code documentation. The hook stdin field `session_id` and `CLAUDE_ENV_FILE` are. Thus the `SessionStart` hook (which already matches `startup|resume|clear`) gets one more command: `terminal.sh session-env --hook`. It reads `session_id` from stdin and writes `export CLUX_SESSION_ID=<id>` to `CLAUDE_ENV_FILE`. Section 2 shows that this reaches the Bash calls, also after `/clear`. `CLAUDE_CODE_SESSION_ID` stays as the fallback, because it also carried the correct ID in each test. When neither is set, the companion fails with the exit 2 message above: it does not fail open.
- An in-process subagent has the same ID and the same process as its parent, so it uses the same companion (section 2).

## 6. The private directory

- Pane owners: `$ROOT/<server-key>-<pane>` (no change).
- Session owners: `$ROOT/sessions/<short>`, where `<short>` is the first 8 characters of the session ID. After `/clear` this is not the job ID that `claude agents` shows (section 2). The full ID would make the socket path too long (section 2).
- The `sessions` subdirectory is necessary for old copies. The 4.0.0 reaper loop sees `sessions` as one name, `_clux_valid_server_key` refuses it, and the loop skips it. Thus an old deployed script ignores the new directories and does not delete them.
- New fields in `state` for session owners:

| Field | Value |
|---|---|
| `session` | The full session ID. Each verb compares it with the owner ID of section 5 (`CLUX_SESSION_ID`, else `CLAUDE_CODE_SESSION_ID`). [inferred] When two sessions have the same `<short>` and the other owner is alive, `open` exits 2 with `the companion directory belongs to another session`. On the same mismatch, `run`, `send`, `read`, `wait` and `close` exit 4 (`no companion is open for this owner`) and touch nothing. [inferred] |
| `owner_pid` | `CLAUDE_PID` when `open` ran. |
| `owner_start` | `ps -o lstart=` of `owner_pid`, with the spaces at the end removed (`rtrim`) before it is stored and before each compare. On macOS, `ps` adds spaces at the end. A pid alone can repeat. |
| `server` | Window mode: the `#{pid}-#{start_time}` key of the user's server. |
| `watch_pid` | The pid of the watchdog. |

- `mode` gets a third value, `window`. In window mode, `socket` holds the `#{socket_path}` of the user's server.
- `write_state` writes all the session-owner fields (`session`, `owner_pid`, `owner_start`, `server`, `watch_pid`) on each call, also for the `seq` rewrite in `run` and for the rewrite in `laya_restart_if_down`. [inferred] It writes to a temporary file in the same directory and then renames it to `state`, so a reader never sees a half-written file. [inferred] The comment above `write_state` (`seq is the only field that changes after open`) changes to say this. [inferred]

## 7. Placement

`open` for a session owner follows these steps:

1. **Find the dashboard.** Get the key of the default server (`tmux display-message -p '#{pid}-#{start_time}'`). When the default server does not answer, go to step 3: a session owner does not need the server key, so this does not fail as `terminal_init` does today (section 3, item 3). Look for `<agent-state>/<key>/agents/*~<session_id>`. The `agent-state.sh` hook writes this file at the first prompt, so it is there before the first Bash call. When it is not there, call `resolve_agents_pane_by_cwd "$PWD"`. Then make sure that the pane still exists.
2. **Dashboard found → window mode.** On the user's server: `tmux -S <socket> new-window -d -P -F '#{pane_id}' -t '<tmux session of the pane>:' -n 'clux-terminal <short>' … <shell>`. `-d` keeps the focus of the user where it is. Add `-c "$PWD"` (the directory of the Bash call), so the shell starts in the same directory as in socket mode. [inferred] Set `automatic-rename off` on that window, so the clux window rename does not change its name. [inferred]
3. **No dashboard, or `--socket` → socket mode.** The same private server as the 4.0.0 `--socket` mode, at `$ROOT/sessions/<short>/sock`.
4. **No tmux binary → exit 2** (`tmux is required`), as today.

`--size` does not apply to window mode or socket mode. It gives no error. [inferred]

## 8. tmux calls and the pane identity

- **Always `-S` for session owners.** There is no `$TMUX`, so plain `tmux` can go to a different server. `tmux_state` uses `tmux -S "$S_SOCKET"` in `socket` and `window` mode. `companion_listing`, the user pattern option (`@clux-terminal-patterns`) and the reaper use the same socket.
- **User patterns.** Window mode reads `@clux-terminal-patterns` from the user's server. Socket mode reads it from the default server when that server answers. Otherwise no user patterns apply. [inferred]
- **Pane identity.** A pane ID is unique only in one server, and a restarted server starts again at `%0`. The directory of a session owner does not contain the server key, so a stale `pane=%5` could name a pane of the user. Thus, for a session owner only (`window` and `socket` mode):
  - `open` sets the pane option `@clux-companion` to the prompt token (`tmux set-option -p`, tmux 3.2 and later).
  - `current_companion_alive` reads `#{@clux-companion}` of `S_PANE` on `S_SOCKET` and compares it with `S_TOKEN`. For a session owner, this takes the place of `list-panes -t` and costs the same single tmux call. When the value is different, the companion is gone.
  - `kill_companion` makes the same check before it kills a pane.
  - `split` mode keeps `list-panes -t` and has no check, because its directory name already holds the server key. The foreground path does not change.
- **`kill_companion` gets a third arm:**

```bash
window)
    # The user's own server: kill the companion pane (its window closes with
    # it), never the server. The identity check stops a stale pane id from
    # naming a pane of the user after a server restart.
    [ -z "$socket" ] || [ -z "$pane" ] || ! companion_pane_is_ours "$socket" "$pane" \
        || tmux -S "$socket" kill-pane -t "$pane" >/dev/null 2>&1 || true ;;
```

The comment above `kill_companion` must also say that the `window` arm never uses `kill-server`.

## 9. Lifetime

### Open

- `open` runs the reaper (next subsection), then makes the directory, the Laya server and the pane in the 4.0.0 order.
- For a session owner, `open` writes a first `state` (`session`, `owner_pid`, `owner_start`, `laya_pid`) at once after `laya_start_server`, before it makes the pane. [inferred] The write uses the atomic write of section 6. [inferred] Thus a directory that has a Laya server always has a record of its Laya pid, also when `open` stops early (a Bash tool timeout or a `kill`). [inferred] The later `write_state` calls add `pane`, `mode`, `socket`, `server` and `watch_pid`. [inferred]
- After the prompt is ready, `open` starts the watchdog. `open` writes `watch_pid` to `state`.
- `open` on a live companion (the 4.0.0 re-use path, after `laya_restart_if_down`) also checks `watch_pid`. When that process is gone, `open` starts a new watchdog and writes its pid.

### The watchdog

- A hidden verb: `terminal.sh watch --session <short>`. `open` starts it with `nohup`, stdin and stdout to `/dev/null`, file descriptor 3 closed, and `trap '' HUP INT`. The end of the Bash call does not stop it.
- Each 10 seconds it reads `state` (the atomic write of section 6 means that it never reads a half-written file): [inferred]
  - No `state`, or a different `watch_pid` → exit (a `close` or a new `open` came first).
  - `owner_pid` is gone, or its `lstart` is different from `owner_start` → run the close steps for this directory (`sessions/<short>`) with the internal close function, then exit. [inferred]
- Cost: one `sleep` and one `ps` each 10 seconds. It never reads the Laya key.
- Known effect: when the session restarts on a new host process, `CLAUDE_PID` changes. After `claude stop` the `SessionEnd` hook closes the companion. After a crash the watchdog closes it. In both cases the next `open` makes a new one. The skill tells Claude to run `open` again after exit code 4.

### Close

- `close` for a session owner: the 4.0.0 steps, then it stops the watchdog (when the caller is not the watchdog).
- New option: `close --session <id>`. It closes the companion of that session. It is for internal use and is not in the skill. [inferred] The hook uses it. The watchdog does not call the verb: it calls the internal close function for its own directory, because the owner process is already gone and `require_owner` would fail. [inferred]
- `close --hook`: when `TMUX` is not set, read `session_id` from the stdin JSON with parameter expansion (as `agent-state.sh` does), check the UUID form, then close that companion. The server stops in a separate process (`laya_stop_server_later`), because the hook has 5 seconds. The hook still exits 0 in all cases and prints nothing.
- `/clear` in a background session: `SessionEnd` with `reason: clear` fires with the old ID and closes the companion, the same as in the foreground.

### The reaper

A new loop over `$ROOT/sessions/*`, after the 4.0.0 loop. It does not depend on the listing of the default server: it runs also when that listing is empty, so `reap_companions` does not return early before it. [inferred] `stop_reaped_servers` runs after both loops. [inferred] The loop runs for both owner kinds, and rule 3 below applies only when the caller is a session owner. [inferred] It removes a directory when:

- the `owner_pid` in its `state` is gone, or has a different start time, or
- the companion pane fails the identity check (section 8), or
- the owner process is the process of the caller (`CLAUDE_PID` and its start time), but the session ID is different. One Claude process runs one session at a time, so this is a companion left from a `/clear` whose `SessionEnd` hook did not run. Without this rule, it and its Laya server stay until the process ends.

It skips a directory that has no `state` yet, or whose pane has no `@clux-companion` mark yet, while the directory is younger than the `open` time budget. [inferred] The budget is a new constant, `OPEN_BUDGET_DEFAULT=120` seconds, in `terminal.sh`. [inferred] It is more than the longest `open` steps (`laya_wait_ready` and `wait_for_prompt 5`). [inferred] The age of a directory is the time now minus its modification time, read with `stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir"` (the same method as `dismiss-notification.sh`). [inferred] `open` makes the directory and starts the Laya server before it sets the mark, so a second `open` must not delete this half-made directory. [inferred] A directory with no `state` that is older than this budget is removed. [inferred] Such a directory has no Laya server, because `open` writes the first `state` (see Open) straight after `laya_start_server`. [inferred] A directory that has `state` (with `owner_pid`, `owner_start` and `laya_pid`) but no pane follows the normal rules above: when its owner is gone, its Laya pid goes to `REAP_PIDS`. [inferred] It never touches a directory whose owner is alive and whose pane is alive. It adds the Laya pid to `REAP_PIDS`, as the 4.0.0 reaper does. The watchdog makes this loop a second line of defense, not the main one.

## 10. What the user sees

`report_open` prints, for each mode:

| Mode | Lines |
|---|---|
| `split` | `pane=`, `mode=split` (no change) |
| `window` | `pane=`, `mode=window`, `window=<tmux session name>:<window index>` |
| `socket` | `pane=`, `mode=socket`, `attach=tmux -S <sock> attach` (no change), and `attach_in_tmux=TMUX= tmux -S <sock> attach` |

The second attach line is necessary because tmux refuses an attach from inside tmux when `TMUX` is set. The skill tells Claude to give the user the `window=` line or both attach lines.

Phase 2 (not in 4.1.0, one line to add later): when `run` waits for a Laya question or a credential prompt, write `needs-you` for this session to the agent-state store, so that the dashboard column shows it. The writer exists (`hooks/agent-state.sh`).

## 11. Changes by verb

| Verb | Change |
|---|---|
| `open` | Owner fork, placement (section 7), pane option, watchdog. |
| `run`, `send`, `read`, `wait` | Only `terminal_init` and `tmux_state`. The Laya gate, the output guard and the exit codes do not change. |
| `close` | `--session <id>`; the `window` arm; stops the watchdog; `--hook` with no `TMUX`. |
| `list` | Also lists `$ROOT/sessions/*`: `owner=sessions/<short> mode=<m> pane=<p> state=alive|gone`. |
| `laya status` | `server=` also for a session owner. |
| `watch` | New, hidden. Not in the skill. |
| `session-env --hook` | New, hidden. The `SessionStart` hook runs it (section 5). It prints nothing and exits 0 in all cases. |

## 12. New messages

| Code | Message | When |
|---|---|---|
| 2 | `clux terminal must run inside tmux or in a Claude Code session` | No tmux owner and no session ID. Takes the place of `clux terminal must run inside tmux`. |
| 2 | `invalid Claude session id` | The ID is not in the UUID form. |
| 2 | `cannot identify the Claude session process` | `CLAUDE_PID` is missing, or `ps` does not know it. |
| 2 | `the companion directory belongs to another session` | The first 8 characters are the same as those of a live session. |

## 13. Results of the open questions

These questions were open in the first version of this document. Tests on 2026-09-30 answered them.

| Question | Result | Effect on the design |
|---|---|---|
| Do subagents get the same session ID? | Yes, for in-process subagents, and the same `CLAUDE_PID`. | One companion for a session and its subagents, as in the foreground. No change. |
| After `/clear`, do the Bash calls get the new ID? | Yes. `CLAUDE_PID` stays the same. | The `SessionEnd` hook closes the old companion. A new reaper rule (section 9) closes it when the hook did not run. |
| Can the ID come from a documented source? | Yes: `CLAUDE_ENV_FILE` from the `SessionStart` hook. | `CLUX_SESSION_ID` first, `CLAUDE_CODE_SESSION_ID` as fallback (section 5). |
| Does a crash give `SessionEnd`? | No. | The watchdog is necessary. It is not only a second line of defense. |
| `claude stop` then `claude attach`? | `SessionEnd` fires. The session resumes with the same ID and a new `CLAUDE_PID`. | The hook closes the companion. The next `open` makes a new one. |
| `claude daemon stop --keep-workers`: does the session process stay alive? | Not tested. The test stops the supervisor of all background sessions of the user, and some of them were at work. | None expected: while the process stays alive, the watchdog keeps the companion. Test it on a machine with no other background sessions. |
| A dashboard on a server that is not the default (`tmux -L name`). | From the code: `resolve_agents_pane_by_cwd` and the server key read only the default server. | Socket mode. A known limit (section 16). |
| The `claude agents` view outside tmux. | Not tested. With no dashboard pane, the lookup finds nothing. | Socket mode with both attach lines. |

### The prototype

`2026-09-30-clux-companion-background-sessions-prototype/` holds `bgc.sh` (the owner identity, the private directory, the dashboard lookup, window and socket placement, the pane marker, the watchdog, `close` and `close --hook`, the reaper) and `test.sh`. The prototype has no Laya and no gate: those parts do not change. `test.sh` sets `TMUX_TMPDIR` to a private folder, so it never touches the user's tmux, and it unsets `TMUX` and `TMUX_PANE`. Result: 22 of 22 checks pass (tmux 3.7b, macOS):

- A: window mode in the dashboard session; the window keeps its name; typing works; `open` again re-uses the pane; `close` removes the window only; the watchdog ends after `close`.
- B: no dashboard gives socket mode and both attach lines; typing works.
- C: `kill -9` of the owner process; the watchdog removes the directory and the window.
- D: `close --hook` with a JSON payload and no `TMUX` closes the companion; a bad `session_id` does nothing and exits 0.
- E: after a `/clear` with no hook, a verb under the new ID gets exit 4 and does not touch the old pane; `open` under the new ID closes the old companion.
- F: after a server restart, a user pane gets the old pane ID; `run` gets exit 4, types nothing, and `close` does not kill that pane.
- G: the socket path under the real macOS `TMPDIR` is 90 bytes.

## 14. Tests

### `test/terminal.bats` (stub tmux)

- With `TMUX` and `TMUX_PANE` set, all tests of 4.0.0 pass. The test setup unsets `CLAUDE_CODE_SESSION_ID`, `CLUX_SESSION_ID` and `CLAUDE_PID`, because a run from a Claude Code Bash call inherits them. [inferred] The test `tmux verbs refuse outside tmux while hook close is silent` (`test/terminal.bats`) also unsets them and expects the new message of section 12. [inferred]
- The unit tests of a session owner put a `ps` on `PATH` that answers `-o lstart=` (the real `/bin/ps`, or a stub that answers), because the committed `ps` stub prints nothing. [inferred]
- After `run`, `state` still has `watch_pid` and `owner_start`. [inferred]
- With `TMUX` unset and `CLAUDE_CODE_SESSION_ID` set: `D` is `$ROOT/sessions/<short>`; `state` has `session`, `owner_pid`, `owner_start`.
- A bad ID, a missing ID and a bad `CLAUDE_PID` give the section 12 messages and exit 2.
- The `window` arm of `kill_companion` never calls `kill-server`. It does not kill a pane whose `@clux-companion` differs.
- `close --hook` with a JSON payload on stdin and no `TMUX` removes the session directory. With a bad `session_id` it does nothing and exits 0.
- The 4.0.0 reaper loop skips `$ROOT/sessions`.
- The sessions reaper removes a directory whose `owner_pid` is a `sleep` that the test killed. It keeps one whose `sleep` runs.
- A directory that has the owner fields and a `laya_pid` but no pane, and whose owner is dead, has its Laya pid in `REAP_PIDS`. [inferred] A directory with no `state` that is younger than `OPEN_BUDGET_DEFAULT` is kept, and one that is older is removed. [inferred]
- After `laya_start_server` and before the pane exists, `open` has already written `state` with `laya_pid`. [inferred]
- The socket path of a session owner under a 49-byte `TMPDIR` is at most 100 bytes.

### `test/terminal-e2e.bats` (real tmux)

Each test sets `TMUX_TMPDIR` to its own directory, so the "default server" is a test server. It unsets `TMUX`, `TMUX_PANE` and `CLUX_SESSION_ID`, sets `CLAUDE_CODE_SESSION_ID`, and sets `CLAUDE_PID` to a `sleep` that the test owns. [inferred] It unsets `CLUX_SESSION_ID` because section 5 reads that variable first, and a run from a Claude Code Bash call inherits the real value after 4.1.0 is deployed. [inferred] Test 5 changes the ID through `CLUX_SESSION_ID`, the variable that section 5 reads first. [inferred]

1. A test session with a pane and a cache file `agents/%P~<id>` → `open` gives `mode=window` and a new window in that session. `run -- 'echo hi'` gives `hi` and `exit=0`. `run -- pwd` gives the directory of the caller. [inferred] `close` removes the window and not the session.
2. No cache file and no dashboard → `mode=socket` and both attach lines.
3. Kill the `sleep` → within 15 seconds the watchdog removes the directory, the window and the Laya server.
4. Restart the test server, make a pane with the same ID as the old companion pane → `run` gives exit 4, and nothing goes to that pane. `close` does not kill it.
5. `/clear` with no hook: a verb under the new ID gets exit 4; `open` under the new ID closes the old companion (prototype test E).
6. `cd /tmp` then `export X=1` with `run`, then `run -- 'pwd; echo $X'` → `/tmp`, `1` (the 4.0.0 persistence rules, in window mode).

### Live check (by hand, once)

Start `claude --bg` from a `claude agents` dashboard in tmux, ask for `/clux:terminal`, run one plain command and one dangerous command, answer `y` in the window, then `claude stop <id>`. Expect: the window and the Laya server are gone within 5 seconds.

## 15. Skill and document changes

- `hooks/hooks.json`: the `SessionStart` entry gets `terminal.sh session-env --hook` (section 5).
- `skills/terminal/SKILL.md`: the "refuses to operate outside tmux" line changes. New text: in a background session, `open` opens a window in the tmux session of the dashboard, or a private server; give the user the `window=` line or the attach lines; exit code 4 after the session restarts means "use `open` again". Snippet S1 does not change.
- `README.md`: the companion section gets a "Background sessions" paragraph.
- `CONTRIBUTING.md`: no new file, so the file tree does not change.
- `CHANGELOG.md`: 4.1.0.
- `plugins/clux/.claude-plugin/plugin.json`: `version` 4.1.0.

## 16. Out of scope

- Cloud sessions and Remote Control sessions on another machine. They have no local tmux.
- `open --pane %N` (a pane that the user names).
- The phase 2 `needs-you` mark (section 10).
- A dashboard on a tmux server that is not the default one (section 13, item 4).
- Keeping the companion when a session restarts on a new host process.
