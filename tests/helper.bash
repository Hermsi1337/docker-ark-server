#!/usr/bin/env bash

# Loads the entrypoint functions into the current test without running the
# startup sequence, and points every path at the test's own tmpdir. The stub
# directory comes first on PATH so a stray arkmanager/steamcmd call is caught
# instead of hitting the real tools or the network.
load_entrypoint() {
  export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  export PATH="${BATS_TEST_DIRNAME}/stubs:${PATH}"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub-calls.log"

  export ARK_SERVER_VOLUME="${BATS_TEST_TMPDIR}/volume"
  export ARK_TOOLS_DIR="${BATS_TEST_TMPDIR}/arkmanager"
  export TEMPLATE_DIRECTORY="${REPO_ROOT}/conf.d"

  mkdir -p "${ARK_SERVER_VOLUME}" "${ARK_TOOLS_DIR}/instances"

  source "${REPO_ROOT}/bin/steam-entrypoint.sh"
}

assert_no_stub_calls() {
  [ ! -s "${STUB_LOG}" ]
}
