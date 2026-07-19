[![Build and Publish](https://github.com/Hermsi1337/docker-ark-server/actions/workflows/build-and-deploy.yml/badge.svg)](https://github.com/Hermsi1337/docker-ark-server/actions/workflows/build-and-deploy.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/hermsi/ark-server?label=hub.docker.com%20pulls&style=flat-square)](https://hub.docker.com/r/hermsi/ark-server)
[![Docker Repository on Quay](https://img.shields.io/badge/Quay.io-Repository-blue)](https://quay.io/repository/hermsi1337/ark-server)
[![Donate](https://img.shields.io/badge/Donate-PayPal-blue.svg)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=T85UYT37P3YNJ&source=url)

# ARK: Survival Evolved server, dockerized

Run a dedicated **ARK: Survival Evolved** server in Docker.
The game server is installed and updated through `steamcmd` and managed with
[arkmanager (ark-server-tools)](https://github.com/arkmanager/ark-server-tools),
so day-to-day tasks like updates, backups and mod installs are one command away.

> **Scope:** This image runs ARK: Survival **Evolved** (ASE).
> ARK: Survival **Ascended** (ASA) is a different game with a different,
> Windows-based server and is not covered by this image.

## Registries and tags

The same image is published to three registries:

```bash
docker pull hermsi/ark-server:latest                    # Docker Hub
docker pull quay.io/hermsi1337/ark-server:latest        # Quay.io
docker pull ghcr.io/hermsi1337/ark-server:latest        # GitHub Container Registry
```

| Tag | Meaning |
|---|---|
| `latest` | Most recent build from `master` |
| `latest-<unix-timestamp>` | Immutable snapshot of a specific `latest` build |
| `tools-<sha>` | Build pinned to the ark-server-tools commit it was built with |

Images are rebuilt from scratch **every Monday at 02:00 UTC** (and on every push
to `master`), always against a freshly pulled base image. The ARK server files
themselves live in your mounted volume and are installed and kept up to date at
runtime via `steamcmd`/`arkmanager` — the image tag mainly determines the
tooling around them.

The `Dockerfile` pins arkmanager to release `v1.6.69` by default for
reproducible local builds; published images are built against the current
ark-server-tools `master` commit, which is what the `tools-<sha>` tag refers to.

## Quick start

### ⚠️ Windows / WSL notice ⚠️

**Mount the container volumes directly inside WSL's filesystem.** Mounting them
inside a filesystem managed by Windows causes the installation to be painfully
slow or even get stuck.

### `docker run`

```bash
# You may want to change SESSION_NAME, ADMIN_PASSWORD or the host volume
docker run -d \
  --name ark-server \
  --restart unless-stopped \
  -v "${HOME}/ark-server:/app" \
  -e SESSION_NAME="Awesome ARK is awesome" \
  -e SERVER_PASSWORD="YouShallNotPass" \
  -e ADMIN_PASSWORD="FooB4r" \
  -p 7777:7777/udp \
  -p 7778:7778/udp \
  -p 27015:27015/udp \
  -p 27020:27020/tcp \
  hermsi/ark-server:latest
```

### `docker compose`

```yml
services:
  server:
    image: hermsi/ark-server:latest
    container_name: ark-server
    restart: unless-stopped
    volumes:
      - ${HOME}/ark-server:/app
    environment:
      - SESSION_NAME=Awesome ARK is awesome
      - SERVER_MAP=TheIsland
      - SERVER_PASSWORD=YouShallNotPass
      - ADMIN_PASSWORD=FooB4r
      - MAX_PLAYERS=20
      - UPDATE_ON_START=false
      - PRE_UPDATE_BACKUP=true
    ports:
      # Port for connections from the ARK game client
      - "7777:7777/udp"
      # Raw UDP socket port (always game client port +1)
      - "7778:7778/udp"
      # Steam's server-list port
      - "27015:27015/udp"
      # RCON management port
      - "27020:27020/tcp"
```

```bash
docker compose up -d
```

A ready-made compose setup with an `.env` file lives in the
[`deploy/`](deploy/) directory of this repository.

**Note:** on first start the container installs the complete ARK dedicated
server into your volume via `steamcmd` — that is a very large download. Follow
the progress with `docker logs -f ark-server`.

## Configuration

Basic configuration is done with environment variables:

| Variable | Default value | Explanation |
|:-----------------:|:----------------------------------------------:|:------------------------------------------------------------------------------------------------------------------------------------:|
| SESSION_NAME | Dockerized ARK Server by github.com/hermsi1337 | The name of your ARK session, visible in the in-game server browser |
| SERVER_MAP | TheIsland | Desired map you want to play |
| SERVER_PASSWORD | YouShallNotPass | Server password required to join your session (overwrite with an empty string to disable password authentication) |
| ADMIN_PASSWORD | Th155houldD3f1n3tlyB3Chang3d | Admin password for the in-game admin console and RCON |
| MAX_PLAYERS | 20 | Maximum number of players in your session |
| GAME_MOD_IDS | `empty` | Additional game mods to install, separated by comma (e.g. `GAME_MOD_IDS=487516323,487516324,487516325`) |
| UPDATE_ON_START | false | Update the ARK server and mods (with a backup, if configured) before each start |
| VALIDATE_ON_START | false | Let `steamcmd` validate and repair the server files during `UPDATE_ON_START` — useful after a corrupted update, but makes the start noticeably slower |
| PRE_UPDATE_BACKUP | true | Create a backup before updating the ARK server |
| BACKUP_ON_STOP | false | Create a backup after the world save when the container is stopped gracefully |
| WARN_ON_STOP | true | Broadcast a shutdown warning to players when the container is stopped gracefully |
| ENABLE_CROSSPLAY | false | Enable crossplay (starts the server with `-crossplay`). When enabled, BattlEye should be disabled as it likes to disconnect Epic players |
| DISABLE_BATTLEYE | false | Disable BattlEye protection (starts the server with `-NoBattlEye`) |
| ARK_EXTRA_OPTS | `empty` | Additional ARK command line options, space separated (e.g. `ARK_EXTRA_OPTS=-ForceAllowCaveFlyers -PreventHibernation`). Each option must be of the form `-Flag` or `-Name=Value`; spaces inside an option are not supported |
| BETA | `empty` | Opt into a Steam beta branch if necessary (e.g. `BETA=preaquatica`) |
| BETA_ACCESSCODE | `empty` | Access code for the chosen beta branch, if it requires one |
| STEAM_LOGIN | anonymous | Steam account used by `steamcmd` (see [Steam login session](#configure-a-steam-login-session)) |
| ARK_SERVER_VOLUME | /app | Path inside the container where the server files are stored |
| PUID | `empty` | Run the server with a custom UID, e.g. to match the owner of a bind mount on NAS systems. If the server volume's ownership does not match, it is adopted once via a recursive chown, which can take a while |
| PGID | `empty` | Run the server with a custom GID (see `PUID`) |
| GAME_CLIENT_PORT | 7777 | Exposed game client port |
| UDP_SOCKET_PORT | 7778 | Raw UDP socket port (always game client port +1) |
| RCON_PORT | 27020 | Exposed RCON port |
| SERVER_LIST_PORT | 27015 | Exposed server-list (query) port |
| SKIP_DISK_CHECK | false | Skip the free-disk-space check (~25GB) before the initial server installation |
| DEBUG | `empty` | Set to `true` for verbose (`set -x`) entrypoint logging |

### Graceful shutdown

On `docker stop` / `docker restart` the entrypoint warns players
(`WARN_ON_STOP`), saves the world via `arkmanager stop --saveworld` and
optionally creates a backup (`BACKUP_ON_STOP`). Docker only waits 10 seconds
by default before force-killing the container — far too short for an ARK
world save. Raise the grace period, otherwise you risk losing progress:

```yaml
services:
  server:
    stop_grace_period: 5m
```

For plain `docker` commands use `docker stop -t 300 ark-server` (and
`docker run --stop-timeout 300 ...`).

Note: the world save itself is additionally bounded by arkmanager-internal
timeouts (roughly 50 seconds) — the grace period has to cover the shutdown
warning, the save, the optional backup and the process shutdown.

### Data layout

Everything the server needs lives in the volume mounted at `/app`
(`ARK_SERVER_VOLUME`):

| Path | Purpose |
|---|---|
| `/app/server` | The ARK dedicated server installation |
| `/app/backup` | Backups created by `arkmanager backup` |
| `/app/log` | arkmanager log files |
| `/app/staging` | Staging directory for server updates |
| `/app/crontab` | Cron definitions loaded at container start |
| `/app/environment` | Auto-generated on every start: container environment for cron jobs (contains credentials, mode 600) |
| `/app/arkmanager` | Persisted arkmanager configuration (global + instance) |
| `/app/Game.ini`, `/app/GameUserSettings.ini` | Convenience symlinks to the real config files |

### Tweak the configuration

After your container is up and ARK is installed you can start tweaking your
configuration. Basically, you can modify every setting ark-server-tools is
capable of. For reference of the available settings check
[their docs](https://github.com/arkmanager/ark-server-tools#configuration).

The main game config files are located at:

* `/app/server/ShooterGame/Saved/Config/LinuxServer/GameUserSettings.ini`
* `/app/server/ShooterGame/Saved/Config/LinuxServer/Game.ini`

The entrypoint symlinks both of them into the volume root, so on the host you
can simply edit `<your-volume>/Game.ini` and `<your-volume>/GameUserSettings.ini`.
If an upload replaces one of these symlinks with a regular file, the entrypoint
adopts the uploaded content as the real config on the next start (keeping the
previous one as `.bak`) and re-creates the symlink.

The arkmanager configuration (`arkmanager.cfg` and the `main` instance config)
persists in `<your-volume>/arkmanager/`. The bundled templates are only copied
there when the files do not exist yet, so your changes survive image updates.

Alternatively, run any ark-server-tools command directly:

```bash
docker exec -u steam ark-server arkmanager status
docker exec -u steam ark-server arkmanager update --force
docker exec -u steam ark-server arkmanager installmods
docker exec -u steam ark-server arkmanager backup
```

For a full list of all available commands
[check here](https://github.com/arkmanager/ark-server-tools#commands-acting-on-instances).

### Add cronjobs

You can add cronjobs inside the container, e.g. for scheduled updates or
backups. Edit the crontab file located in the server volume:

```bash
vim "${HOME}/ark-server/crontab"
```

Add your desired cronjobs with valid syntax (they run as the `steam` user):

```bash
0 4 * * * arkmanager update --warn --update-mods >> /app/log/crontab.log 2>&1
0 0 * * * arkmanager backup >> /app/log/crontab.log 2>&1
```

The container environment is exported to `/app/environment` on every start and
loaded into each job via the crontab's `BASH_ENV` header, so cron jobs see the
same variables as the server process. If your crontab was created by an older
image and jobs fail with errors like `mkdir: cannot create directory '/server'`,
add these two lines at the top of the file:

```bash
SHELL=/bin/bash
BASH_ENV=/app/environment
```

The crontab is loaded when the container starts, so apply your changes with:

```bash
docker restart ark-server
```

### Configure a Steam login session

For `steamcmd` to respect your account's non-anonymous DLCs and content, mount
a Steam session into the container.

The [`deploy/steam-login.sh`](deploy/steam-login.sh) helper automates the
whole procedure (including resetting a broken session):

```bash
cd deploy && STEAM_LOGIN=your_steam_username ./steam-login.sh
```

Or do it manually: log in once with `steamcmd` to create a valid session:

```shell
mkdir Steam && chown 1000:1000 Steam
docker run --rm -it -u steam \
  -v "$(pwd)/Steam:/home/steam/Steam" \
  --entrypoint /home/steam/steamcmd/steamcmd.sh \
  hermsi/ark-server '+login YOUR_STEAM_USERNAME "YOUR_STEAM_PASSWORD"'
# ...enter your Steam Guard code when prompted, then type: quit
```

Afterwards, set the env var `STEAM_LOGIN` to your username and mount the newly
created `Steam` directory into your ARK container:

```yaml
    environment:
      STEAM_LOGIN: "YOUR_STEAM_USERNAME"
    volumes:
      - ./Steam:/home/steam/Steam:rw
```

`arkmanager` will then install/update ARK using your login. When using
`PUID`/`PGID`, the ARK container adopts ownership of the mounted Steam
session automatically on start.

⚠️ **Upgrade note:** the arkmanager config in your volume is only created once
and never overwritten. If your server volume was first created with an image
older than timestamp `1656497302`, edit line 15 of
`<your-volume>/arkmanager/arkmanager.cfg` and replace it with:
`steamlogin="${STEAM_LOGIN}"`

## Troubleshooting

### `[S_API FAIL] SteamAPI_Init() failed` in the logs

Harmless. This message shows up on virtually every steamcmd-based dedicated
server (there is no Steam client running inside the container) and is **not**
the reason your server is unreachable.

### Log lines full of backslashes (`TheIsland\?SessionName=My\ Server`)

Also harmless — arkmanager logs the launch command in shell-escaped form.
The server receives the unescaped values.

### Server does not show up in the server list / cannot connect

- ARK speaks **UDP**. All three UDP ports (`7777`, `7778`, `27015`) must be
  published *and* forwarded in your router/firewall; `7778` must stay game
  client port +1.
- The in-game server browser is slow and unreliable. Test via the Steam
  client instead: *View → Game Servers → Favorites → Add* `your-ip:27015`.
- Give a freshly started server several minutes before it responds to
  queries — map loading and mod installs take time.
- Docker Desktop on macOS/Windows has flaky UDP port forwarding. On a Linux
  host, `network_mode: host` (drop the `ports:` section) is the most reliable
  setup if the lists stay empty.
- Port-remapping tunnel services (playit.gg and friends) break ARK's
  assumption that the raw socket port is game port +1 and that the query port
  it announces is reachable — prefer plain port forwarding.

### Changes to `Game.ini` / `GameUserSettings.ini` disappear

The ARK **server itself** rewrites both files on startup and shutdown — that
is game behavior, not this image. Stop the container first, then edit, then
start:

```bash
docker stop -t 300 ark-server
vim "${HOME}/ark-server/GameUserSettings.ini"
docker start ark-server
```

Also note that settings supplied on the command line (via the environment
variables / arkmanager) override the corresponding INI values.

### How much RAM / disk do I need?

Plan with **at least 8 GB of RAM** (more with mods and larger maps — ARK is
hungry) and **~25 GB of disk** for the base install, plus headroom for
staging, backups and mods. Memory can be capped with docker's usual
`mem_limit` / `deploy.resources` settings, but if the limit is below what the
map needs the server will simply be OOM-killed.

### Restore a backup

`arkmanager restore` must not run while the server is up — the next autosave
would overwrite the restored files again. Use a throwaway container on the
stopped volume:

```bash
# 1. stop the server gracefully (world save)
docker stop -t 300 ark-server

# 2. restore (picks the most recent backup; pass a backup file to choose one)
docker run --rm -it -v "${HOME}/ark-server:/app" --entrypoint bash hermsi/ark-server \
  -c 'rm -rf /etc/arkmanager && ln -s /app/arkmanager /etc/arkmanager && gosu steam arkmanager restore'

# 3. start the server again
docker start ark-server
```

If you run with `PUID`/`PGID`, replace `gosu steam` with `gosu <PUID>:<PGID>`
(gosu accepts numeric ids) so the restored files get the right owner.

### Xbox crossplay?

Not possible with this image. ASE's `-crossplay` flag covers **Steam and
Epic** players only; console crossplay requires the Windows-Store/"Play
Anywhere" server or ARK: Survival Ascended — both out of scope here.

### arm64 / Raspberry Pi / Apple Silicon?

Not possible — see [Architecture](#architecture): the ARK server binary only
exists for x86-64.

### Mods fail to download / `No cached credentials`

Non-anonymous content requires a persistent
[Steam login session](#configure-a-steam-login-session). If an interactive
login dies with `Assertion Failed: Failed to write file after download`,
delete the mounted `Steam` session directory and log in again (a known
steamcmd quirk — accounts using the Steam Guard **mobile authenticator**
work most reliably); the bundled
[`deploy/steam-login.sh`](deploy/steam-login.sh) automates exactly that.

## Architecture

This image is built for **`linux/amd64` only**. Both the underlying
`cm2network/steamcmd` base image and the ARK: Survival Evolved dedicated server
are x86-only software, so arm64 builds are not possible.

## Contributing and maintenance

Development, CI/CD and maintenance conventions for this repository are
documented in [AGENTS.md](AGENTS.md). Pull requests against `master`
automatically get a preview image build.

## Sponsors

[@Skyfay](https://github.com/Skyfay) - [skyfay.ch](https://skyfay.ch)
