#!/usr/bin/env bash

set -e

[[ -z "${DEBUG}" ]] || set -x

function may_update() {
  if [[ "${UPDATE_ON_START}" != "true" ]]; then
    return
  fi

  echo "\$UPDATE_ON_START is 'true'..."

  # 0: No update is available
  if ${ARKMANAGER} checkupdate; then
    echo "...no update available"
    return
  fi

  ${ARKMANAGER} update --force --backup
}

function create_missing_dir() {
  for DIRECTORY in ${@}; do
    [[ -n "${DIRECTORY}" ]] || return
    if [[ ! -d "${DIRECTORY}" ]]; then
      mkdir -p "${DIRECTORY}"
      echo "...successfully created ${DIRECTORY}"
    fi
  done
}

function copy_missing_file() {
  SOURCE="${1}"
  DESTINATION="${2}"

  if [[ ! -f "${DESTINATION}" ]]; then
    cp -a "${SOURCE}" "${DESTINATION}"
    echo "...successfully copied ${SOURCE} to ${DESTINATION}"
  fi
}

if [[ ! "$(id -u "${STEAM_USER}")" -eq "${STEAM_UID}" ]] || [[ ! "$(id -g "${STEAM_GROUP}")" -eq "${STEAM_GID}" ]]; then
  sudo usermod -o -u "${STEAM_UID}" "${STEAM_USER}"
  sudo groupmod -o -g "${STEAM_GID}" "${STEAM_GROUP}"
  sudo chown -R "${STEAM_USER}":"${STEAM_GROUP}" "${ARK_SERVER_VOLUME}" "${STEAM_HOME}"
fi

echo "_______________________________________"
echo ""
echo "# Ark Server - $(date)"
echo "# UID ${STEAM_UID} - GID ${STEAM_GID}"
echo "_______________________________________"

ARKMANAGER="$(command -v arkmanager)"
[[ -x "${ARKMANAGER}" ]] || (
  echo "Arkamanger is missing"
  exit 1
)

cd "${ARK_SERVER_VOLUME}"

echo "Setting up folder and file structure..."
create_missing_dir "${ARK_SERVER_VOLUME}/log" "${ARK_SERVER_VOLUME}/backup" "${ARK_SERVER_VOLUME}/staging" "${ARK_SERVER_VOLUME}/template"
copy_missing_file "${STEAM_HOME}/arkmanager.cfg" "${ARK_SERVER_VOLUME}/template/arkmanager.cfg"
copy_missing_file "${STEAM_HOME}/crontab" "${ARK_SERVER_VOLUME}/template/crontab"
copy_missing_file "${ARK_SERVER_VOLUME}/template/arkmanager.cfg" "${ARK_SERVER_VOLUME}/arkmanager.cfg"
copy_missing_file "${ARK_SERVER_VOLUME}/template/crontab" "${ARK_SERVER_VOLUME}/crontab"

[[ -L "${ARK_SERVER_VOLUME}/Game.ini" ]] ||
  ln -s "${ARK_SERVER_VOLUME}"/server/ShooterGame/Saved/Config/LinuxServer/Game.ini Game.ini
[[ -L "${ARK_SERVER_VOLUME}/GameUserSettings.ini" ]] ||
  ln -s "${ARK_SERVER_VOLUME}"/server/ShooterGame/Saved/Config/LinuxServer/GameUserSettings.ini GameUserSettings.ini

if [[ ! -d ${ARK_SERVER_VOLUME}/server ]] || [[ ! -f ${ARK_SERVER_VOLUME}/server/version.txt ]]; then
  echo "No game files found. Installing..."
  create_missing_dir \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/SavedArks" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux"
  touch "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"
  ${ARKMANAGER} install
else
  may_update
fi

ACTIVE_CRONS="$(grep -v "^#" "${ARK_SERVER_VOLUME}/crontab" 2>/dev/null | wc -l)"
if [[ ${ACTIVE_CRONS} -gt 0 ]]; then
  echo "Loading crontab..."
  crontab "${ARK_SERVER_VOLUME}/crontab"
  sudo cron -f &
  echo "...done"
else
  echo "No crontab set"
fi

exec ${ARKMANAGER} run
