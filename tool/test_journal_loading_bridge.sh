#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
switch=logseq-journal-lui
ocaml_include=$(opam exec --switch="$switch" -- ocamlc -where)
cp "$root/apple-tests/loading/bridge_fixture.ml" "$output/bridge_fixture.ml"
opam exec --switch="$switch" -- ocamlopt -output-complete-obj \
  -o "$output/fixture.o" "$output/bridge_fixture.ml"
clang -I "$ocaml_include" -c "$root/app/journal_lui_bridge.c" \
  -o "$output/bridge.o"
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$output/module-cache" \
  "$root/apple-tests/loading/JournalLoadingBridgeTests.swift" \
  "$output/bridge.o" "$output/fixture.o" -o "$output/bridge-test"
"$output/bridge-test"
