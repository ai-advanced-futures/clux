# Changelog

All notable changes to clux are documented here.

## [4.5.1]

### Removed

- The sessions pane no longer plays a sound when a background session needs input. The toast and the `needs input` count in the footer stay. The file `sounds/needs-input.wav` is gone. The tmux notification sounds (`@claude-notify-*-sound`) do not change

## [4.5.0]

### Added

- **The background sessions pane: `/clux:sessions`.** One pane for the background sessions of the current repository. Each row shows the name, the status (needs input, working, unknown, done, failed, stopped), the PRs as links, and the description: the question of a session that needs input, else what the session does now or the result it gave. `/clux:sessions` toggles the pane; `/clux:sessions on` and `/clux:sessions off` set it
- `ctrl+x b` toggles the pane from anywhere, also with a draft in the composer. No Claude Code action runs a plugin command, so the footer's `sessions` label and the pane's **Hide** button take the `app:cycleDiffBase` action, which Claude Code uses only in the diff panel
- Select a row (its number `1` to `9`, or Tab and Enter) to open that session: `claude attach <id>` in a new window of the current tmux session, or the command on the clipboard outside tmux
- clux draws nothing above the prompt. A dim `sessions` label at the right end of the prompt footer opens the pane, and shows the count when a session needs input (`1 needs input`). When a session writes `needs input:`, a toast shows its question and a sound plays (`afplay`, `paplay`, `pw-play`, `aplay` or `play`), one time for each new question, also a second question from the same session
- clux reads `~/.claude/jobs/*/state.json` every 5 seconds, one poll at a time. A session counts when its folder or its worktree is under the main working tree, or under a worktree that `git worktree list` names. A working session with no write for 30 minutes, or a state clux does not know, shows as unknown
- The pane is the first function-hooks module of clux (`hooks/sessions/register.tsx`, listed under `modules` in `hooks/hooks.json`). It needs Claude Code 2.1.291 or later. On an older Claude Code, `/clux:sessions` says that the pane did not load

## [4.4.1]

### Changed

- A notification from a `claude agents` session now starts with the name of the tmux window that holds the agents view, for example `plugins / pr-flow-implementation`. Before, it always started with `agents /`. When clux cannot find the window, the prefix stays `agents`
- The status bar shows a `#` in a window or session name as plain text. Before, tmux read `#[...]` in a name as a style and `#{...}` as a format

## [4.4.0]

### Added

- **`/clux:upgrade`** installs the installed plugin version into tmux with the answers of the last `/clux:setup`, and asks no questions. Run it after each plugin update, in place of `/clux:setup`
- First it compares the installed version with the latest version of the marketplace (`plugin-version.sh`). When a newer version is available, it gives the `claude plugin marketplace update` and `claude plugin update` commands and stops. When the update ran and Claude Code did not restart, it upgrades and tells you to restart
- `render-clux-conf.sh --from FILE` reads the answers back out of a `clux.tmux.conf` that it wrote before, with the same option table that writes them. A flag after `--from` overrides the value it read. A setting that this version does not write is reported as `dropped:`, and a new setting gets its default. When a required answer is missing, it prints one `missing: --<flag>` line for each
- `upgrade-clux.sh` renders with `--from` first, so a render failure changes nothing. Then it backs up the file, deploys the scripts from the manifest, puts the new file in place, verifies it on a throwaway server and reloads it. When a later step fails, the backup goes back in place
- `plugin-version.sh` reads the installed version from `claude plugin list --json` (the plugin cache when there is no CLI), and the latest version from the clux entry of the marketplace
- It asks a question only when the old file has no value for a required answer. It does not change the tmux.conf or `~/.claude/settings.json`. When the tmux.conf has no clux line or no token, it reports this and offers `/clux:setup`

## [4.3.0]

### Added

- **prefix + A shows the saved workspaces.** Each time prefix + A opens a workspace, clux saves its name and its absolute folder on top of a list (`workspace-history.sh`, in `${XDG_STATE_HOME:-~/.local/state}/clux/workspaces`, mode 0600). The list keeps 9 workspaces, newest first. When the list is not empty, the popup shows it before it asks for a name. A `●` mark shows a live session, and a `✗` mark shows a folder that is gone
- The keys of the list: `1`-`9` open that row at once. `j` and `k` move the selection, and Enter opens the selected row. Space sets the folder of the row (with the same rules as a new workspace). `x` deletes the row. `n` goes to the name prompt. `q`, Esc and Ctrl-C cancel. Another letter or digit starts a new name with that character
- To open a row: a live session gets a switch, and a gone session is made again in its saved folder. When the session of a row is gone and a live session that is not in the list has the same folder (a session that prefix + $ renamed), the client switches to that session and the row takes its name
- **`a` opens all saved workspaces** that are not live and have their folder, after a `y/n` question. They open in the background (`new-workspace.sh --restore`), and the list keeps its order. After a restart of the tmux server, this makes the workspaces again
- `new-workspace.sh --resolve <folder>` prints the absolute folder of a name and makes nothing

### Changed

