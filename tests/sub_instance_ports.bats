#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  GAME_CLIENT_PORT=7778
  SERVER_LIST_PORT=27015
  RCON_PORT=32330
  SUB_KEYS=(ragnarok)
}

@test "plain port numbers pass" {
  run assert_valid_sub_instance_ports

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ports are not validated without sub instances" {
  SUB_KEYS=()
  GAME_CLIENT_PORT="not-a-port"

  run assert_valid_sub_instance_ports

  [ "$status" -eq 0 ]
}

@test "rejects a port with a leading zero" {
  GAME_CLIENT_PORT="07778"

  run assert_valid_sub_instance_ports

  [ "$status" -eq 1 ]
  [[ "$output" == *"GAME_CLIENT_PORT='07778' must be a plain port number"* ]]
}

@test "rejects a non numeric port" {
  RCON_PORT="32330a"

  run assert_valid_sub_instance_ports

  [ "$status" -eq 1 ]
  [[ "$output" == *"RCON_PORT='32330a'"* ]]
}

@test "rejects an empty port" {
  SERVER_LIST_PORT=""

  run assert_valid_sub_instance_ports

  [ "$status" -eq 1 ]
  [[ "$output" == *"SERVER_LIST_PORT=''"* ]]
}

@test "rejects a port given as an arithmetic expression" {
  SERVER_LIST_PORT="27015+1"

  run assert_valid_sub_instance_ports

  [ "$status" -eq 1 ]
  [[ "$output" == *"SERVER_LIST_PORT='27015+1'"* ]]
}
