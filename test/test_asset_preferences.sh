#!/bin/sh
set -eu
root="$1"
binary="${TMPDIR:-/tmp}/logseq-journal-asset-preferences-test-$$"
trap 'rm -f "$binary"' EXIT HUP INT TERM
swiftc -swift-version 6 "$root/swift/JournalAssetPreferences.swift" \
  "$root/test/asset_preferences_test.swift" -o "$binary"
"$binary"
