#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  RUNNING_INSTANCES="${ARK_SERVER_VOLUME}/running-instances"
}

@test "writes one instance per line" {
  write_running_instances main sub.Fjordur sub.Caballus_P

  [ "$(cat "${RUNNING_INSTANCES}")" = "$(printf 'main\nsub.Fjordur\nsub.Caballus_P')" ]
}

@test "leaves no temp file behind" {
  write_running_instances main

  [ ! -e "${RUNNING_INSTANCES}.tmp" ]
}

@test "replaces the list of an earlier run" {
  printf 'main\nsub.Ghost\n' > "${RUNNING_INSTANCES}"

  write_running_instances main

  [ "$(cat "${RUNNING_INSTANCES}")" = "main" ]
}

@test "fails and warns when the volume cannot be written" {
  export ARK_SERVER_VOLUME="${BATS_TEST_TMPDIR}/missing/volume"

  run write_running_instances main

  [ "$status" -eq 1 ]
  assert_contains "$output" "will report unhealthy"
  [ ! -e "${BATS_TEST_TMPDIR}/missing/volume/running-instances" ]
}

@test "keeps the previous list when the write fails" {
  printf 'main\n' > "${RUNNING_INSTANCES}"
  # a directory in the way fails the write for root as well
  mkdir -p "${RUNNING_INSTANCES}.tmp"

  run write_running_instances main sub.Fjordur

  [ "$status" -eq 1 ]
  [ "$(cat "${RUNNING_INSTANCES}")" = "main" ]
}

@test "writes the list without calling arkmanager or steamcmd" {
  write_running_instances main

  assert_stubs_installed_and_unused
}
