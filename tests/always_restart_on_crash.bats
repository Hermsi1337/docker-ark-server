#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  ALWAYS_RESTART_ON_CRASH=""
}

@test "an unset value passes" {
  run assert_valid_always_restart_on_crash

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "true passes" {
  ALWAYS_RESTART_ON_CRASH="true"

  run assert_valid_always_restart_on_crash

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "false passes" {
  ALWAYS_RESTART_ON_CRASH="false"

  run assert_valid_always_restart_on_crash

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# arkmanager arms the watchdog on any non-empty value, so a spelling the config
# does not forward has to fail loudly instead of looking accepted
@test "rejects True" {
  ALWAYS_RESTART_ON_CRASH="True"

  run assert_valid_always_restart_on_crash

  [ "$status" -eq 1 ]
  assert_contains "$output" "ALWAYS_RESTART_ON_CRASH='True' must be 'true' or 'false'"
}

@test "rejects yes" {
  ALWAYS_RESTART_ON_CRASH="yes"

  run assert_valid_always_restart_on_crash

  [ "$status" -eq 1 ]
  assert_contains "$output" "ALWAYS_RESTART_ON_CRASH='yes'"
}

@test "rejects 1" {
  ALWAYS_RESTART_ON_CRASH="1"

  run assert_valid_always_restart_on_crash

  [ "$status" -eq 1 ]
  assert_contains "$output" "ALWAYS_RESTART_ON_CRASH='1'"
}

@test "rejects on" {
  ALWAYS_RESTART_ON_CRASH="on"

  run assert_valid_always_restart_on_crash

  [ "$status" -eq 1 ]
  assert_contains "$output" "ALWAYS_RESTART_ON_CRASH='on'"
}

@test "rejects TRUE" {
  ALWAYS_RESTART_ON_CRASH="TRUE"

  run assert_valid_always_restart_on_crash

  [ "$status" -eq 1 ]
  assert_contains "$output" "ALWAYS_RESTART_ON_CRASH='TRUE'"
}

@test "validates the value without calling arkmanager or steamcmd" {
  ALWAYS_RESTART_ON_CRASH="true"

  run assert_valid_always_restart_on_crash

  assert_stubs_installed_and_unused
}
