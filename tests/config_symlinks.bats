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

@test "leaves existing symlinks alone" {
  mkdir -p "${CONFIG_DIR}"
  echo "kept" > "${CONFIG_DIR}/Game.ini"
  ln -s "./${CONFIG_DIR}/Game.ini" Game.ini

  heal_config_symlinks

  [ "$(cat Game.ini)" = "kept" ]
}

@test "adopts an uploaded regular file as the real config" {
  echo "uploaded by the user" > Game.ini

  run heal_config_symlinks

  [[ "$output" == *"is a regular file but should be a symlink"* ]]
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

  [[ "$output" == *"exists but is not a file - moving it aside"* ]]
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
