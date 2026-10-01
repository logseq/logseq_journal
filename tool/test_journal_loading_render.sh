#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$output/module-cache" \
  "$root/swift/JournalLoadingModel.swift" \
  "$root/swift/JournalLoadingView.swift" \
  "$root/apple-tests/loading/JournalLoadingRenderTests.swift" \
  -o "$output/render-test"
"$output/render-test"
