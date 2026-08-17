#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  SERVER_DIR="${ARK_SERVER_VOLUME}/server"
  SERVER_EXEC="${SERVER_DIR}/ShooterGame/Binaries/Linux/ShooterGameServer"
  APP_MANIFEST="${SERVER_DIR}/steamapps/appmanifest_376030.acf"
}

install_server_files() {
  mkdir -p "$(dirname "${SERVER_EXEC}")" "$(dirname "${APP_MANIFEST}")"
  echo "binary" > "${SERVER_EXEC}"
  echo "manifest" > "${APP_MANIFEST}"
}

@test "wants an install on an empty volume" {
  run needs_install

  [ "$status" -eq 0 ]
  [[ "$output" == *"${SERVER_DIR} not found"* ]]
}

@test "is satisfied by a complete install" {
  install_server_files

  run needs_install

  [ "$status" -eq 1 ]
  [ "$output" = "Already installed." ]
}

@test "wants an install when the server executable is missing" {
  install_server_files
  rm "${SERVER_EXEC}"

  run needs_install

  [ "$status" -eq 0 ]
  [[ "$output" == *"ShooterGameServer is not complete"* ]]
}

@test "wants an install when the server executable is empty" {
  install_server_files
  : > "${SERVER_EXEC}"

  run needs_install

  [ "$status" -eq 0 ]
  [[ "$output" == *"is not complete"* ]]
}

@test "wants an install when the steam app manifest is missing" {
  install_server_files
  rm "${APP_MANIFEST}"

  run needs_install

  [ "$status" -eq 0 ]
  [[ "$output" == *"appmanifest_376030.acf is not complete"* ]]
}

@test "is satisfied by a legacy install that only has version.txt" {
  install_server_files
  rm "${APP_MANIFEST}"
  echo "1.2.3" > "${SERVER_DIR}/version.txt"

  run needs_install

  [ "$status" -eq 1 ]
  [[ "$output" == *"found ${SERVER_DIR}/version.txt"* ]]
}

@test "wants a repair install when version.txt outlives the server executable" {
  install_server_files
  rm "${SERVER_EXEC}"
  echo "1.2.3" > "${SERVER_DIR}/version.txt"

  run needs_install

  [ "$status" -eq 0 ]
  [[ "$output" == *"is not complete"* ]]
}

@test "checks the files without calling arkmanager or steamcmd" {
  install_server_files

  run needs_install

  assert_no_stub_calls
}
