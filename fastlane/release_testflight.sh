#!/bin/bash
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage: fastlane/release_testflight.sh

Build, verify and publish the current main branch to TestFlight using the
existing Fastlane lanes. Required environment variables:

  MAIN_WORKTREE             clean checkout of the intended main revision
  DEVICE_RECEIPT            verified device build receipt manifest
  LUI_PACKAGE               prepared LUI Apple package matching the receipt
  RELEASE_DIR               unused directory for this release's outputs
  RELEASE_CACHE             reusable, exclusively owned archive cache
  RELEASE_STATE             durable TestFlight attempt state directory
  EXISTING_APPSTORE_PROFILE existing Journal App Store provisioning profile
  EXISTING_CERTIFICATE_SHA1 existing Apple Distribution certificate SHA1

Optional: VERSION (defaults to apple/Info.plist), WAIT_TIMEOUT (default 3600).
The App Store Connect API key must be supplied through the JOURNAL_ASC_* process
environment documented in docs/ios-release.md. Secrets are never lane arguments.
USAGE
}

fail() {
  printf 'release_testflight: %s\n' "$1" >&2
  exit 1
}

if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
  usage
  exit 0
fi

required=(MAIN_WORKTREE DEVICE_RECEIPT LUI_PACKAGE RELEASE_DIR RELEASE_CACHE RELEASE_STATE EXISTING_APPSTORE_PROFILE EXISTING_CERTIFICATE_SHA1)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || fail "missing required environment variable $name"
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

[[ -d "$MAIN_WORKTREE/.git" || -f "$MAIN_WORKTREE/.git" ]] || fail 'MAIN_WORKTREE is not a Git checkout'
[[ -f "$DEVICE_RECEIPT" ]] || fail 'DEVICE_RECEIPT does not exist'
[[ -d "$LUI_PACKAGE" ]] || fail 'LUI_PACKAGE does not exist'
[[ -f "$EXISTING_APPSTORE_PROFILE" ]] || fail 'EXISTING_APPSTORE_PROFILE does not exist'
[[ ! -e "$RELEASE_DIR" ]] || fail 'RELEASE_DIR already exists; use an unused release directory'
[[ "$EXISTING_CERTIFICATE_SHA1" =~ ^[0-9A-Fa-f]{40}$ ]] || fail 'EXISTING_CERTIFICATE_SHA1 must be a certificate SHA1'

WAIT_TIMEOUT=${WAIT_TIMEOUT:-3600}
[[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ && "$WAIT_TIMEOUT" -gt 0 ]] || fail 'WAIT_TIMEOUT must be positive seconds'

SOURCE_SHA=$(git -C "$MAIN_WORKTREE" rev-parse HEAD)
[[ -z "$(git -C "$MAIN_WORKTREE" status --porcelain)" ]] || fail 'MAIN_WORKTREE is not clean'
REMOTE_SHA=$(git -C "$MAIN_WORKTREE" ls-remote origin refs/heads/main | awk 'NR==1 {print $1}')
[[ -n "$REMOTE_SHA" ]] || fail 'could not resolve origin refs/heads/main'
[[ "$REMOTE_SHA" == "$SOURCE_SHA" ]] || fail "MAIN_WORKTREE is not current main ($REMOTE_SHA)"

if [[ -z "${VERSION:-}" ]]; then
  VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$MAIN_WORKTREE/apple/Info.plist")
fi
[[ -n "$VERSION" ]] || fail 'could not determine VERSION'

mkdir -p "$RELEASE_DIR"

