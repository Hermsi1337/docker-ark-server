#!/usr/bin/env bash

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

if [[ "$(id -u)" != "$(id -u "${STEAM_USER}")" ]]; then
  echo "run this script as steam-user"
  exit 1
fi

# minimal stop handler for the install/update phase: bash as PID 1 would
# otherwise ignore SIGTERM entirely; replaced by stop_server once the
# server is about to run
trap 'exit 143' TERM INT

function may_update() {
  if [[ "${UPDATE_ON_START}" != "true" ]]; then
    [[ "${VALIDATE_ON_START}" != "true" ]] ||
      echo "WARNING: VALIDATE_ON_START has no effect because UPDATE_ON_START is not 'true' - skipping validation"
    return
  fi

  echo "\$UPDATE_ON_START is 'true'..."

  local UPDATE_ARGS=(--verbose --update-mods --backup --no-autostart)
  # let steamcmd validate and repair the installed files, e.g. after a
  # corrupted download - slower, therefore opt-in
  if [[ "${VALIDATE_ON_START}" == "true" ]]; then
    echo "\$VALIDATE_ON_START is 'true'..."
    UPDATE_ARGS+=(--validate)
  fi

  # auto checks if a update is needed, if yes, then update the server or mods
  # (otherwise it just does nothing). At boot time no instance is running yet,
  # so updating via @main is enough - post-boot updates in a multi-instance
  # setup must target @all instead (see the crontab examples), because an
  # update swaps the shared binaries but only restarts the chosen instance
  ${ARKMANAGER} update @main "${UPDATE_ARGS[@]}" "${BETA_ARGS[@]}"
}

function stop_server() {
  # ignore further stop signals: a second TERM would re-enter this handler
  # and restart the whole broadcast/stop/backup sequence
  trap '' TERM INT

  echo "Caught stop signal, gracefully stopping all ARK server instances..."

  if [[ "${WARN_ON_STOP}" == "true" ]]; then
    ${ARKMANAGER} broadcast @all "Server is shutting down" || true
  fi

  ${ARKMANAGER} stop @all --saveworld || echo "Graceful stop failed, the server may not have saved!"

  if [[ "${BACKUP_ON_STOP}" == "true" ]]; then
    echo "\$BACKUP_ON_STOP is 'true', creating a backup..."
    ${ARKMANAGER} backup @all || echo "Backup on stop failed, continuing shutdown..."
  fi

  # terminate any run processes that are still alive (e.g. the signal arrived
  # before their pidfiles existed, so stop had nothing to do) - pkill against
  # our own children also covers a runner forked moments before its pid was
  # recorded in ARK_RUN_PIDS
  pkill -TERM -P $$ 2>/dev/null || true

  wait "${ARK_RUN_PIDS[@]}" 2>/dev/null || true
  exit 0
}

