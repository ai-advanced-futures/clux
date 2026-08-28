# Changelog

All notable changes to clux are documented here.

## [3.8.0]

### Added

- **A finished agent now reaches the bar.** The `Stop` hook was registered but dropped on the way: in a `claude agents` workspace `notify-tmux.sh` handled only `Notification`, so `agent-state.sh` painted the green `v` while no notification was ever queued; in a tmux pane the entry was written but `@claude-notify-stop-visual` defaults to `off`. The agents branch now queues `Stop` (marker `✓`, replacing any older `⚡` entry for that session), gated on the same `@claude-notify-stop-visual` option the pane path reads — one answer governs both. The default stays `off`, so nothing changes until `/clux:setup` asks
- **`StopFailure` → a fourth agent state, `failed`.** The turn ended on an API error (`rate_limit`, `overloaded`, `billing_error`, `authentication_failed`, `max_output_tokens`, …) and Claude is stopped — the one case where the user was completely blind: the bar kept showing the busy glyph forever. `agent-state.sh failed` writes it, `agent-query.sh` ranks it above needs-you, `agent-bar.sh` and `session-list.sh` draw it with `@clux-agent-glyph-fail` (`x`) in `@clux-agent-fail-color` (`red`), and `agent-clear.sh` clears it on view like `finished`. `notify-tmux.sh` queues `✗ agents / <name> — Stopped: <error_type>` under a new `failure` notification type, visual and sound **on** by default
- **`Notification` sub-types the agents dashboard emits are handled.** `agent_needs_input`, `elicitation_dialog` and `elicitation_url_dialog` are needs-you (both hooks silently dropped them before); `agent_completed` is finished and follows the `stop` preference; `quota_auto_resume_stale` / `_disabled` are needs-you under a new `quota` type (on by default) and `quota_auto_resume_fired` queues a "Resumed after quota" entry without touching the state
- **`TeammateIdle`** queues an entry under a new `teammate` type, off by default
- **`SessionStart`** (matcher `startup|resume|clear`, never `compact`) runs `agent-state.sh remove`: a Claude restarted in a pane whose last session died without its `SessionEnd` no longer keeps that session's stale glyph until the first prompt. `compact` is excluded on purpose — it fires mid-turn and would blank a busy glyph while Claude is still working
- **`/clux:setup` §3.6 asks about all six types** — notification, stop, failure, quota, prompt, teammate — one AskUserQuestion each, a live value offered back as the first option on a re-run, and only an answer that differs from the shipped default written. `render-clux-conf.sh` gains repeatable `--notify-visual TYPE on|off` / `--notify-sound TYPE on|off` (a type outside the closed set, or a value other than on/off, is refused before anything is written), `--notify-bg` / `--notify-fg`, `--agent-fail-color` and `--agent-glyph-fail`. The preferences therefore land in `clux.tmux.conf`, the one file clux owns — the previous text told setup to write them "inside the user's clux markers", a second file the one-file rule forbids
- `/clux:validate` checks the two new events in `hooks.json`, the `StopFailure:failed` and `SessionStart:remove` pairs, and reports all six preference types

### Fixed

- **A `Notification` clux ignores no longer plays the notification sound.** `notify-tmux.sh` played the sound before it checked the sub-type, so `auth_success` (and now `elicitation_complete` / `_response`) rang the bell. `map_event_to_type()` now takes the sub-type and returns an empty type for one clux ignores; the hook exits before the sound on an empty type

### Internal

- `session-list.sh`'s batched read grows from sixteen fields to eighteen; the two new ones are last so a sixteen-field stub still splits exactly as before
- Every test file gains cases for the new events and the fourth state; `render-clux-conf.bats` covers the new flags and parses a conf carrying them on a real throwaway server. Not covered, because it needs a live `claude agents` dashboard: which session (the dashboard or the agent) actually fires `agent_completed`. Both are handled — the interactive path writes the dashboard pane's own file, the detached path writes the agent's — but the shape of the real payload has not been observed

## [3.7.0]

### Fixed

