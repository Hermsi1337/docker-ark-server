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

write_configs() {
  echo "${1}" > "${ARK_TOOLS_DIR}/arkmanager.cfg"
  echo "${2}" > "${ARK_TOOLS_DIR}/instances/main.cfg"
}

@test "no warning when nothing overrides the budget" {
  MAX_BACKUP_SIZE_MB="4096"
  write_configs 'arkbackupdir="/app/backup"' 'serverMap="TheIsland"'

  run warn_on_overridden_backup_budget

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# upstream multiplies the GB value into the MB one before it checks the budget
@test "warns about arkMaxBackupSizeGB in the global config" {
  MAX_BACKUP_SIZE_MB="4096"
  write_configs 'arkMaxBackupSizeGB="2"' 'serverMap="TheIsland"'

  run warn_on_overridden_backup_budget

  [ "$status" -eq 0 ]
  assert_contains "$output" "assigns arkMaxBackupSizeGB, which overrides MAX_BACKUP_SIZE_MB"
}

@test "the commented example does not warn" {
  MAX_BACKUP_SIZE_MB="4096"
  write_configs '#arkMaxBackupSizeGB="2"' 'serverMap="TheIsland"'

  run warn_on_overridden_backup_budget

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "warns about arkMaxBackupSizeGB in the instance config" {
  MAX_BACKUP_SIZE_MB="4096"
  write_configs 'arkbackupdir="/app/backup"' 'arkMaxBackupSizeGB="2"'

  run warn_on_overridden_backup_budget

  [ "$status" -eq 0 ]
  assert_contains "$output" "instances/main.cfg assigns arkMaxBackupSizeGB"
}

# arkmanager sources the instance config after the global one
@test "warns about a hand set budget in the instance config" {
  MAX_BACKUP_SIZE_MB="4096"
  write_configs 'arkbackupdir="/app/backup"' 'arkMaxBackupSizeMB="500"'

  run warn_on_overridden_backup_budget

  [ "$status" -eq 0 ]
  assert_contains "$output" "instances/main.cfg assigns arkMaxBackupSizeMB"
}

# the shipped global template assigns it, that is the value the variable
# replaces rather than fights with
@test "the global budget the template ships does not warn" {
  MAX_BACKUP_SIZE_MB="4096"
  write_configs 'arkMaxBackupSizeMB="500"' 'serverMap="TheIsland"'

  run warn_on_overridden_backup_budget

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# the startup sequence runs under set -e, so a non-zero status here kills the
# container on the default configuration
@test "no warning while the variable is unset" {
  MAX_BACKUP_SIZE_MB=""
  write_configs 'arkMaxBackupSizeGB="2"' 'arkMaxBackupSizeMB="500"'

  run warn_on_overridden_backup_budget

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a missing instance config does not break the check" {
  MAX_BACKUP_SIZE_MB="4096"
  echo 'arkbackupdir="/app/backup"' > "${ARK_TOOLS_DIR}/arkmanager.cfg"
  rm -f "${ARK_TOOLS_DIR}/instances/main.cfg"

  run warn_on_overridden_backup_budget

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
