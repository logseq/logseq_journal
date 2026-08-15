#!/bin/sh

set -eu

usage() {
  printf '%s\n' \
    'Usage: test_ios_device.sh --device DEVICE_ID --inbox-bundle DIRECTORY' \
    '' \
    'Runs the externally provisioned signed physical-iPhone import, mutation,' \
    'orderly shutdown, cold relaunch, and persisted-response acceptance lane.'
}

fail() {
  printf '%s\n' "Logseq DB Worker iOS device failure: $1" >&2
  exit 1
}

require_environment() {
  variable_name=$1
  eval "variable_value=\${$variable_name:-}"
  test -n "$variable_value" || fail "required environment variable is unset: $variable_name"
}

device=
inbox_bundle=
while test "$#" -gt 0; do
  case "$1" in
    --device)
      test "$#" -ge 2 || fail '--device requires a value'
      device=$2
      shift 2
      ;;
    --inbox-bundle)
      test "$#" -ge 2 || fail '--inbox-bundle requires a value'
      inbox_bundle=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

test -n "$device" || fail '--device is required'
test -n "$inbox_bundle" || fail '--inbox-bundle is required'
test -d "$inbox_bundle" || fail "inbox bundle is not a directory: $inbox_bundle"
test -f "$inbox_bundle/db.sqlite" || fail 'inbox bundle does not contain db.sqlite'

inbox_entry=$(basename -- "$inbox_bundle")
case "$inbox_entry" in
  ''|.|..|*/*|*\\*) fail 'inbox bundle basename is not one confined path component' ;;
esac

require_environment IOS_DEVELOPMENT_TEAM
require_environment IOS_BUNDLE_IDENTIFIER
require_environment IOS_DEVELOPMENT_PROFILE_PATH

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/../.." && pwd)
flutter_root="$repository_root/flutter"
bonsai_flutter_root="$repository_root/../bonsai_flutter"
preflight=${LOGSEQ_IOS_DEVICE_PREFLIGHT:-$bonsai_flutter_root/tool/ci/ios_device_preflight.sh}
test -x "$preflight" || fail "physical-device preflight is unavailable: $preflight"

for command in codesign flutter jq plutil security xcrun; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done

work_root="$repository_root/_build/ios/logseq-db-worker-device"
mkdir -p "$work_root"
work_directory=$(mktemp -d "$work_root/run.XXXXXX")
profile_plist="$work_directory/development-profile.plist"
signing_xcconfig="$work_directory/development-signing.xcconfig"
first_log="$work_directory/first-launch.log"
second_log="$work_directory/second-launch.log"
cleanup() {
  rm -rf "$work_directory"
}
trap cleanup EXIT HUP INT TERM

"$preflight" "$device"

security cms -D -i "$IOS_DEVELOPMENT_PROFILE_PATH" >"$profile_plist" ||
  fail 'development provisioning profile cannot be decoded'
profile_team=$(plutil -extract TeamIdentifier.0 raw -o - "$profile_plist")
test "$profile_team" = "$IOS_DEVELOPMENT_TEAM" ||
  fail 'development provisioning profile has the wrong Team ID'
profile_application_identifier=$(
  plutil -extract Entitlements.application-identifier raw -o - "$profile_plist"
)
case "$profile_application_identifier" in
  *."$IOS_BUNDLE_IDENTIFIER"|*.\*) ;;
  *) fail 'development provisioning profile does not cover the bundle identifier' ;;
esac
plutil -p "$profile_plist" | grep -F -- "$device" >/dev/null ||
  fail 'development provisioning profile does not contain the selected device'
profile_debuggable=$(plutil -extract Entitlements.get-task-allow raw -o - "$profile_plist")
test "$profile_debuggable" = true || fail 'development provisioning profile is not debuggable'
profile_uuid=$(plutil -extract UUID raw -o - "$profile_plist")
signing_identity=${IOS_DEVELOPMENT_SIGNING_IDENTITY:-Apple Development}
security find-identity -v -p codesigning | grep -F -- "$signing_identity" >/dev/null ||
  fail 'development signing identity is unavailable'

{
  printf '%s\n' "DEVELOPMENT_TEAM = $IOS_DEVELOPMENT_TEAM"
  printf '%s\n' 'CODE_SIGN_STYLE = Manual'
  printf '%s\n' "CODE_SIGN_IDENTITY = $signing_identity"
  printf '%s\n' "PROVISIONING_PROFILE_SPECIFIER = $profile_uuid"
  printf '%s\n' "PRODUCT_BUNDLE_IDENTIFIER = $IOS_BUNDLE_IDENTIFIER"
} >"$signing_xcconfig"

(
  cd "$flutter_root"
  XCODE_XCCONFIG_FILE="$signing_xcconfig" flutter build ios --profile --no-pub
)
application_bundle="$flutter_root/build/ios/iphoneos/Runner.app"
test -d "$application_bundle" || fail 'signed iPhoneOS application was not produced'
codesign --verify --deep --strict "$application_bundle" ||
  fail 'signed iPhoneOS application failed code-sign verification'

xcrun devicectl device uninstall app \
  --device "$device" \
  "$IOS_BUNDLE_IDENTIFIER" >/dev/null 2>&1 || true
xcrun devicectl device install app \
  --device "$device" \
  "$application_bundle" >/dev/null
xcrun devicectl device copy to \
  --device "$device" \
  --source "$inbox_bundle" \
  --destination "Library/Application Support/logseq-db-worker/inbox/$inbox_entry" \
  --domain-type appDataContainer \
  --domain-identifier "$IOS_BUNDLE_IDENTIFIER" >/dev/null

test_target=integration_test/logseq_db_worker_ios_device_test.dart
marker="logseq-ios-device-$(date +%s)-$$"
run_phase() {
  phase=$1
  log=$2
  (
    cd "$flutter_root"
    XCODE_XCCONFIG_FILE="$signing_xcconfig" flutter test \
      "$test_target" \
      --device-id "$device" \
      --no-pub \
      --dart-define="LOGSEQ_IOS_DEVICE_PHASE=$phase" \
      --dart-define="LOGSEQ_IOS_DEVICE_INBOX_ENTRY=$inbox_entry" \
      --dart-define="LOGSEQ_IOS_DEVICE_MARKER=$marker"
  ) >"$log" 2>&1 || {
    sed -n '1,320p' "$log" >&2
    fail "$phase physical-device phase failed"
  }
}

run_phase first "$first_log"
for expected in \
  LOGSEQ_IOS_DEVICE_IMPORT_RESPONSE \
  LOGSEQ_IOS_DEVICE_MUTATION_RESPONSE \
  LOGSEQ_IOS_DEVICE_ORDERLY_SHUTDOWN; do
  grep -F -- "$expected" "$first_log" >/dev/null || {
    sed -n '1,320p' "$first_log" >&2
    fail "first launch omitted protocol marker: $expected"
  }
done

run_phase second "$second_log"
for expected in \
  LOGSEQ_IOS_DEVICE_COLD_RELAUNCH_RESPONSE \
  LOGSEQ_IOS_DEVICE_PERSISTED_MARKER; do
  grep -F -- "$expected" "$second_log" >/dev/null || {
    sed -n '1,320p' "$second_log" >&2
    fail "cold relaunch omitted protocol marker: $expected"
  }
done

printf '%s\n' "Logseq DB Worker signed physical-iPhone persistence lane passed: $device"

