#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 swift/JournalTimelineFilterPreferences.swift \
  test/timeline_filter_preferences_test.swift -o "$work/preferences"
"$work/preferences"

bash test/test_timeline_filter_contract.sh
dune exec ./test/timeline_filter_preferences_codec_test.exe
