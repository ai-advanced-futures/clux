#!/usr/bin/env bash
# test.sh — drive bgc.sh against an isolated "default" tmux server. It never
# touches the user's tmux: TMUX_TMPDIR points at a private folder, and TMUX
# and TMUX_PANE are unset, as in a background Claude session.
set -u
P="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BGC="$P/bgc.sh"
W=$(cd "$(mktemp -d /tmp/bgct.XXXX)" && pwd -P)
export TMUX_TMPDIR="$W/tt" CLUX_TERMINAL_DIR="$W/r" CLUX_AGENT_STATE_DIR="$W/st" BGC_WATCH_EVERY=1
unset TMUX TMUX_PANE CLUX_SESSION_ID
mkdir -p "$TMUX_TMPDIR"
PASS=0 FAILN=0
ok() { PASS=$((PASS+1)); echo "  ok   $1"; }
no() { FAILN=$((FAILN+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }
uuid() { printf '%08x-aaaa-4bbb-8ccc-%012x' "$1" "$2"; }
newowner() { sleep 600 & OWNER=$!; export CLAUDE_PID=$OWNER; }

tmux -f /dev/null new-session -d -s dash -x 120 -y 30 'sleep 900'
DASH=$(tmux display-message -p -t dash '#{pane_id}')
KEY=$(tmux display-message -p '#{pid}-#{start_time}')
USOCK=$(tmux display-message -p '#{socket_path}')
case "$USOCK" in "$W"/*) ;; *) echo "isolation failed: $USOCK"; exit 1 ;; esac

echo "A. window mode, typing, close"
export CLAUDE_CODE_SESSION_ID=$(uuid 1 1); newowner
mkdir -p "$CLUX_AGENT_STATE_DIR/$KEY/agents"; : > "$CLUX_AGENT_STATE_DIR/$KEY/agents/$DASH~$CLAUDE_CODE_SESSION_ID"
out=$("$BGC" open); echo "$out" | sed 's/^/     /'
check "mode=window" '[[ "$out" == *mode=window* ]]'
check "window is in the dashboard session" '[ "$(tmux list-windows -t dash | wc -l | tr -d " ")" = 2 ]'
check "window keeps its name" '[ "$(tmux list-windows -t dash -F "#{window_name}" | tail -1)" = "clux-terminal ${CLAUDE_CODE_SESSION_ID:0:8}" ]'
check "run types into it" '"$BGC" run "echo hi-\$((6*7))" | grep -q "^hi-42"'
out2=$("$BGC" open)
check "open again re-uses the pane" '[ "$(echo "$out" | head -1)" = "$(echo "$out2" | head -1)" ]'
"$BGC" close
check "close removes the window only" '[ "$(tmux list-windows -t dash | wc -l | tr -d " ")" = 1 ]'
check "close removes the directory" '[ ! -d "$CLUX_TERMINAL_DIR/sessions/${CLAUDE_CODE_SESSION_ID:0:8}" ]'
check "watchdog ended after close" 'sleep 2; ! pgrep -f "bgc.sh watch ${CLAUDE_CODE_SESSION_ID:0:8}" >/dev/null'
kill $OWNER

echo "B. no dashboard: socket mode"
export CLAUDE_CODE_SESSION_ID=$(uuid 2 2); newowner
out=$("$BGC" open); echo "$out" | sed 's/^/     /'
check "mode=socket and both attach lines" '[[ "$out" == *mode=socket* && "$out" == *attach_in_tmux=TMUX=* ]]'
check "run types into it" '"$BGC" run "echo sock-ok" | grep -q "^sock-ok"'
"$BGC" close; kill $OWNER

echo "C. watchdog closes after the owner process ends (a crash: no hook)"
export CLAUDE_CODE_SESSION_ID=$(uuid 3 3); newowner
: > "$CLUX_AGENT_STATE_DIR/$KEY/agents/$DASH~$CLAUDE_CODE_SESSION_ID"
"$BGC" open >/dev/null
kill -9 $OWNER; sleep 3
check "directory gone" '[ ! -d "$CLUX_TERMINAL_DIR/sessions/${CLAUDE_CODE_SESSION_ID:0:8}" ]'
check "window gone" '[ "$(tmux list-windows -t dash | wc -l | tr -d " ")" = 1 ]'

echo "D. SessionEnd hook with no TMUX closes by the stdin session_id"
export CLAUDE_CODE_SESSION_ID=$(uuid 4 4); newowner
: > "$CLUX_AGENT_STATE_DIR/$KEY/agents/$DASH~$CLAUDE_CODE_SESSION_ID"
"$BGC" open >/dev/null
( unset CLAUDE_CODE_SESSION_ID; printf '{"session_id":"%s","hook_event_name":"SessionEnd","reason":"other"}' "$(uuid 4 4)" | "$BGC" close --hook )
check "hook closed it" '[ ! -d "$CLUX_TERMINAL_DIR/sessions/$(uuid 4 4 | cut -c1-8)" ] && [ "$(tmux list-windows -t dash | wc -l | tr -d " ")" = 1 ]'
check "bad session_id: hook does nothing, exits 0" 'echo "{\"session_id\":\"../../x\"}" | "$BGC" close --hook'
kill $OWNER

echo "E. /clear: new session id, same process"
export CLAUDE_CODE_SESSION_ID=$(uuid 5 5); newowner
: > "$CLUX_AGENT_STATE_DIR/$KEY/agents/$DASH~$CLAUDE_CODE_SESSION_ID"
"$BGC" open >/dev/null
OLD=$CLAUDE_CODE_SESSION_ID; export CLAUDE_CODE_SESSION_ID=$(uuid 6 6)   # SessionEnd hook "missed"
"$BGC" run "echo x" >/dev/null 2>&1; rc=$?
check "verb under the new id gets exit 4, not the old pane" '[ "$rc" = 4 ]'
check "old companion stays while its process lives (hook is the only closer)" '[ -d "$CLUX_TERMINAL_DIR/sessions/${OLD:0:8}" ]'
: > "$CLUX_AGENT_STATE_DIR/$KEY/agents/$DASH~$CLAUDE_CODE_SESSION_ID"   # agent-state.sh writes this at the first prompt
"$BGC" open >/dev/null
check "open under the new id closes the old companion of the same process" '[ ! -d "$CLUX_TERMINAL_DIR/sessions/${OLD:0:8}" ] && [ "$(tmux list-windows -t dash | wc -l | tr -d " ")" = 2 ]'
"$BGC" close; kill $OWNER

echo "F. server restart: a stale pane id must not reach a user pane"
export CLAUDE_CODE_SESSION_ID=$(uuid 7 7); newowner
: > "$CLUX_AGENT_STATE_DIR/$KEY/agents/$DASH~$CLAUDE_CODE_SESSION_ID"
"$BGC" open >/dev/null
STALE=$(grep '^pane=' "$CLUX_TERMINAL_DIR/sessions/${CLAUDE_CODE_SESSION_ID:0:8}/state" | cut -d= -f2)
# stop the watchdog so it does not race the test
kill "$(grep '^watch_pid=' "$CLUX_TERMINAL_DIR/sessions/${CLAUDE_CODE_SESSION_ID:0:8}/state" | cut -d= -f2)"
tmux kill-server; sleep 0.5
tmux -f /dev/null new-session -d -s user -x 120 -y 30 'bash --noprofile --norc -i'
for i in 1 2 3 4 5 6 7 8; do tmux has-session -t "$STALE" 2>/dev/null && break; tmux split-window -d -t user 'bash --noprofile --norc -i' 2>/dev/null || tmux new-window -d -t user 'bash --noprofile --norc -i'; done
check "a user pane now has the stale id $STALE" 'tmux display-message -p -t "$STALE" "#{pane_id}" >/dev/null 2>&1'
"$BGC" run "echo SHOULD-NOT-TYPE" >/dev/null 2>&1; rc=$?
check "run gets exit 4" '[ "$rc" = 4 ]'
check "nothing typed in the user pane" '! tmux capture-pane -p -t "$STALE" | grep -q SHOULD-NOT-TYPE'
"$BGC" close
check "close does not kill the user pane" 'tmux display-message -p -t "$STALE" "#{pane_id}" >/dev/null 2>&1'
kill $OWNER

echo "G. socket path length with the real macOS TMPDIR"
r="${TMPDIR:-/tmp}/clux-terminal-$EUID/sessions/abcdef01/sock"
check "${#r} bytes <= 100" '[ "${#r}" -le 100 ]'

tmux kill-server 2>/dev/null
pkill -f "$W" 2>/dev/null
rm -rf "$W"
echo "passed=$PASS failed=$FAILN"
[ "$FAILN" -eq 0 ]