run_step() {
  local name=$1
  shift
  printf '==> %s\n' "$name"
  set +e
  "$@" >"$RELEASE_DIR/$name.log" 2>&1
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    tail -80 "$RELEASE_DIR/$name.log" >&2 || true
    printf 'release_testflight: %s failed; full log: %s\n' "$name" "$RELEASE_DIR/$name.log" >&2
    exit "$status"
  fi
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

printf '==> build-number\n'
set +e
BUILD=$(bundle exec ruby fastlane/next_testflight_build_number.rb 2>"$RELEASE_DIR/build-number.log")
status=$?
set -e
if [[ $status -ne 0 ]]; then
  cat "$RELEASE_DIR/build-number.log" >&2 || true
  exit "$status"
fi
[[ "$BUILD" =~ ^[0-9]{12}$ ]] || fail "invalid generated build number: $BUILD"
printf '%s\n' "$BUILD" >"$RELEASE_DIR/build-number"
printf '%s\n' "$VERSION" >"$RELEASE_DIR/version"
printf '%s\n' "$SOURCE_SHA" >"$RELEASE_DIR/source-sha"
printf 'version=%s build=%s source=%s\n' "$VERSION" "$BUILD" "$SOURCE_SHA"

run_step prepare bundle exec fastlane ios prepare \
  "root:$MAIN_WORKTREE" "manifest:$DEVICE_RECEIPT" "lui:$LUI_PACKAGE" \
  "prepared:$RELEASE_DIR/prepared" "version:$VERSION" "build:$BUILD" experimental:true

run_step archive bundle exec fastlane ios archive \
  "prepared:$RELEASE_DIR/prepared" "archive:$RELEASE_DIR/Journal.xcarchive" "cache:$RELEASE_CACHE"

run_step export bundle exec fastlane ios export \
  "prepared:$RELEASE_DIR/prepared" "archive:$RELEASE_DIR/Journal.xcarchive" \
  "output:$RELEASE_DIR/export" "profile:$EXISTING_APPSTORE_PROFILE" \
  "identity:$EXISTING_CERTIFICATE_SHA1"

IPA="$RELEASE_DIR/export/Journal.ipa"
[[ -f "$IPA" ]] || fail 'export did not produce Journal.ipa'
unzip -tq "$IPA" >"$RELEASE_DIR/unzip.log"
IPA_SHA256=$(sha256 "$IPA")
EXPORTED_SHA256=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("ipa_sha256")' "$RELEASE_DIR/export/verification.json")
[[ "$IPA_SHA256" == "$EXPORTED_SHA256" ]] || fail 'IPA SHA256 differs from export verification'
printf '%s\n' "$IPA_SHA256" >"$RELEASE_DIR/ipa-sha256"
chmod a-w "$IPA"

printf '==> pre-publish freshness\n'
set +e
FRESH_BUILD=$(bundle exec ruby fastlane/next_testflight_build_number.rb 2>"$RELEASE_DIR/build-number-fresh.log")
status=$?
set -e
if [[ $status -ne 0 ]]; then
  cat "$RELEASE_DIR/build-number-fresh.log" >&2 || true
  exit "$status"
fi
printf '%s\n' "$FRESH_BUILD" >"$RELEASE_DIR/build-number-fresh"
[[ "$FRESH_BUILD" == "$BUILD" ]] || fail "TestFlight sequence advanced during build ($BUILD != $FRESH_BUILD)"
[[ "$(sha256 "$IPA")" == "$IPA_SHA256" ]] || fail 'IPA changed after verification'
REMOTE_SHA_NOW=$(git -C "$MAIN_WORKTREE" ls-remote origin refs/heads/main | awk 'NR==1 {print $1}')
[[ "$REMOTE_SHA_NOW" == "$SOURCE_SHA" ]] || fail 'origin/main advanced during build; refusing stale release'

run_step publish bundle exec fastlane ios publish \
  "ipa:$IPA" "version:$VERSION" "build:$BUILD" "sha256:$IPA_SHA256" \
  "source:$SOURCE_SHA" experimental:true "state:$RELEASE_STATE" "wait_timeout:$WAIT_TIMEOUT"

ruby -rjson -e '
  path = File.join(ARGV.fetch(0), "release-summary.json")
  report = {
    version: ARGV.fetch(1), build: ARGV.fetch(2), source_sha: ARGV.fetch(3),
    ipa_sha256: ARGV.fetch(4), status: "published_to_logseq_team"
  }
  File.write(path, JSON.pretty_generate(report) + "\n", perm: 0o600)
' "$RELEASE_DIR" "$VERSION" "$BUILD" "$SOURCE_SHA" "$IPA_SHA256"

printf 'published %s (%s); summary: %s\n' "$VERSION" "$BUILD" "$RELEASE_DIR/release-summary.json"
