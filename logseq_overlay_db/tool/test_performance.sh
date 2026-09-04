#!/bin/sh
set -eu

workspace_root=${1:-$(pwd)}
output_directory=$(mktemp -d)
output_file="$output_directory/combined.json"
trap 'rm -rf "$output_directory"' EXIT

cd "$workspace_root"
for outbox_records in 0 1 32 128 1024 4096; do
  dune exec --profile release logseq_overlay_db/tool/performance_benchmark.exe -- \
    --block-count 100000 \
    --outbox-records "$outbox_records" \
    >"$output_directory/$outbox_records.json"
done

jq -s \
  '{
    block_count: .[0].block_count,
    fixture_checksum: .[0].fixture_checksum,
    samples: map(.samples[0])
  }' \
  "$output_directory/0.json" \
  "$output_directory/1.json" \
  "$output_directory/32.json" \
  "$output_directory/128.json" \
  "$output_directory/1024.json" \
  "$output_directory/4096.json" \
  >"$output_file"

jq -e '
  ([.samples[] | select(.active_outbox_records == 0) | .rss_samples[]] | min) as $baseline_rss |
  .block_count == 100000 and
  ([.samples[].active_outbox_records] == [0, 1, 32, 128, 1024, 4096]) and
  all(.samples[];
    .status == "Measured" and
    (.wall_time_samples | length) >= 5 and
    (.allocation_samples | length) >= 5 and
    (.rss_samples | length) >= 5 and
    (.get_blocks_64 | length) >= 5 and
    (.get_structure_200 | length) >= 5 and
    (.get_journals_200 | length) >= 5 and
    (.reopen | length) >= 5 and
    all(.wall_time_samples[]; . > 0) and
    all(.allocation_samples[]; . > 0) and
    all(.rss_samples[]; . > 0)) and
  all(.samples[] | select(.active_outbox_records < 4096);
    all(.get_blocks_64[].wall_time_ms; . < 20) and
    all(.get_structure_200[].wall_time_ms; . < 20) and
    all(.get_journals_200[].wall_time_ms; . < 25)) and
  all(.samples[] | select(.active_outbox_records == 4096);
    all(.get_blocks_64[].wall_time_ms; . < 80) and
    all(.get_structure_200[].wall_time_ms; . < 80) and
    all(.get_journals_200[].wall_time_ms; . < 100)) and
  all(.samples[] | select(.active_outbox_records == 0);
    (.single_block_change_classification | length) >= 5 and
    all(.single_block_change_classification[].wall_time_ms; . < 10)) and
  all(.samples[] | select(.active_outbox_records == 128);
    (.replan_and_diff | length) >= 5 and
    all(.replan_and_diff[].wall_time_ms; . < 100)) and
  all(.samples[] | select(.active_outbox_records == 1024);
    all(.reopen[].wall_time_ms; . < 100)) and
  all(.samples[] | select(.active_outbox_records == 4096);
    (.replan_and_diff | length) >= 5 and
    (.delete_conflict | length) >= 5 and
    all(.replan_and_diff[].wall_time_ms; . < 3200) and
    all(.delete_conflict[].wall_time_ms; . < 3200) and
    all(.reopen[].wall_time_ms; . < 500)) and
  all(.samples[] | .get_blocks_64[], .get_structure_200[], .get_journals_200[];
    .allocation_bytes < 33554432) and
  all(.samples[];
    ([.rss_samples[]] | max)
      <= ($baseline_rss + (12 * .active_outbox_bytes) + 33554432))
' "$output_file" >/dev/null || {
  echo "performance benchmark failed its fixture, sample, latency, or allocation gates" >&2
  jq '.samples' "$output_file" >&2
  exit 1
}
