#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  CONFIG="${ARK_TOOLS_DIR}/arkmanager.cfg"
}

# the state of a volume created before these settings existed: the backup
# budget is hardcoded, neither block is there yet
write_config_without_the_blocks() {
  {
    echo 'arkbackupdir="/app/backup"'
    echo 'arkMaxBackupSizeMB="500"'
  } > "${CONFIG}"
}

@test "adds the backup retention block to a config that predates it" {
  write_config_without_the_blocks

  run add_backup_retention_to_arkmanager_cfg

  [ "$status" -eq 0 ]
  assert_contains "$output" "Adding backup retention settings"
  run cat "${CONFIG}"
  assert_contains "$output" '[ -z "${MAX_BACKUP_SIZE_MB}" ] || arkMaxBackupSizeMB="${MAX_BACKUP_SIZE_MB}"'
}

@test "adds the crash restart block to a config that predates it" {
  write_config_without_the_blocks

  run add_always_restart_on_crash_to_arkmanager_cfg

  [ "$status" -eq 0 ]
  assert_contains "$output" "Adding crash restart settings"
  run cat "${CONFIG}"
  assert_contains "$output" '[ "${ALWAYS_RESTART_ON_CRASH}" != "true" ] || arkAlwaysRestartOnCrash=true'
}

@test "keeps the settings that were already in the config" {
  write_config_without_the_blocks

  add_backup_retention_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg

  run cat "${CONFIG}"
  assert_contains "$output" 'arkbackupdir="/app/backup"'
  assert_contains "$output" 'arkMaxBackupSizeMB="500"'
}

@test "adds each block only once" {
  write_config_without_the_blocks

  add_backup_retention_to_arkmanager_cfg
  add_backup_retention_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg

  run grep -cF '|| arkMaxBackupSizeMB=' "${CONFIG}"
  [ "$output" = "1" ]
  run grep -cF '|| arkAlwaysRestartOnCrash=true' "${CONFIG}"
  [ "$output" = "1" ]
}

@test "the hardcoded backup budget does not count as migrated" {
  write_config_without_the_blocks

  run add_backup_retention_to_arkmanager_cfg

  assert_contains "$output" "Adding backup retention settings"
}

@test "a comment naming the variables does not block the append" {
  write_config_without_the_blocks
  echo '# MAX_BACKUP_SIZE_MB and ALWAYS_RESTART_ON_CRASH are documented in the README' >> "${CONFIG}"

  add_backup_retention_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg

  run grep -cF '|| arkMaxBackupSizeMB=' "${CONFIG}"
  [ "$output" = "1" ]
  run grep -cF '|| arkAlwaysRestartOnCrash=true' "${CONFIG}"
  [ "$output" = "1" ]
}

@test "leaves the shipped config alone" {
  cp "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${CONFIG}"

  run add_backup_retention_to_arkmanager_cfg
  [ -z "$output" ]
  run add_always_restart_on_crash_to_arkmanager_cfg
  [ -z "$output" ]

  run diff "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${CONFIG}"
  [ "$status" -eq 0 ]
}

@test "a config arkmanager can source survives a failed staging" {
  write_config_without_the_blocks
  cp "${CONFIG}" "${BATS_TEST_TMPDIR}/expected.cfg"

  mktemp() { return 1; }
  run add_backup_retention_to_arkmanager_cfg
  unset -f mktemp

  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING"
  run diff "${BATS_TEST_TMPDIR}/expected.cfg" "${CONFIG}"
  [ "$status" -eq 0 ]
}

@test "a failed staging leaves no half written file behind" {
  write_config_without_the_blocks

  mktemp() { return 1; }
  add_backup_retention_to_arkmanager_cfg
  unset -f mktemp

  run find "${ARK_TOOLS_DIR}" -name 'arkmanager.cfg.*'
  [ -z "$output" ]
}

@test "the added settings stay inactive while the variables are empty" {
  write_config_without_the_blocks
  add_backup_retention_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg

  MAX_BACKUP_SIZE_MB=""
  ALWAYS_RESTART_ON_CRASH=""
  arkAlwaysRestartOnCrash=""
  source "${CONFIG}"

  [ "${arkMaxBackupSizeMB}" = "500" ]
  [ -z "${arkAlwaysRestartOnCrash}" ]
}

@test "the backup budget follows MAX_BACKUP_SIZE_MB" {
  write_config_without_the_blocks
  add_backup_retention_to_arkmanager_cfg

  MAX_BACKUP_SIZE_MB="4096"
  source "${CONFIG}"

  [ "${arkMaxBackupSizeMB}" = "4096" ]
}

@test "a zero budget reaches arkmanager as zero" {
  write_config_without_the_blocks
  add_backup_retention_to_arkmanager_cfg

  MAX_BACKUP_SIZE_MB="0"
  source "${CONFIG}"

  [ "${arkMaxBackupSizeMB}" = "0" ]
}

@test "a literal true arms the crash restart" {
  write_config_without_the_blocks
  add_always_restart_on_crash_to_arkmanager_cfg

  ALWAYS_RESTART_ON_CRASH="true"
  source "${CONFIG}"

  [ "${arkAlwaysRestartOnCrash}" = "true" ]
}

# arkmanager arms the watchdog on any non-empty value, so anything that is not
# exactly 'true' has to stay unset rather than be passed through
@test "false does not arm the crash restart" {
  write_config_without_the_blocks
  add_always_restart_on_crash_to_arkmanager_cfg

  ALWAYS_RESTART_ON_CRASH="false"
  arkAlwaysRestartOnCrash=""
  source "${CONFIG}"

  [ -z "${arkAlwaysRestartOnCrash}" ]
}

@test "True does not arm the crash restart" {
  write_config_without_the_blocks
  add_always_restart_on_crash_to_arkmanager_cfg

  ALWAYS_RESTART_ON_CRASH="True"
  arkAlwaysRestartOnCrash=""
  source "${CONFIG}"

  [ -z "${arkAlwaysRestartOnCrash}" ]
}

@test "migrates the config without calling arkmanager or steamcmd" {
  write_config_without_the_blocks

  add_backup_retention_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg

  assert_stubs_installed_and_unused
}