- **The agents window of a workspace has the name `<workspace>-claude`** (it was the name of the workspace). For a workspace `olly`, the windows are `---` and `olly-claude`
- The prefix + A popup is 15 rows high (it was 7), so that the 9 rows of the list fit. Run `/clux:setup` again to write the new binding. With an old binding, the list shows the rows that fit and moves with the selection
- `new-workspace.sh` switches to an existing session with an exact target (`=name`)

## [4.2.0]

### Added

- **Mirror mode: `/clux:follow`.** With mirror mode on, all clients of the tmux server show the same session. When one client changes session, the others go with it. This is for two or more terminals that are attached to one tmux server, for example two computers that connect to one remote machine. `/clux:follow` shows the state, the sessions and the clients and asks; `/clux:follow on`, `off` and `status` do not ask
- `scripts/session-follow.sh` (`status`, `on`, `off`, `sync <client>`), in the deploy manifest. `on` sets the hook `client-session-changed[92]` and `off` removes it, so the hook is the state: there is no option, the rendered `clux.tmux.conf` does not change, and a new tmux server starts with mirror mode off
- `sync` moves only the clients that are on a different session, and reads the session of the client when it runs. tmux 3.5a also fires `client-session-changed` for a switch to the same session, and gives the old session in a hook format for a client that the hook moved; each one made an endless loop in a first version
- `sync` reads, compares and targets a session by its id. A session name is not a safe tmux target: `a.c`, `a:c`, `%2` and `$9` each mean something else to tmux
- The hook line quotes the path of the script for sh, for `run-shell` and for the tmux parser. A hook whose script is gone removes itself at the next session change and shows a message, so the state does not stay "on" with no script behind it
- `/clux:validate` reports mirror mode, and does not warn about index `[92]` when `session-follow.sh` holds it. The free band is now 93–99

## [4.1.0]

### Added

- **The companion operates in background sessions.** In a Claude Code session with no tmux pane (`claude --bg`, or a session that a `claude agents` dashboard starts), `terminal.sh open` opens the companion as a new window, `clux-terminal <id>`, in the tmux session of the dashboard (`mode=window`, `window=<session>:<index>`). With no dashboard, or with `--socket`, it opens on a private tmux server. The owner is the Claude session: `CLUX_SESSION_ID`, which the `SessionStart` hook now writes to `CLAUDE_ENV_FILE`, else `CLAUDE_CODE_SESSION_ID`, and the process `CLAUDE_PID`. Its private directory is `sessions/<first 8 characters of the session id>`
- A watchdog process closes a background companion and stops its Laya server when the session process ends, also after a crash with no `SessionEnd`. `close --hook` with no `TMUX` closes the companion of the `session_id` in the hook payload
- A background companion pane holds a mark (`@clux-companion`). A verb that does not find the mark gives exit code 4, so a stale pane ID after a restart of the tmux server never names a pane of the user
- The reaper also removes the directory of a session whose process ended, and a companion left from a `/clear` whose `SessionEnd` hook did not run

### Changed

- Outside tmux and outside a Claude Code session, the verbs give exit code 2 and `clux terminal must run inside tmux or in a Claude Code session` (it was `clux terminal must run inside tmux`)
- `open` in socket mode also prints `attach_in_tmux=TMUX= tmux -S <sock> attach`, because tmux refuses an attach from inside tmux when `TMUX` is set
- `state` is written to a temporary file and then renamed, so a reader never sees a half-written file
- `open`, `close`, the watchdog and the reaper make or remove a companion directory only while they hold its lock (`<dir>.lock`). Two parallel `open` calls of one session make one companion: the second waits and re-uses it. Before, the call that failed removed the directory of the call that worked. A second `open` or `close` waits at most 120 seconds (the time that one `open` can take), then gives exit code 5 and `another open or close of this companion is at work: try again`. The `SessionEnd` hook waits at most 2 seconds; then a separate process waits for the lock and closes the companion that the hook saw, for a pane owner and for a session owner. The watchdog and the reaper skip a companion that another verb holds
- **The locks are kernel locks (`flock`) that a small `perl` process holds for the verb.** This is true for the directory lock, the typing lock of `send` and `run`, and the reading lock of a run output. The kernel frees a lock when its holder ends, also after `kill -9`, so no verb takes over a lock with a pid test. Before, a lock was a link with the pid of its holder: two verbs could both take over a stale lock, and a pid that a new process got kept a lock for ever. `perl` is now necessary (macOS and most Linux systems have it); without it the verbs give exit code 2 and `clux terminal needs perl`
- The busy lock of `run` holds the pid and the start time of its holder, so a new process with the same pid does not keep it. A start time is stored in one form, seconds since 1970 in UTC, so a verb with another `TZ` or `LC_ALL` does not see a live owner as dead. Two start times name one process when they are 2 s apart or less (on Linux, two reads of one process can differ by 1 s). When `ps` or `perl` cannot read the start time of a process that exists, the owner counts as alive: the watchdog, the reaper and `run` keep the companion and the busy lock. A busy lock of clux 4.0.0 holds only a pid; the pid alone then decides. The reaper keeps the directory of a foreign tmux server only while a tmux process has its pid and the start time in the server key
- After `claude --resume`, `open` uses the companion again and records the new Claude process as its owner, so the watchdog of the old process does not close it. A verb that holds the directory lock and calls a step that takes the same lock now runs that step, and does not skip it
- The `SessionEnd` hook closes only a companion of its own session, at once or later. A pane companion now records its session id too, so a second Claude session in the same pane (for example `claude -p` from a script) does not close it when it ends. When a new session in the same pane uses the companion again (`open`), the companion records the new session: its hook closes it, and a late hook of the old session does not
- Limits: the 2 s slack of a start time covers rounding, not a step of the system clock (on Linux, `ps` makes the start time from the boot time). A pane `open` by a caller with no valid session id keeps the session in state, so the hook of that caller does not close the companion
- `/clux:validate` checks the event and the command of each hook in one `hooks.json` entry (with `jq`, else `python3`). A command under the wrong event is a `FAIL`. With neither tool, the check is a `FAIL` that says so. The check compares the full command path, so a script of the same name in another directory is a `FAIL`. A `hooks.json` that is not valid JSON gives `FAIL hooks.json is not valid JSON`. A missing `perl` is a `WARN` that names `clux:terminal`, the only part that needs it

