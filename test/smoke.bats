#!/usr/bin/env bats
# smoke.bats — minimal smoke test verifying the bats harness is functional.
# Deleted after Task 12 sweep confirms the full suite passes.

load test_helper

@test "smoke: bats harness is functional" {
    run bash -c 'echo hello'
    [ "$status" -eq 0 ]
    [[ "$output" == "hello" ]] || false
}
