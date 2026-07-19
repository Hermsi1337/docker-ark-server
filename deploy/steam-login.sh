#!/usr/bin/env bash
#
# Create or refresh the persistent Steam session used with STEAM_LOGIN.
# See the README section "Configure a Steam login session".
#
# Usage:
#   STEAM_LOGIN=your_steam_username ./steam-login.sh
# or set STEAM_LOGIN (and optionally STEAM_SESSION_VOLUME) in ./.env
#
# steamcmd will prompt for your password and Steam Guard interactively.
# If a previous session is broken (e.g. 'Assertion Failed: Failed to write
# file after download'), pass --reset to wipe it before logging in again.

set -euo pipefail

cd "$(dirname "$0")"

if [[ -f ".env" ]]; then
  # shellcheck disable=SC1091
  source ".env"
fi

STEAM_SESSION_VOLUME="${STEAM_SESSION_VOLUME:-${PWD}/Steam}"
IMAGE="${IMAGE:-hermsi/ark-server:latest}"

if [[ -z "${STEAM_LOGIN:-}" ]] || [[ "${STEAM_LOGIN}" == "anonymous" ]]; then
  echo "ERROR: set STEAM_LOGIN to your Steam username, e.g.:"
  echo "       STEAM_LOGIN=your_steam_username ${0}"
  exit 1
fi

if [[ "${1:-}" == "--reset" ]]; then
  echo "Wiping existing Steam session in ${STEAM_SESSION_VOLUME}..."
  rm -rf "${STEAM_SESSION_VOLUME}"
fi

mkdir -p "${STEAM_SESSION_VOLUME}"

# the session files must belong to the container's steam user
docker run --rm -v "${STEAM_SESSION_VOLUME}:/home/steam/Steam" \
  --entrypoint chown "${IMAGE}" -R steam: /home/steam/Steam

docker run --rm -it -u steam \
  -v "${STEAM_SESSION_VOLUME}:/home/steam/Steam" \
  --entrypoint /home/steam/steamcmd/steamcmd.sh \
  "${IMAGE}" +login "${STEAM_LOGIN}" +quit

echo ""
echo "Steam session stored in ${STEAM_SESSION_VOLUME}."
echo "Mount it into your server container as /home/steam/Steam and set STEAM_LOGIN=${STEAM_LOGIN}."
