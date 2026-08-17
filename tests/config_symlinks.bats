#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  CONFIG_DIR="server/ShooterGame/Saved/Config/LinuxServer"
  cd "${ARK_SERVER_VOLUME}"
}

@test "creates both symlinks in an empty volume" {
  heal_config_symlinks

  [ -L Game.ini ]
  [ -L GameUserSettings.ini ]
  [ "$(readlink Game.ini)" = "./${CONFIG_DIR}/Game.ini" ]
  [ "$(readlink GameUserSettings.ini)" = "./${CONFIG_DIR}/GameUserSettings.ini" ]
}

@test "keeps a symlink the user pointed at a target of their own" {
  mkdir -p "${BATS_TEST_TMPDIR}/shared"
  echo "shared config" > "${BATS_TEST_TMPDIR}/shared/Game.ini"
  ln -s "${BATS_TEST_TMPDIR}/shared/Game.ini" Game.ini

  heal_config_symlinks

  [ "$(readlink Game.ini)" = "${BATS_TEST_TMPDIR}/shared/Game.ini" ]
  [ "$(cat Game.ini)" = "shared config" ]
}

@test "keeps a dangling symlink instead of replacing it" {
  ln -s /does/not/exist Game.ini

  heal_config_symlinks

  [ "$(readlink Game.ini)" = "/does/not/exist" ]
}

@test "adopts an uploaded regular file as the real config" {
  echo "uploaded by the user" > Game.ini

  run heal_config_symlinks

  assert_contains "$output" "is a regular file but should be a symlink"
  [ -L Game.ini ]
  [ "$(cat "${CONFIG_DIR}/Game.ini")" = "uploaded by the user" ]
  [ "$(cat Game.ini)" = "uploaded by the user" ]
}

@test "adopts an uploaded GameUserSettings.ini too" {
  echo "uploaded settings" > GameUserSettings.ini

  heal_config_symlinks

  [ -L GameUserSettings.ini ]
  [ "$(cat GameUserSettings.ini)" = "uploaded settings" ]
}

@test "backs up the existing config before adopting an upload" {
  mkdir -p "${CONFIG_DIR}"
  echo "previous config" > "${CONFIG_DIR}/Game.ini"
  echo "uploaded by the user" > Game.ini

  heal_config_symlinks

  [ "$(cat "${CONFIG_DIR}/Game.ini.bak")" = "previous config" ]
  [ "$(cat Game.ini)" = "uploaded by the user" ]
}

@test "moves a config directory aside before adopting an upload" {
  mkdir -p "${CONFIG_DIR}/Game.ini"
  echo "uploaded by the user" > Game.ini

  heal_config_symlinks

  [ "$(cat Game.ini)" = "uploaded by the user" ]
  run find "${CONFIG_DIR}" -maxdepth 1 -type d -name 'Game.ini.invalid.*'
  [ -n "$output" ]
}

@test "moves a directory in the volume root aside and links again" {
  mkdir Game.ini

  run heal_config_symlinks

  assert_contains "$output" "exists but is not a file - moving it aside"
  [ -L Game.ini ]
  run find . -maxdepth 1 -type d -name 'Game.ini.invalid.*'
  [ -n "$output" ]
}

@test "is idempotent" {
  echo "uploaded by the user" > Game.ini

  heal_config_symlinks
  heal_config_symlinks

  [ -L Game.ini ]
  [ "$(cat Game.ini)" = "uploaded by the user" ]
  [ ! -e "${CONFIG_DIR}/Game.ini.bak" ]
}

@test "heals the symlinks without calling arkmanager or steamcmd" {
  echo "uploaded by the user" > Game.ini

  heal_config_symlinks

  assert_stubs_installed_and_unused
}
