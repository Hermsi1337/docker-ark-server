#!/usr/bin/env bats

load helper

setup() {
  load_cron_schedule
}

accepts() {
  run assert_valid_cron_schedule BACKUP_CRON "${1}"

  if [ "$status" -ne 0 ]; then
    echo "expected '${1}' to be accepted, got: ${output}"
    return 1
  fi
}

rejects() {
  run assert_valid_cron_schedule BACKUP_CRON "${1}"

  if [ "$status" -ne 1 ]; then
    echo "expected '${1}' to be rejected, got status ${status}"
    return 1
  fi
  assert_contains "$output" "${2}"
}

@test "an empty schedule is not a schedule" {
  run assert_valid_cron_schedule BACKUP_CRON ""

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "accepts the plain five field forms" {
  accepts "0 4 * * *"
  accepts "* * * * *"
  accepts "30 5 * * 1-5"
  accepts "5,10,15 * * * *"
  accepts "07 04 * * *"
}

@test "accepts steps over a star and over a range" {
  accepts "*/15 * * * *"
  accepts "0 */6 * * *"
  accepts "0-30/5 * * * *"
}

@test "accepts names for month and day of week" {
  accepts "0 0 1 jan *"
  accepts "0 0 * * mon-fri"
  accepts "0 0 1 JAN *"
  accepts "0 0 * * SUN"
}

@test "accepts sunday as 0 and as 7" {
  accepts "0 0 * * 0"
  accepts "0 0 * * 7"
}

@test "accepts february 29, it exists in leap years" {
  accepts "0 0 29 feb *"
}

@test "accepts the shorthands cron understands" {
  accepts "@yearly"
  accepts "@annually"
  accepts "@monthly"
  accepts "@weekly"
  accepts "@daily"
  accepts "@midnight"
  accepts "@hourly"
}

@test "trims whitespace around the value" {
  accepts "  0 4 * * *  "
  accepts "	@daily "
}

@test "rejects the wrong number of fields" {
  rejects "0 4 * *" "4 fields instead of 5"
  rejects "0 0 * * * extra" "6 fields instead of 5"
}

@test "rejects values cron installs but never fires" {
  rejects "0 24 * * *" "hour entry '24' is out of range"
  rejects "60 4 * * *" "minute entry '60' is out of range"
  rejects "0 4 32 * *" "day-of-month entry '32' is out of range"
  rejects "0 4 * 13 *" "month entry '13' is out of range"
  rejects "0 4 * * 8" "day-of-week entry '8' is out of range"
  rejects "0 0 0 * *" "day-of-month entry '0' is out of range"
  rejects "0 0 * 0 *" "month entry '0' is out of range"
  rejects "1-70 * * * *" "minute entry '1-70' is out of range"
}

@test "rejects a date that does not exist" {
  rejects "0 0 31 2 *" "month 2 never has 31 days"
  rejects "0 0 31 feb *" "month 2 never has 31 days"
  rejects "0 0 31 4 *" "month 4 never has 31 days"
}

@test "rejects a backwards range" {
  rejects "0 0 * * 5-1" "counts backwards"
  rejects "30-10 * * * *" "counts backwards"
}

@test "rejects broken steps" {
  rejects "*/ * * * *" "needs a step of at least 1"
  rejects "*/0 * * * *" "needs a step of at least 1"
  rejects "0-30/0 * * * *" "needs a step of at least 1"
  rejects "5/10 * * * *" "can only step over '*' or a range"
  rejects "*/abc * * * *" "needs a step of at least 1"
}

@test "rejects empty list entries" {
  rejects "0,, 4 * * *" "has an empty list entry"
  rejects ",0 4 * * *" "has an empty list entry"
  rejects "0 4 * * *," "has an empty list entry"
}

@test "rejects things that are not numbers, names or ranges" {
  rejects "0 h * * *" "neither a number, a name nor a range"
  rejects "0 4 * * mon-" "neither a number, a name nor a range"
  rejects "0 4 * * 0-1-2" "neither a number, a name nor a range"
  rejects "** * * * *" "neither a number, a name nor a range"
  rejects "+5 * * * *" "neither a number, a name nor a range"
  rejects "0 4 * * 5#2" "neither a number, a name nor a range"
  rejects "0 4 L * *" "neither a number, a name nor a range"
}

@test "rejects shell metacharacters" {
  rejects '0 0 * * *$(id)' "neither a number, a name nor a range"
  rejects "0 0 * * * ; rm -rf /" "fields instead of 5"
  rejects '0 0 * * *`id`' "neither a number, a name nor a range"
  rejects "0 0 * * *|tee" "neither a number, a name nor a range"
}

@test "rejects more than one line" {
  rejects "$(printf '* * * * *\n0 0 * * *')" "single line"
  rejects "$(printf '0 0 * * *\ry')" "single line"
}

@test "a trailing carriage return from a CRLF env file is trimmed, not rejected" {
  accepts "$(printf '0 3 * * *\r')"
}

@test "rejects unsupported shorthands" {
  rejects "@reboot" "@reboot is not"
  rejects "@Daily" "supported shorthands"
  rejects "@weekly extra" "supported shorthands"
  rejects "@" "supported shorthands"
}

@test "rejects numbers long enough to wrap the arithmetic" {
  rejects "18446744073709551616 4 * * *" "more than four digits"
  rejects "*/18446744073709551617 * * * *" "more than four digits"
}

@test "rejects an absurdly long schedule" {
  local long
  long="$(printf '0%.0s' $(seq 1 250))"

  rejects "${long} 4 * * *" "more than the 200 this image allows"
}

@test "rejects a list with more entries than the field can hold" {
  local many
  many="1$(printf ',1%.0s' $(seq 1 64))"

  rejects "${many} 4 * * *" "more than the 64 this image allows"
}

@test "a full accept run touches no external tool" {
  accepts "0 4 * * *"
  accepts "@daily"

  assert_stubs_installed_and_unused
}
