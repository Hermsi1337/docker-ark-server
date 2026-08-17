#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  CONFIG="${ARK_TOOLS_DIR}/arkmanager.cfg"
  INSTANCE_CONFIG="${ARK_TOOLS_DIR}/instances/main.cfg"
}

write_config_without_discord_settings() {
  {
    echo "arkserverroot=\"${ARK_SERVER_VOLUME}/server\""
    echo 'arkbackupdir="/app/backup"'
  } > "${CONFIG}"
}

# the example the template shipped before DISCORD_WEBHOOK_URL existed; every
# volume created back then still has this line
write_config_with_the_old_commented_example() {
  write_config_without_discord_settings
  echo '# discordWebhookURL="https://discordapp.com/api/webhooks/{webhook.id}/{webhook.token}"' >> "${CONFIG}"
}

count_generated_assignments() {
  grep -cF '|| discordWebhookURL=' "${1}"
}

@test "adds the discord setting to a config that predates it" {
  write_config_without_discord_settings

  run add_discord_to_arkmanager_cfg

  [ "$status" -eq 0 ]
  assert_contains "$output" "Adding Discord notification settings"
  run cat "${CONFIG}"
  assert_contains "$output" '[ -z "${DISCORD_WEBHOOK_URL}" ] || discordWebhookURL="${DISCORD_WEBHOOK_URL}"'
}

@test "keeps the settings that were already in the config" {
  write_config_without_discord_settings

  add_discord_to_arkmanager_cfg

  run cat "${CONFIG}"
  assert_contains "$output" 'arkbackupdir="/app/backup"'
}

@test "adds the discord setting only once" {
  write_config_without_discord_settings

  add_discord_to_arkmanager_cfg
  add_discord_to_arkmanager_cfg
  add_discord_to_arkmanager_cfg

  run count_generated_assignments "${CONFIG}"
  [ "$output" = "1" ]
}

@test "the old commented example does not count as migrated" {
  write_config_with_the_old_commented_example

  run add_discord_to_arkmanager_cfg

  [ "$status" -eq 0 ]
  assert_contains "$output" "Adding Discord notification settings"
  run count_generated_assignments "${CONFIG}"
  [ "$output" = "1" ]
}

@test "a comment naming the variable does not count as migrated" {
  write_config_without_discord_settings
  echo '# see the README for DISCORD_WEBHOOK_URL' >> "${CONFIG}"

  add_discord_to_arkmanager_cfg

  run count_generated_assignments "${CONFIG}"
  [ "$output" = "1" ]
}

@test "leaves the shipped config alone" {
  cp "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${CONFIG}"

  run add_discord_to_arkmanager_cfg

  [ -z "$output" ]
  run diff "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${CONFIG}"
  [ "$status" -eq 0 ]
}

@test "the added setting stays inactive without a webhook url" {
  write_config_without_discord_settings
  add_discord_to_arkmanager_cfg

  DISCORD_WEBHOOK_URL=""
  discordWebhookURL=""
  source "${CONFIG}"

  [ -z "${discordWebhookURL}" ]
}

@test "the added setting activates with a webhook url" {
  write_config_without_discord_settings
  add_discord_to_arkmanager_cfg

  DISCORD_WEBHOOK_URL="https://example.invalid/hook"
  source "${CONFIG}"

  [ "${discordWebhookURL}" = "https://example.invalid/hook" ]
}

@test "leaves no staged file behind" {
  write_config_without_discord_settings

  add_discord_to_arkmanager_cfg

  run find "${ARK_TOOLS_DIR}" -type f -name '*.discord.*'
  [ -z "$output" ]
  [ -z "${STAGED_CONFIG}" ]
}

@test "keeps a symlinked config a symlink and rewrites its target" {
  local target="${BATS_TEST_TMPDIR}/real-config.cfg"
  write_config_without_discord_settings
  mv "${CONFIG}" "${target}"
  ln -s "${target}" "${CONFIG}"

  add_discord_to_arkmanager_cfg

  [ -L "${CONFIG}" ]
  [ "$(readlink "${CONFIG}")" = "${target}" ]
  run count_generated_assignments "${target}"
  [ "$output" = "1" ]
}