## [4.0.0]

### Changed

- **Breaking: the companion needs Laya.** `clux:terminal` does not operate without a local Laya model (`laya` 0.3.21, English checkpoint). Until the user runs `terminal.sh laya install`, `open` gives exit code 6 and `laya not installed: run terminal.sh laya install`. `open` starts one loopback `laya-serve` for each companion, with a random API key and its log in the private directory (0600). `close`, the `SessionEnd` hook and the reaper stop it. `CLUX_LAYA_URL` names a server that the user starts; it must be a loopback host, and clux never stops it
- **The default time limit of `run` is 64 seconds** (it was 100 seconds), so that the Laya checks (the command gate, the pane probe and a 15 s output guard) fit in the 120-second limit of the Bash tool
- `wait --pattern` examines the screen each second, not each 0.2 s. When the screen changes, it guards only the lines that no earlier guard of the wait examined (each with the line above it), and tests the pattern only on the guarded text. One failed guard does not end the wait; 3 in a row give exit code 6
- `send --key` with `C-c`, `C-d`, `C-z`, `C-\` or `Escape` does not go through the Laya pane check, so Claude can stop a command when Laya is not available
- There is no safe list: each `run` command goes to Laya, also `ls` and `echo`. A command that ran can make a function with the name of any builtin that a first-word check uses, so such a check cannot be trusted. The pane shell does not expand aliases
- A command or a line that Laya would cut (about 500 tokens) is refused with exit code 2 and `too long to examine`, because Laya would examine only a part of it. The pane probe and the pair of the line check are cut to fit, and a line check that Laya cuts holds the line
- Only one `send` or `run` types at a time (a lock with the pid of its holder; exit code 5 when another one types). `send` reads the cursor line again after the gate, and types nothing when it changed (exit code 5)
- The output guard makes its blocks from the last line up, and sends no pair request for a line that is held already
- `C-d` at the prompt does not end the pane shell (`ignoreeof`)
- In the pane shell `MAIL`, `MAILPATH`, `MAILCHECK` and `FUNCNEST` are unset and read-only, and `run` does not carry them back: bash expands `MAILPATH` before each prompt with no gate
- In a nested shell, the shell rule of `send` reads only the text that clux typed in the line, not the prompt, so a prompt such as `~/source$` does not refuse `ls`, and `.` after a prompt is found. It also refuses `complete`, `compgen`, `bindkey`, `setopt`, `unsetopt`, `zle`, `autoload`, `zmodload` and assignments to `path`, `fpath`, `cdpath`, `FPATH`, `MAIL*` and `FUNCNEST`
- `health` sends no API key. The pane check tries the last 100 characters of a long cursor line, and a cursor line that Laya still cuts gives exit code 2 and `laya: the cursor line is too long to examine: send --key C-c`
- `open` checks the install (the laya import and the checkpoint) with one Python process
- The nested-shell rule of `send` reads the program name with no case (`Python` on macOS gets no shell rule), and applies when a program runs a shell of its own (`pty.spawn`, `:terminal`). It also refuses `.` or `r` after `then`, `do`, `time` and other keywords, history expansion (`!!`, `!rm`, `^a^b`), `fc`, `umask`, `ulimit` and assignments to `HOME`, `TMPDIR`, `INPUTRC` and `ZDOTDIR`, with no Laya request
- Text that `send` typed and a program did not show goes to the gate with the next text
- The nested-shell rule of `send` finds the front program with `ps` below the pane, so `python3` that a `send` line starts (under the subshell) gets no shell rule. It also refuses `\.`, `X=1 . file`, the zsh prompts (`PROMPT`, `RPROMPT` and others), the zsh hook arrays and `${NAME:=...}` defaults of shell names. `cd` stays allowed
- The client does not follow a redirect, so the API key goes only to the loopback host. `open` with `CLUX_LAYA_URL` ignores the `laya_pid` of a dead companion
- `wait --pattern` also examines the lines that scrolled off between two checks. A wait probe sends no Laya request while the window changes each second
- **In a nested shell, only the user ends a line.** When a nested shell (`bash`, `zsh`, `ssh`, `docker exec`, `kubectl exec`, `su`, `tmux` and others) is in front of the pane, `send --enter` and each key that does not edit the line give exit code 2. Claude types the text, and the user presses Enter. A script that reads a line and a program that is not a shell take Enter as before
- At the clux prompt `Escape` is refused with no case (`ESCAPE`). `PROMPT_COMMAND` and `PS0`-`PS4` are read-only in the pane shell. A key with no typed text (`BSpace` on text that the user typed) makes the shell rule read all of the line. A pager or menu state from Laya counts only when no nested shell is in front, and `send` keeps its typed text in each state
- The first Laya call of each verb checks that the pid of the server is `laya-serve`. `wait --pattern` keeps only the lines of the last capture as examined, so a long wait does not use more CPU over time
- A line that ends after `Home` on a long wrapped line goes whole to the gate and to the pane. In `vim`, `nano` and other full-screen programs, `send` has no cursor check. The pane shell drops keys that came while a command ran (typeahead) before each prompt. `Escape` is refused in a nested shell, and a command under a nested shell that does not read the keys counts as the nested shell
- `wait --pattern` guards many new lines in pieces of whole lines, and finds scrolled lines also when a full history drops lines. One `send` reads the process tree one time, and the pid check of the Laya server runs one time in a verb
- `wait --run <n> --discard` exits 5 while another verb reads that output. A late alone request of a line above does not hold a line of a block that passed
- A shell with a name that is not in the list (a copy of `bash`, `exec -a x bash`, `ksh93`, `rbash`) counts as a nested shell: it leads its own process group in front. A program that the user starts at the pane prompt counts too, except a known program. After the user presses Enter in a nested shell, the next `send` does not read the old typed text or the prompt. The shell rule also refuses `for PATH in`, `select`, `getopts`, `sched`, `local`, zsh `prompt=` and others. `__clux_run` and `__clux_line` refuse a call that the prompt did not type (`"__clux"_run` in a line). `wait --pattern` starts no guard of a piece after its time limit. With no `lsof` and no `ss`, `open` reads `/proc`, and with none of them it does not send the key
- The output guard sends the newest lines to Laya first, so when its time limit ends, the lines that stay not examined are the top lines, not the last error. `output --render` gives `not_examined=<m>` next to `held=<k>`. A run with lines not examined keeps its output and the lock, so `wait --run <n>` examines it again. `wait --pattern` sends such lines to the guard again and does not treat them as held, and one client guards all of its pieces. At the clux prompt, `send --enter` sends the line alone to the gate, as `run` does. A `-----BEGIN` line with no `-----END` holds the lines below it only for a private key, not for a certificate. `Escape` is refused while the clux shell is in front, also when no prompt shows. A wait probe keeps the Laya answer of a window that comes back. `send` with no text and no key is a usage error before any pane request
- When the clux shell is in front and no clux prompt shows (a typed line longer than the pane pushed the prompt up), `send` refuses text and all keys except the interrupt keys, with exit code 5 and `the clux prompt is not on the screen: send --key C-c, then try again`. In this state `send` sends no `Enter` to the clux shell. At the clux prompt and in a nested shell, the edit keys are only `Left`, `Right`, `Home`, `End`, `BSpace`, `DC`, `Delete`, `C-u` and `C-k`: `Tab` (completion can run commands), `Up`, `Down`, `C-a`, `C-e`, `C-w` and `M-` keys give exit code 2. The functions of `rc.bash` run `stty`, `dd`, `rm`, `mv`, `tee` and `sleep` with `command -p`, so a `PATH` that a run gives back does not change them
- A `secret` or `prompt_injection` hold wins over `not_examined`, so a retry never gives back a held line; a `not_examined` marker keeps only the lines that no hold covers. The half rule does not count lines that are not examined. `output --pieces` reads the policies one time, and the PEM rule sees the full text, so a key over the edge of a piece is held. `not-secret.txt` patterns with `^` and `$` match no `=`, `:` or `@` in the `ls -l` owner and group and in the diffstat file name. The client refuses a time limit or a threshold of `nan` or `inf` (exit code 2). The cursor check counts a variation selector as 0 cells (VS16 after a narrow character as 1), and never counts fewer cells than tmux. One `drop_lines` function in `terminal.sh` removes lines for the guard, `wait --pattern` and the pattern test
- `run` and `send` refuse a Unicode format character (a bidi control such as U+202E, a zero width character such as U+200B or U+FEFF, a tag character), a C1 control character and the line and paragraph separators U+2028 and U+2029, as well as the C0 control characters and DEL (exit code 2). The messages are `run command must not contain a control character or a Unicode format character: give one line` and `send text must not contain a control character or a Unicode format character: use --enter or --key`. One list in UTF-8 bytes (Unicode 15.0) in `hides_text` serves the two verbs, and a test compares it with Python `unicodedata`. An emoji ZWJ sequence is refused (U+200D is a format character). A character that shows as a blank but is a letter or a space (U+00A0, U+3000, U+115F, U+1160, U+3164) is not refused, because it does not hide or reorder the text
- `__clux_sub` removes only its own EXIT trap, so an EXIT trap that the command sets (`trap "rm -rf $tmp" EXIT`) runs one time when the command ends. The keep step runs with `set +e +u +C`, so `set -e`, `set -u` and `noclobber` of the command do not stop the keep file. A read of a clux file that another verb can remove puts `2>/dev/null` before the `<` redirect, so a removed file gives no error text. `wait --idle` and `wait --pattern` read the run number again on each check: a Laya question that another verb starts during the wait stops it with exit code 3, and so does a secret run for `wait --pattern`
- A wait probe settles on the cursor line and the line above it, not on the full window of 5 lines, so a timer or a status line higher on the screen does not stop the Laya request. `wait --pattern` gives the client the first line of each run of new lines (`output --runs 0,a,b`), and the PEM rule runs in each run, so it does not join a `-----BEGIN` and an `-----END` from two places on the screen. `--runs` must start at `0` and go up, else the client exits 2. The cursor line makes a second capture only when the line can go on below the cursor row
- The client has no `--cut` argument now (exit code 2). An `-----END <words> PRIVATE KEY-----` line (also `PRIVATE KEY BLOCK`) with no `-----BEGIN` above it holds in all text, not only in cut text: from the first line, or from the line after an earlier `-----END` line. `tail`, `grep -A` and `sed -n` on a key file give such text. `-----END CERTIFICATE-----` and `-----END OF REPORT-----` hold nothing. Key lines with no `-----BEGIN` and no `-----END` line (`sed -n 2,4p keyfile`) are not held by this rule; only the line check and Laya examine them
- When the guard cuts the output to 32768 bytes, it removes the part of a line at the start of the cut (not when the byte before the cut is a newline), so a part of a secret never goes to Laya or to Claude. The note is now `output cut: the last 32768 bytes, from the first full line`
- When the time limit leaves output not examined, the message on stderr says that `wait --run <n>` again helps only when Laya was slow for a short time, and that `wait --run <n> --discard` and a command with less output (for example `| head -n 50`) is the other way; `--max-lines` keeps the last lines, which Laya examined. On a machine with no GPU, Laya needs about 59 s for 32768 bytes of hard output, and the time limit is 15 s
- A shell in the pane is a nested shell only when it reads commands from the terminal: no `-c` and no script file, or `-i` or `-s`, or an option form that clux does not know. `sh -c '...'` and `bash script.sh` of `npm` or `make` take Enter from `send` again. A loop such as `sh -c 'while read c; do eval "$c"; done'` looks like such a shell, so this rule does not find it
- The cursor check counts a character with no Unicode category (`Cn`, for example an emoji newer than the Unicode 15.0 data of Python) as 2 cells, because tmux can show it in 2 cells; this is never fewer cells than tmux. A private use character is 1 cell
- A verb reads the process tree of the pane one time, and each check of the verb uses that read
- `wait --pattern` reads the run number one time for the two checks of each tick
- One function (`random_hex`) reads `/dev/urandom` for the API key and the prompt token
- `scrub` uses the same secret-value match as the output guard
- When the last 32768 bytes of the output are one line with no newline (minified JSON, or `curl` output with no last newline), nothing of that line goes to Laya or to Claude. The note is then `output cut: the last 32768 bytes are one line with no start: nothing is shown`. The other note stays `output cut: the last 32768 bytes, from the first full line`. One function (`guard_cut_note`) prints the note for `run`, `wait --run` and `read`
- The output guard reads the byte before the cut in the same read as the text, so it starts fewer processes
- The nested shell rule knows the option forms of the POSIX shells (`bash`, `sh`, `dash`, `zsh`, `ksh`, `mksh`, `yash`, `ash`): a group of short letters (in `-euo pipefail`, `o` and `O` take the next word as a value, also at the end of a group), `-` and `--` that end the options, and the known long options (`--rcfile`, `--init-file` and `--emulate` take a value). Each form that it does not know (an unknown letter or long option, `--rcfile=x`, `-c` with no text, a value that is not there) counts as a shell that reads the terminal, so `send` refuses Enter. Another shell (`fish`, `tcsh`) is not a nested shell only when its first word is a script file; `busybox` always counts as a nested shell. This rule decides for a shell that a script starts with no job control (for example `sh -c 'zsh +m ...'` of a tool); a shell that the user starts at the pane prompt, and an interactive `bash`, lead a process group of their own, and the group rule finds them
- The `-----BEGIN` line of a private key is not a pattern in `secret-values.txt` now: `PEM_KEY_BEGIN` of the client (`-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----`) is the one pattern, and the extra layer uses it too. So `-----BEGIN PGP PRIVATE KEY BLOCK-----` and key names with a digit are held by the extra layer too
- `secret-values.txt` holds Stripe secret and restricted keys: `sk_live_`, `sk_test_`, `rk_live_` and `rk_test_`, with 20 or more letters or digits after them
- A table test has one row for each pattern of `secret-values.txt` and `not-secret.txt` (a line that it holds or frees, and a line that it does not), and fails when a pattern has no row. The test makes the tokens when it runs, so the source holds no key
- The PEM rule reads each `-----BEGIN` and `-----END` marker of a line in order (one `PEM_MARKER` pattern), so a line with more than one marker is correct. `cat cert.pem key.pem`, when the certificate file has no newline at its end, gives the line `-----END CERTIFICATE----------BEGIN RSA PRIVATE KEY-----`. The key after it is now held. Before, the END test of that line cleared the state, the BEGIN of the key was lost, and the key body was shown. A BEGIN, a body and an END on one line, two keys on one line, and the END of a key then a BEGIN on one line are correct too
- The client has one table for the HTTP errors of `laya-serve` (`HTTP_ERRORS`). 401 and 403 give exit code 4 and `laya: the server refused the API key`. 413 gives exit code 3 and `laya: too long to examine`, the same as a state that Laya cuts: `laya-serve` 0.3.21 refuses a state longer than 50000 characters (`MAX_STATE_CHARS`), and only a command or a pane state can be that long (an output block is at most 600 characters). Each other code gives exit code 1 and `laya: the server gave error <code>`. After a 503 the client waits for the `Retry-After` time and tries one time more. A second 503 is now late, the same as a time-out: the output guard holds those lines as `not_examined` (the next tick of a wait or `wait --run <n>` sends them again), and does not say `laya not available`. A live test sends a command of 60000 characters to the real `laya-serve` and gets exit code 3
- `wait --pattern --timeout N` ends near N seconds, not up to 15 s later. A guard gets at most the time that is left before the time limit of the wait (15 s or less). The pane probe also gets at most the time that is left (the new client option `pane --limit S`; a value above the gate limit of 11 s is 11 s; 0, a negative number, `nan`, `inf` or text gives exit code 2). No guard and no probe starts at or after the time limit
- Two limits are now written in the spec. The nested shell word rule of `send` is a help, not a full gate: it does not know each form that can change a shell, for example the zsh form `${NAME::=value}` (it sets `NAME` in that shell). At a nested shell prompt only the user presses Enter, so the user sees the line before it runs, and Laya still examines the line. `wait --pattern` finds the lines that a guard examined by their text, not by their place on the screen. So a new line with the same text as a line that an earlier guard examined (and that did not match) is not sent again and is not tested again. A pattern that must find a second line with the same text does not find it
- The Laya API key is not in the arguments of a process. clux sends nothing when the server that `open` started ended. At the clux prompt, `send` and `run` make no pane request. A command that only the `risk` choice makes dangerous shows `risk dangerous` as its reason
- The typed `__clux_run` line carries the sum of the command that Laya examined and the mode (`plain` or `confirm`; other modes are refused). The pane shell refuses a command file with a different sum, and it asks the question from the mode, not from a file. `rc.bash` gets the private directory as a read-only value, not from an exported variable
- `run` refuses a command with a control character (exit code 2). The question shows control characters of the reason and the command as `?`
- The prompt is `clux-<token>$ ` with a random token, so output that shows `clux$ ` is not the prompt
- `send` refuses when the capture of the pane fails two times (exit code 5, or 4 when the pane is gone), because the gate cannot examine the line
- In a pager or a menu, the move keys (`Up`, `Down`, `Left`, `Right`, `Home`, `End` and the page keys) go to the pane with no command request
- The output guard uses a new temporary file for each check, and `LC_ALL=C` for `tail`, `wc` and `tr`
- A line that `not-secret.txt` clears no longer stops the pair rule for the line after it
- `send` refuses text with exit code 2 when the cursor is not at the end of the line, in all pane states (in screen cells, so wide characters count 2). When the cursor cannot be read, `send` refuses with exit code 5
- `send --key` takes only a tmux key name; other text gives exit code 2
- When the output guard fails, the run keeps its lock until `wait --run <n>` gives the output, so a new run cannot delete it (exit code 5)
- The output guard sends at most 2 requests at one time: `laya-serve` runs one request at a time
- `open` makes sure that the process that listens on the Laya port is the server it started, and the reaper stops the servers of gone companions with one wait
- `close --hook` stops the Laya server in a separate process, with `kill -9` after 3 s. `open` stops the server of a dead companion of the same owner
- `wait --run <n> --discard` deletes output that Laya cannot examine and frees the companion
- A blank line in a program (for example a `[Y/n]` question) goes to Laya with the screen above it. The prompt is found also after output with no last newline
- Interrupt keys work while a Laya question is open; `C-c` declines the run
- With `CLUX_LAYA_URL`, `open` checks that the client Python can import `laya`. `laya install` reports an installed venv also when no `python3` 3.10 is on `PATH`. Binary output with NUL bytes gives no bash warning
- `close` removes the pane and the private directory first, then stops the Laya server; `close --hook` does not wait for the server to stop
- One failed pane probe does not stop a wait (also `wait --pattern`): the wait ends with exit code 6 after 3 failed probes in a row. For `run` and `wait --run` the message says that the command continues. A probe sends no request when the screen did not change
- Each run command runs one time: a declined command cannot run again through `__clux_run`, and `send` and `run` refuse `__clux_` names (exit code 2)
- After a 503 from Laya, the client waits for the `Retry-After` time of the server (at most 1 s), then tries one time more
- When the output guard reaches its time limit, only the text that Laya did not examine is held (`[held by laya: not_examined, <k> lines]`); the other lines stay and the verb exits 0
- `run` refuses with exit code 5 (`the pane is not at an empty prompt`) when text came on the prompt line while Laya examined the command, and types `C-u` before its line. `send --key C-c` ends a run whose typed line the pane shell never read (`run <n> did not start: the typed line changed`, `exit=126`)
- Each `run` command runs in a subshell, so it cannot change the functions, aliases, traps or options of the pane shell. Only the directory and the exported variables come back (from a NUL-separated file with an end record, read with no `eval`; `BASH*`, `PS0`-`PS4`, `PROMPT_COMMAND`, `IFS` and other shell names are not taken). A variable that is not exported does not persist to the next `run`
- In a `run` command, `exit`, `exec` and `logout` work as usual and end only that command (`cd dir || exit 1` stops it). `run` does not refuse these first words now. An `IFS` that a command leaves does not change which variables come back
- `IGNOREEOF` and `TMOUT` are read-only in the pane shell, and `send` refuses an assignment to them at a shell prompt
- `send` and `run` read the state file again after the typing lock, so a run that started in the meantime is seen
- The shell rules of `send` apply only at a nested shell prompt, and only when the process in the pane is a shell (not `python3` or `psql`). The client runs no `bash -n` check
- At a nested shell prompt (`pane=shell_prompt` and a shell in the pane), `send` refuses a line that can change the shell (`eval`, `source`, `export`, `alias`, `trap`, `set`, `read`, `exit`, `printf -v`, a function, an array item, an assignment to `PATH`, `POSIXLY_CORRECT` or `LD_*`, `<<` and others, also inside quotes; exit code 6). The rule is not complete: quotes can split a word. The pane shell has the continuation prompt `clux-<token>> `; at that prompt `send` gives exit code 5
- At the clux prompt, no line from Claude runs in the pane shell itself. A line that `send` ends goes to the pane as `__clux_line <sum>` and runs in a subshell, as `run` does: `cd` and `export` persist, other changes do not. A background job keeps running, but `fg`, `bg` and `jobs` do not see it. Only `Enter` and the keys that edit the line work there with `--key`; `Escape` and other keys give exit code 2. The functions of `rc.bash` are read-only, and POSIX mode does not stay after a command
- `open` on a live companion starts a new Laya server when the server that it started does not answer
- The pieces of a long line share 100 characters, so a short token is whole in one piece
- `wait --pattern` starts no guard after its time limit, and keeps each examined line one time
- `send` and `run` clear the prompt line with `C-e`, then `C-u`, so text to the right of the cursor does not join the typed line. The pane shell uses the emacs keys, also when `~/.inputrc` sets vi mode
- The shell rules of `send` also apply in `ssh`, `docker exec`, `kubectl exec` and other processes that are not a known program such as `python3` or `psql`
- `run` and a `send` line do not give back `LD_*` and `DYLD_*` to the pane shell
- `wait --pattern` keeps a line held that an earlier guard of the wait held
- `open` on a live companion exits 6 when the companion has no Laya server (clux 3.x), or when the server at `CLUX_LAYA_URL` does not answer
- `run` takes the busy lock of a `run` that stopped before it typed its line
- With `CLUX_LAYA_URL`, `open` sends one request to check `CLUX_LAYA_KEY` (`/health` does not check it), and names the key when the server refuses it (client exit code 4)
- The secret value `sk-...` needs no letter or digit before `sk-`, so names such as `flask-app-...` and `task-runner-...` are not held
- `send --key C-c` ends a plain run whose typed line the pane shell never read, as it does for a run with a question
- The shell rules of `send` apply by the process in the pane (a shell, `ssh` or an unknown name), not by the Laya class of the prompt
- A `run` command that sets its own EXIT trap still gives back its directory and exported variables; when it also ends with `exit`, a note says that they did not come back
- One guard request that reaches the 5 s request limit holds only its own text as not examined; the guard goes on
- `open` starts a new Laya server only under the typing lock
- A dangerous `send` outside the clux prompt says `ask the user to type this line in the pane`, not `use run`
- Only one verb reads the output of a run at a time: a second reader exits 5 (`another verb reads the output of run <n> now: try again`)
- `laya install` makes a venv again when its Python cannot import `laya`, and exits 2 when `CLUX_LAYA_PYTHON` names a Python with no `laya`
- The pane probe sends no request when only rows above the last 5 lines change
- A reader of a run keeps the lock and the output of that run, and an older run cannot free the lock of a newer run
- `wait --pattern` does not match a `[held by laya: ...]` marker line
- `send` cuts each screen line of the gate to its last 200 characters. An `-----END ... PRIVATE KEY-----` line with no start holds from the first line only in cut text. A line that `secret-values.txt` holds sends no request. `laya install` with a venv and no checkpoint needs no base `python3`

### Added

- **Command gate.** Each `run` command goes to Laya before it runs. `caution` adds `laya: caution (<reason>)` before `exit=<rc>`. `dangerous` shows `laya: dangerous (<reason>)` and `run? [y/N]` in the pane: only `y` from the user runs it; other input gives `laya: declined by the user` and `exit=126`. While the question is open, `send`, `read`, `wait --idle` and `wait --pattern` exit 3
- **Send gate.** Each `send` (text with or without `--enter`, and each key except `C-c`, `C-d`, `C-z`, `C-\` and `Escape`) sends the cursor line and the new text to Laya first, also inside `ssh`, `python3` or `psql`. Text that the pane does not show (for example after `stty -echo`; not a key that a program takes, such as `q` in `less`) stops each later `send` and `run` with exit code 3 until `send --key C-c`. A dangerous line gives exit code 6. `send` text with a control character, for example a newline, a carriage return or a tab, gives exit code 2; use `--enter` or `--key` (for example `--key Tab`)
- **Output guard.** All pane text that goes to Claude (`run`, `wait --run`, `read`, `wait --pattern`) goes to Laya in blocks, then line by line where a block is doubtful. A secret line becomes `[held by laya: secret]`, a prompt-injection block becomes `[held by laya: prompt_injection, <k> lines]`, and `laya: held <k> lines` gives the count. PEM blocks and the values in `config/laya/secret-values.txt` are always held; `config/laya/not-secret.txt` removes known false positives. When Laya does not answer, no output text goes to Claude: `output held: laya not available: use wait --run <n> again`, then `exit=<rc>`, and exit code 6; the output stays for `wait --run <n>`. The guard gets at most the last 32768 bytes (`output cut: the last 32768 bytes, from the first full line`, or `output cut: the last 32768 bytes are one line with no start: nothing is shown` when these bytes are one line)
- **Pane state.** `credential_on_cursor` becomes `pane_state`: Laya gives `credential`, `yes_no`, `menu`, `pager`, `shell_prompt` or `other`, and the 3.9.0 patterns can still add `credential`. `wait --idle` prints `pane=<state>` when its time limit ends
- **Exit code 6** for Laya: not installed, not available, a dangerous `send`, or output held
- `terminal.sh laya install` (Python 3.10 or later, a venv in `~/.local/share/clux/laya`, `pip install laya[serve]==0.3.21` and the checkpoint download, in one 540 s budget) and `terminal.sh laya status`
- `config/laya/`: the four policies (`command.json`, `output-block.json`, `output-line.json`, `pane.json`). There is no user copy: a command in the companion could write it and turn off the checks

### Internal

- `scripts/laya_client.py` is the only code that speaks to Laya. It uses no proxy and refuses a host that is not loopback. It is not deployed: it runs from the plugin tree, as `terminal.sh` does
- `test/fixtures/fake-laya.py` answers in the wire format captured from `laya-serve` 0.3.21 in `test/fixtures/laya-wire/`. `test/laya-client.bats` covers the client; the e2e tests run against the fake server. `test/laya-live.bats` (`CLUX_LAYA_LIVE=1`, not in CI) runs the real model and measures the guard time

## [3.9.0]

### Added

- **`clux:terminal`: a companion pane that the user can see.** Claude runs commands in one tmux pane for the full session, and the user sees each command run. `scripts/terminal.sh` has the verbs `open`, `run`, `send`, `read`, `wait`, `close` and `list`. `open` makes a split pane below Claude by default, or a session on a private server with `--socket`. Both modes refuse outside tmux, and each Claude session has its own private server. The pane shell is `bash` with no history file, so `cd` and `export` stay from one command to the next
- **`run` gives the real result, not a screen scrape.** A wrapper in the pane copies the output to a 0600 file in a private 0700 directory and writes the exit code to a second file. `run` waits for both files, prints the output (at most 200 lines, `--max-lines N`), then `exit=<rc>` on its own line, and deletes the output file. The default time limit is 100 seconds, below the 120-second limit of the Bash tool. On a time-out the command continues, and `wait --run <n>` gets the result later. One run at a time: a second `run` gives exit code 5
- **Credential prompts go to the user.** `config/credential-patterns.txt` holds the keywords (password, passphrase, code, token, key and more) and the `[y/N]` exclusions. The tmux option `@clux-terminal-patterns` adds a user file. When the cursor line of the pane is a credential prompt, `run`, `wait`, `send` and `read` stop with exit code 3 and show no screen text. The run becomes secret, and its output never goes back to Claude. `run --secret` does the same from the start. After a secret run, `read` and `wait --pattern` refuse until the next plain `run` clears the screen and the history
- **`SessionEnd` runs `terminal.sh close --hook`.** It clears the history, closes the pane (or stops the private server) and deletes the private directory. It is silent and always exits 0. `open` also removes the companions of owner panes that are gone, because `SessionEnd` does not come when the terminal is killed
- `/clux:validate` checks the new `SessionEnd` command

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
