#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
flutter_root="$repository_root/flutter"
generator="$repository_root/_build/default/logseq_db_worker/tool/generate_fixtures.exe"
container_tmp="$HOME/Library/Containers/com.example.bonsaiFlutterLogseqJournalHost/Data/tmp"

if [ ! -x "$generator" ]; then
  printf '%s\n' "Build logseq_db_worker/tool/generate_fixtures.exe before this test." >&2
  exit 1
fi

normal_one=$(mktemp -d "$container_tmp/logseq-runtime-flow-normal-one.XXXXXX")
normal_two=$(mktemp -d "$container_tmp/logseq-runtime-flow-normal-two.XXXXXX")
failure_one=$(mktemp -d "$container_tmp/logseq-runtime-flow-failure.XXXXXX")

cleanup() {
  /bin/rm -rf -- "$normal_one" "$normal_two" "$failure_one"
}
trap cleanup EXIT HUP INT TERM

normal_one_json=$($generator runtime-flow --support-root "$normal_one")
normal_two_json=$($generator runtime-flow --support-root "$normal_two")
failure_one_json=$($generator runtime-flow-failure --support-root "$failure_one")
fixtures_json=$(printf '{"normal":[%s,%s],"persistenceFailure":[%s]}' \
  "$normal_one_json" \
  "$normal_two_json" \
  "$failure_one_json")

cd "$flutter_root"
LOGSEQ_DB_WORKER_RUNTIME_FIXTURES_JSON="$fixtures_json" \
  opam exec -- bonsai-flutter exec --profile=debug -- \
  flutter test --no-pub -d macos \
  integration_test/logseq_db_worker_runtime_flow_test.dart "$@"