@test "a symlinked config is migrated only once" {
  local target="${BATS_TEST_TMPDIR}/real-config.cfg"
  write_config_without_discord_settings
  mv "${CONFIG}" "${target}"
  ln -s "${target}" "${CONFIG}"

  add_discord_to_arkmanager_cfg
  add_discord_to_arkmanager_cfg

  run count_generated_assignments "${target}"
  [ "$output" = "1" ]
}

@test "does not write through a symlink planted at a guessable staged name" {
  local victim="${BATS_TEST_TMPDIR}/victim.txt"
  write_config_without_discord_settings
  echo "untouched" > "${victim}"
  # $$ is always 1 in the container, so this was the old staged path
  ln -s "${victim}" "${CONFIG}.discord.1"

  add_discord_to_arkmanager_cfg

  run cat "${victim}"
  [ "$output" = "untouched" ]
  [ ! -L "${CONFIG}" ]
  run count_generated_assignments "${CONFIG}"
  [ "$output" = "1" ]
}

@test "warns and keeps the config when the tools directory is read-only" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores directory permissions"
  fi
  write_config_without_discord_settings
  local before
  before="$(cat "${CONFIG}")"
  chmod a-w "${ARK_TOOLS_DIR}"

  run add_discord_to_arkmanager_cfg
  chmod u+w "${ARK_TOOLS_DIR}"

  [ "$status" -eq 0 ]
  assert_contains "$output" "WARNING"
  [ "$(cat "${CONFIG}")" = "${before}" ]
}

@test "no warning for a config that only carries the generated setting" {
  write_config_without_discord_settings
  add_discord_to_arkmanager_cfg

  run warn_on_hardcoded_discord_webhook

  [ -z "$output" ]
}

@test "no warning for the old commented example alone" {
  write_config_with_the_old_commented_example

  run warn_on_hardcoded_discord_webhook

  [ -z "$output" ]
}

@test "warns about a hardcoded webhook in the global config" {
  write_config_without_discord_settings
  echo 'discordWebhookURL="https://example.invalid/hardcoded"' >> "${CONFIG}"

  run warn_on_hardcoded_discord_webhook

  assert_contains "$output" "assigns discordWebhookURL directly"
  assert_contains "$output" "arkmanager.cfg"
}

@test "warns about an exported hardcoded webhook" {
  write_config_without_discord_settings
  echo 'export discordWebhookURL="https://example.invalid/hardcoded"' >> "${CONFIG}"

  run warn_on_hardcoded_discord_webhook

  assert_contains "$output" "assigns discordWebhookURL directly"
}

@test "warns about a hardcoded webhook in an instance config" {
  write_config_without_discord_settings
  add_discord_to_arkmanager_cfg
  echo 'discordWebhookURL="https://example.invalid/instance"' > "${INSTANCE_CONFIG}"

  run warn_on_hardcoded_discord_webhook

  assert_contains "$output" "instances/main.cfg"
  assert_contains "$output" "assigns discordWebhookURL directly"
}

@test "an instance config wins over the generated setting" {
  write_config_without_discord_settings
  add_discord_to_arkmanager_cfg
  echo 'discordWebhookURL="https://example.invalid/instance"' > "${INSTANCE_CONFIG}"

  DISCORD_WEBHOOK_URL="https://example.invalid/from-env"
  source "${CONFIG}"
  source "${INSTANCE_CONFIG}"

  [ "${discordWebhookURL}" = "https://example.invalid/instance" ]
}

@test "no warning without any instance config" {
  write_config_without_discord_settings
  add_discord_to_arkmanager_cfg
  rm -f "${ARK_TOOLS_DIR}/instances/"*.cfg

  run warn_on_hardcoded_discord_webhook

  [ -z "$output" ]
}

@test "migrates the config without calling arkmanager or steamcmd" {
  write_config_without_discord_settings

  add_discord_to_arkmanager_cfg
  warn_on_hardcoded_discord_webhook

  assert_stubs_installed_and_unused
}
