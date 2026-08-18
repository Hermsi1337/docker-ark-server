#!/usr/bin/env bash

# Validation for a single cron schedule string, sourced by the entrypoint.
# Definitions only, no startup code: everything here is about cron syntax,
# nothing about this container. Stays bash 3.2 compatible, the test suite
# sources it on the bash macOS ships.
#
# Cron itself validates almost nothing: it installs '0 24 * * *' or
# '0 0 31 2 *' without a word and simply never runs them. Every rule below
# came out of a schedule that was accepted somewhere and then silently did
# nothing.

CRON_FIELD_NAMES=("minute" "hour" "day-of-month" "month" "day-of-week")
CRON_FIELD_MINIMUM=(0 0 1 1 0)
CRON_FIELD_MAXIMUM=(59 23 31 12 7)
CRON_DAYS_PER_MONTH=(31 29 31 30 31 30 31 31 30 31 30 31)
# cron drops crontab lines beyond 1000 bytes, and every list entry costs two
# forks to validate, so keep both bounded well below that
CRON_MAX_SCHEDULE_LENGTH=200
CRON_MAX_FIELD_ENTRIES=64

function trim_whitespace() {
  local VALUE="${1}"

  VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
  VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"

  printf '%s' "${VALUE}"
}

function reject_cron_schedule() {
  local -r VAR_NAME="${1}"
  local -r SCHEDULE="${2}"
  local -r REASON="${3}"

  echo "ERROR: ${VAR_NAME}='${SCHEDULE}' is not a valid cron schedule: ${REASON}."
  echo "       Expected five fields - minute (0-59) hour (0-23) day-of-month (1-31) month (1-12) day-of-week (0-7),"
  echo "       for example ${VAR_NAME}='0 4 * * *'."
  exit 1
}

function cron_field_number() {
  local -r FIELD_INDEX="${1}"
  local ITEM="${2}"
  local NAMES NAME
  local -i NUMBER

  if [[ "${ITEM}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$((10#${ITEM}))"
    return 0
  fi

  case "${FIELD_INDEX}" in
    3) NAMES="jan feb mar apr may jun jul aug sep oct nov dec"; NUMBER=1 ;;
    4) NAMES="sun mon tue wed thu fri sat"; NUMBER=0 ;;
    *) return 1 ;;
  esac

  # ${ITEM,,} would be shorter, but the test suite also runs on the bash 3.2
  # that macOS ships, where that expansion does not exist
  ITEM="$(printf '%s' "${ITEM}" | tr '[:upper:]' '[:lower:]')"

  for NAME in ${NAMES}; do
    if [[ "${NAME}" == "${ITEM}" ]]; then
      printf '%s' "${NUMBER}"
      return 0
    fi
    NUMBER=$((NUMBER + 1))
  done

  return 1
}

function assert_valid_cron_field() {
  local -r VAR_NAME="${1}"
  local -r SCHEDULE="${2}"
  local -r FIELD_INDEX="${3}"
  local -r FIELD="${4}"
  local -r FIELD_NAME="${CRON_FIELD_NAMES[FIELD_INDEX]}"
  local -ri MINIMUM="${CRON_FIELD_MINIMUM[FIELD_INDEX]}"
  local -ri MAXIMUM="${CRON_FIELD_MAXIMUM[FIELD_INDEX]}"
  local -a ITEMS=()
  local ITEM RANGE STEP LOW HIGH LOW_NUMBER HIGH_NUMBER

  if [[ "${FIELD}" == *,,* ]] || [[ "${FIELD}" == ,* ]] || [[ "${FIELD}" == *, ]]; then
    reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} field '${FIELD}' has an empty list entry"
  fi

  IFS=',' read -ra ITEMS <<< "${FIELD}"
  if [[ ${#ITEMS[@]} -gt ${CRON_MAX_FIELD_ENTRIES} ]]; then
    reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} field lists ${#ITEMS[@]} entries, more than the ${CRON_MAX_FIELD_ENTRIES} this image allows"
  fi

  for ITEM in "${ITEMS[@]}"; do
    RANGE="${ITEM}"

    # bash arithmetic wraps at 64 bits, so a long enough number would come out
    # as a value that passes the range check below
    if [[ "${ITEM}" =~ [0-9]{5} ]]; then
      reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} entry '${ITEM}' contains a number with more than four digits"
    fi

    if [[ "${ITEM}" == */* ]]; then
      RANGE="${ITEM%%/*}"
      STEP="${ITEM#*/}"
      if [[ ! "${STEP}" =~ ^[0-9]+$ ]] || (( 10#${STEP} < 1 )); then
        reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} entry '${ITEM}' needs a step of at least 1 behind the slash"
      fi
      # cron only steps over '*' or a range, '5/10' is rejected by crontab
      if [[ "${RANGE}" != "*" ]] && [[ "${RANGE}" != *-* ]]; then
        reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} entry '${ITEM}' can only step over '*' or a range, like '*/15' or '0-30/5'"
      fi
    fi

    [[ "${RANGE}" != "*" ]] || continue

    LOW="${RANGE%%-*}"
    HIGH="${RANGE#*-}"
    if ! LOW_NUMBER="$(cron_field_number "${FIELD_INDEX}" "${LOW}")" ||
      ! HIGH_NUMBER="$(cron_field_number "${FIELD_INDEX}" "${HIGH}")"; then
      reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} entry '${ITEM}' is neither a number, a name nor a range"
    fi

    if (( LOW_NUMBER < MINIMUM || HIGH_NUMBER > MAXIMUM )); then
      reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} entry '${ITEM}' is out of range, this field accepts ${MINIMUM}-${MAXIMUM}"
    fi

    if (( LOW_NUMBER > HIGH_NUMBER )); then
      reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "the ${FIELD_NAME} range '${ITEM}' counts backwards"
    fi
  done
}

