#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  ARKMANAGER="$(command -v arkmanager)"
  BACKUP_CLUSTER="false"
  CLUSTER_ID=""
  CLUSTER_BACKUP_ARGS=()
  BETA_ARGS=()
  ARK_RUN_PIDS=()
  UPDATE_ON_START="true"
  VALIDATE_ON_START="false"
  PRE_UPDATE_BACKUP="true"
  BACKUP_ON_STOP="true"
  WARN_ON_STOP="false"
}

# stop_server signals its own children and ends the shell, neither of which
# belongs in a test run
pkill() {
  :
}

# the update call overrides PRE_UPDATE_BACKUP for arkmanager only, so record
# the assignments before handing over to the real env
env() {
  local arg

  for arg in "$@"; do
    case "${arg}" in
      *=*) echo "env ${arg}" >> "${STUB_LOG}" ;;
      *) break ;;
    esac
  done

  command env "$@"
}

stub_calls() {
  cat "${STUB_LOG}"
}

@test "no cluster arguments without the opt-in" {
  run resolve_cluster_backup_args

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "${#CLUSTER_BACKUP_ARGS[@]}" -eq 0 ]
}

@test "the opt-in without a cluster id warns and stays inactive" {
  BACKUP_CLUSTER="true"

  run resolve_cluster_backup_args

  [ "$status" -eq 0 ]
  assert_contains "$output" "BACKUP_CLUSTER has no effect because CLUSTER_ID is not set"

  resolve_cluster_backup_args >/dev/null
  [ "${#CLUSTER_BACKUP_ARGS[@]}" -eq 0 ]
}

@test "the opt-in with a cluster id adds --cluster and warns about the retention limit" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"

  run resolve_cluster_backup_args

  [ "$status" -eq 0 ]
  assert_contains "$output" "arkMaxBackupSizeMB"
  assert_contains "$output" "delete your whole backup history"

  resolve_cluster_backup_args >/dev/null
  [ "${CLUSTER_BACKUP_ARGS[*]}" = "--cluster" ]
}

@test "the backup on stop stays unchanged without the opt-in" {
  run stop_server

  run stub_calls
  assert_contains "$output" "arkmanager backup @all"
  assert_not_contains "$output" "--cluster"
}

@test "the backup on stop includes the cluster data with the opt-in" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  resolve_cluster_backup_args >/dev/null

  run stop_server

  run stub_calls
  assert_contains "$output" "arkmanager backup @all --cluster"
}

@test "the pre-update backup stays with arkmanager without the opt-in" {
  run may_update

  run stub_calls
  assert_contains "$output" "arkmanager update @main"
  assert_contains "$output" "--backup"
  assert_not_contains "$output" "arkmanager backup @main"
  assert_not_contains "$output" "env PRE_UPDATE_BACKUP"
}

@test "the pre-update backup is taken by us with the opt-in" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  resolve_cluster_backup_args >/dev/null

  run may_update

  run stub_calls
  assert_contains "$output" "arkmanager backup @main --cluster"
  assert_contains "$output" "env PRE_UPDATE_BACKUP=false"
  assert_contains "$output" "arkmanager update @main"
  assert_not_contains "$output" "--backup"
}

@test "the pre-update backup is skipped when PRE_UPDATE_BACKUP is false" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  PRE_UPDATE_BACKUP="false"
  resolve_cluster_backup_args >/dev/null

  run may_update

  run stub_calls
  assert_not_contains "$output" "arkmanager backup @main"
  assert_contains "$output" "arkmanager update @main"
}
