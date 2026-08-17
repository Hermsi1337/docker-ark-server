#!/usr/bin/env bats

# Covers install_pinned_manifest and the helpers it drives, against a steamcmd
# stub that mimics the real one on Linux: the depot lands below
# steamcmd/linux32/steamapps, the depotcache entry lands below Steam/, the
# completion line mixes path separators and carries no file count, the ARK
# depot ships no version.txt and no executable bit.

load helper

setup() {
  load_entrypoint

  SERVER_DIR="${ARK_SERVER_VOLUME}/server"
  SERVER_EXEC="${SERVER_DIR}/ShooterGame/Binaries/Linux/ShooterGameServer"
  APP_MANIFEST="${SERVER_DIR}/steamapps/appmanifest_376030.acf"

  export STEAM_HOME="${BATS_TEST_TMPDIR}/steamhome"
  export STEAM_LOGIN="ark_owner"
  export STUB_MODE="ok"
  mkdir -p "${STEAM_HOME}/steamcmd" "${ARK_SERVER_VOLUME}/log" "${SERVER_DIR}"

  TARGET_MANIFEST_ID="6740753408000000000"
  PRE_UPDATE_BACKUP="false"
  ARKMANAGER="$(command -v arkmanager)"

  DEPOT_ROOT="${STEAM_HOME}/steamcmd/linux32/steamapps/content/app_376030"
  CONTENT_STAGING="${DEPOT_ROOT}/depot_376031"
  REDIST_STAGING="${DEPOT_ROOT}/depot_1006"
  STAGING_MARKER="${DEPOT_ROOT}/.ark_requested_manifest_376031"

  write_steamcmd_stub
}

write_steamcmd_stub() {
  cat > "${STEAM_HOME}/steamcmd/steamcmd.sh" <<'STUB'
#!/usr/bin/env bash
DEPOT_ID=""; MANIFEST_ID=""; IS_DOWNLOAD=""
while [ $# -gt 0 ]; do
  case "${1}" in
    +download_depot)
      IS_DOWNLOAD=1; DEPOT_ID="${3}"; MANIFEST_ID="${4:-}"
      case "${MANIFEST_ID}" in +*) MANIFEST_ID="" ;; esac
      ;;
    +app_info_print) touch "${STEAM_HOME}/.appinfo_cached" ;;
  esac
  shift
done
[ -n "${IS_DOWNLOAD}" ] || exit 0

DEPOT_DIR="${STEAM_HOME}/steamcmd/linux32/steamapps/content/app_376030/depot_${DEPOT_ID}"
LINE_PATH="${STEAM_HOME}/steamcmd/linux32\\steamapps\\content\\app_376030\\depot_${DEPOT_ID}"
mkdir -p "${DEPOT_DIR}" "${STEAM_HOME}/Steam/depotcache"

if [ "${DEPOT_ID}" = "1006" ]; then
  case "${STUB_MODE}" in
    noredist)
      echo "Depot download failed : missing license for depot (No subscription)"
      exit 1
      ;;
  esac
  mkdir -p "${DEPOT_DIR}/linux64"
  echo so > "${DEPOT_DIR}/linux64/steamclient.so"
  echo " Depot download complete : \"${LINE_PATH}\" (manifest 6403079453713498174)"
  exit 0
fi

mkdir -p "${DEPOT_DIR}/ShooterGame/Binaries/Linux" "${DEPOT_DIR}/Engine"
echo "server binary for ${MANIFEST_ID}" > "${DEPOT_DIR}/ShooterGame/Binaries/Linux/ShooterGameServer"
chmod 644 "${DEPOT_DIR}/ShooterGame/Binaries/Linux/ShooterGameServer"
echo engine > "${DEPOT_DIR}/Engine/engine.bin"

case "${STUB_MODE}" in
  interrupted)
    echo "Depot download failed : Manifest not available"
    exit 1
    ;;
  wrongbuild)
    echo " Depot download complete : \"${LINE_PATH}\" (manifest 6366771435093287465)"
    touch "${STEAM_HOME}/Steam/depotcache/376031_6366771435093287465.manifest"
    ;;
  *)
    echo " Depot download complete : \"${LINE_PATH}\" (manifest ${MANIFEST_ID})"
    touch "${STEAM_HOME}/Steam/depotcache/376031_${MANIFEST_ID}.manifest"
    ;;
esac
STUB
  chmod +x "${STEAM_HOME}/steamcmd/steamcmd.sh"
}

assert_not_pinned() {
  if [ -f "${MANIFEST_PIN_FILE}" ]; then
    echo "expected no pin file, got:"
    cat "${MANIFEST_PIN_FILE}"
    return 1
  fi
}

@test "a completed pinned install lands the depot, the redist and the pin" {
  run install_pinned_manifest

  [ "$status" -eq 0 ]
  [ -x "${SERVER_EXEC}" ]
  [ -s "${SERVER_DIR}/linux64/steamclient.so" ]
  [ -d "${SERVER_DIR}/Engine" ]
  assert_contains "$(cat "${MANIFEST_PIN_FILE}")" "manifest=${TARGET_MANIFEST_ID}"
}

@test "the pin file records the build id and binary as its own fields" {
  install_pinned_manifest

  run cat "${MANIFEST_PIN_FILE}"

  assert_contains "$output" "buildid_at_pin=none"
  assert_contains "$output" "binary_at_pin=$(cksum < "${SERVER_EXEC}" | awk '{print $1"-"$2}')"
}