function create_missing_dir() {
  for DIRECTORY in "${@}"; do
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

  # repair installs already have most content on disk and steamcmd validate
  # only fetches what is missing - the full-size gate is for fresh installs.
  # Content is only ever created by the install path (not the config-symlink
  # healing above), so it reliably marks a previous install attempt.
  if [[ -d "${ARK_SERVER_VOLUME}/server/ShooterGame/Content" ]]; then
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

function add_cluster_to_arkmanager_cfg() {
  local -r config="${ARK_TOOLS_DIR}/arkmanager.cfg"
  if ! grep -q 'arkopt_ClusterDirOverride=' "${config}"; then
    echo "Adding cluster settings to the existing arkmanager.cfg ..."
    if ! cat <<'EOF' >> "${config}"

# Cluster settings - active only when CLUSTER_ID is set (see README)
[ -z "${CLUSTER_ID}" ] || arkflag_NoTransferFromFiltering=true
[ -z "${CLUSTER_ID}" ] || arkopt_ClusterDirOverride="/cluster"
[ -z "${CLUSTER_ID}" ] || arkopt_clusterid="${CLUSTER_ID}"
EOF
    then
      echo "WARNING: could not append cluster settings to ${config} (read-only?), continuing..."
    fi
  fi
}

function remake_sub_instances_cfg() {
  local key target f
  local -i i=1
  local -r instances_dir="${ARK_TOOLS_DIR}/instances"

  # remove previously generated sub instance configs; never touch files the
  # user created by hand (they lack the auto-generated marker)
  for f in "${instances_dir}"/sub.*.cfg; do
    [[ -e "${f}" ]] || continue
    if head -n1 "${f}" | grep -q "Auto-regenerated"; then
      rm -f "${f}"
    fi
  done

  # create new sub instance configs
  for key in "${SUB_KEYS[@]}"; do
    target="${instances_dir}/sub.${key}.cfg"
    if [[ -f "${target}" ]]; then
      echo "ERROR: ${target} exists but was not generated by this image - refusing to overwrite."
      echo "       Remove or rename the file, or drop '${key}' from SUB_INSTANCE_KEYS."
      exit 1
    fi
    sed -r \
      -e "s/^# Template configuration.*$/# DO NOT EDIT THIS FILE - Auto-regenerated/i" \
      -e "s/<KEY>/${key}/g" \
      -e "s/<NUMBER_SUFFIX>/$((i+1))/g" \
      -e "s/<GAME_CLIENT_PORT>/$((GAME_CLIENT_PORT+i*2))/g" \
      -e "s/<SERVER_LIST_PORT>/$((SERVER_LIST_PORT+i))/g" \
      -e "s/<RCON_PORT>/$((RCON_PORT+i))/g" \
      "${TEMPLATE_DIRECTORY}/arkmanager-sub.cfg.template" \
      > "${target}"
    i=$((i+1))
  done
}

function get_all_mod_ids() {
  local key mod_id var_name
  local -a collected=()

  [[ -n "${SERVER_MAP_MOD_ID}" ]] && collected+=("${SERVER_MAP_MOD_ID}")

  for mod_id in ${GAME_MOD_IDS//,/ }; do
    [[ -n "${mod_id}" ]] && collected+=("${mod_id}")
  done

  for key in "${SUB_KEYS[@]}"; do
    var_name="SUB_${key}_SERVER_MAP_MOD_ID"
    [[ -n "${!var_name}" ]] && collected+=("${!var_name}")

    var_name="SUB_${key}_GAME_MOD_IDS"
    for mod_id in ${!var_name//,/ }; do
      [[ -n "${mod_id}" ]] && collected+=("${mod_id}")
    done
  done

  [[ ${#collected[@]} -eq 0 ]] || printf '%s\n' "${collected[@]}" | sort -u
}

# parse and validate SUB_INSTANCE_KEYS once: each key becomes part of a bash
# variable name (SUB_<KEY>_*), a config filename (sub.<KEY>.cfg) and an
# arkmanager instance name - restrict keys to a safe charset and fail loudly
# instead of silently generating corrupt configs
SUB_KEYS=()
if [[ -n "${SUB_INSTANCE_KEYS}" ]]; then
  IFS=',' read -ra RAW_SUB_KEYS <<< "${SUB_INSTANCE_KEYS}"
  for RAW_KEY in "${RAW_SUB_KEYS[@]}"; do
    KEY="${RAW_KEY//[[:space:]]/}"
    [[ -n "${KEY}" ]] || continue
    if [[ ! "${KEY}" =~ ^[A-Za-z0-9_]+$ ]]; then
      echo "ERROR: invalid SUB_INSTANCE_KEYS entry '${RAW_KEY}'."
      echo "       Keys may only contain letters, digits and underscores."
      exit 1
    fi
    for SEEN_KEY in "${SUB_KEYS[@]}"; do
      if [[ "${SEEN_KEY}" == "${KEY}" ]]; then
        echo "ERROR: duplicate SUB_INSTANCE_KEYS entry '${KEY}'."
        exit 1
      fi
    done
    SUB_KEYS+=("${KEY}")
  done
fi

# the sub instance port defaults are derived arithmetically - empty or
# non-numeric ports would silently evaluate to 0 in bash arithmetic
if [[ ${#SUB_KEYS[@]} -gt 0 ]]; then
  for PORT_VAR in GAME_CLIENT_PORT SERVER_LIST_PORT RCON_PORT; do
    if [[ ! "${!PORT_VAR}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: ${PORT_VAR}='${!PORT_VAR}' must be a plain port number when SUB_INSTANCE_KEYS is set."
      exit 1
    fi
  done
fi

args=("$@")
if [[ "${ENABLE_CROSSPLAY}" == "true" ]]; then
  args=('--arkopt,-crossplay' "${args[@]}")
fi
if [[ "${DISABLE_BATTLEYE}" == "true" ]]; then
  args=('--arkopt,-NoBattlEye' "${args[@]}")
fi
# pass arbitrary additional ARK command line options, space separated,
# e.g. ARK_EXTRA_OPTS="-ForceAllowCaveFlyers -PreventHibernation"
EXTRA_ARGS=()
for EXTRA_OPT in ${ARK_EXTRA_OPTS}; do
  EXTRA_ARGS+=("--arkopt,${EXTRA_OPT}")
done
args=("${EXTRA_ARGS[@]}" "${args[@]}")
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

add_cluster_to_arkmanager_cfg
remake_sub_instances_cfg

# multi-instance needs per-instance autorestart files: the historic template
# pinned one shared arkautorestartfile, so 'arkmanager stop @one' would
# disable crash-autorestart for every other running instance
if [[ ${#SUB_KEYS[@]} -gt 0 ]] && grep -q '^arkautorestartfile=' "${ARK_TOOLS_DIR}/arkmanager.cfg"; then
  echo "Disabling the legacy shared arkautorestartfile override for multi-instance operation..."
  sed -i 's/^arkautorestartfile=/#&/' "${ARK_TOOLS_DIR}/arkmanager.cfg" ||
    echo "WARNING: could not update ${ARK_TOOLS_DIR}/arkmanager.cfg, continuing..."
fi

# Game.ini and GameUserSettings.ini in the volume root are convenience
# symlinks to the real config files. Users regularly replace them with
# regular files by accident (e.g. via SFTP upload) - in that case adopt the
# uploaded content as the real config and re-create the symlink, instead of
# dying on 'ln: File exists'.
CONFIG_DIR="./server/ShooterGame/Saved/Config/LinuxServer"
for INI_FILE in Game.ini GameUserSettings.ini; do
  INI_LINK="${ARK_SERVER_VOLUME}/${INI_FILE}"
  if [[ -e "${INI_LINK}" ]] && [[ ! -L "${INI_LINK}" ]]; then
    if [[ ! -f "${INI_LINK}" ]]; then
      echo "${INI_LINK} exists but is not a file - moving it aside..."
      mv "${INI_LINK}" "${INI_LINK}.invalid.$(date +%s)"
    else
      echo "${INI_LINK} is a regular file but should be a symlink to ${CONFIG_DIR}/${INI_FILE} - fixing..."
      mkdir -p "${CONFIG_DIR}"
      if [[ -d "${CONFIG_DIR}/${INI_FILE}" ]]; then
        mv "${CONFIG_DIR}/${INI_FILE}" "${CONFIG_DIR}/${INI_FILE}.invalid.$(date +%s)"
      elif [[ -f "${CONFIG_DIR}/${INI_FILE}" ]]; then
        cp -a "${CONFIG_DIR}/${INI_FILE}" "${CONFIG_DIR}/${INI_FILE}.bak"
      fi
      mv -f "${INI_LINK}" "${CONFIG_DIR}/${INI_FILE}"
    fi
  fi
  [[ -L "${INI_LINK}" ]] || ln -s "${CONFIG_DIR}/${INI_FILE}" "${INI_FILE}"
done

if needs_install; then
  echo "No game files found. Installing..."

  assert_free_disk_space

  create_missing_dir \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/SavedArks" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux"

  touch "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"
  chmod +x "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"

  if ! ${ARKMANAGER} install @main --verbose "${BETA_ARGS[@]}"; then
    echo "ERROR: Installation failed - check the steamcmd output above."
    echo "       Common causes: not enough disk space ($(df -Ph "${ARK_SERVER_VOLUME}" | awk 'NR==2 {print $4}') left on ${ARK_SERVER_VOLUME}), network hiccups."
    exit 1
  fi

  # steamcmd occasionally reports success although the download is incomplete
  # (e.g. 'state is 0x202 after update job' on full disks) - verify it
  if VERIFY_OUTPUT="$(needs_install)"; then
    echo "${VERIFY_OUTPUT}"
    echo "ERROR: Installation finished but the server files are still incomplete."
    echo "       Check the steamcmd output above and the free disk space on ${ARK_SERVER_VOLUME}"
    echo "       ($(df -Ph "${ARK_SERVER_VOLUME}" | awk 'NR==2 {print $4}') left), then restart the container to retry."
    exit 1
  fi
fi

declare -a ALL_GAME_MOD_IDS=()
mapfile -t ALL_GAME_MOD_IDS < <(get_all_mod_ids)
if [[ ${#ALL_GAME_MOD_IDS[@]} -gt 0 ]]; then
  echo "Installing mods: '${ALL_GAME_MOD_IDS[*]}' ..."

  for MOD_ID in "${ALL_GAME_MOD_IDS[@]}"; do
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

# Run every configured instance in the background and wait for them, so that
# this script stays PID 1 and can react to docker stop/restart: without this,
# the container is killed without a world save and players lose progress (#38).
# Docker's default grace period of 10s is far too short for an ARK world save,
# so raise it (docker stop -t / stop_grace_period) as documented in the README.
ARK_RUN_PIDS=()
trap stop_server TERM INT

# remove state files left behind if a previous shutdown did not complete in
# time (the glob also covers upstream's per-instance .autorestart-<name>)
rm -f "${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/".*.pid \
      "${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/".autorestart*

# start exactly the instances this image manages: main plus the generated
# sub instances - never arbitrary *.cfg files a user may keep in instances/
INSTANCES=(main)
for KEY in "${SUB_KEYS[@]}"; do
  INSTANCES+=("sub.${KEY}")
done

for INSTANCE in "${INSTANCES[@]}"; do
  echo "Running instance ${INSTANCE} ..."
  "${ARKMANAGER}" run "@${INSTANCE}" --verbose "${args[@]}" &
  ARK_RUN_PIDS+=($!)
done

# wait for every runner individually so a crashed instance cannot hide
# behind the exit status of the last one
RC=0
for RUN_PID in "${ARK_RUN_PIDS[@]}"; do
  wait "${RUN_PID}" || {
    WRC=$?
    echo "An instance runner (pid ${RUN_PID}) exited with status ${WRC}"
    [[ ${RC} -ne 0 ]] || RC=${WRC}
  }
done
exit "${RC}"
