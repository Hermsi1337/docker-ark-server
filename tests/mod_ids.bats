#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint

  SERVER_MAP_MOD_ID=""
  GAME_MOD_IDS=""
  SUB_KEYS=()
}

@test "collects nothing when no mods are configured" {
  run get_all_mod_ids

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "collects the map mod of the main instance" {
  SERVER_MAP_MOD_ID="111111"

  run get_all_mod_ids

  [ "$output" = "111111" ]
}

@test "splits the comma separated main mod list" {
  GAME_MOD_IDS="111111,222222,333333"

  run get_all_mod_ids

  [ "${#lines[@]}" -eq 3 ]
  [ "$output" = "111111
222222
333333" ]
}

@test "collects mods of sub instances" {
  SUB_KEYS=(ragnarok)
  SUB_ragnarok_SERVER_MAP_MOD_ID="444444"
  SUB_ragnarok_GAME_MOD_IDS="555555,666666"

  run get_all_mod_ids

  [ "$output" = "444444
555555
666666" ]
}

@test "reports a mod used by main and a sub instance only once" {
  GAME_MOD_IDS="111111,222222"
  SUB_KEYS=(ragnarok)
  SUB_ragnarok_GAME_MOD_IDS="222222,333333"

  run get_all_mod_ids

  [ "${#lines[@]}" -eq 3 ]
  [ "$output" = "111111
222222
333333" ]
}

@test "reports a mod used by two sub instances only once" {
  SUB_KEYS=(ragnarok aberration)
  SUB_ragnarok_GAME_MOD_IDS="222222"
  SUB_aberration_GAME_MOD_IDS="222222"
  SUB_aberration_SERVER_MAP_MOD_ID="222222"

  run get_all_mod_ids

  [ "$output" = "222222" ]
}

@test "ignores empty entries in a mod list" {
  GAME_MOD_IDS="111111,,222222,"

  run get_all_mod_ids

  [ "${#lines[@]}" -eq 2 ]
  [ "$output" = "111111
222222" ]
}

@test "collects the ids without calling arkmanager or steamcmd" {
  GAME_MOD_IDS="111111"

  run get_all_mod_ids

  assert_stubs_installed_and_unused
}
