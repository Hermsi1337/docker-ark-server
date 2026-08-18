#!/usr/bin/env bats

load helper

setup() {
  load_docker_entrypoint
  write_user_crontab
}

@test "without BACKUP_CRON the crontab is not touched at all" {
  cp "${TEMPLATE_DIRECTORY}/crontab" "${ARK_SERVER_VOLUME}/crontab"

  render_generated_cronjobs

  run diff "${TEMPLATE_DIRECTORY}/crontab" "${ARK_SERVER_VOLUME}/crontab"
  [ "$status" -eq 0 ]
}

@test "renders the backup job into a marked block" {
  BACKUP_CRON="0 3 * * *"

  render_generated_cronjobs

  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "# >>> docker-ark-server: generated cron jobs"
  assert_contains "$output" "0 3 * * * arkmanager backup @all >> ${ARK_SERVER_VOLUME}/log/crontab.log 2>&1"
  assert_contains "$output" "# <<< docker-ark-server: generated cron jobs"
  [ "$(generated_job_lines)" -eq 1 ]
}

@test "keeps hand written jobs and regenerates only the block" {
  BACKUP_CRON="0 3 * * *"
  render_generated_cronjobs
  BACKUP_CRON="0 5 * * *"
  render_generated_cronjobs

  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "0 1 * * * echo hi"
  assert_contains "$output" "0 5 * * * arkmanager backup @all"
  assert_not_contains "$output" "0 3 * * * arkmanager backup @all"
  [ "$(generated_job_lines)" -eq 1 ]
}

@test "clearing BACKUP_CRON removes the block and leaves the rest" {
  BACKUP_CRON="0 3 * * *"
  render_generated_cronjobs
  BACKUP_CRON=""
  render_generated_cronjobs

  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_not_contains "$output" "docker-ark-server: generated cron jobs"
  assert_contains "$output" "0 1 * * * echo hi"
  [ "$(generated_job_lines)" -eq 0 ]
}

@test "a schedule with surrounding whitespace lands trimmed in the file" {
  BACKUP_CRON="  0 3 * * *  "

  assert_valid_cron_configuration
  render_generated_cronjobs

  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "0 3 * * * arkmanager backup @all"
  assert_not_contains "$output" "  0 3 * * * arkmanager"
}

@test "a CRLF block is replaced instead of duplicated" {
  BACKUP_CRON="0 3 * * *"
  render_generated_cronjobs
  awk '{ printf "%s\r\n", $0 }' "${ARK_SERVER_VOLUME}/crontab" > "${ARK_SERVER_VOLUME}/crontab.crlf"
  mv "${ARK_SERVER_VOLUME}/crontab.crlf" "${ARK_SERVER_VOLUME}/crontab"

  render_generated_cronjobs

  [ "$(grep -c 'docker-ark-server: generated cron jobs - do not edit' "${ARK_SERVER_VOLUME}/crontab")" -eq 1 ]
  [ "$(generated_job_lines)" -eq 1 ]
}

@test "a CRLF block disappears when BACKUP_CRON is cleared" {
  BACKUP_CRON="0 3 * * *"
  render_generated_cronjobs
  awk '{ printf "%s\r\n", $0 }' "${ARK_SERVER_VOLUME}/crontab" > "${ARK_SERVER_VOLUME}/crontab.crlf"
  mv "${ARK_SERVER_VOLUME}/crontab.crlf" "${ARK_SERVER_VOLUME}/crontab"
  BACKUP_CRON=""

  render_generated_cronjobs

  [ "$(generated_job_lines)" -eq 0 ]
}

@test "an indented marker is not mistaken for a generated block" {
  printf '   # >>> docker-ark-server: generated cron jobs - do not edit, this block is rewritten on every start >>>\n' \
    >> "${ARK_SERVER_VOLUME}/crontab"

  run render_generated_cronjobs

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a begin marker without its end marker is an error, not a silent delete" {
  printf '%s\n0 3 * * * arkmanager backup @all\n' "${CRON_BLOCK_BEGIN}" >> "${ARK_SERVER_VOLUME}/crontab"
  local before
  before="$(cat "${ARK_SERVER_VOLUME}/crontab")"
  BACKUP_CRON="0 3 * * *"

  run render_generated_cronjobs

  [ "$status" -eq 1 ]
  assert_contains "$output" "is broken"
  [ "$(cat "${ARK_SERVER_VOLUME}/crontab")" = "${before}" ]
}

@test "an end marker without a begin marker is an error too" {
  printf '%s\n' "${CRON_BLOCK_END}" >> "${ARK_SERVER_VOLUME}/crontab"
  BACKUP_CRON="0 3 * * *"

  run render_generated_cronjobs

  [ "$status" -eq 1 ]
  assert_contains "$output" "is broken"
}

@test "writes the SHELL and BASH_ENV header into a crontab from an older image" {
  printf '# crontab from an old image\n0 1 * * * echo hi\n' > "${ARK_SERVER_VOLUME}/crontab"
  BACKUP_CRON="0 3 * * *"

  render_generated_cronjobs

  run head -n2 "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "SHELL=/bin/bash"
  assert_contains "$output" "BASH_ENV=${ARK_SERVER_VOLUME}/environment"
  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "0 1 * * * echo hi"
}

@test "replaces a SHELL that would ignore BASH_ENV" {
  printf 'SHELL=/bin/sh\nBASH_ENV=%s/environment\n0 1 * * * echo hi\n' "${ARK_SERVER_VOLUME}" \
    > "${ARK_SERVER_VOLUME}/crontab"
  BACKUP_CRON="0 3 * * *"

  render_generated_cronjobs

  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "SHELL=/bin/bash"
  assert_not_contains "$output" "SHELL=/bin/sh"
}

