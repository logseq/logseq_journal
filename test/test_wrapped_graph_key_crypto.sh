#!/bin/sh
set -eu

root="$1"
binary="${TMPDIR:-/tmp}/logseq-journal-wrapped-key-test-$$"
trap 'rm -f "$binary"' EXIT HUP INT TERM

swiftc \
  -D DEBUG \
  "$root/flutter/JournalE2EECrypto.swift" \
  "$root/test/wrapped_graph_key_crypto_test.swift" \
  -o "$binary"
"$binary"
