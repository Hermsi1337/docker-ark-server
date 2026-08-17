#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  SKIP_DISK_CHECK="false"
}

@test "passes when there is enough free space" {
  stub_df_available_mb 30000

  run assert_free_disk_space

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "refuses to install with too little free space" {
  stub_df_available_mb 5000

  run assert_free_disk_space

  [ "$status" -eq 1 ]
  assert_contains "$output" "Not enough free disk space"
  assert_contains "$output" "5000MB available"
  assert_contains "$output" "SKIP_DISK_CHECK=true"
}

@test "SKIP_DISK_CHECK lets the install through" {
  stub_df_available_mb 1
  SKIP_DISK_CHECK="true"

  run assert_free_disk_space

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an existing install may repair itself on a full disk" {
  stub_df_available_mb 1
  mkdir -p "${ARK_SERVER_VOLUME}/server/ShooterGame/Content"

  run assert_free_disk_space

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a df that reports nothing does not block the install" {
  stub_df_without_output

  run assert_free_disk_space

  [ "$status" -eq 0 ]
}

@test "checks the disk without calling arkmanager or steamcmd" {
  stub_df_available_mb 30000

  run assert_free_disk_space

  assert_stubs_installed_and_unused
}
