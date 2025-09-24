#!/usr/bin/env bash

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

if [[ ! -d "${ARK_SERVER_VOLUME}" ]]; then
  mkdir -p "${ARK_SERVER_VOLUME}"
fi

chown "${STEAM_USER}": "${ARK_SERVER_VOLUME}" || echo "Failed setting rights on ${ARK_SERVER_VOLUME}, continuing startup..."

if [[ ! -d ${ARK_TOOLS_DIR} ]]; then
  mv "/etc/arkmanager" "${ARK_TOOLS_DIR}"
  rm -f "${ARK_TOOLS_DIR}/arkmanager.cfg" "${ARK_TOOLS_DIR}/instances/main.cfg"
fi

chown -R "${STEAM_USER}": "${ARK_TOOLS_DIR}" || echo "Failed setting rights on ${ARK_TOOLS_DIR}, continuing startup..."

if [[ ! -d /cluster ]]; then
  mkdir -p "/cluster"
fi

chown "${STEAM_USER}": "/cluster" || echo "Failed setting rights on /cluster, continuing startup..."

# symlink arkmanager directories
rm -rf "/etc/arkmanager"
ln -s "${ARK_TOOLS_DIR}" "/etc/arkmanager"

service cron start

exec gosu "${STEAM_USER}" /steam-entrypoint.sh $*
