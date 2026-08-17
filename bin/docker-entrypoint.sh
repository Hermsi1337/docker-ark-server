#!/usr/bin/env bash

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

CRON_BLOCK_BEGIN="# >>> docker-ark-server: generated cron jobs - do not edit, this block is rewritten on every start >>>"
CRON_BLOCK_END="# <<< docker-ark-server: generated cron jobs <<<"
CRON_FIELD_NAMES=("minute" "hour" "day-of-month" "month" "day-of-week")
CRON_FIELD_MINIMUM=(0 0 1 1 0)
CRON_FIELD_MAXIMUM=(59 23 31 12 7)
GENERATED_CRON_JOB_COUNT=0

function reject_cron_schedule() {
  local -r VAR_NAME="${1}"
  local -r SCHEDULE="${2}"
  local -r REASON="${3}"

  echo "ERROR: ${VAR_NAME}='${SCHEDULE}' is not a valid cron schedule: ${REASON}."
  echo "       Expected five fields - minute (0-59) hour (0-23) day-of-month (1-31) month (1-12) day-of-week (0-7),"
  echo "       for example ${VAR_NAME}='0 4 * * *'."
  exit 1
}

function cron_field_number() {
  local -r FIELD_INDEX="${1}"
  local -r ITEM="${2,,}"
  local NAMES NAME
  local -i NUMBER

  if [[ "${ITEM}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$((10#${ITEM}))"
    return 0
  fi

  case "${FIELD_INDEX}" in
    3) NAMES="jan feb mar apr may jun jul aug sep oct nov dec"; NUMBER=1 ;;
    4) NAMES="sun mon tue wed thu fri sat"; NUMBER=0 ;;
    *) return 1 ;;
  esac

  for NAME in ${NAMES}; do
    if [[ "${NAME}" == "${ITEM}" ]]; then
      printf '%s' "${NUMBER}"
      return 0
    fi
    NUMBER=$((NUMBER + 1))
  done

  return 1
}

function assert_valid_cron_field() {
  local -r VAR_NAME="${1}"
  local -r SCHEDULE="${2}"
  local -r FIELD_INDEX="${3}"
  local -r FIELD="${4}"
  local -r FIELD_NAME="${CRON_FIELD_NAMES[FIELD_INDEX]}"
  local -ri MINIMUM="${CRON_FIELD_MINIMUM[FIELD_INDEX]}"
  local -ri MAXIMUM="${CRON_FIELD_MAXIMUM[FIELD_INDEX]}"
  local -a ITEMS=()
  local ITEM RANGE STEP LOW HIGH LOW_NUMBER HIGH_NUMBER

  if [[ "${FIELD}" == *,,* ]] || [[ "${FIELD}" == ,* ]] || [[ "${FIELD}" == *, ]]; then
    reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} field '${FIELD}' has an empty list entry"
  fi

  IFS=',' read -ra ITEMS <<< "${FIELD}"
  for ITEM in "${ITEMS[@]}"; do
    RANGE="${ITEM}"

    if [[ "${ITEM}" == */* ]]; then
      RANGE="${ITEM%%/*}"
      STEP="${ITEM#*/}"
      if [[ ! "${STEP}" =~ ^[0-9]+$ ]] || (( 10#${STEP} < 1 )); then
        reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} entry '${ITEM}' needs a step of at least 1 behind the slash"
      fi
      # cron only steps over '*' or a range, '5/10' is rejected by crontab
      if [[ "${RANGE}" != "*" ]] && [[ "${RANGE}" != *-* ]]; then
        reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} entry '${ITEM}' can only step over '*' or a range, like '*/15' or '0-30/5'"
      fi
    fi

    [[ "${RANGE}" != "*" ]] || continue

    LOW="${RANGE%%-*}"
    HIGH="${RANGE#*-}"
    if ! LOW_NUMBER="$(cron_field_number "${FIELD_INDEX}" "${LOW}")" ||
      ! HIGH_NUMBER="$(cron_field_number "${FIELD_INDEX}" "${HIGH}")"; then
      reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} entry '${ITEM}' is neither a number, a name nor a range"
    fi

    if (( LOW_NUMBER < MINIMUM || HIGH_NUMBER > MAXIMUM )); then
      reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} entry '${ITEM}' is out of range, this field accepts ${MINIMUM}-${MAXIMUM}"
    fi

    if (( LOW_NUMBER > HIGH_NUMBER )); then
      reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} range '${ITEM}' counts backwards"
    fi
  done
}

