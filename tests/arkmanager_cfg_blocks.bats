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

snapshot_config() {
  command cp "${CONFIG}" "${BATS_TEST_TMPDIR}/expected.cfg"
}

assert_config_unchanged() {
  run diff "${BATS_TEST_TMPDIR}/expected.cfg" "${CONFIG}"
  [ "$status" -eq 0 ]
}

assert_no_staged_files() {
  run find "${ARK_TOOLS_DIR}" -name 'arkmanager.cfg.*'
  [ -z "$output" ]
}

# GNU and busybox stat take -c, the BSD one on macOS takes -f
file_inode() {
  stat -c %i "${1}" 2>/dev/null || stat -f %i "${1}"
}

@test "a config that cannot be staged is left alone" {
  write_config_without_the_blocks
  snapshot_config

  mktemp() { return 1; }
  run add_backup_retention_to_arkmanager_cfg
  unset -f mktemp

  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING"
  assert_config_unchanged
  assert_no_staged_files
}

# without this the config ends up holding the new block and nothing else,
# every setting the user had is gone and the rename makes it permanent
@test "a failed copy never reaches the config" {
  write_config_without_the_blocks
  snapshot_config

  cp() { return 1; }
  run add_backup_retention_to_arkmanager_cfg
  unset -f cp

  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING"
  assert_config_unchanged
  assert_no_staged_files
}

@test "a failed rename never reaches the config" {
  write_config_without_the_blocks
  snapshot_config

  mv() { return 1; }
  run add_backup_retention_to_arkmanager_cfg
  unset -f mv

  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING"
  assert_config_unchanged
  assert_no_staged_files
}

# the block has to arrive by rename: arkmanager sources this file on every
# invocation, so anything that writes it in place can be read half finished
@test "the block is put in place with a rename" {
  write_config_without_the_blocks
  MV_LOG="${BATS_TEST_TMPDIR}/mv-calls.log"
  : > "${MV_LOG}"

  mv() { echo "$*" >> "${MV_LOG}"; command mv "$@"; }
  add_backup_retention_to_arkmanager_cfg
  unset -f mv

  run cat "${MV_LOG}"
  assert_contains "$output" "${CONFIG}"
  run grep -cF '|| arkMaxBackupSizeMB=' "${CONFIG}"
  [ "$output" = "1" ]
}

# a config whose last line has no newline would otherwise get the block glued
# onto it, turning the budget into 500"# Backup retention ...
@test "the block starts on its own line" {
  printf 'arkbackupdir="/app/backup"\narkMaxBackupSizeMB="500"' > "${CONFIG}"

  add_backup_retention_to_arkmanager_cfg

  run grep -c '^arkMaxBackupSizeMB="500"$' "${CONFIG}"
  [ "$output" = "1" ]
}

# arkmanager may be sourcing this file at any moment, so it has to be swapped
# whole. A config that grew in place kept its inode and was readable half done
@test "the config is replaced rather than appended in place" {
  write_config_without_the_blocks
  local before after
  before="$(file_inode "${CONFIG}")"

  add_backup_retention_to_arkmanager_cfg

  after="$(file_inode "${CONFIG}")"
  [ "${before}" != "${after}" ]
}

# through a symlink cp can hand back a symlink as the staged file, and then the
# append runs straight into the live config instead of the copy
@test "a symlinked config is replaced rather than written through" {
  local target="${BATS_TEST_TMPDIR}/real-config.cfg"
  local before after
  write_config_without_the_blocks
  command mv "${CONFIG}" "${target}"
  ln -s "${target}" "${CONFIG}"
  before="$(file_inode "${target}")"

  add_backup_retention_to_arkmanager_cfg

  after="$(file_inode "${target}")"
  [ "${before}" != "${after}" ]
}

@test "a symlinked config stays a symlink and its target gets the block" {
  local target="${BATS_TEST_TMPDIR}/real-config.cfg"
  write_config_without_the_blocks
  command mv "${CONFIG}" "${target}"
  ln -s "${target}" "${CONFIG}"

  add_backup_retention_to_arkmanager_cfg

  [ -L "${CONFIG}" ]
  [ "$(readlink "${CONFIG}")" = "${target}" ]
  run grep -cF '|| arkMaxBackupSizeMB=' "${target}"
  [ "$output" = "1" ]
}

@test "a symlinked config is migrated only once" {
  local target="${BATS_TEST_TMPDIR}/real-config.cfg"
  write_config_without_the_blocks
  command mv "${CONFIG}" "${target}"
  ln -s "${target}" "${CONFIG}"

  add_backup_retention_to_arkmanager_cfg
  add_backup_retention_to_arkmanager_cfg

  run grep -cF '|| arkMaxBackupSizeMB=' "${target}"
  [ "$output" = "1" ]
}

# through a symlink the append would land in the live config instead of the
# staged copy, which is exactly the crash the staging exists to prevent
@test "a failed copy through a symlinked config leaves the target alone" {
  local target="${BATS_TEST_TMPDIR}/real-config.cfg"
  write_config_without_the_blocks
  command mv "${CONFIG}" "${target}"
  ln -s "${target}" "${CONFIG}"
  command cp "${target}" "${BATS_TEST_TMPDIR}/expected.cfg"

  cp() { return 1; }
  add_backup_retention_to_arkmanager_cfg
  unset -f cp

  run diff "${BATS_TEST_TMPDIR}/expected.cfg" "${target}"
  [ "$status" -eq 0 ]
}

@test "a marker the block does not contain is refused" {
  write_config_without_the_blocks

  run add_block_to_arkmanager_cfg 'bogus settings' 'never-in-the-block' 'someSetting=1'

  [ "$status" -eq 1 ]
  assert_contains "$output" "does not occur in the bogus settings block"
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

# the staged path is what the TERM/INT handler cleans up, so it has to be
# cleared again once the file is gone
@test "leaves no staged path recorded for the signal handler" {
  write_config_without_the_blocks

  add_backup_retention_to_arkmanager_cfg

  [ -z "${STAGED_CONFIG}" ]
}

# the Discord migration appends to the same file in the same shape, so no
# marker may match another migration's block
@test "coexists with the other config migrations" {
  write_config_without_the_blocks

  add_discord_to_arkmanager_cfg
  add_backup_retention_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg
  add_discord_to_arkmanager_cfg
  add_backup_retention_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg

  run grep -cF '|| discordWebhookURL=' "${CONFIG}"
  [ "$output" = "1" ]
  run grep -cF '|| arkMaxBackupSizeMB=' "${CONFIG}"
  [ "$output" = "1" ]
  run grep -cF '|| arkAlwaysRestartOnCrash=true' "${CONFIG}"
  [ "$output" = "1" ]
}

@test "a config carrying every migration still sources cleanly" {
  write_config_without_the_blocks
  add_discord_to_arkmanager_cfg
  add_backup_retention_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg

  DISCORD_WEBHOOK_URL="https://example.invalid/hook"
  MAX_BACKUP_SIZE_MB="4096"
  ALWAYS_RESTART_ON_CRASH="true"
  source "${CONFIG}"

  [ "${discordWebhookURL}" = "https://example.invalid/hook" ]
  [ "${arkMaxBackupSizeMB}" = "4096" ]
  [ "${arkAlwaysRestartOnCrash}" = "true" ]
}

@test "migrates the config without calling arkmanager or steamcmd" {
  write_config_without_the_blocks

  add_backup_retention_to_arkmanager_cfg
  add_always_restart_on_crash_to_arkmanager_cfg

  assert_stubs_installed_and_unused
}
