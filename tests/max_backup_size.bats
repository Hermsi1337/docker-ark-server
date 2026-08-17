#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  MAX_BACKUP_SIZE_MB=""
}

@test "an unset budget passes" {
  run assert_valid_max_backup_size

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a plain number of megabytes passes" {
  MAX_BACKUP_SIZE_MB="4096"

  run assert_valid_max_backup_size

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the smallest budget arkmanager still prunes on passes" {
  MAX_BACKUP_SIZE_MB="65"

  run assert_valid_max_backup_size

  [ "$status" -eq 0 ]
}

@test "zero passes and disables the pruning" {
  MAX_BACKUP_SIZE_MB="0"

  run assert_valid_max_backup_size

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rejects a unit suffix" {
  MAX_BACKUP_SIZE_MB="2GB"

  run assert_valid_max_backup_size

  [ "$status" -eq 1 ]
  assert_contains "$output" "MAX_BACKUP_SIZE_MB='2GB' must be a plain number of megabytes"
  assert_contains "$output" "Use 0 to disable"
}

@test "rejects a lowercase unit suffix" {
  MAX_BACKUP_SIZE_MB="500m"

  run assert_valid_max_backup_size

  [ "$status" -eq 1 ]
  assert_contains "$output" "MAX_BACKUP_SIZE_MB='500m'"
}

# bash would read a leading zero as octal, so 0500 would silently mean 320
@test "rejects a budget with a leading zero" {
  MAX_BACKUP_SIZE_MB="0500"

  run assert_valid_max_backup_size

  [ "$status" -eq 1 ]
  assert_contains "$output" "MAX_BACKUP_SIZE_MB='0500'"
  assert_contains "$output" "no leading zero"
}

@test "rejects a non numeric budget" {
  MAX_BACKUP_SIZE_MB="abc"

  run assert_valid_max_backup_size

  [ "$status" -eq 1 ]
  assert_contains "$output" "MAX_BACKUP_SIZE_MB='abc'"
}

@test "rejects a budget with surrounding whitespace" {
  MAX_BACKUP_SIZE_MB=" 500"

  run assert_valid_max_backup_size

  [ "$status" -eq 1 ]
  assert_contains "$output" "must be a plain number of megabytes"
}

@test "rejects a negative budget" {
  MAX_BACKUP_SIZE_MB="-1"

  run assert_valid_max_backup_size

  [ "$status" -eq 1 ]
  assert_contains "$output" "MAX_BACKUP_SIZE_MB='-1'"
}

@test "rejects a fractional budget" {
  MAX_BACKUP_SIZE_MB="1.5"

  run assert_valid_max_backup_size

  [ "$status" -eq 1 ]
  assert_contains "$output" "MAX_BACKUP_SIZE_MB='1.5'"
}

@test "rejects a budget given as an arithmetic expression" {
  MAX_BACKUP_SIZE_MB="500+1"

  run assert_valid_max_backup_size

  [ "$status" -eq 1 ]
  assert_contains "$output" "MAX_BACKUP_SIZE_MB='500+1'"
}

@test "validates the budget without calling arkmanager or steamcmd" {
  MAX_BACKUP_SIZE_MB="500"

  run assert_valid_max_backup_size

  assert_stubs_installed_and_unused
}
