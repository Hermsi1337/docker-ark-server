#!/usr/bin/env bash

# bats runs the test bodies with the system bash, and on bash 3.2 a failing
# non-final '[[ ... ]]' does not fail the test. Assert with '[ ... ]' or with
# the helpers below, never with '[[ ... ]]'.

# Loads the entrypoint functions into the current test without running the
# startup sequence, and points every path at the test's own tmpdir. The stub
# directory comes first on PATH so a stray arkmanager/steamcmd call is caught
# instead of hitting the real tools or the network.
load_entrypoint() {
  export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  export STUB_DIR="${BATS_TEST_DIRNAME}/stubs"
  export PATH="${STUB_DIR}:${PATH}"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-calls.log"

  export ARK_SERVER_VOLUME="${BATS_TEST_TMPDIR}/volume"
  export ARK_TOOLS_DIR="${BATS_TEST_TMPDIR}/arkmanager"
  export TEMPLATE_DIRECTORY="${REPO_ROOT}/conf.d"

  mkdir -p "${ARK_SERVER_VOLUME}" "${ARK_TOOLS_DIR}/instances"
  : > "${STUB_LOG}"

  source "${REPO_ROOT}/bin/steam-entrypoint.sh"
}

# Same for the root entrypoint: sourcing it defines the cron helpers without
# running the startup sequence, which would need root and a real volume.
load_docker_entrypoint() {
  export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  export STUB_DIR="${BATS_TEST_DIRNAME}/stubs"
  export PATH="${STUB_DIR}:${PATH}"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-calls.log"

  export ARK_SERVER_VOLUME="${BATS_TEST_TMPDIR}/volume"
  export TEMPLATE_DIRECTORY="${REPO_ROOT}/conf.d"
  export BACKUP_CRON=""
  export UPDATE_WARN_MINUTES=""

  mkdir -p "${ARK_SERVER_VOLUME}"
  : > "${STUB_LOG}"

  source "${REPO_ROOT}/bin/docker-entrypoint.sh"
}

# A crontab in the volume, template plus a job the user added by hand.
write_user_crontab() {
  cp "${TEMPLATE_DIRECTORY}/crontab" "${ARK_SERVER_VOLUME}/crontab"
  printf '# my own job\n0 1 * * * echo hi\n' >> "${ARK_SERVER_VOLUME}/crontab"
}

generated_job_lines() {
  grep -c '^[^#]*arkmanager backup' "${ARK_SERVER_VOLUME}/crontab" || true
}

assert_contains() {
  case "${1}" in
    *"${2}"*) return 0 ;;
  esac

  echo "expected to contain: ${2}"
  echo "actual: ${1}"
  return 1
}

assert_not_contains() {
  case "${1}" in
    *"${2}"*)
      echo "expected NOT to contain: ${2}"
      echo "actual: ${1}"
      return 1
      ;;
  esac
}

assert_stubs_installed_and_unused() {
  local tool resolved

  for tool in arkmanager steamcmd; do
    resolved="$(command -v "${tool}")"
    if [ "${resolved}" != "${STUB_DIR}/${tool}" ]; then
      echo "expected ${tool} to resolve to ${STUB_DIR}/${tool}, got '${resolved}'"
      return 1
    fi
  done

  if [ -s "${STUB_LOG}" ]; then
    echo "expected no stub calls, got:"
    cat "${STUB_LOG}"
    return 1
  fi
}

stub_df_available_mb() {
  local bin_dir="${BATS_TEST_TMPDIR}/bin"

  mkdir -p "${bin_dir}"
  {
    echo '#!/usr/bin/env bash'
    echo 'echo "Filesystem 1M-blocks Used Available Capacity Mounted-on"'
    echo "echo \"fake 1 1 ${1} 1% /\""
  } > "${bin_dir}/df"
  chmod +x "${bin_dir}/df"

  export PATH="${bin_dir}:${PATH}"
}

stub_df_without_output() {
  local bin_dir="${BATS_TEST_TMPDIR}/bin"

  mkdir -p "${bin_dir}"
  {
    echo '#!/usr/bin/env bash'
    echo 'exit 1'
  } > "${bin_dir}/df"
  chmod +x "${bin_dir}/df"

  export PATH="${bin_dir}:${PATH}"
}
