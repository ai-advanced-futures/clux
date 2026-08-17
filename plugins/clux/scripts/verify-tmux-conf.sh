#!/usr/bin/env bash
# verify-tmux-conf.sh — parse a candidate tmux config for real, on a
# throwaway server, per the config-updater design
# (docs/superpowers/specs/2026-08-10-clux-config-updater-skill-design.md).
#
# The old verify_config() in the retired setup-tmux-conf.sh never verified
# anything — both branches of its inner test were empty and it unconditionally
# reported success. This replaces that with an actual parse.
#
# The design's literal sequence is `tmux -L clux-verify -f <file> new-session
# -d` followed by `tmux -L clux-verify kill-server`. Measured against a real
# tmux (3.7b): that sequence does NOT surface a parse error. tmux loads a `-f`
# config on the "global" queue during server startup, before any client is
# attached, and `-d` means no client ever attaches — so a `cfg_add_cause` (an
# unclosed brace, an unknown option, a syntax error) is recorded but never
# delivered anywhere, and the client's exit status reflects only the
# `new-session -d` command that follows it, which succeeds independently.
# Repeating that sequence here would repeat exactly the bug this script
# exists to fix, just with different dead code.
#
# What DOES surface an error, measured the same way: running `source-file` as
# an ordinary command against an ALREADY-RUNNING server. A command dispatched
# by a connected client (as opposed to config loaded at server startup) goes
# through that client's own command queue, and `cmdq_error` reaches it —
# confirmed against an invalid option (exit 1, "invalid option: …" on
# stderr), an unclosed brace (exit 1, "<file>:<line>: syntax error"), and a
# clean file (exit 0, silent). So this script starts the throwaway server
# with NO `-f` (a bare `new-session -d`, which always succeeds — it carries
# none of the candidate's content), then `source-file`s the candidate into
# that live server. Same throwaway `-L` socket, same "cannot disturb a live
# session" guarantee, same two tmux calls in spirit — just reordered so the
# parse actually happens on a queue that reports back.
#
# A real client must be attached before that source-file runs, because
# `cmdq_error` is delivered to a client: with nobody attached the parse error
# has nowhere to go and this script would report a broken config as clean —
# the exact failure mode of the verify_config() it replaced. So it attaches
# one throwaway client of its own first, in control mode (`-C`, which needs no
# real tty) with stdin held open so it cannot exit before source-file runs.
#
# The client used to be needed for a second reason as well, no longer true:
# clux.tmux.conf ends with a synchronous `run-shell session-bar-refresh.sh`,
# and that script's closing `tmux refresh-client -S` exited 1 with "no current
# client" against an unattached server, which run-shell reported as the whole
# source-file failing. session-bar-refresh.sh now treats a redraw with no
# client as the ordinary thing it is (see its own closing comment), so a
# candidate file no longer fails to source for that reason. The client stays
# for the error-delivery reason above, which is the load-bearing one.
#
# Usage: verify-tmux-conf.sh <path-to-candidate-config>
# Exit 0 and silent on success. Exit non-zero with tmux's own parse error on
# stderr on failure.

set -u

# PID-suffixed, not the bare "clux-verify" the design names: kill-server
# returns as soon as it has signalled the server, not once the server has
# actually exited and removed its socket file, so two verify-tmux-conf.sh
# calls in quick succession (the corpus test loop this feeds race a stale
# socket under the shared literal name — observed directly while testing
# this script). A unique socket per invocation removes the race instead of
# papering over it with a retry loop, while keeping every guarantee the
# design asks of the throwaway socket: still per-run, still never the user's
# real socket, still killed before this script exits.
SOCKET="clux-verify-$$"
CONF="${1:-}"
CLIENT_PID=""
STDIN_DIR=""
SOCKET_PATH=""

if [ -z "$CONF" ]; then
    echo "verify-tmux-conf.sh: usage: verify-tmux-conf.sh <path-to-candidate-config>" >&2
    exit 1
fi

if [ ! -f "$CONF" ]; then
    echo "verify-tmux-conf.sh: no such file: $CONF" >&2
    exit 1
fi

if ! command -v tmux >/dev/null 2>&1; then
    echo "verify-tmux-conf.sh: tmux not found on PATH" >&2
    exit 1
fi

cleanup() {
    [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" >/dev/null 2>&1
    tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    # tmux does NOT unlink its socket file when the server exits — verified
    # directly: a killed server leaves the socket behind indefinitely. With a
    # shared socket name that cost one stale file forever; with the per-PID
    # name above it costs one per call, and a single test run left 175 of them
    # in the tmux directory. The server is dead by this line and the name
    # carries our own pid, so removing the file is ours to do.
    [ -n "$SOCKET_PATH" ] && rm -f "$SOCKET_PATH" >/dev/null 2>&1
    # Closing the write end lets the control client's read hit EOF; removing
    # the directory takes the fifo with it. Nothing of ours outlives this.
    exec 3>&- 2>/dev/null || true
    [ -n "$STDIN_DIR" ] && rm -rf "$STDIN_DIR" >/dev/null 2>&1
}
trap cleanup EXIT

# Clear any throwaway server left over from a prior run that crashed before
# reaching cleanup() — never touches the user's real socket.
tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true

if ! tmux -L "$SOCKET" new-session -d 2>/dev/null; then
    echo "verify-tmux-conf.sh: could not start the throwaway tmux server" >&2
    exit 1
fi

# Asked of the live server rather than rebuilt from $TMUX_TMPDIR/$UID by hand,
# so cleanup() removes the file tmux actually created.
SOCKET_PATH="$(tmux -L "$SOCKET" display-message -p '#{socket_path}' 2>/dev/null)"

# The control client needs a stdin that blocks forever instead of hitting EOF
# immediately: a `< /dev/null` control client reads EOF on its first read and
# self-detaches before source-file ever runs, which reintroduces the exact "no
# current client" failure this exists to avoid.
#
# A fifo this script holds open does that with NO extra process. The earlier
# `< <(tail -f /dev/null)` worked, but bash 3.2 (macOS) does not report a
# process substitution's pid in $!, so that tail could not be killed and every
# invocation leaked one forever — two per /clux:setup run.
#
# Opening the fifo read-write on one fd never blocks, so there is no
# ordering deadlock with the client's own open-for-read.
STDIN_DIR="$(mktemp -d 2>/dev/null)" || STDIN_DIR=""
if [ -n "$STDIN_DIR" ] && mkfifo "$STDIN_DIR/stdin" 2>/dev/null; then
    exec 3<>"$STDIN_DIR/stdin"
    tmux -L "$SOCKET" -C attach-session -t 0 <"$STDIN_DIR/stdin" >/dev/null 2>&1 &
    CLIENT_PID=$!
else
    echo "verify-tmux-conf.sh: could not create the control client's stdin fifo" >&2
    exit 1
fi

# Give the control client a moment to register as attached before the parse
# runs — cheap (well under the interval a human would notice) and this is a
# one-shot verify, not a hot path.
sleep 0.3

ERR="$(tmux -L "$SOCKET" source-file "$CONF" 2>&1)"
STATUS=$?

if [ "$STATUS" -ne 0 ]; then
    printf '%s\n' "$ERR" >&2
    exit "$STATUS"
fi

exit 0
