#!/usr/bin/env bash
echo "_______________________________________"
echo ""
echo "# Ark Server - $(date)"
echo "# UID ${STEAM_UID} - GID ${STEAM_GID}"
echo "_______________________________________"

function stop {
	if [[ ${BACKUP_ON_STOP} == "true" ]] && [[ "$(ls -A server/ShooterGame/Saved/SavedArks)" ]]; then
		echo "[Backup on stop]"
		${ARKMANAGER} backup
	fi
	if [[ ${WARN_ON_STOP} == "true" ]];then
	    ${ARKMANAGER} stop --warn
	else
	    ${ARKMANAGER} stop
	fi
	exit 0
}

function create_missing_dir {
    for DIRECTORY in ${@}; do
        [[ -n "${DIRECTORY}" ]] || return
        if [[ ! -d ${DIRECTORY} ]]; then
            mkdir -p ${DIRECTORY}
            echo "Successfully created ${DIRECTORY}"
        fi
    done
}


[[ -p /tmp/FIFO ]] && rm /tmp/FIFO
mkfifo /tmp/FIFO

ARKMANAGER="$(command -v arkmanager)"
[[ -n "${ARKMANAGER}" ]] || (echo "Arkamanger is missing" ; exit 1)

# Change working directory to ${ARK_SERVER_VOLUME}
cd ${ARK_SERVER_VOLUME}

# Creating directory tree
# Add a template directory to store the last version of config file
create_missing_dir "${ARK_SERVER_VOLUME}/log" "${ARK_SERVER_VOLUME}/backup" "${ARK_SERVER_VOLUME}/staging" "${ARK_SERVER_VOLUME}/template"
# We overwrite the template file each time
cp ${STEAM_HOME}/arkmanager.cfg ${ARK_SERVER_VOLUME}/template/arkmanager.cfg
cp ${STEAM_HOME}/crontab ${ARK_SERVER_VOLUME}/template/crontab
# Create symbolic links
[[ -f ${ARK_SERVER_VOLUME}/arkmanager.cfg ]] || cp ${ARK_SERVER_VOLUME}/template/arkmanager.cfg ${ARK_SERVER_VOLUME}/arkmanager.cfg
[[ -L ${ARK_SERVER_VOLUME}/Game.ini ]] || ln -s server/ShooterGame/Saved/Config/LinuxServer/Game.ini Game.ini
[[ -L ${ARK_SERVER_VOLUME}/GameUserSettings.ini ]] || ln -s server/ShooterGame/Saved/Config/LinuxServer/GameUserSettings.ini GameUserSettings.ini
[[ -f ${ARK_SERVER_VOLUME}/crontab ]] || cp ${ARK_SERVER_VOLUME}/template/crontab ${ARK_SERVER_VOLUME}/crontab

if [[ ! -d ${ARK_SERVER_VOLUME}/server  ]] || [[ ! -f ${ARK_SERVER_VOLUME}/server/version.txt ]];then
	echo "No game files found. Installing..."
	create_missing_dir \
	    ${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/SavedArks \
	    ${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods \
	    ${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux
	touch ${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer
	${ARKMANAGER} install
fi

# If there is uncommented line in the file
ACTIVE_CRONS="$(grep -v "^#" ${ARK_SERVER_VOLUME}/crontab 2>/dev/null | wc -l)"
if [[ ${ACTIVE_CRONS} -gt 0 ]]; then
	echo "Loading crontab..."
	# We load the crontab file if it exist.
	crontab ${ARK_SERVER_VOLUME}/crontab
	# Cron is attached to this process
	sudo cron -f &
else
	echo "No crontab set."
fi

# Launching ark server
${ARKMANAGER} run

# Stop server in case of signal INT or TERM
echo "Waiting..."
trap stop INT
trap stop TERM

read < /tmp/FIFO &
wait