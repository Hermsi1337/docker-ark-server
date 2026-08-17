FROM        cm2network/steamcmd:root

# the key has been MAINTAINER since the first published tag; lowercasing it to
# the form hadolint wants would change docker inspect output on every tag
# hadolint ignore=DL3048
LABEL       MAINTAINER="https://github.com/Hermsi1337/"

ARG         ARK_TOOLS_VERSION="v1.6.69"
ARG         IMAGE_VERSION="dev"

# the *_PASSWORD and STEAM_LOGIN defaults are placeholders and the documented
# config surface of the image, not credentials baked into a layer
# hadolint ignore=DL3064
ENV         IMAGE_VERSION="${IMAGE_VERSION}" \
            SESSION_NAME="Dockerized ARK Server by github.com/hermsi1337" \
            SERVER_MAP="TheIsland" \
            SERVER_MAP_MOD_ID="" \
            SERVER_PASSWORD="YouShallNotPass" \
            ADMIN_PASSWORD="Th155houldD3f1n3tlyB3Chang3d" \
            MAX_PLAYERS="20" \
            GAME_MOD_IDS="" \
            ARK_EXTRA_OPTS="" \
            ARK_GAME_INI_FILE="" \
            ARK_GAME_USER_SETTINGS_INI_FILE="" \
            UPDATE_ON_START="false" \
            VALIDATE_ON_START="false" \
            BACKUP_ON_STOP="false" \
            PRE_UPDATE_BACKUP="true" \
            MAX_BACKUP_SIZE_MB="" \
            WARN_ON_STOP="true" \
            ALWAYS_RESTART_ON_CRASH="" \
            SKIP_DISK_CHECK="false" \
            DISCORD_WEBHOOK_URL="" \
            CLUSTER_ID="" \
            SUB_INSTANCE_KEYS="" \
            ARK_TOOLS_VERSION="${ARK_TOOLS_VERSION}" \
            ARK_SERVER_VOLUME="/app" \
            BETA="" \
            BETA_ACCESSCODE="" \
            TEMPLATE_DIRECTORY="/conf.d" \
            GAME_CLIENT_PORT="7777" \
            UDP_SOCKET_PORT="7778" \
            RCON_PORT="27020" \
            SERVER_LIST_PORT="27015" \
            STEAM_HOME="/home/${USER}" \
            STEAM_USER="${USER}" \
            STEAM_LOGIN="anonymous" \
            PUID="" \
            PGID=""

ENV         ARK_TOOLS_DIR="${ARK_SERVER_VOLUME}/arkmanager"

# pipefail so a failed netinstall.sh download cannot be swallowed by the pipe
# and ship an image without arkmanager
SHELL       ["/bin/bash", "-o", "pipefail", "-c"]

# --no-install-recommends is deliberately not used: curl recommends
# ca-certificates, which the https fetch below needs, and cron recommends an
# MTA. Versions are not pinned either, every publish rebuilds with no-cache on
# a freshly pulled base so it ships current state on purpose.
# hadolint ignore=DL3008,DL3015
RUN         set -x && \
            apt-get update && \
            apt-get install -y  perl-modules \
                                curl \
                                lsof \
                                libc6-i386 \
                                lib32gcc-s1 \
                                bzip2 \
                                gosu \
                                cron \
                                procps \
            && \
            opt=$([ "${ARK_TOOLS_VERSION#v}" != "${ARK_TOOLS_VERSION}" ] && echo -n "--tag" || echo -n "--commit") && \
            curl -fsSL https://raw.githubusercontent.com/arkmanager/ark-server-tools/refs/heads/master/netinstall.sh | \
            bash -s "${USER}" "${opt}=${ARK_TOOLS_VERSION}" && \
            ln -s /usr/local/bin/arkmanager /usr/bin/arkmanager && \
            install -d -o "${USER}" "${ARK_SERVER_VOLUME}" && \
            su "${USER}" -c "bash -x ${STEAMCMDDIR}/steamcmd.sh +login anonymous +quit" && \
            apt-get -qq autoclean && apt-get -qq autoremove && apt-get -qq clean && \
            rm -rf /tmp/* /var/cache/*

COPY        bin/    /
COPY        conf.d  ${TEMPLATE_DIRECTORY}

EXPOSE      ${GAME_CLIENT_PORT}/udp ${UDP_SOCKET_PORT}/udp ${SERVER_LIST_PORT}/udp ${RCON_PORT}/tcp

VOLUME      ["${ARK_SERVER_VOLUME}"]
WORKDIR     ${ARK_SERVER_VOLUME}

HEALTHCHECK --interval=1m --timeout=30s --start-period=5m --retries=5 \
            CMD ["/healthcheck.sh"]

ENTRYPOINT  ["/docker-entrypoint.sh"]
CMD         []
