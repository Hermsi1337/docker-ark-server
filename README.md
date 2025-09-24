![Gitlab pipeline status](https://img.shields.io/gitlab/pipeline-status/hermsi1337/docker-ark-server?branch=master&style=flat-square)
[![Docker Pulls](https://img.shields.io/docker/pulls/hermsi/ark-server?label=hub.docker.com%20pulls&style=flat-square)](https://hub.docker.com/r/hermsi/ark-server)
[![Docker Repository on Quay](https://img.shields.io/badge/Quay.io-Repository-blue)](https://quay.io/repository/hermsi1337/ark-server)
[![Donate](https://img.shields.io/badge/Donate-PayPal-blue.svg)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=T85UYT37P3YNJ&source=url)

# Dockerize ARK managed with [ARK-Server-Tools](https://github.com/arkmanager/ark-server-tools)

You can use this image in order to start an ARK-Server for either public or private sessions.   
The Server itself is managable by ARK-Server-Tools.

## Tags

This image always installs the latest version of ARK-Server currently avaialable.   
Thus, the tags are reffering to the ARK-Server-Tools version which is used by the corresponding image.

## Usage

### ⚠️ Windows / WSL Notice ⚠️

**Mount the container volumes directly inside WSL's filesystem.** Mounting them inside a filesystem managed by Windows causes the installation to be painfully slow or even get stuck.

### Startup your ARK-Server

#### Basic configuration

The basic configuration of your server is done by using environment variables when starting the container:

| Variable | Default value | Explanation |
|:-----------------:|:----------------------------------------------:|:------------------------------------------------------------------------------------------------------------------------------------:|
| SESSION_NAME | Dockerized ARK Server by github.com/hermsi1337 | The name of your ARK-session which is visible in game when searching for servers |
| SERVER_MAP | TheIsland | Desired map you want to play |
| SERVER_PASSWORD | YouShallNotPass | Server password which is required to join your session. (overwrite with empty string if you want to disable password authentication) |
| ADMIN_PASSWORD | Th155houldD3f1n3tlyB3Chang3d | Admin-password in order to access the admin console of ARK |
| MAX_PLAYERS | 20 | Maximum number of players to join your session |
| UPDATE_ON_START | false | Whether you want to update the ARK-server upon startup or not |
| BACKUP_ON_STOP | false | Create a backup before gracefully stopping the ARK-server |
| PRE_UPDATE_BACKUP | true | Create a backup before updating ARK-server |
| WARN_ON_STOP | true | Broadcast a warning upon graceful shutdown |
| ENABLE_CROSSPLAY | false | Enable crossplay. When enabled battleye should be disabled as it likes to disconnect epic players |
| DISABLE_BATTLEYE | false | Disable Battleye protection |
| ARK_SERVER_VOLUME | /app | Path where the server-files are stored |
| GAME_CLIENT_PORT | 7777 | Exposed game-client port |
| UDP_SOCKET_PORT | 7778 | Raw UDP socket port (always Game client port +1) |
| RCON_PORT | 27020 | Exposed RCON port |
| SERVER_LIST_PORT | 27015 | Exposed server-list port |
| GAME_MOD_IDS | `empty` |  Additional game-mods you want to install, seperated by comma. (e.g. GAME_MOD_IDS=487516323,487516324,487516325) |
| BETA | `empty` | Specify the beta version if necessary. (e.g. BETA=preaquatica) |

#### Get things runnning

##### `docker-run`

I personally prefer `docker-compose` but for those of you, who want to run their own ARK-server without any "zip and zap", here you go:
```bash
# You may want to change SESSION_NAME, ADMIN_PASSWORD or host-volume
$ docker run -d --name="ark_server" --restart=always -v "${HOME}/ark-server:/app" -e SESSION_NAME="Awesome ARK is awesome" -e ADMIN_PASSWORD="FooB4r" hermsi/ark-server:latest
```

##### `docker-compose`

In order to startup your own ARK-server with `docker-compose` - which I personally preffer over a simple `docker run` - you may adapt the following `docker-compose.yml`:
```yml
version: '3'

services:
  server:
    restart: always
    container_name: ark_server
    image: hermsi/ark-server:latest
    volumes:
      - ${HOME}/ark-server:/app
      - ${HOME}/ark-server-backups:/home/steam/ARK-Backups
    environment:
      - SESSION_NAME=${SESSION_NAME}
      - SERVER_MAP=${SERVER_MAP}
      - SERVER_PASSWORD=${SERVER_PASSWORD}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD}
      - MAX_PLAYERS=${MAX_PLAYERS}
      - UPDATE_ON_START=${UPDATE_ON_START}
      - BACKUP_ON_STOP=${BACKUP_ON_STOP}
      - PRE_UPDATE_BACKUP=${PRE_UPDATE_BACKUP}
      - WARN_ON_STOP=${WARN_ON_STOP}
    ports:
      # Port for connections from ARK game client
      - "7777:7777/udp"
      # Raw UDP socket port (always Game client port +1)
      - "7778:7778/udp"
      # RCON management port
      - "27020:27020/tcp"
      # Steam's server-list port
      - "27015:27015/udp"
    networks:
      - default
```

After applying your changes to the `docker-compose.yml` above, light it up:
```bash
$ docker-compose up -d
```

### Tweak configuration

After your container is up and ARK is installed you can start tweaking your configuration.   
Basically, you can modify every setting which ARK-Server-Tools are capable of.   
For reference of the available commands check [their docs](https://github.com/FezVrasta/ark-server-tools#configuration).   

The main config files are located at the following path in the container:

* `/app/server/ShooterGame/Saved/Config/LinuxServer/GameUserSettings.ini`   
* `/app/server/ShooterGame/Saved/Config/LinuxServer/Game.ini`

You can easily apply your changes directly into these files.

Alternatively, it is possible to run any available command with ARK-Server-Tools and apply your changes that way:

```bash
$ docker exec -u steam ark_server arkmanager status
$ docker exec -u steam ark_server arkmanager update --force
$ docker exec -u steam ark_server arkmanager installmods
```

For a full list of all available commands [check here](https://github.com/FezVrasta/ark-server-tools#commands-acting-on-instances)

### Add cronjobs

It is also possible to add cronjobs inside the cointainer. You could use the crontab for update- or backup-stuff.   
In order to do so, edit the crontab-file located direct in the server-volume.

```bash
$ vim "${HOME}/ark-server/crontab"
```

Add your desired cronjobs with valid syntax:

```bash
0 0 * * * arkmanager update --warn --update-mods >> ${SERVER_VOLUME}/log/crontab.log 2>&1
0 0 * * * arkmanager backup >> ${SERVER_VOLUME}/log/crontab.log 2>&1
````

Close file (`:wq`) and restart the container:

```bash
$ docker restart ark_server
```

### Configure Steam login session
  
In order for `steamcmd` to respect your user's non-anonymous dlc's and stuff, you have to mount the steam-session inside the ark-server container.

To do so, you first need to login with steamcmd in order to create a valid session:

```shell
$ root@myVPS:/var/storage/ark-server# mkdir Steam
$ root@myVPS:/var/storage/ark-server# chown 1000.1000 Steam
$ root@myVPS:/var/storage/ark-server# docker run --rm --entrypoint /home/steam/steamcmd/steamcmd.sh -it -u steam -v $(pwd)/Steam:/home/steam/Steam hermsi/ark-server '+login YOUR_STEAM_USERNAME "YOUR_STEAM_PASSWORD"'
Redirecting stderr to '/home/steam/Steam/logs/stderr.txt'
[  0%] Checking for available updates...
[----] Verifying installation...
Steam Console Client (c) Valve Corporation - version 1654574676
-- type 'quit' to exit --
Loading Steam API...OK
Logging in user 'YOUR_STEAM_USERNAME' to Steam Public...
Enter the current code from your Steam Guard Mobile Authenticator app
Two-factor code:FOOBAR
OK
Waiting for client config...OK
Waiting for user info...OK

Steam>quit
```

Afterward, set the env-var `STEAM_LOGIN` to your user and mount the newly created `Steam`-directory inside your Ark-container:

```yaml
    environment:
      STEAM_LOGIN: "YOUR_STEAM_USERNAME"
    volumes:
      ./Steam:/home/steam/Steam:rw
```

Then, `arkmanager` will install / update `ark` using your provided login.

⚠️ Upgrade-Information ⚠️    
If you upgrade from an image-version prior to the timestamp `1656497302` you'll have to edit `line 15` in `arkmanager.cfg`.  
Replace with: `steamlogin="${STEAM_LOGIN}"`

## Sponsors

[@Skyfay](https://github.com/Skyfay) - [skyfay.ch](https://skyfay.ch)
