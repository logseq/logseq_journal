#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
flutter_root="$repository_root/flutter"
generator="$repository_root/_build/default/logseq_db_worker/tool/generate_fixtures.exe"
container_tmp=${TMPDIR:-/tmp}

cd "$repository_root"
opam exec -- dune build logseq_db_worker/tool/generate_fixtures.exe

valid=$(mktemp -d "$container_tmp/logseq-encrypted-warm-valid.XXXXXX")
missing_wrapped_key=$(mktemp -d "$container_tmp/logseq-encrypted-warm-missing.XXXXXX")

cleanup() {
  /bin/rm -rf -- "$valid" "$missing_wrapped_key"
}
trap cleanup EXIT HUP INT TERM

valid_json=$("$generator" encrypted-offline-warm-start --support-root "$valid")
missing_wrapped_key_json=$(
  "$generator" encrypted-offline-warm-start --support-root "$missing_wrapped_key"
)
fixtures_json=$(printf '{"valid":%s,"missingWrappedKey":%s}' \
  "$valid_json" \
  "$missing_wrapped_key_json")

cd "$flutter_root"
LOGSEQ_JOURNAL_ENCRYPTED_WARM_FIXTURES_JSON="$fixtures_json" \
LOGSEQ_JOURNAL_E2EE_TEST_PRIVATE_KEY_STORAGE=memory \
LOGSEQ_JOURNAL_E2EE_TEST_WRAPPED_KEY_STORAGE=memory \
  opam exec -- bonsai-flutter exec --profile=debug -- \
  flutter test --no-pub -d macos \
  integration_test/encrypted_offline_warm_start_test.dart "$@"
