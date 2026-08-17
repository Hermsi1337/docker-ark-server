#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  SERVER_DIR="${ARK_SERVER_VOLUME}/server"
  SERVER_EXEC="${SERVER_DIR}/ShooterGame/Binaries/Linux/ShooterGameServer"
  APP_MANIFEST="${SERVER_DIR}/steamapps/appmanifest_376030.acf"

  TARGET_MANIFEST_ID="6366771435093287465"
}

write_app_manifest() {
  mkdir -p "$(dirname "${APP_MANIFEST}")"
  printf '"AppState"\n{\n\t"appid"\t\t"376030"\n\t"buildid"\t\t"%s"\n}\n' "${1}" > "${APP_MANIFEST}"
}

# a pinned install as install_pinned_manifest leaves it: depot files unpacked,
# no appmanifest and no version.txt, and the image's own pin record
install_pinned_files() {
  mkdir -p "$(dirname "${SERVER_EXEC}")" "${SERVER_DIR}/Engine"
  echo "pinned binary" > "${SERVER_EXEC}"

  printf 'manifest=%s\nbuildid=%s\nbinary=%s\n' \
    "${TARGET_MANIFEST_ID}" "$(installed_steam_buildid)" "$(server_binary_fingerprint)" \
    > "${MANIFEST_PIN_FILE}"
}

@test "wants an install when nothing is pinned yet" {
  mkdir -p "$(dirname "${SERVER_EXEC}")" "${SERVER_DIR}/Engine"
  echo "binary" > "${SERVER_EXEC}"

  run needs_install

  [ "$status" -eq 0 ]
  assert_contains "$output" "not pinned to manifest ${TARGET_MANIFEST_ID}"
}

@test "is satisfied by a completed pinned install" {
  install_pinned_files

  run needs_install

  [ "$status" -eq 1 ]
  assert_contains "$output" "Already installed (pinned to manifest ${TARGET_MANIFEST_ID})"
}

@test "wants an install when the pin file names a different manifest" {
  install_pinned_files
  TARGET_MANIFEST_ID="385619103637186563"

  run needs_install

  [ "$status" -eq 0 ]
  assert_contains "$output" "not pinned to manifest 385619103637186563"
}

@test "wants an install when the depot did not land completely" {
  install_pinned_files
  rmdir "${SERVER_DIR}/Engine"

  run needs_install

  [ "$status" -eq 0 ]
  assert_contains "$output" "pinned server files are not complete"
}

@test "re-applies the pin when the steam build id changed" {
  write_app_manifest "111"
  install_pinned_files
  write_app_manifest "222"

  run needs_install

  [ "$status" -eq 0 ]
  assert_contains "$output" "Steam build id changed"
}

@test "re-applies the pin when an update appears where there was no appmanifest" {
  install_pinned_files
  write_app_manifest "222"

  run needs_install

  [ "$status" -eq 0 ]
  assert_contains "$output" "Steam build id changed"
}

@test "a truncated appmanifest counts as drift, not as no appmanifest" {
  install_pinned_files
  mkdir -p "$(dirname "${APP_MANIFEST}")"
  printf '"AppState"\n{\n\t"appid"\t\t"376030"\n\t"buil' > "${APP_MANIFEST}"

  run needs_install

  [ "$status" -eq 0 ]
  assert_contains "$output" "Steam build id changed"
}

@test "re-applies the pin when the server binary was replaced" {
  write_app_manifest "111"
  install_pinned_files
  echo "somebody else's binary" > "${SERVER_EXEC}"

  run needs_install

  [ "$status" -eq 0 ]
  assert_contains "$output" "server binary changed"
  assert_not_contains "$output" "Already installed"
}

@test "an unpinned server ignores a leftover pin file" {
  install_pinned_files
  write_app_manifest "111"
  TARGET_MANIFEST_ID=""

  run needs_install

  [ "$status" -eq 1 ]
  [ "$output" = "Already installed." ]
}

@test "reports no appmanifest and an unreadable one differently" {
  run installed_steam_buildid
  [ "$output" = "none" ]

  write_app_manifest "4711"
  run installed_steam_buildid
  [ "$output" = "4711" ]

  printf 'garbage' > "${APP_MANIFEST}"
  run installed_steam_buildid
  [ "$output" = "unreadable" ]
}

@test "fingerprints a missing server binary as none" {
  run server_binary_fingerprint

  [ "$output" = "none" ]
}

@test "checks the pin without calling arkmanager or steamcmd" {
  install_pinned_files

  run needs_install

  assert_stubs_installed_and_unused
}

@test "a pinned install needs room for the volume and the staging copy" {
  export STEAM_HOME="${BATS_TEST_TMPDIR}/steamhome"
  mkdir -p "${STEAM_HOME}/steamcmd"
  SKIP_DISK_CHECK="false"
  stub_df_available_mb 30000

  run assert_free_disk_space

  [ "$status" -eq 1 ]
  assert_contains "$output" "~50000MB required"
}

@test "a re-pin only needs room for the staging copy" {
  export STEAM_HOME="${BATS_TEST_TMPDIR}/steamhome"
  mkdir -p "${STEAM_HOME}/steamcmd" "${ARK_SERVER_VOLUME}/server/ShooterGame/Content"
  SKIP_DISK_CHECK="false"
  stub_df_available_mb 30000

  run assert_free_disk_space

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unpinned install is not charged for a staging copy" {
  export STEAM_HOME="${BATS_TEST_TMPDIR}/steamhome"
  mkdir -p "${STEAM_HOME}/steamcmd"
  TARGET_MANIFEST_ID=""
  SKIP_DISK_CHECK="false"
  stub_df_available_mb 30000

  run assert_free_disk_space

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