- **On tmux 3.4 the session bar ignored every `@clux-bar-*` colour and printed the literal text `\037` on the status line.** `session-list.sh` and `session-bar-refresh.sh` each read their options in ONE `tmux display-message -p` call, joining the fields on `\037` so the hot path does not fork `get_tmux_option` sixteen times. tmux 3.4 **escapes control bytes out of that command's output**: a literal `0x1F` comes back as the four characters `\037`. The `IFS` read therefore never split — field 1 swallowed the whole string, every other field came back empty and fell through to its hardcoded default, and the escaped separator leaked onto the bar. Both scripts now join on `U+E001`, a private-use code point that tmux 3.4 passes through byte for byte. tmux 3.7b never escaped it, which is why this went unnoticed
- Not TAB, which also survives 3.4: `session-bar-refresh.sh` cannot use it, because `@clux_bar_tpl` holds `"<epoch><TAB><template>"` and is field 1 of that same read. One separator for both scripts keeps them identical
- The separator is written as octal UTF-8 (`$'\356\200\201'`), never the `\u` dollar-quote form, for the reason already documented for `SENTINEL`: bash 3.2 on macOS mis-parses `$'\ue001'` into six literal characters

### Added

- **`render-clux-conf.sh` takes six new flags: `--agent-busy-color`, `--agent-needs-color`, `--agent-done-color`, `--agent-glyph-busy`, `--agent-glyph-needs`, `--agent-glyph-done`.** They follow the same rule as every `--bar-*` flag: a line is written only for a value the caller actually passed. Before this, a migrated hand-written bar could keep its `@clux-bar-*` palette but not its agent-glyph colours — those had no flag, so they survived only as live server state and reverted to `cyan`/`yellow`/`green` on the next tmux server restart, long after `/clux:setup` ran
- `@clux-agent-glyph-busy-frames` still has no flag, on purpose: its default holds a backslash that needs single-quoting, and an animation cadence is not something detection reads off an old bar

### Changed

- The `configuring-tmux` skill now reads the bar the user **already has** as a colour source, not only the config's `status-style` and `message-style`. It greps a hand-written `session-list.sh` for its `#[fg=…]` / `#[bg=…]` values and reads the live `@clux-agent-*` options, then passes what it found to the new flags. The live options matter most: for the agent colours they are frequently the only copy anywhere

### Internal

- `test/session-list.bats` gains a real-server case asserting that configured `@clux-bar-*` values actually reach the rendered bar. Every other case in that file feeds the batched read through a tmux **stub**, which hands the fields back verbatim — so no stub can catch a tmux build that mangles the separator. Verified to fail on the old `\037` separator and pass on the new one
- `test/session-picker.bats`: the choose-tree fallback case ran with `PATH='<stubs>:/usr/bin:/bin'`, which hides `fzf` only where `fzf` is not in `/usr/bin`. Debian and Ubuntu ship it there via apt, so on those machines `have_fzf()` kept succeeding and the case failed for a reason unrelated to the code. It now builds a PATH holding only the tools the script needs and nothing named `fzf`

## [3.6.0]

### Changed

- **The `prefix + A` workspace popup was restyled and made much shorter.** It was 30% of the terminal height, which grew it to fifteen lines on a tall screen for a two-field prompt, and it drew in plain text. It is now a fixed seven rows at the top-left corner (`-w 62 -h 7 -x 0 -y S`). The `S` position resolves to the line below the bar when `status-position` is `top` and the line above it when it is `bottom`, so the popup follows the bar and clux does not add a second setting for it
- The popup draws in the colours the **bar** was already configured with. A popup is a real terminal, so it cannot use a tmux `#[...]` format; the new `clux_ansi()` helper in `helpers.sh` translates one tmux style string into an ANSI escape. It reads `@clux-bar-name-attached-style`, `@clux-bar-bracket-style`, `@clux-bar-separator-style`, `@clux-bar-window-open`, `@clux-bar-window-close`, and the two agent-state colours. No new option was added: reusing the bar's own options is what keeps the chip in the popup identical to the session chip on the bar, with nothing configured twice
- The rejected-name branch now prints the reason **inside the popup** and waits for a key. The popup covers the status line that `display-message` writes to, so the old message could not be read before `-E` closed the popup. Both are written now, because a caller outside a popup still only sees the `display-message` one. The in-popup line is deliberately short: `-h 7` minus the popup border leaves five rows of sixty columns, and a full sentence wrapped and pushed the header off the top
- The folder prompt states the default it falls back to (`folder  [myws]`). bash 3.2 has no `read -i`, so the default cannot be prefilled, and without it a user has no way to know that Enter alone reuses the name