function assert_valid_cron_schedule() {
  local -r VAR_NAME="${1}"
  local -r SCHEDULE="${2}"
  local -a FIELDS=()
  local -i FIELD_INDEX

  [[ -n "${SCHEDULE}" ]] || return 0

  if [[ "${SCHEDULE}" == *$'\n'* ]] || [[ "${SCHEDULE}" == *$'\r'* ]]; then
    reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "it has to stay on a single line"
  fi

  if [[ "${SCHEDULE}" == @* ]]; then
    case "${SCHEDULE}" in
      @yearly|@annually|@monthly|@weekly|@daily|@midnight|@hourly) return 0 ;;
      *) reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" \
        "the supported shorthands are @yearly, @annually, @monthly, @weekly, @daily, @midnight and @hourly (@reboot is not, use UPDATE_ON_START for that)" ;;
    esac
  fi

  read -ra FIELDS <<< "${SCHEDULE}"
  if [[ ${#FIELDS[@]} -ne 5 ]]; then
    reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "it has ${#FIELDS[@]} fields instead of 5"
  fi

  # the schedule ends up in a file that cron executes through a shell, so this
  # parser is a whitelist: everything it does not understand is rejected
  for (( FIELD_INDEX = 0; FIELD_INDEX < 5; FIELD_INDEX++ )); do
    assert_valid_cron_field "${VAR_NAME}" "${SCHEDULE}" "${FIELD_INDEX}" "${FIELDS[FIELD_INDEX]}"
  done
}

function assert_valid_cron_configuration() {
  assert_valid_cron_schedule BACKUP_CRON "${BACKUP_CRON}"
  assert_valid_cron_schedule UPDATE_CRON "${UPDATE_CRON}"

  if [[ -n "${UPDATE_WARN_MINUTES}" ]] && [[ ! "${UPDATE_WARN_MINUTES}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "ERROR: UPDATE_WARN_MINUTES must be a whole number of minutes, got '${UPDATE_WARN_MINUTES}'"
    exit 1
  fi

  # a scheduled update restarts every instance detached: on a multi-instance
  # container the runner this script waits on is gone, so PID 1 exits and
  # docker kills the freshly started instances before they can save
  if [[ -n "${UPDATE_CRON}" ]] && [[ -n "${SUB_INSTANCE_KEYS//[[:space:],]/}" ]]; then
    echo "ERROR: UPDATE_CRON cannot be combined with SUB_INSTANCE_KEYS."
    echo "       A scheduled update would restart the instances detached, this container would exit"
    echo "       without saving and docker would kill the new instances mid-start."
    echo "       Use UPDATE_ON_START=true and restart the container on a schedule instead."
    exit 1
  fi
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
  # required on multi-map servers, where an update swaps the shared binaries
  [[ -z "${BACKUP_CRON}" ]] || JOBS+=("${BACKUP_CRON} arkmanager backup @all >> ${LOG_TARGET} 2>&1")
  [[ -z "${UPDATE_CRON}" ]] || JOBS+=("${UPDATE_CRON} arkmanager update @all --warn --update-mods >> ${LOG_TARGET} 2>&1")
  GENERATED_CRON_JOB_COUNT=${#JOBS[@]}

  if grep -qF "${CRON_BLOCK_BEGIN}" "${CRONTAB_FILE}"; then
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
