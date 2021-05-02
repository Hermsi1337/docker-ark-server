FROM        debian:stable-slim

LABEL       MAINTAINER="https://github.com/Hermsi1337/"

ARG         ARK_TOOLS_VERSION="1.6.42"
ENV         LANG="en_US.UTF-8" \
            LANGUAGE="en_US:en" \
            LC_ALL="en_US.UTF-8" \
            TERM="linux" \
            SESSION_NAME="Dockerized ARK Server by github.com/hermsi1337" \
            SERVER_MAP="TheIsland" \
            SERVER_PASSWORD="YouShallNotPass" \
            ADMIN_PASSWORD="Th155houldD3f1n3tlyB3Chang3d" \
            MAX_PLAYERS="20" \
            GAME_MOD_IDS="" \
            UPDATE_ON_START="false" \
            BACKUP_ON_STOP="false" \
            PRE_UPDATE_BACKUP="true" \
            WARN_ON_STOP="true" \
            ARK_TOOLS_VERSION="${ARK_TOOLS_VERSION}" \
            ARK_SERVER_VOLUME="/app" \
            GAME_CLIENT_PORT="7777" \
            UDP_SOCKET_PORT="7778" \ #(always Game client port +1
            RCON_PORT="27020" \
            SERVER_LIST_PORT="27015" \
            STEAM_USER="steam" \
            STEAM_GROUP="steam" \
            STEAM_UID="1000" \
            STEAM_GID="1000" \
            STEAM_HOME="/home/steam"

RUN         set -x && \
            apt-get -qq update && apt-get -qq upgrade && \
            apt-get -qq install curl lib32gcc1 lsof perl-modules libc6-i386 bzip2 bash-completion locales sudo cron && \
            sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen && \
            addgroup --gid ${STEAM_GID} ${STEAM_USER} && \
            adduser --home ${STEAM_HOME} --uid ${STEAM_UID} --gid ${STEAM_GID} --disabled-login --shell /bin/bash --gecos "" ${STEAM_USER} && \
            echo "${STEAM_USER} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
            usermod -a -G sudo ${STEAM_USER} && \
            mkdir -p ${ARK_SERVER_VOLUME} ${STEAM_HOME}/steamcmd && \
            curl -L https://github.com/FezVrasta/ark-server-tools/archive/v${ARK_TOOLS_VERSION}.tar.gz \
                | tar -xvzf - -C /tmp/ && \
            bash -c "cd /tmp/ark-server-tools-${ARK_TOOLS_VERSION}/tools && bash install.sh ${STEAM_USER}" && \
            ln -s /usr/local/bin/arkmanager /usr/bin/arkmanager && \
            curl -L http://media.steampowered.com/installer/steamcmd_linux.tar.gz \
                | tar -xvzf - -C ${STEAM_HOME}/steamcmd/ && \
            bash -x ${STEAM_HOME}/steamcmd/steamcmd.sh +login anonymous +quit && \
            chown -R ${STEAM_USER}:${STEAM_GROUP} ${STEAM_HOME} ${ARK_SERVER_VOLUME} && \
            chmod 755 /root/ && \
            apt-get -qq autoclean && apt-get -qq autoremove && apt-get -qq clean && \
            rm -rf /tmp/* /var/cache/apt/*

COPY         conf.d/arkmanager-user.cfg  /etc/arkmanager/instances/main.cfg
COPY         bin/    /
COPY         conf.d/ ${STEAM_HOME}/

EXPOSE      ${GAME_CLIENT_PORT}/udp ${SERVER_LIST_PORT}/udp ${RCON_PORT}/tcp

VOLUME      ["${ARK_SERVER_VOLUME}"]
WORKDIR     ${ARK_SERVER_VOLUME}

USER        ${STEAM_USER}

ENTRYPOINT  ["/entrypoint.sh"]
