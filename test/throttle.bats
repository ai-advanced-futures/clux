#!/usr/bin/env bats
# throttle.bats — plugins/clux/scripts/throttle.sh memoizes any #() status
# job. tmux re-runs EVERY #() job on the status line on every redraw, so a
# job with no cache of its own pays its full cost on every tick once
# status-interval drops low enough to animate the busy glyph (the feature
# this script was added to support). These tests pin the contract in the
# design spec (2026-08-23-clux-animated-busy-glyph-design.md §4): hit, miss,
# expiry, one cache entry per distinct argv, a failed command keeping its
# previous output while still re-stamping the epoch, the miss-only prune,
# and an atomic write so a redraw never sees a half-written cache file.

load test_helper

THROTTLE="$SCRIPTS_DIR/throttle.sh"

# A "command" throttle.sh can invoke: appends one line to $1 (a counter
# file) and prints RUN. Counting lines in that file proves whether
# throttle.sh actually forked the command or served a cached hit.
_install_counter() {
    local path="$1"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
echo x >> "$1"
echo RUN
EOF
    chmod +x "$path"
}

setup() {
    install_stubs
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdgcache"
    COUNTER="$BATS_TEST_TMPDIR/counter.sh"
    _install_counter "$COUNTER"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# Task 1.1 — contract and skeleton: bad invocations, stderr only, no stdout
# ---------------------------------------------------------------------------

@test "throttle: no arguments — stdout is empty and stderr carries usage" {
    run bash -c "'$THROTTLE' 2>'$BATS_TEST_TMPDIR/err'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    grep -qi usage "$BATS_TEST_TMPDIR/err"
}

@test "throttle: non-numeric seconds is rejected the same way" {
    run bash -c "'$THROTTLE' notanumber echo hi 1>'$BATS_TEST_TMPDIR/out' 2>'$BATS_TEST_TMPDIR/err'"
    [ "$status" -ne 0 ]
    [ ! -s "$BATS_TEST_TMPDIR/out" ]
    grep -qi usage "$BATS_TEST_TMPDIR/err"
}

@test "throttle: seconds with no command is rejected" {
    run bash -c "'$THROTTLE' 10 1>'$BATS_TEST_TMPDIR/out' 2>'$BATS_TEST_TMPDIR/err'"
    [ "$status" -ne 0 ]
    [ ! -s "$BATS_TEST_TMPDIR/out" ]
    grep -qi usage "$BATS_TEST_TMPDIR/err"
}

# ---------------------------------------------------------------------------
# Task 1.2 — cache location, key, hit path
# ---------------------------------------------------------------------------

@test "throttle: hit — second call within the window does not fork the command" {
    local counterfile="$BATS_TEST_TMPDIR/hits"
    run "$THROTTLE" 60 "$COUNTER" "$counterfile"
    [ "$status" -eq 0 ]
    [ "$output" = "RUN" ]

    run "$THROTTLE" 60 "$COUNTER" "$counterfile"
    [ "$status" -eq 0 ]
    [ "$output" = "RUN" ]

    [ "$(wc -l < "$counterfile" | tr -d ' ')" -eq 1 ]
}

@test "throttle: honours XDG_CACHE_HOME — exactly one cache file after the first call" {
    run "$THROTTLE" 60 "$COUNTER" "$BATS_TEST_TMPDIR/hits2"
    [ "$status" -eq 0 ]
    local n
    n=$(find "$XDG_CACHE_HOME/clux/throttle" -type f | wc -l | tr -d ' ')
    [ "$n" -eq 1 ]
}

@test "throttle: falls back to \$HOME/.cache when XDG_CACHE_HOME is unset" {
    unset XDG_CACHE_HOME
    run "$THROTTLE" 60 "$COUNTER" "$BATS_TEST_TMPDIR/hits3"
    [ "$status" -eq 0 ]
    [ -d "$HOME/.cache/clux/throttle" ]
    local n
    n=$(find "$HOME/.cache/clux/throttle" -type f | wc -l | tr -d ' ')
    [ "$n" -eq 1 ]
}

@test "throttle: per-argv key — two different commands cache and read back uncrossed" {
    run "$THROTTLE" 60 echo A
    [ "$output" = "A" ]
    run "$THROTTLE" 60 echo B
    [ "$output" = "B" ]

    local n
    n=$(find "$XDG_CACHE_HOME/clux/throttle" -type f | wc -l | tr -d ' ')
    [ "$n" -eq 2 ]

    # Re-read both — still uncrossed, proving the key is stable, not random.
    run "$THROTTLE" 60 echo A
    [ "$output" = "A" ]
    run "$THROTTLE" 60 echo B
    [ "$output" = "B" ]
}

@test "throttle: per-argv key — same command, two different path arguments, two entries" {
    run "$THROTTLE" 60 echo "/path/one"
    [ "$output" = "/path/one" ]
    run "$THROTTLE" 60 echo "/path/two"
    [ "$output" = "/path/two" ]

    local n
    n=$(find "$XDG_CACHE_HOME/clux/throttle" -type f | wc -l | tr -d ' ')
    [ "$n" -eq 2 ]
}

@test "throttle: never calls stat, and runs with no tmux on PATH" {
    local stubdir="$BATS_TEST_TMPDIR/nostat"
    mkdir -p "$stubdir"
    cat > "$stubdir/stat" <<EOF
#!/usr/bin/env bash
echo "stat \$*" >> "$BATS_TEST_TMPDIR/stat.log"
exit 127
EOF
    chmod +x "$stubdir/stat"

    # /usr/bin and /bin carry every coreutil throttle.sh needs (date, cksum,
    # mkdir, mv, cat, tail, awk, mktemp, rm) on this machine, and neither
    # directory holds a tmux binary — so this PATH has no tmux at all, and
    # any call to `stat` hits the logging stub above instead of the real one.
    PATH="$stubdir:/usr/bin:/bin" run "$THROTTLE" 60 "$COUNTER" "$BATS_TEST_TMPDIR/hits4"
    [ "$status" -eq 0 ]
    [ "$output" = "RUN" ]
    [ ! -e "$BATS_TEST_TMPDIR/stat.log" ]
}

# ---------------------------------------------------------------------------
# Task 1.3 — miss path and atomic write
# ---------------------------------------------------------------------------

@test "throttle: expiry — a stale cache entry is refreshed" {
    mkdir -p "$XDG_CACHE_HOME/clux/throttle"
    local counterfile="$BATS_TEST_TMPDIR/hits5"
    _install_counter "$COUNTER"

    # Prime a cache entry for this exact argv, stale by an hour, body OLD.
    run "$THROTTLE" 10 "$COUNTER" "$counterfile"
    [ "$output" = "RUN" ]
    local cache_file
    cache_file=$(find "$XDG_CACHE_HOME/clux/throttle" -type f | head -1)
    local now stale
    now=$(date +%s)
    stale=$((now - 3600))
    printf '%s\nOLD\n' "$stale" > "$cache_file"

    run "$THROTTLE" 10 "$COUNTER" "$counterfile"
    [ "$status" -eq 0 ]
    [ "$output" = "RUN" ]
    [ "$(wc -l < "$counterfile" | tr -d ' ')" -eq 2 ]
    run bash -c "tail -n +2 '$cache_file'"
    [ "$output" = "RUN" ]
}

@test "throttle: atomic write — a concurrent reader never sees a torn cache file" {
    mkdir -p "$XDG_CACHE_HOME/clux/throttle"
    local key
    key=$(printf '%s\n' 10 bash -c 'printf N; sleep 0.4; printf EW' | cksum | awk '{print $1 "-" $2}')
    local cache_file="$XDG_CACHE_HOME/clux/throttle/$key"
    local now stale
    now=$(date +%s)
    stale=$((now - 3600))
    printf '%s\nOLD\n' "$stale" > "$cache_file"

    "$THROTTLE" 10 bash -c 'printf N; sleep 0.4; printf EW' > "$BATS_TEST_TMPDIR/bg.out" &
    local bgpid=$!

    local saw_bad=0
    local i
    for i in 1 2 3 4 5 6 7 8; do
        local body
        body=$(tail -n +2 "$cache_file" 2>/dev/null)
        if [ "$body" != "OLD" ] && [ "$body" != "NEW" ]; then
            saw_bad=1
        fi
        sleep 0.05
    done
    wait "$bgpid"

    [ "$saw_bad" -eq 0 ]
    local final_body
    final_body=$(tail -n +2 "$cache_file")
    [ "$final_body" = "NEW" ]
}

@test "throttle: no temp files left behind after a successful miss" {
    run "$THROTTLE" 60 echo "clean"
    [ "$status" -eq 0 ]
    local leftovers
    leftovers=$(find "$XDG_CACHE_HOME/clux/throttle" -maxdepth 1 -type f -name '.tmp.*')
    [ -z "$leftovers" ]
}

@test "throttle: stderr of the command is dropped, never reaches stdout or the cache" {
    local script="$BATS_TEST_TMPDIR/noisy.sh"
    cat > "$script" <<'EOF'
#!/usr/bin/env bash
echo "err line" >&2
echo "out line"
EOF
    chmod +x "$script"

    run "$THROTTLE" 60 "$script"
    [ "$status" -eq 0 ]
    [ "$output" = "out line" ]
    [[ "$output" != *"err line"* ]]
}

# ---------------------------------------------------------------------------
# Task 1.4 — a failing command keeps the output, re-stamps the epoch
# ---------------------------------------------------------------------------

@test "throttle: a failing command keeps the previous cached output" {
    mkdir -p "$XDG_CACHE_HOME/clux/throttle"
    local key
    key=$(printf '%s\n' 10 "$BATS_TEST_TMPDIR/fails.sh" | cksum | awk '{print $1 "-" $2}')
    local cache_file="$XDG_CACHE_HOME/clux/throttle/$key"
    local now stale
    now=$(date +%s)
    stale=$((now - 3600))
    printf '%s\nGOOD\n' "$stale" > "$cache_file"

    cat > "$BATS_TEST_TMPDIR/fails.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/fails.sh"

    run "$THROTTLE" 10 "$BATS_TEST_TMPDIR/fails.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "GOOD" ]
    run bash -c "tail -n +2 '$cache_file'"
    [ "$output" = "GOOD" ]
}

@test "throttle: a failing command still re-stamps the epoch — the next call is a hit" {
    mkdir -p "$XDG_CACHE_HOME/clux/throttle"
    local counterfile="$BATS_TEST_TMPDIR/hits6"
    local key
    key=$(printf '%s\n' 10 "$BATS_TEST_TMPDIR/fails2.sh" | cksum | awk '{print $1 "-" $2}')
    local cache_file="$XDG_CACHE_HOME/clux/throttle/$key"
    local now stale
    now=$(date +%s)
    stale=$((now - 3600))
    printf '%s\nGOOD\n' "$stale" > "$cache_file"

    cat > "$BATS_TEST_TMPDIR/fails2.sh" <<EOF
#!/usr/bin/env bash
echo x >> "$counterfile"
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/fails2.sh"

    run "$THROTTLE" 10 "$BATS_TEST_TMPDIR/fails2.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "GOOD" ]
    [ "$(wc -l < "$counterfile" | tr -d ' ')" -eq 1 ]

    # Immediately again — must be a hit: the counter must NOT increment.
    run "$THROTTLE" 10 "$BATS_TEST_TMPDIR/fails2.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "GOOD" ]
    [ "$(wc -l < "$counterfile" | tr -d ' ')" -eq 1 ]
}

@test "throttle: a failing command with no previous cache leaves an empty body that still hits" {
    local counterfile="$BATS_TEST_TMPDIR/hits7"
    cat > "$BATS_TEST_TMPDIR/fails3.sh" <<EOF
#!/usr/bin/env bash
echo x >> "$counterfile"
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/fails3.sh"

    run "$THROTTLE" 10 "$BATS_TEST_TMPDIR/fails3.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run "$THROTTLE" 10 "$BATS_TEST_TMPDIR/fails3.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(wc -l < "$counterfile" | tr -d ' ')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Task 1.5 — prune on a miss, never on a hit
# ---------------------------------------------------------------------------

@test "throttle: a miss prunes entries older than a day, leaves the rest, adds the new one" {
    mkdir -p "$XDG_CACHE_HOME/clux/throttle"
    local dir="$XDG_CACHE_HOME/clux/throttle"
    local now
    now=$(date +%s)

    printf '%s\nOLD\n' "$((now - 172800))" > "$dir/stale-two-days"
    printf '%s\nRECENT\n' "$((now - 7200))" > "$dir/stale-two-hours"
    printf '%s\nFRESH\n' "$now" > "$dir/fresh-entry"

    run "$THROTTLE" 60 echo "unrelated-miss"
    [ "$status" -eq 0 ]
    [ "$output" = "unrelated-miss" ]

    [ ! -e "$dir/stale-two-days" ]
    [ -e "$dir/stale-two-hours" ]
    [ -e "$dir/fresh-entry" ]
    local n
    n=$(find "$dir" -type f | wc -l | tr -d ' ')
    [ "$n" -eq 3 ]
}

@test "throttle: a hit does not prune" {
    mkdir -p "$XDG_CACHE_HOME/clux/throttle"
    local dir="$XDG_CACHE_HOME/clux/throttle"
    local now
    now=$(date +%s)
    printf '%s\nOLD\n' "$((now - 172800))" > "$dir/stale-two-days"

    # Force a hit for this exact argv.
    local key
    key=$(printf '%s\n' 60 echo hit-me | cksum | awk '{print $1 "-" $2}')
    printf '%s\nhit-me\n' "$now" > "$dir/$key"

    run "$THROTTLE" 60 echo hit-me
    [ "$status" -eq 0 ]
    [ "$output" = "hit-me" ]
    [ -e "$dir/stale-two-days" ]
}
