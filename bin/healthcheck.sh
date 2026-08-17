#!/usr/bin/env bash

set -e

if [[ "${DISABLE_HEALTHCHECK}" == "true" ]]; then
  echo "healthy: disabled via DISABLE_HEALTHCHECK"
  exit 0
fi

if [[ "$(id -u)" == "0" ]]; then
  exec gosu "${STEAM_USER}" "${0}" "$@"
fi

ARKMANAGER="$(command -v arkmanager)"
ARK_TOOLS_CONFIG_DIR="${ARK_TOOLS_DIR:-/etc/arkmanager}"
RUNNING_INSTANCES_FILE="${ARK_SERVER_VOLUME}/running-instances"
UPDATE_GRACE_MARKER="${ARK_SERVER_VOLUME}/.healthcheck-update-grace"
STATUS_TIMEOUT_SECONDS="10"
STATUS_KILL_AFTER_SECONDS="5"

UPDATE_GRACE_MINUTES="${HEALTHCHECK_UPDATE_GRACE_MINUTES:-30}"
if [[ ! "${UPDATE_GRACE_MINUTES}" =~ ^[0-9]+$ ]]; then
  echo "WARNING: HEALTHCHECK_UPDATE_GRACE_MINUTES='${UPDATE_GRACE_MINUTES}' is not a number, falling back to 30"
  UPDATE_GRACE_MINUTES=30
fi

function resolve_update_lock_file() {
  (
    # these files are edited by users and may well end on a failing test, which
    # must not cost the update exemption
    set +e

    for CONFIG in "${ARK_TOOLS_CONFIG_DIR}/arkmanager.cfg" "${HOME}/.arkmanager.cfg" "${ARK_TOOLS_CONFIG_DIR}/instances/main.cfg"; do
      if [[ -r "${CONFIG}" ]]; then
        # shellcheck source=/dev/null
        source "${CONFIG}"
      fi
    done

    [[ -n "${arkserverroot}" ]] || exit 1
    printf '%s/%s\n' "${arkserverroot}" "${arkupdatelockfile:-${arkserverdir:-ShooterGame}/Saved/.ark-update.lock}"
  ) 2>/dev/null
}

function update_lock_held() {
  local LOCK_PID LOCK_CMDLINE

  [[ -n "${UPDATE_LOCK_FILE}" ]] && [[ -s "${UPDATE_LOCK_FILE}" ]] || return 1

  LOCK_PID="$(<"${UPDATE_LOCK_FILE}")"
  [[ "${LOCK_PID}" =~ ^[0-9]+$ ]] || return 1

  # upstream only checks that the pid is alive, which a recycled pid also is -
  # believing a recycled one would keep this check green for good
  LOCK_CMDLINE="$(tr -d '\0' 2>/dev/null < "/proc/${LOCK_PID}/cmdline" || true)"
  [[ "${LOCK_CMDLINE}" == *arkmanager* ]]
}

function within_update_grace() {
  local NOW SINCE

  NOW="$(date +%s)"
  if [[ -s "${UPDATE_GRACE_MARKER}" ]]; then
    SINCE="$(<"${UPDATE_GRACE_MARKER}")"
  else
    SINCE="${NOW}"
    echo "${SINCE}" > "${UPDATE_GRACE_MARKER}" || return 1
  fi

  [[ "${SINCE}" =~ ^[0-9]+$ ]] || return 1
  (( NOW - SINCE <= UPDATE_GRACE_MINUTES * 60 ))
}

# arkmanager's status forks lsof and perl, and past the line we read it calls
# api.ipify.org and the Steam API without a timeout. 'timeout' would signal the
# command but not reliably its children, which leaves one set of them behind per
# probe, so the call runs as its own process group ('set -m') and the watchdog
# signals the whole group. The pipe into grep usually ends arkmanager before it
# reaches the http calls, but that is an optimization, not the guarantee.
function instance_is_running() {
  local STATUS_PID WATCHDOG_PID RESULT

  set -m
  { "${ARKMANAGER}" status "@${1}" </dev/null 2>/dev/null | grep -qE 'Server running:.*Yes'; } &
  STATUS_PID=$!
  {
    sleep "${STATUS_TIMEOUT_SECONDS}"
    kill -TERM -- "-${STATUS_PID}" 2>/dev/null
    sleep "${STATUS_KILL_AFTER_SECONDS}"
    kill -KILL -- "-${STATUS_PID}" 2>/dev/null
  } &
  WATCHDOG_PID=$!
  set +m

  wait "${STATUS_PID}" 2>/dev/null
  RESULT=$?

  # the pipeline ending does not mean arkmanager is gone: the group signal that
  # ended it can be ignored by the command itself, and on a match grep leaves
  # while arkmanager still runs. Sweep the group before calling the watchdog off
  kill -KILL -- "-${STATUS_PID}" 2>/dev/null
  kill -KILL -- "-${WATCHDOG_PID}" 2>/dev/null
  wait "${WATCHDOG_PID}" 2>/dev/null

  return "${RESULT}"
}

# 'main' is always the first entry, so an empty or half written file (out of
# disk) cannot pass as a complete instance list
if [[ ! -s "${RUNNING_INSTANCES_FILE}" ]] || ! grep -qx "main" "${RUNNING_INSTANCES_FILE}"; then
  echo "not ready: no instances launched yet (installing, updating, or out of disk)"
  exit 1
fi

INSTANCES=()
while read -r INSTANCE; do
  [[ -n "${INSTANCE}" ]] || continue
  INSTANCES+=("${INSTANCE}")
done < "${RUNNING_INSTANCES_FILE}"

UPDATE_LOCK_FILE="$(resolve_update_lock_file || true)"
if update_lock_held; then
  UPDATE_IN_PROGRESS="true"
else
  UPDATE_IN_PROGRESS="false"
  rm -f "${UPDATE_GRACE_MARKER}"
fi

RUNNING_INSTANCES=()
STOPPED_INSTANCES=()
for INSTANCE in "${INSTANCES[@]}"; do
  if instance_is_running "${INSTANCE}"; then
    RUNNING_INSTANCES+=("${INSTANCE}")
  else
    STOPPED_INSTANCES+=("${INSTANCE}")
  fi
done

if [[ ${#STOPPED_INSTANCES[@]} -eq 0 ]]; then
  echo "healthy: running ${RUNNING_INSTANCES[*]}"
  exit 0
fi

if [[ ${#RUNNING_INSTANCES[@]} -gt 0 ]] && [[ "${HEALTHCHECK_REQUIRE_ALL_INSTANCES}" != "true" ]]; then
  echo "healthy: running ${RUNNING_INSTANCES[*]} - not running ${STOPPED_INSTANCES[*]}"
  exit 0
fi

if [[ "${UPDATE_IN_PROGRESS}" == "true" ]] && within_update_grace; then
  echo "healthy: arkmanager is updating - not running ${STOPPED_INSTANCES[*]}"
  exit 0
fi

echo "unhealthy: no server process for ${STOPPED_INSTANCES[*]}"
exit 1
