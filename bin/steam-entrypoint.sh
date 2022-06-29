#!/usr/bin/env bash

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

if [[ "$(whoami)" != "${STEAM_USER}" ]]; then
  echo "run this script as steam-user"
  exit 1
fi

function may_update() {
  if [[ "${UPDATE_ON_START}" != "true" ]]; then
    return
  fi

  echo "\$UPDATE_ON_START is 'true'..."

  # auto checks if a update is needed, if yes, then update the server or mods
  # (otherwise it just does nothing)
  ${ARKMANAGER} update --verbose --update-mods --backup --no-autostart
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

args=("$*")
if [[ "${ENABLE_CROSSPLAY}" == "true" ]]; then
  args=('--arkopt,-crossplay' "${args[@]}")
fi
if [[ "${DISABLE_BATTLEYE}" == "true" ]]; then
  args=('--arkopt,-NoBattlEye' "${args[@]}")
fi

echo "_______________________________________"
echo ""
echo "# Ark Server - $(date)"
echo "# HERMSI_VERSION: '${HERMSI_VERSION}'"
echo "# RUNNING AS USER '${STEAM_USER}'"
echo "# ARGS: ${args[*]}"
echo "_______________________________________"

ARKMANAGER="$(command -v arkmanager)"
[[ -x "${ARKMANAGER}" ]] || (
  echo "Arkamanger is missing"
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

if [[ ! -d ${ARK_SERVER_VOLUME}/server ]] || [[ ! -f ${ARK_SERVER_VOLUME}/server/version.txt ]]; then
  echo "No game files found. Installing..."

  create_missing_dir \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/SavedArks" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux"

  touch "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"
  chmod +x "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"

  ${ARKMANAGER} install --verbose
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

exec "${ARKMANAGER}" run --verbose ${args[@]}
