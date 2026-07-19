#!/usr/bin/env bash

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

if [[ ! -d "${ARK_SERVER_VOLUME}" ]]; then
  mkdir -p "${ARK_SERVER_VOLUME}"
fi

# Optionally remap the steam user to a custom UID/GID, e.g. to match the
# owner of a bind mount on NAS systems (Synology, UGREEN, ...)
if [[ -n "${PUID}${PGID}" ]]; then
  CURRENT_UID="$(id -u "${STEAM_USER}")"
  CURRENT_GID="$(id -g "${STEAM_USER}")"
  STEAM_GROUP="$(id -gn "${STEAM_USER}")"
  TARGET_UID="${PUID:-${CURRENT_UID}}"
  TARGET_GID="${PGID:-${CURRENT_GID}}"

  if [[ "${TARGET_GID}" != "${CURRENT_GID}" ]]; then
    echo "Changing GID of ${STEAM_USER} from ${CURRENT_GID} to ${TARGET_GID}..."
    groupmod -o -g "${TARGET_GID}" "${STEAM_GROUP}"
  fi
  if [[ "${TARGET_UID}" != "${CURRENT_UID}" ]]; then
    echo "Changing UID of ${STEAM_USER} from ${CURRENT_UID} to ${TARGET_UID}..."
    usermod -o -u "${TARGET_UID}" "${STEAM_USER}"
  fi
  if [[ "${TARGET_UID}" != "${CURRENT_UID}" ]] || [[ "${TARGET_GID}" != "${CURRENT_GID}" ]]; then
    echo "Adopting ownership of ${STEAM_HOME} and ${ARK_SERVER_VOLUME} (one-time, may take a while)..."
    chown -R "${STEAM_USER}": "${STEAM_HOME}" || echo "Failed setting rights on ${STEAM_HOME}, continuing startup..."
    chown -R "${STEAM_USER}": "${ARK_SERVER_VOLUME}" || echo "Failed setting rights on ${ARK_SERVER_VOLUME}, continuing startup..."
  fi
fi

chown "${STEAM_USER}": "${ARK_SERVER_VOLUME}" || echo "Failed setting rights on ${ARK_SERVER_VOLUME}, continuing startup..."

if [[ ! -d ${ARK_TOOLS_DIR} ]]; then
  mv "/etc/arkmanager" "${ARK_TOOLS_DIR}"
  rm -f "${ARK_TOOLS_DIR}/arkmanager.cfg" "${ARK_TOOLS_DIR}/instances/main.cfg"
fi

chown -R "${STEAM_USER}": "${ARK_TOOLS_DIR}" || echo "Failed setting rights on ${ARK_TOOLS_DIR}, continuing startup..."

# symlink arkmanager directories
rm -rf "/etc/arkmanager"
ln -s "${ARK_TOOLS_DIR}" "/etc/arkmanager"

# Copy the crontab template on first start and load it as root: the setgid
# crontab binary fails with "mkstemp: Permission denied" on hosts that run
# containers with no-new-privileges (e.g. some NAS systems).
if [[ ! -f "${ARK_SERVER_VOLUME}/crontab" ]]; then
  cp -a "${TEMPLATE_DIRECTORY}/crontab" "${ARK_SERVER_VOLUME}/crontab"
  # the template defaults to /app - point BASH_ENV at the actual volume path
  sed -i "s|^BASH_ENV=.*|BASH_ENV=${ARK_SERVER_VOLUME}/environment|" "${ARK_SERVER_VOLUME}/crontab"
  chown "${STEAM_USER}": "${ARK_SERVER_VOLUME}/crontab" || true
fi
crontab -u "${STEAM_USER}" "${ARK_SERVER_VOLUME}/crontab" || echo "Failed loading crontab, continuing startup..."

service cron start

exec gosu "${STEAM_USER}" /steam-entrypoint.sh $*
