#!/usr/bin/env bash

CRON_BLOCK_BEGIN="# >>> docker-ark-server: generated cron jobs - do not edit, this block is rewritten on every start >>>"
CRON_BLOCK_END="# <<< docker-ark-server: generated cron jobs <<<"
GENERATED_CRON_JOB_COUNT=0

# the schedule parser lives next to this script: bin/ in the repository, / in
# the image (the Dockerfile copies bin/ to /)
# shellcheck source=bin/cron-schedule.sh
source "$(dirname "${BASH_SOURCE[0]}")/cron-schedule.sh"

function assert_valid_cron_configuration() {
  local UNSUPPORTED

  BACKUP_CRON="$(trim_whitespace "${BACKUP_CRON}")"
  assert_valid_cron_schedule BACKUP_CRON "${BACKUP_CRON}"

  if [[ -n "${UPDATE_WARN_MINUTES}" ]] && [[ ! "${UPDATE_WARN_MINUTES}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "ERROR: UPDATE_WARN_MINUTES must be a whole number of minutes, got '${UPDATE_WARN_MINUTES}'"
    exit 1
  fi

  # people arrive from images that do have these, and a variable that silently
  # does nothing is worse than one that says so
  for UNSUPPORTED in UPDATE_CRON RESTART_CRON; do
    if [[ -n "${!UNSUPPORTED}" ]]; then
      echo "WARNING: ${UNSUPPORTED} is not supported by this image and is ignored."
      echo "         An arkmanager update or restart stops the server, which is the process this container"
      echo "         waits on, so the container would exit in the middle of it. Use UPDATE_ON_START=true"
      echo "         and restart the container on a schedule instead (see the README)."
    fi
  done
}

function assert_crontab_is_regular_file() {
  local -r CRONTAB_FILE="${ARK_SERVER_VOLUME}/crontab"

  if [[ -e "${CRONTAB_FILE}" ]] && [[ ! -f "${CRONTAB_FILE}" ]]; then
    echo "ERROR: ${CRONTAB_FILE} exists but is not a regular file."
    echo "       A bind mount whose host path does not exist shows up as a directory here."
    echo "       Fix the mount or remove the path, then start the container again."
    exit 1
  fi
}

# the rewriter matches the marker on the exact line, so the detection has to
# use the same comparison - a substring match would flag an indented marker
# that the rewriter then never finds
function crontab_has_generated_block() {
  local -r CRONTAB_FILE="${1}"

  awk -v begin="${CRON_BLOCK_BEGIN}" '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line == begin) { found = 1; exit }
    }
    END { exit !found }
  ' "${CRONTAB_FILE}"
}

function crontab_header_is_current() {
  local -r CRONTAB_FILE="${1}"
  local -r CARRIAGE_RETURN=$'\r'

  grep -qE "^SHELL=/bin/bash[[:blank:]${CARRIAGE_RETURN}]*$" "${CRONTAB_FILE}" &&
    grep -qE "^BASH_ENV=${ARK_SERVER_VOLUME}/environment[[:blank:]${CARRIAGE_RETURN}]*$" "${CRONTAB_FILE}"
}

function render_generated_cronjobs() {
  local -r CRONTAB_FILE="${ARK_SERVER_VOLUME}/crontab"
  local -r LOG_TARGET="${ARK_SERVER_VOLUME}/log/crontab.log"
  local -a JOBS=()
  local STRIPPED_CRONTAB
  local -i FIX_HEADER=0
  local -i HAS_BLOCK=0

  # @all covers every instance - identical to @main on a single-map server and
  # required on multi-map servers. Only backups are scheduled here: every
  # arkmanager command that stops the server (update, restart) kills the run
  # process this container waits on, which takes the container down with it
  [[ -z "${BACKUP_CRON}" ]] || JOBS+=("${BACKUP_CRON} arkmanager backup @all >> ${LOG_TARGET} 2>&1")
  GENERATED_CRON_JOB_COUNT=${#JOBS[@]}

  if crontab_has_generated_block "${CRONTAB_FILE}"; then
    HAS_BLOCK=1
  fi

  if [[ ${#JOBS[@]} -eq 0 ]] && [[ ${HAS_BLOCK} -eq 0 ]]; then
    return 0
  fi

  # cron runs jobs under SHELL and dash ignores BASH_ENV, so without both lines
  # the jobs start with an empty environment and arkmanager would work on empty
  # paths instead of the server volume
  if [[ ${#JOBS[@]} -gt 0 ]] && ! crontab_header_is_current "${CRONTAB_FILE}"; then
    echo "Adding the SHELL/BASH_ENV header to ${CRONTAB_FILE} so the generated jobs see the container environment..."
    FIX_HEADER=1
  fi

  if ! STRIPPED_CRONTAB="$(awk -v begin="${CRON_BLOCK_BEGIN}" -v end="${CRON_BLOCK_END}" -v fixheader="${FIX_HEADER}" '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line == begin) { if (skip) exit 1; skip = 1; next }
      if (line == end)   { if (!skip) exit 1; skip = 0; next }
      if (skip) next
      if (fixheader && (line ~ /^SHELL=/ || line ~ /^BASH_ENV=/)) next
      print
    }
    END { if (skip) exit 1 }
  ' "${CRONTAB_FILE}")"; then
    echo "ERROR: the generated cron block in ${CRONTAB_FILE} is broken (a begin marker without its end marker, or the other way round)."
    echo "       Remove the '# >>> docker-ark-server' and '# <<< docker-ark-server' marker lines and the jobs between them, then start again."
    exit 1
  fi

  {
    if [[ ${FIX_HEADER} -eq 1 ]]; then
      printf 'SHELL=/bin/bash\nBASH_ENV=%s/environment\n' "${ARK_SERVER_VOLUME}"
    fi
    [[ -z "${STRIPPED_CRONTAB}" ]] || printf '%s\n' "${STRIPPED_CRONTAB}"
    if [[ ${#JOBS[@]} -gt 0 ]]; then
      printf '%s\n' "${CRON_BLOCK_BEGIN}"
      printf '%s\n' "${JOBS[@]}"
      printf '%s\n' "${CRON_BLOCK_END}"
    fi
  } > "${CRONTAB_FILE}"
}

# everything below is the startup sequence; sourcing this script (the test
# suite does) only defines the functions above
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

assert_valid_cron_configuration

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

assert_crontab_is_regular_file

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

if ! crontab -u "${STEAM_USER}" "${ARK_SERVER_VOLUME}/crontab"; then
  # cron rejects the whole file over a single bad line, so carrying on would
  # silently drop the scheduled jobs as well as anything the user added
  if [[ ${GENERATED_CRON_JOB_COUNT} -gt 0 ]]; then
    echo "ERROR: cron refused ${ARK_SERVER_VOLUME}/crontab, none of its jobs would run."
    echo "       Check the file for invalid lines, then start the container again."
    exit 1
  fi
  echo "Failed loading crontab, continuing startup..."
fi

service cron start

exec gosu "${STEAM_USER}" /steam-entrypoint.sh "$@"
