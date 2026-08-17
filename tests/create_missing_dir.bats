#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  WORK_DIR="${BATS_TEST_TMPDIR}/work"
  mkdir -p "${WORK_DIR}"
}

@test "creates a missing directory including its parents" {
  run create_missing_dir "${WORK_DIR}/log/archive"

  [ -d "${WORK_DIR}/log/archive" ]
  assert_contains "$output" "successfully created ${WORK_DIR}/log/archive"
}

@test "creates every directory it is given" {
  create_missing_dir "${WORK_DIR}/log" "${WORK_DIR}/backup" "${WORK_DIR}/staging"

  [ -d "${WORK_DIR}/log" ]
  [ -d "${WORK_DIR}/backup" ]
  [ -d "${WORK_DIR}/staging" ]
}

@test "skips an empty argument and keeps going" {
  create_missing_dir "${WORK_DIR}/log" "" "${WORK_DIR}/backup"

  [ -d "${WORK_DIR}/log" ]
  [ -d "${WORK_DIR}/backup" ]
}

@test "keeps an existing directory and stays quiet about it" {
  mkdir -p "${WORK_DIR}/log"
  echo "keep me" > "${WORK_DIR}/log/world.ark"

  run create_missing_dir "${WORK_DIR}/log"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "${WORK_DIR}/log/world.ark")" = "keep me" ]
}

@test "does nothing without arguments" {
  run create_missing_dir

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "creates the directories without calling arkmanager or steamcmd" {
  create_missing_dir "${WORK_DIR}/log"

  assert_stubs_installed_and_unused
}
