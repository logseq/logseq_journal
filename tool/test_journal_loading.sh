#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
xcrun swiftc -swift-version 6 \
  -module-cache-path "$output/module-cache" \
  "$root/swift/JournalLoadingModel.swift" \
  "$root/apple-tests/loading/JournalLoadingTests.swift" \
  -o "$output/journal-loading-tests"
"$output/journal-loading-tests"