@test "the header is written once, a second start changes nothing" {
  printf '# crontab from an old image\n0 1 * * * echo hi\n' > "${ARK_SERVER_VOLUME}/crontab"
  BACKUP_CRON="0 3 * * *"
  render_generated_cronjobs
  local after_first
  after_first="$(cat "${ARK_SERVER_VOLUME}/crontab")"

  render_generated_cronjobs

  [ "$(cat "${ARK_SERVER_VOLUME}/crontab")" = "${after_first}" ]
}

@test "counts the generated jobs for the crontab load check" {
  BACKUP_CRON="0 3 * * *"
  render_generated_cronjobs
  [ "${GENERATED_CRON_JOB_COUNT}" -eq 1 ]

  BACKUP_CRON=""
  render_generated_cronjobs
  [ "${GENERATED_CRON_JOB_COUNT}" -eq 0 ]
}

@test "a crontab path that is a directory fails with its own message" {
  rm -f "${ARK_SERVER_VOLUME}/crontab"
  mkdir "${ARK_SERVER_VOLUME}/crontab"

  run assert_crontab_is_regular_file

  [ "$status" -eq 1 ]
  assert_contains "$output" "is not a regular file"
  assert_not_contains "$output" "marker"
}

@test "a regular crontab passes the file check" {
  run assert_crontab_is_regular_file

  [ "$status" -eq 0 ]
}

@test "UPDATE_WARN_MINUTES accepts whole numbers including zero" {
  UPDATE_WARN_MINUTES="0"
  run assert_valid_cron_configuration
  [ "$status" -eq 0 ]

  UPDATE_WARN_MINUTES="30"
  run assert_valid_cron_configuration
  [ "$status" -eq 0 ]
}

@test "UPDATE_WARN_MINUTES rejects anything that is not a whole number" {
  UPDATE_WARN_MINUTES="abc"
  run assert_valid_cron_configuration
  [ "$status" -eq 1 ]
  assert_contains "$output" "whole number of minutes"

  UPDATE_WARN_MINUTES="-5"
  run assert_valid_cron_configuration
  [ "$status" -eq 1 ]

  UPDATE_WARN_MINUTES="1.5"
  run assert_valid_cron_configuration
  [ "$status" -eq 1 ]
}

@test "warns about the scheduling variables this image does not have" {
  UPDATE_CRON="0 4 * * *"

  run assert_valid_cron_configuration

  [ "$status" -eq 0 ]
  assert_contains "$output" "UPDATE_CRON is not supported by this image and is ignored"
  assert_contains "$output" "UPDATE_ON_START=true"
}

@test "no warning when the unsupported variables are empty" {
  UPDATE_CRON=""
  RESTART_CRON=""

  run assert_valid_cron_configuration

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "never generates an update or restart job" {
  BACKUP_CRON="0 3 * * *"
  UPDATE_CRON="0 4 * * *"
  RESTART_CRON="0 5 * * *"

  render_generated_cronjobs

  # the template ships commented update examples, so only active lines count
  [ "$(grep -c '^[^#]*arkmanager update' "${ARK_SERVER_VOLUME}/crontab")" -eq 0 ]
  [ "$(grep -c '^[^#]*arkmanager restart' "${ARK_SERVER_VOLUME}/crontab")" -eq 0 ]
  [ "$(generated_job_lines)" -eq 1 ]
  [ "${GENERATED_CRON_JOB_COUNT}" -eq 1 ]
}

# the shipped template documents the flag in a comment, so only active job
# lines can answer whether the generated job carries it
generated_cluster_job_lines() {
  grep -c '^[^#]*arkmanager backup @all --cluster' "${ARK_SERVER_VOLUME}/crontab" || true
}

@test "the backup job leaves the cluster data out without the opt-in" {
  BACKUP_CRON="0 3 * * *"
  CLUSTER_ID="my-cluster"

  render_generated_cronjobs

  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "0 3 * * * arkmanager backup @all >> ${ARK_SERVER_VOLUME}/log/crontab.log 2>&1"
  [ "$(generated_cluster_job_lines)" -eq 0 ]
}

@test "the backup job takes the cluster data with the opt-in" {
  BACKUP_CRON="0 3 * * *"
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"

  render_generated_cronjobs

  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "0 3 * * * arkmanager backup @all --cluster >> ${ARK_SERVER_VOLUME}/log/crontab.log 2>&1"
  [ "$(generated_job_lines)" -eq 1 ]
}

@test "the opt-in without a cluster id changes nothing" {
  BACKUP_CRON="0 3 * * *"
  BACKUP_CLUSTER="true"
  CLUSTER_ID=""

  render_generated_cronjobs

  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "0 3 * * * arkmanager backup @all >> ${ARK_SERVER_VOLUME}/log/crontab.log 2>&1"
  [ "$(generated_cluster_job_lines)" -eq 0 ]
}

@test "turning the opt-in off again drops the flag from the block" {
  BACKUP_CRON="0 3 * * *"
  BACKUP_CLUSTER="true"
  CLUSTER_ID="my-cluster"
  render_generated_cronjobs

  BACKUP_CLUSTER="false"
  render_generated_cronjobs

  run cat "${ARK_SERVER_VOLUME}/crontab"
  assert_contains "$output" "0 3 * * * arkmanager backup @all >> ${ARK_SERVER_VOLUME}/log/crontab.log 2>&1"
  [ "$(generated_cluster_job_lines)" -eq 0 ]
  assert_contains "$output" "0 1 * * * echo hi"
  [ "$(generated_job_lines)" -eq 1 ]
}

@test "rendering never calls arkmanager or steamcmd" {
  BACKUP_CRON="0 3 * * *"

  render_generated_cronjobs

  assert_stubs_installed_and_unused
}
