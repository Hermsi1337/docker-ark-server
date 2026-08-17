#!/usr/bin/env bash

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

# invoked indirectly via 'trap stop_server TERM INT'; SC2317 is what shellcheck
# 0.9.x reports for it (Ubuntu 24.04), SC2329 what 0.10.0 and newer report
# shellcheck disable=SC2317,SC2329
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
    [[ -n "${DIRECTORY}" ]] || continue
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

function ini_file_for_instance() {
  local instance="${1}"
  local var_name="${2}"
  local sub_var_name

  if [[ "${instance}" == sub.* ]]; then
    sub_var_name="SUB_${instance#sub.}_${var_name}"
    if [[ -n "${!sub_var_name}" ]]; then
      printf '%s' "${!sub_var_name}"
      return
    fi
  fi

  printf '%s' "${!var_name}"
}

function assert_ini_source_usable() {
  local source_file="${1}"
  local instance="${2}"
  local complaint="ERROR: instance ${instance} is configured to use '${source_file}', but"

  if [[ ! -e "${source_file}" ]]; then
    echo "${complaint} nothing exists at that path."
    echo "       That path is the one inside the container, not the one on your host."
    exit 1
  fi

  if [[ -d "${source_file}" ]]; then
    echo "${complaint} that is a directory."
    echo "       Docker creates an empty directory when the host side of a bind mount is missing,"
    echo "       so check the host path of your mount."
    exit 1
  fi

  if [[ ! -f "${source_file}" ]]; then
    echo "${complaint} that is not a regular file."
    exit 1
  fi

  if [[ ! -r "${source_file}" ]]; then
    echo "${complaint} $(id -un) may not read it."
    echo "       Fix the file permissions, or set PUID/PGID to match its owner."
    exit 1
  fi

  if [[ ! -s "${source_file}" ]]; then
    echo "${complaint} it is empty."
    echo "       An empty file would replace the whole config with nothing and the server would"
    echo "       come up on vanilla defaults. If you created it to satisfy a bind mount, put a"
    echo "       complete INI in it, or drop both the mount and the variable."
    exit 1
  fi
}

function assert_ini_files_are_usable() {
  local instance var_name source_file claimed_file claimed_by
  local settings_file="" game_file=""

  for var_name in ARK_GAME_USER_SETTINGS_INI_FILE ARK_GAME_INI_FILE; do
    claimed_file=""
    claimed_by=""

    for instance in "${INSTANCES[@]}"; do
      source_file="$(ini_file_for_instance "${instance}" "${var_name}")"
      [[ -n "${source_file}" ]] || continue

      assert_ini_source_usable "${source_file}" "${instance}"

      if [[ -n "${claimed_file}" ]] && [[ "${claimed_file}" != "${source_file}" ]]; then
        echo "ERROR: ${claimed_by} and ${instance} name different files for ${var_name}:"
        echo "       '${claimed_file}' vs '${source_file}'."
        echo "       All instances of a container share one config directory, so one of them would"
        echo "       overwrite the config of the other. Point them at the same file."
        exit 1
      fi

      claimed_file="${source_file}"
      claimed_by="${instance}"
    done

    if [[ "${var_name}" == ARK_GAME_INI_FILE ]]; then
      game_file="${claimed_file}"
    else
      settings_file="${claimed_file}"
    fi
  done

  if [[ -n "${game_file}" ]] && [[ "${game_file}" == "${settings_file}" ]]; then
    echo "ERROR: ARK_GAME_INI_FILE and ARK_GAME_USER_SETTINGS_INI_FILE both name '${game_file}'."
    echo "       Game.ini and GameUserSettings.ini hold different sections, so one of the two"
    echo "       would end up with the wrong content. Point them at separate files."
    exit 1
  fi
}

