#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 swift/JournalTimelineFilterPreferences.swift \
  test/timeline_filter_preferences_test.swift -o "$work/preferences"
"$work/preferences"

bash test/test_timeline_filter_contract.sh
export OCAMLPATH="$PWD/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
awk '/^module Timeline_filter(_preferences)? = struct$/ { inside=1 } inside { print } /^end$/ { inside=0 }' \
  app/application.ml > "$work/filter_modules.ml"
compile=(ocamlfind ocamlopt -package logseq_db_types,yojson,unix -I "$work")
"${compile[@]}" -c -o "$work/filter_modules.cmx" "$work/filter_modules.ml"
"${compile[@]}" -c -o "$work/test.cmx" test/timeline_filter_preferences_codec_test.ml
"${compile[@]}" -linkpkg -o "$work/codec" "$work/filter_modules.cmx" "$work/test.cmx"
"$work/codec"
