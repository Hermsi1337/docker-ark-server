#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  CONFIG="${ARK_TOOLS_DIR}/arkmanager.cfg"
}

write_config_without_cluster_settings() {
  {
    echo "arkserverroot=\"${ARK_SERVER_VOLUME}/server\""
    echo 'arkbackupdir="/app/backup"'
  } > "${CONFIG}"
}

@test "adds the cluster settings to a config that predates them" {
  write_config_without_cluster_settings

  run add_cluster_to_arkmanager_cfg

  [ "$status" -eq 0 ]
  assert_contains "$output" "Adding cluster settings"
  run cat "${CONFIG}"
  assert_contains "$output" 'arkopt_ClusterDirOverride="/cluster"'
  assert_contains "$output" 'arkopt_clusterid="${CLUSTER_ID}"'
  assert_contains "$output" "arkflag_NoTransferFromFiltering=true"
}

@test "keeps the settings that were already in the config" {
  write_config_without_cluster_settings

  add_cluster_to_arkmanager_cfg

  run cat "${CONFIG}"
  assert_contains "$output" 'arkbackupdir="/app/backup"'
}

@test "adds the cluster settings only once" {
  write_config_without_cluster_settings

  add_cluster_to_arkmanager_cfg
  add_cluster_to_arkmanager_cfg
  add_cluster_to_arkmanager_cfg

  run grep -c 'arkopt_ClusterDirOverride=' "${CONFIG}"
  [ "$output" = "1" ]
}

@test "leaves the shipped config alone" {
  cp "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${CONFIG}"

  run add_cluster_to_arkmanager_cfg

  [ -z "$output" ]
  run diff "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${CONFIG}"
  [ "$status" -eq 0 ]
}

@test "the added settings stay inactive without a cluster id" {
  write_config_without_cluster_settings
  add_cluster_to_arkmanager_cfg

  CLUSTER_ID=""
  arkopt_ClusterDirOverride=""
  source "${CONFIG}"

  [ -z "${arkopt_ClusterDirOverride}" ]
}

@test "the added settings activate with a cluster id" {
  write_config_without_cluster_settings
  add_cluster_to_arkmanager_cfg

  CLUSTER_ID="my-cluster"
  source "${CONFIG}"

  [ "${arkopt_ClusterDirOverride}" = "/cluster" ]
  [ "${arkopt_clusterid}" = "my-cluster" ]
  [ "${arkflag_NoTransferFromFiltering}" = "true" ]
}