function apply_ini_file() {
  local source_file="${1}"
  local destination="${2}"
  local instance="${3}"
  local stamp backup staged
  local -i counter=1

  [[ -n "${source_file}" ]] || return 0

  # the paths were validated before the install, which can be a long time and a
  # dropped network mount ago - a source that went away must not cost the live
  # config
  assert_ini_source_usable "${source_file}" "${instance}"

  mkdir -p "$(dirname "${destination}")"

  # a start killed between staging and the write leaves its staged copy behind,
  # and the stop handler that is already installed at this point does not know
  # about it - clear it here instead of growing the trap
  rm -f "${destination}".staged.*

  # a config left read-only by an older start would fail the write below, and
  # ARK could not write its own config back either
  if [[ -f "${destination}" ]] && [[ ! -w "${destination}" ]]; then
    chmod 644 "${destination}"
  fi

  if cmp -s "${source_file}" "${destination}"; then
    return 0
  fi

  # read the source out in full before anything is archived or truncated, so a
  # source that disappears mid-copy cannot leave the live config half written
  staged="${destination}.staged.$$"
  if ! cat "${source_file}" > "${staged}"; then
    rm -f "${staged}"
    echo "ERROR: could not stage '${source_file}' next to ${destination} for instance ${instance}."
    echo "       The live config was left untouched. Check that $(id -un) can write to"
    echo "       $(dirname "${destination}")."
    exit 1
  fi

  if [[ -f "${destination}" ]]; then
    stamp="$(date +%s)"
    backup="${destination}.bak.${stamp}"
    while [[ -e "${backup}" ]]; do
      backup="${destination}.bak.${stamp}-${counter}"
      counter+=1
    done
    # plain cp, not cp -a: if the destination is a symlink, -a would archive a
    # second link to the very file the copy below overwrites
    cp "${destination}" "${backup}"
    echo "...kept the previous ${destination} as ${backup}"
  fi

  # redirection, not cp: writing through a symlinked destination is what we
  # want, and whether cp does that or replaces the link differs between GNU
  # coreutils and busybox
  cat "${staged}" > "${destination}"
  rm -f "${staged}"
  # the source mode is not the server's business - a read-only mount would
  # leave ARK unable to write its config back
  chmod 644 "${destination}"
  echo "...applied ${source_file} to ${destination} for instance ${instance}"
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

function add_discord_to_arkmanager_cfg() {
  local config staged
  # a user may have replaced the config with a symlink - work on its target,
  # otherwise the rename below would swap the symlink for a regular file
  config="$(readlink -f "${ARK_TOOLS_DIR}/arkmanager.cfg")"

  # the marker is the guarded assignment, never a bare 'discordWebhookURL=':
  # every volume created before this feature still holds the commented
  # '# discordWebhookURL="https://discordapp.com/api/webhooks/..."' example
  # that the template used to ship, and a looser marker would match it and
  # skip the migration for exactly the users it exists for
  if grep -qF '|| discordWebhookURL=' "${config}"; then
    return
  fi

  echo "Adding Discord notification settings to the existing arkmanager.cfg ..."

  # stage beside the config and rename it into place: arkmanager sources this
  # file, so a half-written assignment would break every command. The staged
  # name has to be unpredictable - $$ is always 1 in this container, and a
  # symlink pre-placed at a known path would be written through
  if ! staged="$(mktemp "${config}.discord.XXXXXX")"; then
    echo "WARNING: could not stage ${config} (read-only?), continuing..."
    return
  fi
  STAGED_CONFIG="${staged}"

  if ! cp -p "${config}" "${staged}" || ! cat <<'EOF' >> "${staged}"

# Discord notifications - active only when DISCORD_WEBHOOK_URL is set (see README)
[ -z "${DISCORD_WEBHOOK_URL}" ] || discordWebhookURL="${DISCORD_WEBHOOK_URL}"
EOF
  then
    echo "WARNING: could not write ${staged}, continuing without Discord notifications..."
  elif ! mv "${staged}" "${config}"; then
    echo "WARNING: could not replace ${config}, continuing without Discord notifications..."
  fi

  rm -f "${STAGED_CONFIG}"
  STAGED_CONFIG=""
}

function warn_on_hardcoded_discord_webhook() {
  local config

  # arkmanager sources the global config first and the instance config after
  # it, so a hardcoded URL in either one wins over the generated assignment
  for config in "${ARK_TOOLS_DIR}/arkmanager.cfg" "${ARK_TOOLS_DIR}/instances/"*.cfg; do
    [[ -f "${config}" ]] || continue

    if grep -qE '^[[:space:]]*(export[[:space:]]+)?discordWebhookURL=' "${config}"; then
      echo "WARNING: ${config} assigns discordWebhookURL directly."
      echo "         That webhook keeps receiving notifications even when DISCORD_WEBHOOK_URL is empty."
      echo "         Comment the line out to put the environment variable in charge."
    fi
  done
}

function add_block_to_arkmanager_cfg() {
  local -r description="${1}"
  local -r marker="${2}"
  local -r block="${3}"
  local config staged

  # the marker decides whether the block is already there, so a marker the
  # block never contains would append it again on every start
  case "${block}" in
    *"${marker}"*) ;;
    *)
      echo "ERROR: marker '${marker}' does not occur in the ${description} block."
      exit 1
      ;;
  esac

  # a user may have replaced the config with a symlink - work on its target,
  # otherwise cp recreates the symlink over the staged file and the append
  # writes straight into the live config the rename is meant to protect
  config="$(readlink -f "${ARK_TOOLS_DIR}/arkmanager.cfg")"

  # match the generated assignment, not the variable name: a user comment
  # mentioning the variable must not count as "already migrated"
  if grep -qF "${marker}" "${config}"; then
    return
  fi

  echo "Adding ${description} to the existing arkmanager.cfg ..."

  # stage and rename instead of appending in place: arkmanager sources this
  # file, so a half-written assignment (full disk) would break every command
  if ! staged="$(mktemp "${config}.XXXXXX")"; then
    echo "WARNING: could not stage ${config} (read-only?), continuing without ${description}..."
    return
  fi
  STAGED_CONFIG="${staged}"

  if ! cp -p "${config}" "${staged}" || ! printf '\n%s\n' "${block}" >> "${staged}"; then
    echo "WARNING: could not write ${staged}, continuing without ${description}..."
  elif ! mv "${staged}" "${config}"; then
    echo "WARNING: could not replace ${config}, continuing without ${description}..."
  fi

  rm -f "${STAGED_CONFIG}"
  STAGED_CONFIG=""
}

