#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  MOUNTED="${BATS_TEST_TMPDIR}/mounted"
  CONFIG="${ARK_SERVER_VOLUME}/config"
  mkdir -p "${MOUNTED}" "${CONFIG}"

  ARK_GAME_INI_FILE=""
  ARK_GAME_USER_SETTINGS_INI_FILE=""
  INSTANCES=(main)
}

# the archive name carries a unix timestamp, so pin it where a test needs to
# know the resulting filename
stub_date_fixed() {
  local bin_dir="${BATS_TEST_TMPDIR}/bin"

  mkdir -p "${bin_dir}"
  {
    echo '#!/usr/bin/env bash'
    echo "echo ${1}"
  } > "${bin_dir}/date"
  chmod +x "${bin_dir}/date"

  export PATH="${bin_dir}:${PATH}"
}

archives_of() {
  find "$(dirname "${1}")" -name "$(basename "${1}").bak.*" | sort
}

@test "an instance without a value resolves to nothing" {
  [ -z "$(ini_file_for_instance main ARK_GAME_INI_FILE)" ]
  [ -z "$(ini_file_for_instance sub.Fjordur ARK_GAME_INI_FILE)" ]
}

@test "the main instance reads the plain variable" {
  ARK_GAME_INI_FILE="/config/Game.ini"

  [ "$(ini_file_for_instance main ARK_GAME_INI_FILE)" = "/config/Game.ini" ]
}

@test "a sub instance falls back to the main value" {
  ARK_GAME_INI_FILE="/config/Game.ini"

  [ "$(ini_file_for_instance sub.Fjordur ARK_GAME_INI_FILE)" = "/config/Game.ini" ]
}

@test "a sub instance override wins over the main value" {
  ARK_GAME_INI_FILE="/config/Game.ini"
  SUB_Fjordur_ARK_GAME_INI_FILE="/config/fjordur.ini"

  [ "$(ini_file_for_instance sub.Fjordur ARK_GAME_INI_FILE)" = "/config/fjordur.ini" ]
}

@test "the variable lookup is case sensitive like the other sub variables" {
  SUB_FJORDUR_ARK_GAME_INI_FILE="/config/shouting.ini"

  [ -z "$(ini_file_for_instance sub.Fjordur ARK_GAME_INI_FILE)" ]
}

@test "unset variables pass validation" {
  run assert_ini_files_are_usable

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a missing file is refused and names the path" {
  ARK_GAME_INI_FILE="${MOUNTED}/typo.ini"

  run assert_ini_files_are_usable

  [ "$status" -eq 1 ]
  assert_contains "$output" "nothing exists at that path"
  assert_contains "$output" "${MOUNTED}/typo.ini"
}

@test "a directory is refused with the bind mount hint" {
  mkdir -p "${MOUNTED}/Game.ini"
  ARK_GAME_INI_FILE="${MOUNTED}/Game.ini"

  run assert_ini_files_are_usable

  [ "$status" -eq 1 ]
  assert_contains "$output" "that is a directory"
  assert_contains "$output" "host side of a bind mount is missing"
}

@test "an unreadable file is refused before the copy fails" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root reads everything, so -r cannot fail"
  fi

  echo "secret" > "${MOUNTED}/Game.ini"
  chmod 000 "${MOUNTED}/Game.ini"
  ARK_GAME_INI_FILE="${MOUNTED}/Game.ini"

  run assert_ini_files_are_usable

  [ "$status" -eq 1 ]
  assert_contains "$output" "may not read it"
}

@test "an empty file is refused before it can wipe the config" {
  : > "${MOUNTED}/Game.ini"
  ARK_GAME_INI_FILE="${MOUNTED}/Game.ini"

  run assert_ini_files_are_usable

  [ "$status" -eq 1 ]
  assert_contains "$output" "it is empty"
  assert_contains "$output" "come up on vanilla defaults"
}

@test "one file for both variables is refused" {
  echo "shared" > "${MOUNTED}/both.ini"
  ARK_GAME_INI_FILE="${MOUNTED}/both.ini"
  ARK_GAME_USER_SETTINGS_INI_FILE="${MOUNTED}/both.ini"

  run assert_ini_files_are_usable

  [ "$status" -eq 1 ]
  assert_contains "$output" "both name"
  assert_contains "$output" "Point them at separate files"
}

