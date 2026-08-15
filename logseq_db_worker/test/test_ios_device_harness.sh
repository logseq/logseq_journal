#!/bin/sh

set -eu

harness=$1

fail() {
  printf '%s\n' "iOS device harness contract failure: $1" >&2
  exit 1
}

test -x "$harness" || fail "harness is not executable"
sh -n "$harness" || fail "harness has invalid shell syntax"

help=$($harness --help)
printf '%s\n' "$help" | grep -F -- '--device DEVICE_ID' >/dev/null ||
  fail "help omits the physical device argument"
printf '%s\n' "$help" | grep -F -- '--inbox-bundle DIRECTORY' >/dev/null ||
  fail "help omits the inbox bundle argument"

failure_log=$(mktemp)
trap 'rm -f "$failure_log"' EXIT HUP INT TERM
if "$harness" --device physical-device --inbox-bundle /missing/bundle >"$failure_log" 2>&1; then
  fail "harness accepted a missing inbox bundle"
fi
grep -F -- 'inbox bundle is not a directory' "$failure_log" >/dev/null ||
  fail "missing inbox bundle returned an imprecise error"

for marker in \
  LOGSEQ_IOS_DEVICE_IMPORT_RESPONSE \
  LOGSEQ_IOS_DEVICE_MUTATION_RESPONSE \
  LOGSEQ_IOS_DEVICE_ORDERLY_SHUTDOWN \
  LOGSEQ_IOS_DEVICE_COLD_RELAUNCH_RESPONSE \
  LOGSEQ_IOS_DEVICE_PERSISTED_MARKER; do
  grep -F -- "$marker" "$harness" >/dev/null ||
    fail "harness does not assert $marker"
done

grep -F -- 'appDataContainer' "$harness" >/dev/null ||
  fail "harness does not confine the inbox transfer to the app data container"
grep -F -- 'logseq_db_worker_ios_device_test.dart' "$harness" >/dev/null ||
  fail "harness does not run the dedicated physical-device test"

