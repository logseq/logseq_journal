#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
benchmark="$repository_root/_build/default/logseq_db_worker/tool/performance_benchmark.exe"
test_executable="$repository_root/_build/default/logseq_db_worker/test/test_performance.exe"
work_root=$(mktemp -d "${TMPDIR:-/tmp}/logseq-db-worker-performance.XXXXXX")
result="$work_root/result.json"

cleanup() {
  /bin/rm -rf -- "$work_root"
}
trap cleanup EXIT HUP INT TERM

cd "$repository_root"
opam exec -- dune build --profile release \
  logseq_db_worker/tool/performance_benchmark.exe \
  logseq_db_worker/test/test_performance.exe

generated=$($benchmark generate --support-root "$work_root/support")
graph_dir=$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("graphDir")' <<EOF
$generated
EOF
)
graph_id=$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("graphId")' <<EOF
$generated
EOF
)
fixture_hash=$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("fixtureContentSha256")' <<EOF
$generated
EOF
)

$benchmark measure \
  --graph-id "$graph_id" \
  --graph-dir "$graph_dir" \
  --fixture-hash "$fixture_hash" \
  --build-profile release \
  --output "$result"

LOGSEQ_DB_WORKER_PERFORMANCE_RESULT="$result" "$test_executable"
/bin/cat "$result"