@test "two instances naming different files are refused" {
  echo "main" > "${MOUNTED}/main.ini"
  echo "fjordur" > "${MOUNTED}/fjordur.ini"
  INSTANCES=(main sub.Fjordur)
  ARK_GAME_INI_FILE="${MOUNTED}/main.ini"
  SUB_Fjordur_ARK_GAME_INI_FILE="${MOUNTED}/fjordur.ini"

  run assert_ini_files_are_usable

  [ "$status" -eq 1 ]
  assert_contains "$output" "main and sub.Fjordur name different files"
  assert_contains "$output" "share one config directory"
}

@test "two instances naming the same file are fine" {
  echo "shared" > "${MOUNTED}/shared.ini"
  INSTANCES=(main sub.Fjordur)
  ARK_GAME_INI_FILE="${MOUNTED}/shared.ini"
  SUB_Fjordur_ARK_GAME_INI_FILE="${MOUNTED}/shared.ini"

  run assert_ini_files_are_usable

  [ "$status" -eq 0 ]
}

@test "the two ini variables are tracked separately" {
  echo "game" > "${MOUNTED}/Game.ini"
  echo "settings" > "${MOUNTED}/GameUserSettings.ini"
  ARK_GAME_INI_FILE="${MOUNTED}/Game.ini"
  ARK_GAME_USER_SETTINGS_INI_FILE="${MOUNTED}/GameUserSettings.ini"

  run assert_ini_files_are_usable

  [ "$status" -eq 0 ]
}

@test "an empty source path applies nothing" {
  apply_ini_file "" "${CONFIG}/Game.ini" main

  [ ! -e "${CONFIG}/Game.ini" ]
}

@test "applies onto a destination that does not exist yet" {
  echo "declared" > "${MOUNTED}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/nested/Game.ini" main

  [ "$(cat "${CONFIG}/nested/Game.ini")" = "declared" ]
  [ -z "$(archives_of "${CONFIG}/nested/Game.ini")" ]
}

@test "archives the previous config under a timestamped name" {
  stub_date_fixed 1700000000
  echo "declared" > "${MOUNTED}/Game.ini"
  echo "live" > "${CONFIG}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  [ "$(cat "${CONFIG}/Game.ini")" = "declared" ]
  [ "$(cat "${CONFIG}/Game.ini.bak.1700000000")" = "live" ]
}

@test "never overwrites an archive that already exists" {
  stub_date_fixed 1700000000
  echo "declared" > "${MOUNTED}/Game.ini"
  echo "first" > "${CONFIG}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main
  echo "second" > "${CONFIG}/Game.ini"
  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  [ "$(cat "${CONFIG}/Game.ini.bak.1700000000")" = "first" ]
  [ "$(cat "${CONFIG}/Game.ini.bak.1700000000-1")" = "second" ]
  [ "$(cat "${CONFIG}/Game.ini")" = "declared" ]
}

@test "an unchanged config is left alone" {
  echo "declared" > "${MOUNTED}/Game.ini"
  cp "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  [ -z "$(archives_of "${CONFIG}/Game.ini")" ]
}

@test "a symlinked destination is archived by content, not as a link" {
  echo "declared" > "${MOUNTED}/Game.ini"
  echo "external" > "${BATS_TEST_TMPDIR}/external.ini"
  ln -s "${BATS_TEST_TMPDIR}/external.ini" "${CONFIG}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  archive="$(archives_of "${CONFIG}/Game.ini")"
  [ -f "${archive}" ]
  [ ! -L "${archive}" ]
  [ "$(cat "${archive}")" = "external" ]
  [ -L "${CONFIG}/Game.ini" ]
  [ "$(cat "${BATS_TEST_TMPDIR}/external.ini")" = "declared" ]
}

@test "the destination mode is set, not inherited from the source" {
  echo "declared" > "${MOUNTED}/Game.ini"
  chmod 444 "${MOUNTED}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  [ -w "${CONFIG}/Game.ini" ]
}

