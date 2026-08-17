#!/usr/bin/env bash

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

mkdir -p "${ARK_SERVER_VOLUME}" "/cluster"

# drop healthcheck state from a previous container before anything slow runs:
# the chown below can take many minutes on a 25GB volume, and until the file is
# gone the healthcheck would judge this container by the last run's instances
rm -f "${ARK_SERVER_VOLUME}/running-instances" "${ARK_SERVER_VOLUME}/.healthcheck-update-grace"

# Optionally remap the steam user to a custom UID/GID, e.g. to match the
# owner of a bind mount on NAS systems (Synology, UGREEN, ...)
if [[ -n "${PUID}${PGID}" ]]; then
  for ID_VAR in PUID PGID; do
    if [[ -n "${!ID_VAR}" ]] && [[ ! "${!ID_VAR}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: ${ID_VAR} must be numeric, got '${!ID_VAR}'"
      exit 1
    fi
  done
  if [[ "${PUID}" == "0" ]] || [[ "${PGID}" == "0" ]]; then
    echo "ERROR: PUID/PGID 0 (root) is not supported"
    exit 1
  fi

  CURRENT_UID="$(id -u "${STEAM_USER}")"
  CURRENT_GID="$(id -g "${STEAM_USER}")"
  STEAM_GROUP="$(id -gn "${STEAM_USER}")"
  # 10# forces base-10 so values like "01000" cannot be read as octal
  TARGET_UID="$((10#${PUID:-${CURRENT_UID}}))"
  TARGET_GID="$((10#${PGID:-${CURRENT_GID}}))"

  if [[ "${TARGET_GID}" != "${CURRENT_GID}" ]]; then
    echo "Changing GID of ${STEAM_USER} from ${CURRENT_GID} to ${TARGET_GID}..."
    groupmod -o -g "${TARGET_GID}" "${STEAM_GROUP}"
  fi
  if [[ "${TARGET_UID}" != "${CURRENT_UID}" ]]; then
    echo "Changing UID of ${STEAM_USER} from ${CURRENT_UID} to ${TARGET_UID}..."
    usermod -o -u "${TARGET_UID}" "${STEAM_USER}"
  fi
  if [[ "${TARGET_UID}" != "${CURRENT_UID}" ]] || [[ "${TARGET_GID}" != "${CURRENT_GID}" ]]; then
    # small, container-local; also adopts a mounted /home/steam/Steam session
    chown -R "${STEAM_USER}": "${STEAM_HOME}" || echo "Failed setting rights on ${STEAM_HOME}, continuing startup..."
  fi

  # adopt the server volume only when its ownership actually differs:
  # containers are recreated on every image update and re-running a
  # recursive chown over ~25GB each time would hurt exactly the NAS
  # systems this feature is for
  if [[ "$(stat -c '%u:%g' "${ARK_SERVER_VOLUME}")" != "${TARGET_UID}:${TARGET_GID}" ]]; then
    echo "Adopting ownership of ${ARK_SERVER_VOLUME} (one-time, may take a while)..."
    chown -R "${TARGET_UID}:${TARGET_GID}" "${ARK_SERVER_VOLUME}" || echo "Failed setting rights on ${ARK_SERVER_VOLUME}, continuing startup..."
  fi
fi

for DIR in "${ARK_SERVER_VOLUME}" "/cluster"; do
  chown "${STEAM_USER}": "${DIR}" || echo "Failed setting rights on ${DIR}, continuing startup..."
done

# cluster transfer data (uploaded characters/dinos/items) lives in /cluster -
# without a mounted volume it would silently vanish when the container is
# recreated (image update, compose down/up, watchtower)
if [[ -n "${CLUSTER_ID}" ]] && ! mountpoint -q /cluster 2>/dev/null; then
  echo "WARNING: CLUSTER_ID is set but /cluster is not a mounted volume."
  echo "         Uploaded characters/dinos/items would be LOST when this container"
  echo "         is recreated - mount a volume at /cluster (see the README)."
fi

if [[ ! -d ${ARK_TOOLS_DIR} ]]; then
  mv "/etc/arkmanager" "${ARK_TOOLS_DIR}"
  rm -f "${ARK_TOOLS_DIR}/arkmanager.cfg" "${ARK_TOOLS_DIR}/instances/main.cfg"
fi

chown -R "${STEAM_USER}": "${ARK_TOOLS_DIR}" || echo "Failed setting rights on ${ARK_TOOLS_DIR}, continuing startup..."

# symlink arkmanager directories
rm -rf "/etc/arkmanager"
ln -s "${ARK_TOOLS_DIR}" "/etc/arkmanager"

CRON_BLOCK_BEGIN="# >>> generated from BACKUP_CRON/UPDATE_CRON/RESTART_CRON - do not edit, this block is rewritten on every start >>>"
CRON_BLOCK_END="# <<< generated from BACKUP_CRON/UPDATE_CRON/RESTART_CRON <<<"

function assert_valid_cron_schedule() {
  local -r VAR_NAME="${1}"
  local -r SCHEDULE="${2}"
  local -a FIELDS=()
  local FIELD

  [[ -n "${SCHEDULE}" ]] || return 0

  if [[ "${SCHEDULE}" == *$'\n'* ]] || [[ "${SCHEDULE}" == *$'\r'* ]]; then
    echo "ERROR: ${VAR_NAME} must be a single cron schedule on one line."
    exit 1
  fi

  read -ra FIELDS <<< "${SCHEDULE}"
  if [[ ${#FIELDS[@]} -ne 5 ]]; then
    echo "ERROR: ${VAR_NAME}='${SCHEDULE}' must have exactly 5 fields (minute hour day-of-month month day-of-week), got ${#FIELDS[@]}."
    echo "       Example: ${VAR_NAME}='0 4 * * *'"
    exit 1
  fi

  # the schedule ends up in a file that cron executes through a shell, so
  # allow only cron syntax instead of trying to blocklist shell metacharacters
  for FIELD in "${FIELDS[@]}"; do
    if [[ ! "${FIELD}" =~ ^[0-9A-Za-z*/,-]+$ ]]; then
      echo "ERROR: ${VAR_NAME}='${SCHEDULE}' contains the invalid field '${FIELD}'."
      echo "       Cron fields may only contain digits, letters, '*', '/', ',' and '-'."
      exit 1
    fi
  done
}

function render_generated_cronjobs() {
  local -r CRONTAB_FILE="${ARK_SERVER_VOLUME}/crontab"
  local -r LOG_TARGET="${ARK_SERVER_VOLUME}/log/crontab.log"
  local -a JOBS=()
  local STRIPPED_CRONTAB

  assert_valid_cron_schedule BACKUP_CRON "${BACKUP_CRON}"
  assert_valid_cron_schedule UPDATE_CRON "${UPDATE_CRON}"
  assert_valid_cron_schedule RESTART_CRON "${RESTART_CRON}"

  # @all covers every instance - identical to @main on a single-map server and
  # required on multi-map servers, where an update swaps the shared binaries
  [[ -z "${BACKUP_CRON}" ]] || JOBS+=("${BACKUP_CRON} arkmanager backup @all >> ${LOG_TARGET} 2>&1")
  [[ -z "${UPDATE_CRON}" ]] || JOBS+=("${UPDATE_CRON} arkmanager update @all --warn --update-mods >> ${LOG_TARGET} 2>&1")
  [[ -z "${RESTART_CRON}" ]] || JOBS+=("${RESTART_CRON} arkmanager restart @all --warn >> ${LOG_TARGET} 2>&1")

  if [[ ${#JOBS[@]} -eq 0 ]] && ! grep -qxF "${CRON_BLOCK_BEGIN}" "${CRONTAB_FILE}"; then
    return 0
  fi

  if [[ ${#JOBS[@]} -gt 0 ]] && ! grep -q '^BASH_ENV=' "${CRONTAB_FILE}"; then
    echo "WARNING: ${CRONTAB_FILE} has no BASH_ENV header, the generated jobs will run"
    echo "         without the container environment. Add these two lines at the top:"
    echo "         SHELL=/bin/bash"
    echo "         BASH_ENV=${ARK_SERVER_VOLUME}/environment"
  fi

  STRIPPED_CRONTAB="$(awk -v begin="${CRON_BLOCK_BEGIN}" -v end="${CRON_BLOCK_END}" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip
  ' "${CRONTAB_FILE}")"

  {
    printf '%s\n' "${STRIPPED_CRONTAB}"
    if [[ ${#JOBS[@]} -gt 0 ]]; then
      printf '%s\n' "${CRON_BLOCK_BEGIN}"
      printf '%s\n' "${JOBS[@]}"
      printf '%s\n' "${CRON_BLOCK_END}"
    fi
  } > "${CRONTAB_FILE}"
}

if [[ -n "${UPDATE_WARN_MINUTES}" ]] && [[ ! "${UPDATE_WARN_MINUTES}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: UPDATE_WARN_MINUTES must be a positive whole number of minutes, got '${UPDATE_WARN_MINUTES}'"
  exit 1
fi

# Copy the crontab template on first start and load it as root: the setgid
# crontab binary fails with "mkstemp: Permission denied" on hosts that run
# containers with no-new-privileges (e.g. some NAS systems).
if [[ ! -f "${ARK_SERVER_VOLUME}/crontab" ]]; then
  cp -a "${TEMPLATE_DIRECTORY}/crontab" "${ARK_SERVER_VOLUME}/crontab"
  # the template defaults to /app - point BASH_ENV at the actual volume path
  sed -i "s|^BASH_ENV=.*|BASH_ENV=${ARK_SERVER_VOLUME}/environment|" "${ARK_SERVER_VOLUME}/crontab"
  chown "${STEAM_USER}": "${ARK_SERVER_VOLUME}/crontab" || true
fi

render_generated_cronjobs

crontab -u "${STEAM_USER}" "${ARK_SERVER_VOLUME}/crontab" || echo "Failed loading crontab, continuing startup..."

service cron start

exec gosu "${STEAM_USER}" /steam-entrypoint.sh "$@"