# the block lands in the config verbatim, arkmanager expands it when it sources
# the file - expanding it here would freeze the current value into the config
# shellcheck disable=SC2016
function add_backup_retention_to_arkmanager_cfg() {
  add_block_to_arkmanager_cfg 'backup retention settings' '|| arkMaxBackupSizeMB=' \
'# Backup retention - active only when MAX_BACKUP_SIZE_MB is set (see README)
[ -z "${MAX_BACKUP_SIZE_MB}" ] || arkMaxBackupSizeMB="${MAX_BACKUP_SIZE_MB}"'
}

# see add_backup_retention_to_arkmanager_cfg
# shellcheck disable=SC2016
function add_always_restart_on_crash_to_arkmanager_cfg() {
  add_block_to_arkmanager_cfg 'crash restart settings' '|| arkAlwaysRestartOnCrash=true' \
'# Crash restart - arkmanager arms auto-restart on any non-empty value,
# so only a literal true may set it (see README)
[ "${ALWAYS_RESTART_ON_CRASH}" != "true" ] || arkAlwaysRestartOnCrash=true'
}

# parse and validate SUB_INSTANCE_KEYS: each key becomes part of a bash
# variable name (SUB_<KEY>_*), a config filename (sub.<KEY>.cfg) and an
# arkmanager instance name - restrict keys to a safe charset and fail loudly
# instead of silently generating corrupt configs
function parse_sub_instance_keys() {
  local RAW_KEY KEY SEEN_KEY
  local -a RAW_SUB_KEYS=()

  SUB_KEYS=()
  if [[ -n "${SUB_INSTANCE_KEYS}" ]]; then
    IFS=',' read -ra RAW_SUB_KEYS <<< "${SUB_INSTANCE_KEYS}"
    for RAW_KEY in "${RAW_SUB_KEYS[@]}"; do
      # trim surrounding whitespace only - embedded whitespace must fail the
      # charset check below instead of being silently collapsed
      KEY="${RAW_KEY#"${RAW_KEY%%[![:space:]]*}"}"
      KEY="${KEY%"${KEY##*[![:space:]]}"}"
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
}

# the sub instance port defaults are derived arithmetically - empty or
# non-numeric ports would silently evaluate to 0, and a leading zero would
# make bash read the value as octal
function assert_valid_sub_instance_ports() {
  local PORT_VAR

  if [[ ${#SUB_KEYS[@]} -gt 0 ]]; then
    for PORT_VAR in GAME_CLIENT_PORT SERVER_LIST_PORT RCON_PORT; do
      if [[ ! "${!PORT_VAR}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: ${PORT_VAR}='${!PORT_VAR}' must be a plain port number (no leading zero) when SUB_INSTANCE_KEYS is set."
        exit 1
      fi
    done
  fi
}

# arkmanager compares the backup budget arithmetically after every backup: a
# unit suffix aborts the comparison and skips pruning, a leading zero makes
# bash read the value as octal
function assert_valid_max_backup_size() {
  if [[ -n "${MAX_BACKUP_SIZE_MB}" ]] && [[ ! "${MAX_BACKUP_SIZE_MB}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "ERROR: MAX_BACKUP_SIZE_MB='${MAX_BACKUP_SIZE_MB}' must be a plain number of megabytes (no unit, no leading zero)."
    echo "       Use 0 to disable the pruning of old backups."
    exit 1
  fi
}

# arkmanager arms the watchdog on any non-empty value, so the config only
# forwards a literal true - without this every other spelling looks accepted
# and does nothing
function assert_valid_always_restart_on_crash() {
  case "${ALWAYS_RESTART_ON_CRASH}" in
    ""|"true"|"false") ;;
    *)
      echo "ERROR: ALWAYS_RESTART_ON_CRASH='${ALWAYS_RESTART_ON_CRASH}' must be 'true' or 'false' (lowercase)."
      exit 1
      ;;
  esac
}

# upstream multiplies arkMaxBackupSizeGB into arkMaxBackupSizeMB before it
# looks at the budget, and arkmanager sources the instance config last, so
# either one silently wins over the environment variable
function warn_on_overridden_backup_budget() {
  local config
  local -r instance_config="${ARK_TOOLS_DIR}/instances/main.cfg"

  # a bare 'return' would hand the failed test's status to the startup
  # sequence, and set -e would kill the container before it ever starts
  [[ -n "${MAX_BACKUP_SIZE_MB}" ]] || return 0

  for config in "$(readlink -f "${ARK_TOOLS_DIR}/arkmanager.cfg")" "${instance_config}"; do
    [[ -f "${config}" ]] || continue

    if grep -qE '^[[:space:]]*arkMaxBackupSizeGB=' "${config}"; then
      echo "WARNING: ${config} assigns arkMaxBackupSizeGB, which overrides MAX_BACKUP_SIZE_MB."
      echo "         Comment the line out to put the environment variable in charge."
    fi

    if [[ "${config}" == "${instance_config}" ]] && grep -qE '^[[:space:]]*arkMaxBackupSizeMB=' "${config}"; then
      echo "WARNING: ${config} assigns arkMaxBackupSizeMB, which overrides MAX_BACKUP_SIZE_MB."
      echo "         Comment the line out to put the environment variable in charge."
    fi
  done
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

# relative on purpose: it doubles as the target of the volume root symlinks,
# which have to keep working when the volume is mounted somewhere else
function config_dir() {
  printf '%s' "./server/ShooterGame/Saved/Config/LinuxServer"
}

# Game.ini and GameUserSettings.ini in the volume root are convenience
# symlinks to the real config files. Users regularly replace them with
# regular files by accident (e.g. via SFTP upload) - in that case adopt the
# uploaded content as the real config and re-create the symlink, instead of
# dying on 'ln: File exists'.
function heal_config_symlinks() {
  local CONFIG_DIR
  CONFIG_DIR="$(config_dir)"
  local INI_FILE INI_LINK

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
}

# everything below is the startup sequence; sourcing this script (the test
# suite does) only defines the functions above
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

if [[ "$(id -u)" != "$(id -u "${STEAM_USER}")" ]]; then
  echo "run this script as steam-user"
  exit 1
fi

# minimal stop handler for the install/update phase: bash as PID 1 would
# otherwise ignore SIGTERM entirely; replaced by stop_server once the
# server is about to run. A staged config copy must not survive the signal,
# it may contain a webhook URL
STAGED_CONFIG=""
trap '[ -z "${STAGED_CONFIG}" ] || rm -f "${STAGED_CONFIG}"; exit 143' TERM INT

parse_sub_instance_keys
assert_valid_sub_instance_ports
assert_valid_max_backup_size
assert_valid_always_restart_on_crash

# run exactly the instances this image manages: main plus the generated sub
# instances - never arbitrary *.cfg files a user may keep in instances/
INSTANCES=(main)
for KEY in "${SUB_KEYS[@]}"; do
  INSTANCES+=("sub.${KEY}")
done

# validate the declarative config paths here and not next to the copy further
# down: on a fresh volume the install downloads ~25GB, and a container that
# restarts on failure would repeat that on every cycle just to hit the same typo
assert_ini_files_are_usable

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

# without '|| true' set -e kills the script on a missing arkmanager and the
# guard below never gets to report it
ARKMANAGER="$(command -v arkmanager)" || true
[[ -x "${ARKMANAGER}" ]] || (
  echo "Arkmanager is missing"
  exit 1
)

cd "${ARK_SERVER_VOLUME}"

# export the container environment for cron jobs (minus shell bookkeeping):
# the bundled crontab loads it via BASH_ENV so that arkmanager and its
# bash-based config files see the same variables as the server process
#
# the dump holds the admin password and the Discord webhook URL, so it must
# never exist world-readable, not even for the duration of the write. Removing
# it first forces a fresh inode, otherwise the redirect would truncate a file
# an older image version left at 644 and keep that mode; the chmod below is
# the fallback for a file that could not be removed
rm -f "${ARK_SERVER_VOLUME}/environment"
(umask 077 && export -p | grep -Ev '^declare -x (PWD|OLDPWD|SHLVL)($|=)' > "${ARK_SERVER_VOLUME}/environment")
chmod 600 "${ARK_SERVER_VOLUME}/environment" || echo "Failed to restrict permissions on ${ARK_SERVER_VOLUME}/environment, continuing startup..."

echo "Setting up folder and file structure..."
create_missing_dir "${ARK_SERVER_VOLUME}/log" "${ARK_SERVER_VOLUME}/backup" "${ARK_SERVER_VOLUME}/staging"

# copy from template to server volume
copy_missing_file "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${ARK_TOOLS_DIR}/arkmanager.cfg"
copy_missing_file "${TEMPLATE_DIRECTORY}/arkmanager-user.cfg" "${ARK_TOOLS_DIR}/instances/main.cfg"

add_cluster_to_arkmanager_cfg
add_discord_to_arkmanager_cfg
warn_on_hardcoded_discord_webhook
add_backup_retention_to_arkmanager_cfg
add_always_restart_on_crash_to_arkmanager_cfg
warn_on_overridden_backup_budget
remake_sub_instances_cfg

# multi-instance needs per-instance autorestart files: the historic template
# pinned one shared arkautorestartfile, so 'arkmanager stop @one' would
# disable crash-autorestart for every other running instance
if [[ ${#SUB_KEYS[@]} -gt 0 ]] && grep -q '^arkautorestartfile=' "${ARK_TOOLS_DIR}/arkmanager.cfg"; then
  echo "Disabling the legacy shared arkautorestartfile override for multi-instance operation..."
  sed -i 's/^arkautorestartfile=/#&/' "${ARK_TOOLS_DIR}/arkmanager.cfg" ||
    echo "WARNING: could not update ${ARK_TOOLS_DIR}/arkmanager.cfg, continuing..."
fi

heal_config_symlinks

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

# arkmanager only copies arkGameUserSettingsIniFile/arkGameIniFile over the
# save dir config in its 'start' path, and we run 'run' to stay PID 1 - so do
# it here. All instances of a container share one config directory, therefore
# every copy has to be finished before the first server process reads it.
CONFIG_DIR="$(config_dir)"
for INSTANCE in "${INSTANCES[@]}"; do
  apply_ini_file "$(ini_file_for_instance "${INSTANCE}" ARK_GAME_USER_SETTINGS_INI_FILE)" \
    "${CONFIG_DIR}/GameUserSettings.ini" "${INSTANCE}"
  apply_ini_file "$(ini_file_for_instance "${INSTANCE}" ARK_GAME_INI_FILE)" \
    "${CONFIG_DIR}/Game.ini" "${INSTANCE}"
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
