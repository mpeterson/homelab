#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/xseed.sh"

curl() {
  printf "WEBHOOK_CALLED\n" >&2
  printf '%s' "${MOCK_HTTP_CODE}"
}

sleep() {
  printf "SLEEP_CALLED\n" >&2
}

export -f curl sleep

check() {
  local status=$1 http_code=$2 expected_exit=$3 expected_webhook=$4 expected_sleep=$5
  shift 5
  local output actual_exit=0
  output=$(SAB_PP_STATUS="$status" MOCK_HTTP_CODE="$http_code" bash "$SCRIPT" "$@" 2>&1) || actual_exit=$?

  [[ "$actual_exit" == "$expected_exit" ]]
  if [[ "$expected_webhook" == yes ]]; then
    [[ "$output" == *WEBHOOK_CALLED* ]]
  else
    [[ "$output" != *WEBHOOK_CALLED* ]]
    [[ "$output" == *"Skipping cross-seed"* ]]
  fi
  if [[ "$expected_sleep" == yes ]]; then
    [[ "$output" == *SLEEP_CALLED* ]]
  else
    [[ "$output" != *SLEEP_CALLED* ]]
  fi
}

for status in -1 1 2 3 invalid; do
  check "$status" 204 0 no no "/downloads/job"
done

check 0 204 0 yes yes "/downloads/job"
check 0 500 1 yes no "/downloads/job"
check "" 204 0 no no "/downloads/job"
check "" 204 0 yes yes "/downloads/job" original clean report category group 0
check "" 204 0 no no "/downloads/job" original clean report category group 1
check 1 204 0 no no "/downloads/job" original clean report category group 0
check 0 204 0 yes yes "/downloads/job" original clean report category group 1

printf "All cross-seed post-processing checks passed.\n"
