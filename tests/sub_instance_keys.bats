#!/usr/bin/env bats

load helper

setup() {
  load_entrypoint
}

@test "no sub instances without SUB_INSTANCE_KEYS" {
  SUB_INSTANCE_KEYS=""

  parse_sub_instance_keys

  [ "${#SUB_KEYS[@]}" -eq 0 ]
}

@test "keeps the order of a comma separated list" {
  SUB_INSTANCE_KEYS="ragnarok,aberration,center"

  parse_sub_instance_keys

  [ "${SUB_KEYS[*]}" = "ragnarok aberration center" ]
}

@test "trims whitespace around keys" {
  SUB_INSTANCE_KEYS="  ragnarok ,	aberration  "

  parse_sub_instance_keys

  [ "${SUB_KEYS[*]}" = "ragnarok aberration" ]
}

@test "skips empty entries" {
  SUB_INSTANCE_KEYS=",ragnarok,,  ,aberration,"

  parse_sub_instance_keys

  [ "${SUB_KEYS[*]}" = "ragnarok aberration" ]
}

@test "accepts letters, digits and underscores" {
  SUB_INSTANCE_KEYS="the_island2,RAGNAROK"

  parse_sub_instance_keys

  [ "${SUB_KEYS[*]}" = "the_island2 RAGNAROK" ]
}

@test "rejects a key with a dash" {
  SUB_INSTANCE_KEYS="the-island"

  run parse_sub_instance_keys

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid SUB_INSTANCE_KEYS entry 'the-island'"* ]]
}

@test "rejects a key with embedded whitespace instead of collapsing it" {
  SUB_INSTANCE_KEYS="the island"

  run parse_sub_instance_keys

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid SUB_INSTANCE_KEYS entry 'the island'"* ]]
}

@test "rejects a key that would expand a shell variable" {
  SUB_INSTANCE_KEYS='$(whoami)'

  run parse_sub_instance_keys

  [ "$status" -eq 1 ]
  [[ "$output" == *"letters, digits and underscores"* ]]
}

@test "rejects duplicate keys" {
  SUB_INSTANCE_KEYS="ragnarok,aberration,ragnarok"

  run parse_sub_instance_keys

  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate SUB_INSTANCE_KEYS entry 'ragnarok'"* ]]
}

@test "duplicates are detected after trimming" {
  SUB_INSTANCE_KEYS="ragnarok, ragnarok "

  run parse_sub_instance_keys

  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "keys differing in case are not duplicates" {
  SUB_INSTANCE_KEYS="ragnarok,Ragnarok"

  parse_sub_instance_keys

  [ "${SUB_KEYS[*]}" = "ragnarok Ragnarok" ]
}
