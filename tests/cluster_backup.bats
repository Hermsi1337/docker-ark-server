#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint
  stub_arkmanager_with_call_log

  ARKMANAGER="$(command -v arkmanager)"
  BACKUP_CLUSTER="false"
  CLUSTER_ID=""
  CLUSTER_BACKUP_ARGS=()
  ALL_GAME_MOD_IDS=()
  BETA=""
  BETA_ARGS=()
  ARK_RUN_PIDS=()
  UPDATE_ON_START="true"
  VALIDATE_ON_START="false"
  export PRE_UPDATE_BACKUP="true"
  BACKUP_ON_STOP="true"
  WARN_ON_STOP="false"
}

# stop_server signals its own children and ends the shell, neither of which
# belongs in a test run
pkill() {
  :
}

# Records every argument on its own, so a call that leaks an empty argument
# (what "${CLUSTER_BACKUP_ARGS[*]}" would produce on an empty array, and what
# makes arkmanager exit 1) cannot be mistaken for a clean one. The variable
# comes from the process environment, so it also proves what may_update
# actually hands over to arkmanager.
stub_arkmanager_with_call_log() {
  local bin_dir="${BATS_TEST_TMPDIR}/bin"

  mkdir -p "${bin_dir}"
  cat <<'STUB' > "${bin_dir}/arkmanager"
#!/usr/bin/env bash

{
  printf 'arkmanager'
  printf ' [%s]' "$@"
  printf ' PRE_UPDATE_BACKUP=%s\n' "${PRE_UPDATE_BACKUP-unset}"
} >> "${STUB_LOG}"

case "${1}" in
  checkupdate) exit "${STUB_CHECKUPDATE_STATUS:-0}" ;;
  checkmodupdate) exit "${STUB_CHECKMODUPDATE_STATUS:-1}" ;;
  backup) exit "${STUB_BACKUP_STATUS:-0}" ;;
esac
STUB
  chmod +x "${bin_dir}/arkmanager"

  export PATH="${bin_dir}:${PATH}"
}

server_update_is_available() {
  export STUB_CHECKUPDATE_STATUS=1
}

mod_update_is_available() {
  ALL_GAME_MOD_IDS=(487516323)
  export STUB_CHECKMODUPDATE_STATUS=0
}

assert_call() {
  if ! grep -Fxq "${1}" "${STUB_LOG}"; then
    echo "expected call: ${1}"
    echo "actual calls:"
    cat "${STUB_LOG}"
    return 1
  fi
}

refute_call_containing() {
  if grep -Fq "${1}" "${STUB_LOG}"; then
    echo "expected no call containing: ${1}"
    echo "actual calls:"
    cat "${STUB_LOG}"
    return 1
  fi
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

@test "the backup on stop passes no empty argument without the opt-in" {
  run stop_server

  assert_call "arkmanager [backup] [@all] PRE_UPDATE_BACKUP=true"
}

@test "the backup on stop includes the cluster data with the opt-in" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  resolve_cluster_backup_args >/dev/null

  run stop_server

  assert_call "arkmanager [backup] [@all] [--cluster] PRE_UPDATE_BACKUP=true"
}

@test "the pre-update backup stays with arkmanager without the opt-in" {
  run may_update

  assert_call "arkmanager [update] [@main] [--verbose] [--update-mods] [--no-autostart] [--backup] PRE_UPDATE_BACKUP=true"
  refute_call_containing "[backup] [@main]"
}

@test "no pre-update backup when nothing needs updating" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  resolve_cluster_backup_args >/dev/null

  run may_update

  refute_call_containing "[backup] [@main]"
  assert_call "arkmanager [update] [@main] [--verbose] [--update-mods] [--no-autostart] [--backup] PRE_UPDATE_BACKUP=true"
}

@test "a pending server update gets a pre-update backup with the cluster data" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  resolve_cluster_backup_args >/dev/null
  server_update_is_available

  run may_update

  [ "$status" -eq 0 ]
  assert_call "arkmanager [backup] [@main] [--cluster] PRE_UPDATE_BACKUP=true"
  assert_call "arkmanager [update] [@main] [--verbose] [--update-mods] [--no-autostart] PRE_UPDATE_BACKUP=false"
}

@test "a pending mod update gets one too" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  resolve_cluster_backup_args >/dev/null
  mod_update_is_available

  run may_update

  assert_call "arkmanager [backup] [@main] [--cluster] PRE_UPDATE_BACKUP=true"
  assert_call "arkmanager [update] [@main] [--verbose] [--update-mods] [--no-autostart] PRE_UPDATE_BACKUP=false"
}

@test "mods are not checked when none are configured" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  resolve_cluster_backup_args >/dev/null
  export STUB_CHECKMODUPDATE_STATUS=0

  run may_update

  refute_call_containing "[checkmodupdate]"
  refute_call_containing "[backup] [@main]"
}

@test "a validate run always gets a pre-update backup" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  VALIDATE_ON_START="true"
  resolve_cluster_backup_args >/dev/null

  run may_update

  refute_call_containing "[checkupdate]"
  assert_call "arkmanager [backup] [@main] [--cluster] PRE_UPDATE_BACKUP=true"
  assert_call "arkmanager [update] [@main] [--verbose] [--update-mods] [--no-autostart] [--validate] PRE_UPDATE_BACKUP=false"
}

@test "a beta run always gets a pre-update backup" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  BETA="Test"
  BETA_ARGS=(--beta=Test)
  resolve_cluster_backup_args >/dev/null

  run may_update

  refute_call_containing "[checkupdate]"
  assert_call "arkmanager [backup] [@main] [--cluster] PRE_UPDATE_BACKUP=true"
  assert_call "arkmanager [update] [@main] [--verbose] [--update-mods] [--no-autostart] [--beta=Test] PRE_UPDATE_BACKUP=false"
}

@test "a failed pre-update backup stops the update" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  resolve_cluster_backup_args >/dev/null
  server_update_is_available
  export STUB_BACKUP_STATUS=1

  run may_update

  [ "$status" -eq 1 ]
  assert_contains "$output" "refusing to update without one"
  refute_call_containing "[update] [@main]"
}

@test "PRE_UPDATE_BACKUP=false updates without any backup" {
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  export PRE_UPDATE_BACKUP="false"
  resolve_cluster_backup_args >/dev/null
  server_update_is_available

  run may_update

  refute_call_containing "[backup]"
  assert_call "arkmanager [update] [@main] [--verbose] [--update-mods] [--no-autostart] PRE_UPDATE_BACKUP=false"
}

@test "the startup sequence resolves the cluster backup arguments" {
  run grep -cx "resolve_cluster_backup_args" "${REPO_ROOT}/bin/steam-entrypoint.sh"

  [ "$output" = "1" ]
}

@test "arkmanager.cfg derives its pre-update backup from PRE_UPDATE_BACKUP" {
  PRE_UPDATE_BACKUP="false"
  source "${TEMPLATE_DIRECTORY}/arkmanager.cfg"

  [ "${arkBackupPreUpdate}" = "false" ]
}
