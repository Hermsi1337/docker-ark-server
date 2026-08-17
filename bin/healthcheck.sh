#!/usr/bin/env bash

set -e

if [[ "$(id -u)" == "0" ]]; then
  exec gosu "${STEAM_USER}" "${0}" "$@"
fi

ARKMANAGER="$(command -v arkmanager)"
RUNNING_INSTANCES_FILE="${ARK_SERVER_VOLUME}/running-instances"
UPDATE_LOCK_FILE="${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/.ark-update.lock"

function update_in_progress() {
  local LOCK_PID

  [[ -f "${UPDATE_LOCK_FILE}" ]] || return 1

  # the lock survives a hard container kill, so trust it only while the
  # process that took it is still alive (same check arkmanager does)
  LOCK_PID="$(<"${UPDATE_LOCK_FILE}")"
  [[ -n "${LOCK_PID}" ]] && kill -0 "${LOCK_PID}" 2>/dev/null
}

function instance_is_running() {
  # stop reading after the 'Server running' line: below it arkmanager queries
  # api.ipify.org and the Steam API, and a hiccup there must not make a
  # perfectly fine server look unhealthy
  "${ARKMANAGER}" status "@${1}" </dev/null 2>/dev/null | grep -qE 'Server running:.*Yes'
}

if [[ ! -f "${RUNNING_INSTANCES_FILE}" ]]; then
  echo "healthy: no instance started yet (installing or updating)"
  exit 0
fi

if update_in_progress; then
  echo "healthy: arkmanager is updating the server"
  exit 0
fi

STOPPED_INSTANCES=()
while read -r INSTANCE; do
  [[ -n "${INSTANCE}" ]] || continue
  instance_is_running "${INSTANCE}" || STOPPED_INSTANCES+=("${INSTANCE}")
done < "${RUNNING_INSTANCES_FILE}"

if [[ ${#STOPPED_INSTANCES[@]} -gt 0 ]]; then
  echo "unhealthy: no server process for instance(s): ${STOPPED_INSTANCES[*]}"
  exit 1
fi

echo "healthy: all instances are running"
