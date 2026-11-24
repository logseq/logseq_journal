#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dune build logseq_db_types/lib/logseq_db_types.cmxa @install
export OCAMLPATH="$PWD/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
compile=(ocamlfind ocamlopt -package logseq_db_types -I "$work")
"${compile[@]}" -c -o "$work/timeline_filter.cmi" app/spec/filter/timeline_filter.mli
"${compile[@]}" -c -o "$work/timeline_filter.cmx" app/timeline_filter.ml
"${compile[@]}" -c -o "$work/test.cmx" test/timeline_filter_contract_test.ml
"${compile[@]}" -linkpkg -o "$work/test" "$work/timeline_filter.cmx" "$work/test.cmx"
"$work/test"