### Fixed

- **Esc did not cancel the workspace prompt. It printed `^[` and waited.** `read -r` cannot see Esc: in the terminal's canonical mode it is one more character in the line. The terminal is now told that Esc **is** the interrupt character (`stty intr '^['`), so Esc raises SIGINT, the trap exits 0, and tmux closes the popup. No raw mode, and the line keeps its normal editing. A key-by-key raw-mode reader was written first and dropped: on macOS bash 3.2 with tmux 3.7b, any `stty` call after a timed-out raw read hangs, which would leave the popup open forever — worse than the bug. The cost of the chosen fix is that every escape *sequence* starts with Esc, so an arrow key cancels too; telling them apart needs a sub-second wait for the next byte, and bash 3.2 rejects a fractional `read -t`
- **`stty intr` names ONE character, so handing it to Esc TAKES it from Ctrl-C.** Ctrl-C would stop raising SIGINT and land in the line as a literal `\003` — the prompt would keep waiting, and the reject list names no control character, so the workspace would be created under a name carrying one. Ctrl-C is moved onto `quit` (SIGQUIT) and the trap catches both signals, so both keys still cancel; the key `quit` gave up (Ctrl-\\) has no use in a two-field prompt. A terminal that takes `intr` but not `quit` is covered as well: any control character in an answer is read as the cancel the user meant. A terminal that takes neither keeps the old behaviour rather than none — Esc cannot cancel, and Ctrl-C is untouched because `intr` never moved
- The terminal settings are restored on every exit path, including before the closing `exec`. `exec` replaces the process, so the EXIT trap never fires there
- **The popup printed the literal text `\u25b8` instead of a marker.** bash 3.2 — what macOS ships and what runs these scripts — has no `\uXXXX` escape in `printf`. Every such escape is now a literal UTF-8 character in the source
- **`clux_ansi` could print a bash error onto the popup screen.** The hex-colour pattern `\#??????` matched six of *anything*, so a style of `fg=#GGHHII` reached `$((16#GG))` and bash wrote "value too great for base" to stderr. The function is called inside `$( )`, which captures stdout only, so that text landed straight on the screen — the one failure the function exists to prevent. The pattern now demands six hex digits
- **A style term could be replaced by a filename.** `clux_ansi` splits its argument on commas unquoted, which also exposed it to pathname expansion; the popup inherits the pane's working directory, so a file named `fg=red` sitting there made `fg=*` render red. Globbing is off for the loop and restored right after it

### Internal

- `test/new-workspace-prompt.bats` now stages `helpers.sh` and `path.sh` beside the script under test. Without them every staged run printed `get_tmux_option: command not found` into the popup — a real gap that the restyle exposed

## [3.5.0]

### Added

- **The busy glyph moves.** A session with a `busy` Claude shows a small set of
  frames in turn. It no longer shows one character that does not move. You can
  see the difference between "working" and "hung".
- New option `@clux-agent-glyph-busy-frames`. It holds a list of frames,
  separated by spaces. The default is `- \ | /`: four frames, one column each,
  plain ASCII. This follows the width rule the other glyph defaults follow.
- **Write the frames option with single quotes.** tmux removes the backslash
  from a value in double quotes. The value then gives three frames, not four.
  This was tested on tmux 3.7b.
- A moon rotation (`◐ ◓ ◑ ◒`) is an example in `configuring-tmux/SKILL.md`. It
  is not the default. These glyphs have "ambiguous width": one cell in most
  terminals, two cells in a CJK locale.
- Set `@clux-agent-glyph-busy` and do not set `-frames` to keep a glyph that
  does not move. Each existing config keeps its look after an upgrade.
- **`throttle.sh`** — a tool for your own `#()` status jobs. Use
  `throttle.sh <seconds> <command> [args…]`. It keeps the output of a job and
  runs the command again only after `<seconds>`. tmux runs every `#()` job on
  the status line at each redraw. Thus a job costs more when you decrease
  `status-interval` for the animation. clux does not change your jobs. Use this
  tool if you want it.

### Changed

- **`session-bar-refresh.sh` keeps the drawn bar as a template.** Each tick
  replaces one glyph in that template. Before, each redraw did a full render
  with `session-list.sh`, which takes approximately 110 ms. A full render now
  occurs every 5 seconds, or immediately after a hook. A cheap tick takes
  approximately 46 ms.
- **A counter gives the frame, not the clock.** A frame from the clock skips
  frames, because tmux reads the result of a `#()` job again only once each
  `status-interval`, and the two clocks move apart.
- Two new runtime options: `@clux_bar_tpl` holds the template with its time
  stamp, and `@clux_frame_idx[_<client_pid>]` holds the counter. The counter
  has one key for each attached client. Two clients thus do not share one
  counter. `render-clux-conf.sh` clears both options at each load, so a reload
  cannot use a template from before the reload.
- The periodic token takes an argument:
  `#(~/.config/clux/scripts/session-bar-refresh.sh quiet #{client_pid})`. tmux
  runs a `#()` job one time for each attached client that draws the status
  line. The client id lets each client advance only its own counter. The form
  without the argument continues to operate: clux uses one shared counter if
  the id is absent or is not a number. Each 3.3 and 3.4 install thus continues
  to operate.
- **`agent-bar.sh` accepts an optional `--frame N` pair** before its other
  arguments. Without `--frame`, the output is the same as before. The
  standalone-glyph installs in `configuring-tmux/SKILL.md` §3.7 thus keep their
  glyph that does not move.
- **The `status-interval` guidance changes. The CRITICAL RULE does not.** clux
  reports `status-interval` and does not write it in an existing config
  (Mode 2). The busy glyph advances one frame each `status-interval`. Thus `1`
  gives approximately one frame each second, and `2` gives one frame each two
  seconds. With `throttle.sh` around slow jobs, `1` costs approximately 30 ms
  each second. The text before 3.5.0 called `1` "a fork per second for no
  gain". Mode 1 writes `status-interval 1`, which is what `README.md`
  recommends.

### Note

- `status-interval` limits the speed of the animation. The minimum in tmux is 1
  second. `refresh-client -S` runs every `#()` job on the status line again.
  Thus you cannot draw one segment more often than the rest of the bar.
- **Accepted jitter of one frame.** The hook path has no client id. It thus
  reads the shared `@clux_frame_idx`, which a periodic tick for one client does
  not advance. A hook can thus draw the frame at which the shared counter
  stands. The next periodic tick continues the sequence for that client. To
  advance the counter on the hook path was refused: many hooks together would
  move the animation forward too quickly. To use the counter of one client is a
  race. This jitter of one frame, after an action by the user, is the accepted
  cost.

## [3.4.0]

### Fixed

- **Agent state aliased between tmux servers, showing glyphs no one earned and deleting ones that were.** A pane id identifies a pane only *inside* one server — every server numbers its panes from `%0` — but the state store was one directory per `$HOME`, keyed by pane id alone. Two servers therefore shared one namespace. A `busy` Claude on server A drew a busy glyph on server B's `%0` as well (reproduced on tmux 3.7b with two one-pane servers). The other direction lost data: the reaper deleted files whose pane was not live, judged against **its own** server's listing, so any hook firing on B — a prompt typed in the other tmux — deleted A's files and made a Claude waiting for input vanish from A's bar. One server restarting had the same shape, since a fresh server hands out `%0` again; the reaper's own header admitted it could narrow that hole but not close it. State files now live under `<state-dir>/<pid>-<start_time>/`, one directory per tmux server. The pid alone would not have been enough — the kernel recycles pids, which is the same aliasing again — and including the start time is also what makes the key change across a restart, closing the reuse hole. `@clux-agent-state-dir` keeps its meaning as the root, so a user who set it keeps the location they chose. Design: `docs/superpowers/specs/2026-08-17-clux-server-scoped-agent-state-design.md`
- The reaper gained two jobs beside its original one: it collects the directory of a server that has exited (`kill -0` on the pid in the name; a live foreign server is left completely alone, or the collector would become the cross-server deletion it replaces), and it deletes the unscoped files clux <= 3.3.0 wrote. Those legacy names record no server, so they cannot be attributed to one — moving them into the current server's directory would claim them for a server that may never have written them, manufacturing exactly the false glyph this release removes. They are deleted instead, which costs nothing real: the next hook fire rewrites the state that is still true
- Cost of the scoping is one tmux round-trip, in `hooks/agent-state.sh` alone — it must know the key before it writes, and although its own reap fetches a listing further down, six paths between the two can exit early — hoisting would pay for the bigger call on runs that never reach it — and it already made three calls between the reap and the refresh. Every other caller asks for `#{pid}-#{start_time}` inside a `list-panes` format it was already fetching and pays nothing. That includes `agent-query.sh`, which runs once per status redraw per client and is the hottest path in clux
- `/clux:validate` now reports this server's own store and the count of unscoped files left by an older clux, rather than only that the root directory exists — "the root is there but holds nothing of mine" is the state a puzzled user is actually in
- **`prefix + A` could type its own commands into the pane the user was looking at.** `new-workspace.sh` used the window id returned by `new-window` without checking it, and a failed create hands back an EMPTY id — which tmux reads as "the current pane" (`send-keys -t ""` types into whatever is focused, verified). The second create is reachable even on a session tmux DID make: a name holding a `:` parses as `session:window`, so `new-window -t "a:b"` fails with "can't find window: b" while the session itself exists. Both ids are now checked, and a failure reports and exits 1 instead of typing `claude agents …` into the user's work
- **Verifying a config wrote to the user's agent-state store.** `clux.tmux.conf` ends with `run-shell agent-clear.sh --reap`, and `source-file` really does run it, so the reap fired against the throwaway server on every verify — twice per `/clux:setup` run. Server scoping above already stops it from touching a live server's directory, but the legacy sweep would still delete the unscoped files a still-running 3.3.0 server owns. A verification must not write to the user's store at all, so the throwaway server now runs against a scratch `CLUX_AGENT_STATE_DIR` that the script creates and removes
- **A workspace name containing `:` built a workspace nothing could address.** tmux accepts a colon in a session name but reads it as the session/window separator in every *target*, so `prefix + A` typed as `api:v2` produced `has-session -t "=api:v2"` reporting "can't find session: api" (the existing-workspace check therefore never matched), `new-window -t "api:v2"` reporting "can't find window: v2", and `move-window -t "api:v2:0"` failing the same way — a half-built session the user was never switched into. `new-workspace-prompt.sh` now refuses the name up front, which is the only place this can be stopped: every later step is already inside tmux's target syntax
- **`verify-tmux-conf.sh` verified against the user's own tmux config, not against nothing.** The throwaway server was started without `-f`, so tmux loaded `~/.tmux.conf` into it: the previous `clux.tmux.conf` was sourced through that file's own `source-file` line before the candidate was ever read, a plugin-manager line (`run-shell …/tpm`) ran in full on every call — nine of them in the corpus test loop alone — and a candidate that only parsed because the user's file already defined an option verified clean. It now starts with `-f /dev/null` and a named session, so the server carries nothing but the candidate
- **`verify-tmux-conf.sh` could report a broken config as clean.** A fixed `sleep 0.3` stood in for the control client attaching. On a loaded machine the parse ran with no client attached, and `cmdq_error` has nowhere to go without one — the exact failure of the `verify_config()` this script replaced. It now polls `list-clients` until a client is really there and exits non-zero if none arrives, so a silent clean answer can no longer be a lie
- **`session-picker.sh` dropped the "(attached)" label from any session with two or more clients.** `#{session_attached}` is a count of attached clients, not a flag, and it was compared against the literal `1` — so the label went missing in the one case where it matters most

### Known issues

- A store shared between machines over a network filesystem would alias again, because the server key is a pid. `XDG_STATE_HOME` is per-machine and `path.sh` already described the store as per-machine data; that description is now load-bearing rather than incidental

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
- `session-list.sh` reads all sixteen of its `@clux-bar-*` / `@clux-agent-*` options on a **single** `tmux display-message -p` call, `\037`-joined, instead of one `get_tmux_option` fork per option. It sources neither `helpers.sh` nor `path.sh`: this is the hot path — one render per window switch — and it needs nothing from either. Each field reproduces `get_tmux_option()`'s empty-collapses-to-default rule inline

### Changed

- **`@session_order` renamed to `@clux-session-order`.** `/clux:setup` migrates a live value with a direct server read-and-set (`tmux show-option -gqv @session_order` → `tmux set-option -g @clux-session-order`, gated on the destination being empty so a second run can never clobber a since-changed order) — nothing is written to any file, and the old option is left set in server memory and reported as a leftover, never unset. At run time `session-order.sh` reads only `@clux-session-order`; there is no legacy fallback
- **`@session_bar` renamed to `@clux_session_bar`** (runtime-rendered string; underscored per the hyphens-for-config / underscores-for-runtime-state rule that now applies to every `@clux-*` option)
- **`setup-tmux-conf.sh` is retired**, replaced by `render-clux-conf.sh` (writes the owned file whole) and `verify-tmux-conf.sh` (verifies it on a throwaway server). `CONTRIBUTING.md`'s file tree updated to match
- **`/clux:setup` is now an entry point, and the procedure lives in `plugins/clux/skills/configuring-tmux/SKILL.md`** — the split the design's "Entry point" section describes. The whole procedure moved verbatim: the three detection agents, the report, the eight questions, the two install modes, the migration diff, the confirm gate, the apply steps, the verification, and the summary, together with the CRITICAL RULES and both snippets. `commands/setup.md` is 33 lines and states no rule at all, so every rule has exactly one copy — the point of the split, and the reason the command refuses to configure anything if the skill cannot be loaded rather than working from what it remembers. As a skill it also answers "set clux up in my tmux" without the slash command. `test/setup-skill.bats` holds the boundary in both directions: the procedure may not creep back into the command, and the skill may not lose any of nine load-bearing rules or any of the eight phases. All six of its tests fail against the 3.3.0 shape
- **`CONTRIBUTING.md`'s file tree rebuilt from the real directories**, and `test/docs-tree.bats` added to hold it there. It had drifted to two scripts that no longer exist and fourteen missing ones — both libraries, all three agent-state scripts, `truncate-title.sh`, `hooks/agent-state.sh`, and all eight session-surface scripts. Nothing checked it, which is the whole reason it drifted; a tree a contributor cannot trust is worse than no tree, because it reads as authoritative. The new tests check it in both directions against `scripts/` and `hooks/`, and both directions fail against the 3.3.0 text

### Removed

- **`configure-tmux.sh` and `validate-setup.sh` deleted.** Neither command called them anymore — `/clux:setup` and `/clux:validate` both do their own checks inline — and neither was in the deploy manifest, so no install ever held them. They stayed only as a second, silently stale answer to "how do I set clux up": `README.md` and `plugins/clux/docs/setup-guide.md` still pointed users at them. Those three documents now point at `/clux:validate` and `/clux:setup`, and the setup guide says plainly that there is no script-based path, because editing a tmux.conf without losing what it already holds needs judgement
- `test/configure-deploy.bats` deleted with them. Its one load-bearing check — every script sourced by a deployed script must itself be deployed, the closure test that catches the original 3.0.9 fault — is ported into `test/deploy-manifest.bats`, keyed on the manifest instead of on the deleted script's array literal. Verified by removing `path.sh` from the manifest: the ported test names all four scripts that source it. `deploy-manifest.bats` no longer needs its `UNREFERENCED` exemption list

### Fixed

- **`prefix + A` ran arbitrary shell commands typed at its own prompt.** The binding was `command-prompt -p "Session name:" "run-shell '…/new-workspace-prompt.sh \"%1\"'"`, and tmux substitutes a command-prompt answer into its template *before* parsing the template, with no way to escape the substitution. A `"` in the answer closed the shell's quote and everything after it ran: typing `ws" ; touch /tmp/pwned ; "` created `/tmp/pwned` (tmux 3.7b). A `'` instead truncated the name silently, creating the workspace under a different name than the one typed. The folder prompt the script issued had the identical shape and the identical hole, despite being described as the lower-risk value. The reject list inside `new-workspace-prompt.sh` could never have helped — the substitution happens before the script starts. `prefix + A` is now `display-popup -E`, and the script reads both answers itself with `read`, so no user-supplied value reaches a tmux command string on this path. The reject list stays as hygiene against tmux target syntax and the bar format, not as a security boundary. The `"<name>/"` prefill on the folder prompt is gone with the command-prompt (bash 3.2 has no `read -i`); Enter alone now means "same as the session name". `render-clux-conf.bats` asserts the property rather than the one line: no rendered binding may carry a `%1` or a `command-prompt`
- **Every session created with no client attached printed an error.** `session-bar-refresh.sh` ended on `tmux refresh-client -S`, which exits 1 with "no current client" when nothing is attached — the ordinary state at config-load time after `tmux new-session -d`, and on every `session-created[91]` hook fired by a script. The bar was computed and stored correctly; only the redraw failed, and there was nothing to redraw. But the non-zero exit made tmux report `'session-bar-refresh.sh' returned 1` to the next client that attached, which was the first thing a user saw on a fresh detached start. The redraw is now explicitly best-effort and its failure is not the script's
- **`verify-tmux-conf.sh` left one socket file behind per call.** tmux does not unlink a socket when its server exits, and the per-invocation `clux-verify-$$` name (added to remove a race on the shared name) turned one stale file into one per call — a single test run left 175 in the tmux directory. `cleanup()` now removes the file, asking the live server for `#{socket_path}` rather than rebuilding the path by hand
- **`session-list.sh` resolved `agent-query.sh` through a hardcoded `~/.config/clux/scripts` path.** The agent-glyph column silently blanked everywhere clux is not deployed to exactly that directory — running from the plugin tree, and any `render-clux-conf.sh --scripts-dir` install — because a missing `agent-query.sh` is indistinguishable there from "no agent is running". Now resolved through `$CURRENT_DIR`, matching `agent-bar.sh`. `test/session-list.bats` had encoded the defect (its stub wrote to the hardcoded path), so the suite could not catch it; the tests now stage the script in a temp directory with its siblings beside it
- **A dismissed notification stayed on the bar.** `session-bar-refresh.sh` wrote `@clux_status` only when `show-notification.sh` printed something — but printing nothing is that script's normal "nothing pending" path, reached on every dismiss and every jump. The option kept its old value until an unrelated notification replaced it. It is now written whenever the renderer exits 0, empty included. `@clux_session_bar` deliberately keeps the non-empty guard: a running tmux server always has a session to draw, so an empty bar there means a silent failure, not an answer
- `render-clux-conf.sh` created its temp file before the directory it lives in. On a bare machine with no `~/.config/clux`, `mktemp` failed, the fallback path pointed into the same missing directory, and the script exited 1 without ever creating it
- `verify-tmux-conf.sh` leaked one `tail -f /dev/null` process per call — bash 3.2 does not report a process substitution's pid in `$!`, so its own trap could not reap it, and `/clux:setup` left two behind per run. It now holds a fifo open itself and leaves nothing. The tests' `pkill -f 'tail -f /dev/null'` workaround is gone with it; it would equally have killed an unrelated process of the user's

### Known issues

- **Agent state is keyed on pane id, which is only unique per tmux server.** Two servers sharing one state directory alias each other: a `%0` file written by one shows a glyph against the other's `%0`. Observed directly while verifying this release — an unrelated throwaway server drew a `finished` glyph it had never earned. This predates 3.3.0 (the keying is from 3.1.0, and `agent-bar.sh` has the same property), and closing it means putting a server discriminator in the state-file protocol that `hooks/agent-state.sh`, `agent-query.sh`, `agent-clear.sh`, and the detached `agents/<pane>~<sid>` names all share — with a migration for files an older version wrote. Deliberately not folded into this release's fixes. Most users run one server and never see it. **Fixed in 3.4.0**
- **The corpus cannot yet drive a real installer.** `test/corpus.bats` asserts the invariant against fixture pairs (assertion 4 — an installed config differs from its source by clux's additions alone — is checked by stripping those additions and diffing back to the original). But the byte-preserving edit itself is judgement performed by the LLM, now inside `skills/configuring-tmux/SKILL.md`; there is no deterministic script for the corpus to run. The skill boundary at least gives the corpus a named subject, which is what the design's Testing section assumed. When a deterministic edit lands, its test should drive it across every fixture

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