function assert_possible_cron_date() {
  local -r VAR_NAME="${1}"
  local -r SCHEDULE="${2}"
  local -r DAY_FIELD="${3}"
  local -r MONTH_FIELD="${4}"
  local DAY MONTH

  [[ "${DAY_FIELD}" =~ ^[0-9]+$ ]] || return 0
  [[ "${MONTH_FIELD}" =~ ^[0-9A-Za-z]+$ ]] || return 0
  DAY="$(cron_field_number 2 "${DAY_FIELD}")" || return 0
  MONTH="$(cron_field_number 3 "${MONTH_FIELD}")" || return 0

  if (( DAY > CRON_DAYS_PER_MONTH[MONTH - 1] )); then
    reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "month ${MONTH} never has ${DAY} days, so this job would never run"
  fi
}

function assert_valid_cron_schedule() {
  local -r VAR_NAME="${1}"
  local -r SCHEDULE="$(trim_whitespace "${2}")"
  local -a FIELDS=()
  local -i FIELD_INDEX

  [[ -n "${SCHEDULE}" ]] || return 0

  if [[ "${SCHEDULE}" == *$'\n'* ]] || [[ "${SCHEDULE}" == *$'\r'* ]]; then
    reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "it has to stay on a single line"
  fi

  if [[ ${#SCHEDULE} -gt ${CRON_MAX_SCHEDULE_LENGTH} ]]; then
    reject_cron_schedule "${VAR_NAME}" "${SCHEDULE:0:60}..." "it is ${#SCHEDULE} characters long, more than the ${CRON_MAX_SCHEDULE_LENGTH} this image allows"
  fi

  if [[ "${SCHEDULE}" == @* ]]; then
    case "${SCHEDULE}" in
      @yearly|@annually|@monthly|@weekly|@daily|@midnight|@hourly) return 0 ;;
      *) reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" \
        "the supported shorthands are @yearly, @annually, @monthly, @weekly, @daily, @midnight and @hourly (@reboot is not, use UPDATE_ON_START for that)" ;;
    esac
  fi

  read -ra FIELDS <<< "${SCHEDULE}"
  if [[ ${#FIELDS[@]} -ne 5 ]]; then
    reject_cron_schedule "${VAR_NAME}" "${SCHEDULE}" "it has ${#FIELDS[@]} fields instead of 5"
  fi

  # the schedule ends up in a file that cron executes through a shell, so this
  # parser is a whitelist: everything it does not understand is rejected
  for (( FIELD_INDEX = 0; FIELD_INDEX < 5; FIELD_INDEX++ )); do
    assert_valid_cron_field "${VAR_NAME}" "${SCHEDULE}" "${FIELD_INDEX}" "${FIELDS[FIELD_INDEX]}"
  done

  assert_possible_cron_date "${VAR_NAME}" "${SCHEDULE}" "${FIELDS[2]}" "${FIELDS[3]}"
}

# this file only defines things; running it does nothing useful and would hide
# a wrong source path in the caller
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: ${0} is a library, source it instead of running it"
  exit 1
fi
