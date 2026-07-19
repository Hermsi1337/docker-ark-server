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
  local SERVER_EXEC="${SERVER_DIR}/ShooterGame/Binaries/Linux/ShooterGameServer"
  if [ ! -d "${SERVER_DIR}" ]; then
    echo "${SERVER_DIR} not found ..."
    return 0
  fi

  # Backwards compatibility - but only trust version.txt if the server
  # executable actually exists, otherwise trigger a repair install
  local VERSION_FILE="${SERVER_DIR}/version.txt"
  if [ -f "${VERSION_FILE}" ] && [ -s "${SERVER_EXEC}" ]; then
    echo "Already installed. (found ${VERSION_FILE})"
    return 1
  fi

  local INSTALLED_FILES=(
    "${SERVER_DIR}/steamapps/appmanifest_376030.acf"
    "${SERVER_EXEC}"
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

function assert_free_disk_space() {
  # a fresh ARK install needs roughly 25GB (plus staging/backup headroom)
  local REQUIRED_MB="25000"
  local AVAILABLE_MB

  if [[ "${SKIP_DISK_CHECK}" == "true" ]]; then
    return
  fi

  AVAILABLE_MB="$(df -Pm "${ARK_SERVER_VOLUME}" | awk 'NR==2 {print $4}')"
  if [[ -n "${AVAILABLE_MB}" ]] && (( AVAILABLE_MB < REQUIRED_MB )); then
    echo "ERROR: Not enough free disk space on ${ARK_SERVER_VOLUME}:"
    echo "       ${AVAILABLE_MB}MB available, ~${REQUIRED_MB}MB required for the ARK server files."
    echo "       Free up disk space, or set SKIP_DISK_CHECK=true to install anyway."
    exit 1
  fi
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

# export the container environment for cron jobs (minus shell bookkeeping):
# the bundled crontab loads it via BASH_ENV so that arkmanager and its
# bash-based config files see the same variables as the server process
export -p | grep -Ev '^declare -x (PWD|OLDPWD|SHLVL)($|=)' > "${ARK_SERVER_VOLUME}/environment"
chmod 600 "${ARK_SERVER_VOLUME}/environment" || echo "Failed to restrict permissions on ${ARK_SERVER_VOLUME}/environment, continuing startup..."

echo "Setting up folder and file structure..."
create_missing_dir "${ARK_SERVER_VOLUME}/log" "${ARK_SERVER_VOLUME}/backup" "${ARK_SERVER_VOLUME}/staging"

# copy from template to server volume
copy_missing_file "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${ARK_TOOLS_DIR}/arkmanager.cfg"
copy_missing_file "${TEMPLATE_DIRECTORY}/arkmanager-user.cfg" "${ARK_TOOLS_DIR}/instances/main.cfg"

[[ -L "${ARK_SERVER_VOLUME}/Game.ini" ]] ||
  ln -s ./server/ShooterGame/Saved/Config/LinuxServer/Game.ini Game.ini
[[ -L "${ARK_SERVER_VOLUME}/GameUserSettings.ini" ]] ||
  ln -s ./server/ShooterGame/Saved/Config/LinuxServer/GameUserSettings.ini GameUserSettings.ini

if needs_install; then
  echo "No game files found. Installing..."

  assert_free_disk_space

  create_missing_dir \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/SavedArks" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux"

  touch "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"
  chmod +x "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"

  if ! ${ARKMANAGER} install --verbose ${BETA_ARGS[@]}; then
    echo "ERROR: Installation failed - check the steamcmd output above."
    echo "       Common causes: not enough disk space ($(df -Ph "${ARK_SERVER_VOLUME}" | awk 'NR==2 {print $4}') left on ${ARK_SERVER_VOLUME}), network hiccups."
    exit 1
  fi

  # steamcmd occasionally reports success although the download is incomplete
  # (e.g. 'state is 0x202 after update job' on full disks) - verify it
  if needs_install > /dev/null; then
    echo "ERROR: Installation finished but the server files are still incomplete."
    echo "       Check the steamcmd output above and the free disk space on ${ARK_SERVER_VOLUME}"
    echo "       ($(df -Ph "${ARK_SERVER_VOLUME}" | awk 'NR==2 {print $4}') left), then restart the container to retry."
    exit 1
  fi
fi

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
