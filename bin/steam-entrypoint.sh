#!/usr/bin/env bash

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

if [[ "$(whoami)" != "${STEAM_USER}" ]]; then
  echo "run this script as steam-user"
  exit 1
fi

# minimal stop handler for the install/update phase: bash as PID 1 would
# otherwise ignore SIGTERM entirely; replaced by stop_server once the
# server is about to run
trap 'exit 143' TERM INT

function may_update() {
  if [[ "${UPDATE_ON_START}" != "true" ]]; then
    return
  fi

  echo "\$UPDATE_ON_START is 'true'..."

  # auto checks if a update is needed, if yes, then update the server or mods
  # (otherwise it just does nothing)
  ${ARKMANAGER} update --verbose --update-mods --backup --no-autostart ${BETA_ARGS[@]}
}

function stop_server() {
  echo "Caught stop signal, gracefully stopping the ARK server..."

  if [[ "${WARN_ON_STOP}" == "true" ]]; then
    ${ARKMANAGER} broadcast "Server is shutting down" || true
  fi

  ${ARKMANAGER} stop --saveworld || echo "Graceful stop failed, the server may not have saved!"

  if [[ "${BACKUP_ON_STOP}" == "true" ]]; then
    echo "\$BACKUP_ON_STOP is 'true', creating a backup..."
    ${ARKMANAGER} backup || echo "Backup on stop failed, continuing shutdown..."
  fi

  # if the run process is still alive (e.g. the signal arrived before the
  # server pidfile existed, so stop had nothing to do), terminate it directly
  if [[ -n "${ARK_RUN_PID}" ]] && kill -0 "${ARK_RUN_PID}" 2>/dev/null; then
    kill -TERM "${ARK_RUN_PID}" 2>/dev/null || true
  fi

  [[ -z "${ARK_RUN_PID}" ]] || wait "${ARK_RUN_PID}" || true
  exit 0
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

function needs_install() {
  local SERVER_DIR="${ARK_SERVER_VOLUME}/server"
  if [ ! -d "${SERVER_DIR}" ]; then
    echo "${SERVER_DIR} not found ..."
    return 0
  fi

  # Backwards compatibility
  local VERSION_FILE="${SERVER_DIR}/version.txt"
  if [ -f "${VERSION_FILE}" ]; then
    echo "Already installed. (found ${VERSION_FILE})"
    return 1
  fi

  local INSTALLED_FILES=(
    "${SERVER_DIR}/steamapps/appmanifest_376030.acf"
    "${SERVER_DIR}/ShooterGame/Binaries/Linux/ShooterGameServer"
  )
  for FILE in "${INSTALLED_FILES[@]}"; do
    if [ ! -s "${FILE}" ]; then
      echo "${FILE} is not complete ..."
      return 0
    fi
  done

  echo "Already installed."
  return 1
}

args=("$*")
if [[ "${ENABLE_CROSSPLAY}" == "true" ]]; then
  args=('--arkopt,-crossplay' "${args[@]}")
fi
if [[ "${DISABLE_BATTLEYE}" == "true" ]]; then
  args=('--arkopt,-NoBattlEye' "${args[@]}")
fi
BETA_ARGS=(${BETA:+--beta=${BETA}} ${BETA_ACCESSCODE:+--betapassword=${BETA_ACCESSCODE}})

echo "_______________________________________"
echo ""
echo "# Ark Server - $(date)"
echo "# IMAGE_VERSION: '${IMAGE_VERSION}'"
echo "# RUNNING AS USER '${STEAM_USER}' - '$(id -u)'"
echo "# ARGS: ${args[*]}"
if [ -n "${BETA}" ]; then
  echo "# BETA: ${BETA}"
fi
echo "_______________________________________"

ARKMANAGER="$(command -v arkmanager)"
[[ -x "${ARKMANAGER}" ]] || (
  echo "Arkmanager is missing"
  exit 1
)

cd "${ARK_SERVER_VOLUME}"

echo "Setting up folder and file structure..."
create_missing_dir "${ARK_SERVER_VOLUME}/log" "${ARK_SERVER_VOLUME}/backup" "${ARK_SERVER_VOLUME}/staging"

# copy from template to server volume
copy_missing_file "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${ARK_TOOLS_DIR}/arkmanager.cfg"
copy_missing_file "${TEMPLATE_DIRECTORY}/arkmanager-user.cfg" "${ARK_TOOLS_DIR}/instances/main.cfg"
copy_missing_file "${TEMPLATE_DIRECTORY}/crontab" "${ARK_SERVER_VOLUME}/crontab"

[[ -L "${ARK_SERVER_VOLUME}/Game.ini" ]] ||
  ln -s ./server/ShooterGame/Saved/Config/LinuxServer/Game.ini Game.ini
[[ -L "${ARK_SERVER_VOLUME}/GameUserSettings.ini" ]] ||
  ln -s ./server/ShooterGame/Saved/Config/LinuxServer/GameUserSettings.ini GameUserSettings.ini

if needs_install; then
  echo "No game files found. Installing..."

  create_missing_dir \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/SavedArks" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux"

  touch "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"
  chmod +x "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"

  if ! ${ARKMANAGER} install --verbose ${BETA_ARGS[@]}; then
    echo "Installation failed"
    exit 1
  fi
fi

crontab "${ARK_SERVER_VOLUME}/crontab"

if [[ -n "${GAME_MOD_IDS}" ]]; then
  echo "Installing mods: '${GAME_MOD_IDS}' ..."

  for MOD_ID in ${GAME_MOD_IDS//,/ }; do
    echo "...installing '${MOD_ID}'"

    if [[ -d "${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods/${MOD_ID}" ]]; then
      echo "...already installed"
      continue
    fi

    ${ARKMANAGER} installmod "${MOD_ID}" --verbose
    echo "...done"
  done
fi

may_update

# Run the server in the background and wait for it, so that this script stays
# PID 1 and can react to docker stop/restart: without this, the container is
# killed without a world save and players lose progress (#38).
# Docker's default grace period of 10s is far too short for an ARK world save,
# so raise it (docker stop -t / stop_grace_period) as documented in the README.
trap stop_server TERM INT

"${ARKMANAGER}" run --verbose ${args[@]} &
ARK_RUN_PID=$!
wait "${ARK_RUN_PID}"