@test "a destination left read-only by an earlier start recovers" {
  echo "declared" > "${MOUNTED}/Game.ini"
  echo "stale" > "${CONFIG}/Game.ini"
  chmod 444 "${CONFIG}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  [ "$(cat "${CONFIG}/Game.ini")" = "declared" ]
  [ -w "${CONFIG}/Game.ini" ]
}

@test "the read-only repair also fires when the content already matches" {
  echo "declared" > "${MOUNTED}/Game.ini"
  cp "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini"
  chmod 444 "${CONFIG}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  [ -w "${CONFIG}/Game.ini" ]
  [ -z "$(archives_of "${CONFIG}/Game.ini")" ]
}

@test "a source that vanished after validation leaves the config alone" {
  echo "declared" > "${MOUNTED}/Game.ini"
  echo "live" > "${CONFIG}/Game.ini"
  ARK_GAME_INI_FILE="${MOUNTED}/Game.ini"

  assert_ini_files_are_usable
  rm "${MOUNTED}/Game.ini"
  run apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  [ "$status" -eq 1 ]
  assert_contains "$output" "nothing exists at that path"
  [ "$(cat "${CONFIG}/Game.ini")" = "live" ]
  [ -z "$(archives_of "${CONFIG}/Game.ini")" ]
}

@test "a source truncated after validation leaves the config alone" {
  echo "declared" > "${MOUNTED}/Game.ini"
  echo "live" > "${CONFIG}/Game.ini"
  ARK_GAME_INI_FILE="${MOUNTED}/Game.ini"

  assert_ini_files_are_usable
  : > "${MOUNTED}/Game.ini"
  run apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  [ "$status" -eq 1 ]
  [ "$(cat "${CONFIG}/Game.ini")" = "live" ]
}

@test "a config directory it cannot write to fails before the archive" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root writes everywhere, so the staging write cannot fail"
  fi

  echo "declared" > "${MOUNTED}/Game.ini"
  echo "live" > "${CONFIG}/Game.ini"
  chmod 555 "${CONFIG}"

  run apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  chmod 755 "${CONFIG}"
  [ "$status" -eq 1 ]
  assert_contains "$output" "The live config was left untouched"
  [ "$(cat "${CONFIG}/Game.ini")" = "live" ]
  [ -z "$(archives_of "${CONFIG}/Game.ini")" ]
}

@test "a staged copy left by a killed start is cleared" {
  echo "declared" > "${MOUNTED}/Game.ini"
  echo "live" > "${CONFIG}/Game.ini"
  echo "half written" > "${CONFIG}/Game.ini.staged.4242"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  run find "${CONFIG}" -name '*.staged.*'
  [ -z "$output" ]
  [ "$(cat "${CONFIG}/Game.ini")" = "declared" ]
}

@test "the staging cleanup only touches its own destination" {
  echo "declared" > "${MOUNTED}/Game.ini"
  echo "live" > "${CONFIG}/Game.ini"
  echo "mine" > "${CONFIG}/Game.ini.staged.4242"
  echo "the other ini" > "${CONFIG}/GameUserSettings.ini.staged.4242"
  echo "an archive" > "${CONFIG}/Game.ini.bak.1700000000"
  echo "a config helper file" > "${CONFIG}/arkmanager.cfg.aB3xY9"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  [ ! -e "${CONFIG}/Game.ini.staged.4242" ]
  [ "$(cat "${CONFIG}/GameUserSettings.ini.staged.4242")" = "the other ini" ]
  [ "$(cat "${CONFIG}/Game.ini.bak.1700000000")" = "an archive" ]
  [ "$(cat "${CONFIG}/arkmanager.cfg.aB3xY9")" = "a config helper file" ]
}

@test "no staging leftovers once the config is applied" {
  echo "declared" > "${MOUNTED}/Game.ini"
  echo "live" > "${CONFIG}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  run find "${CONFIG}" -name '*.staged.*'
  [ -z "$output" ]
}

@test "applies the config without calling arkmanager or steamcmd" {
  echo "declared" > "${MOUNTED}/Game.ini"

  apply_ini_file "${MOUNTED}/Game.ini" "${CONFIG}/Game.ini" main

  assert_stubs_installed_and_unused
}
