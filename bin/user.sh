#!/usr/bin/env bash

# Change the UID if needed
if [[ ! "$(id -u steam)" -eq "${STEAM_UID}" ]]; then
	echo "Changing steam uid to ${STEAM_UID}."
	usermod -o -u "${STEAM_UID}" steam ;
fi
# Change gid if needed
if [[ ! "$(id -g steam)" -eq "${STEAM_GID}" ]]; then
	echo "Changing steam gid to ${STEAM_GID}."
	groupmod -o -g "${STEAM_GID}" steam ;
fi

# Put steam owner of directories (if the uid changed, then it's needed)
chown -R steam:steam "${ARK_SERVER_VOLUME}" "${STEAM_HOME}"
chmod 755 /root/

# Launch run.sh with user steam (-p allow to keep env variables)
exec su -p - steam -c "${STEAM_HOME}/run.sh"