@test "a completed pinned install leaves no staging behind" {
  install_pinned_manifest

  [ ! -d "${CONTENT_STAGING}" ]
  [ ! -d "${REDIST_STAGING}" ]
}

@test "a pinned install drops the appmanifest of the build it replaced" {
  mkdir -p "$(dirname "${APP_MANIFEST}")"
  echo "old build" > "${APP_MANIFEST}"

  install_pinned_manifest

  [ ! -f "${APP_MANIFEST}" ]
}

@test "a wrong manifest is refused and its download discarded" {
  STUB_MODE="wrongbuild"

  run install_pinned_manifest

  [ "$status" -eq 1 ]
  assert_contains "$output" "did not deliver manifest ${TARGET_MANIFEST_ID}"
  assert_not_pinned
  [ ! -d "${CONTENT_STAGING}" ]
  [ ! -d "${REDIST_STAGING}" ]
}

@test "an interrupted download is kept and labelled with its manifest" {
  STUB_MODE="interrupted"

  run install_pinned_manifest

  [ "$status" -eq 1 ]
  assert_contains "$output" "did not finish downloading"
  assert_not_pinned
  [ -d "${CONTENT_STAGING}" ]
  [ "$(cat "${STAGING_MARKER}")" = "${TARGET_MANIFEST_ID}" ]
  [ ! -d "${REDIST_STAGING}" ]
}

@test "staging left over from another manifest is discarded, not written over" {
  mkdir -p "${CONTENT_STAGING}/ShooterGame/Binaries/Linux"
  echo "older build leftovers" > "${CONTENT_STAGING}/ShooterGame/Binaries/Linux/ShooterGameServer"
  echo "dropped by the newer build" > "${CONTENT_STAGING}/stale.bin"
  echo "385619103637186563" > "${STAGING_MARKER}"

  run install_pinned_manifest

  [ "$status" -eq 0 ]
  assert_contains "$output" "discarding a staged download"
  [ "$(cat "${SERVER_EXEC}")" = "server binary for ${TARGET_MANIFEST_ID}" ]
  [ ! -f "${SERVER_DIR}/stale.bin" ]
}

@test "staging kept for this manifest is resumed" {
  mkdir -p "${CONTENT_STAGING}"
  echo "${TARGET_MANIFEST_ID}" > "${STAGING_MARKER}"

  run install_pinned_manifest

  [ "$status" -eq 0 ]
  assert_contains "$output" "resuming the staged download"
}

@test "a missing redist is fatal when steamclient.so is not installed yet" {
  STUB_MODE="noredist"

  run install_pinned_manifest

  [ "$status" -eq 1 ]
  assert_contains "$output" "steamclient.so is not installed either"
  assert_not_pinned
}

@test "a missing redist is survivable when steamclient.so is already installed" {
  STUB_MODE="noredist"
  mkdir -p "${SERVER_DIR}/linux64"
  echo so > "${SERVER_DIR}/linux64/steamclient.so"

  run install_pinned_manifest

  [ "$status" -eq 0 ]
  assert_contains "$output" "keeping the copy that is already installed"
  assert_contains "$(cat "${MANIFEST_PIN_FILE}")" "manifest=${TARGET_MANIFEST_ID}"
}

@test "a failed backup stops the swap before anything is copied" {
  PRE_UPDATE_BACKUP="true"
  mkdir -p "${SERVER_DIR}/ShooterGame/Saved/SavedArks"
  echo world > "${SERVER_DIR}/ShooterGame/Saved/SavedArks/TheIsland.ark"
  ARKMANAGER="false"

  run install_pinned_manifest

  [ "$status" -eq 1 ]
  assert_contains "$output" "refusing to swap the server binaries"
  assert_not_pinned
  [ ! -f "${SERVER_EXEC}" ]
  [ ! -d "${CONTENT_STAGING}" ]
}

@test "a copy that runs out of space leaves no pin and no staging" {
  local bin_dir="${BATS_TEST_TMPDIR}/failbin"
  mkdir -p "${bin_dir}"
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$*" in *depot_376031*) echo "cp: No space left on device" >&2; exit 1 ;; esac'
    echo 'exec /bin/cp "$@"'
  } > "${bin_dir}/cp"
  chmod +x "${bin_dir}/cp"
  PATH="${bin_dir}:${PATH}"

  run install_pinned_manifest

  [ "$status" -eq 1 ]
  assert_contains "$output" "out of disk space"
  assert_not_pinned
  [ ! -d "${CONTENT_STAGING}" ]
  [ ! -d "${REDIST_STAGING}" ]
}

@test "an expired session is not blamed on the wrong steam account" {
  STUB_MODE="interrupted"

  run install_pinned_manifest

  assert_contains "$output" "Manifest not available"
}

@test "a licence failure names the session before the account" {
  : > "${PINNED_INSTALL_LOG}"
  echo "Depot download failed : missing license for depot (No subscription)" >> "${PINNED_INSTALL_LOG}"

  run explain_steamcmd_failure

  assert_contains "$output" "session for 'ark_owner' has expired"
  assert_contains "$output" "deploy/steam-login.sh"
}

@test "a missing app info failure points at the session too" {
  : > "${PINNED_INSTALL_LOG}"
  echo "Depot download failed : missing app info (Missing configuration)" >> "${PINNED_INSTALL_LOG}"

  run explain_steamcmd_failure

  assert_contains "$output" "could not load the app info"
  assert_contains "$output" "deploy/steam-login.sh"
}
