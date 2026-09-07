#!/bin/sh
# Compile the existing module through its .mli without changing Dune visibility.
set -eu
cd "$(dirname "$0")/../.."
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/block-order-contract.XXXXXX")
trap 'rm -rf "$probe_directory"' EXIT HUP INT TERM
dune build logseq_db_types/lib/logseq_db_types.cma
ocamlc -I _build/default/logseq_db_types/lib/.logseq_db_types.objs/byte \
  -c -o "$probe_directory/outliner_order.cmi" logseq_overlay_db/lib/outliner_order.mli
ocamlc -I _build/default/logseq_db_types/lib/.logseq_db_types.objs/byte \
  -I "$probe_directory" -c -o "$probe_directory/outliner_order.cmo" logseq_overlay_db/lib/outliner_order.ml
ocamlc -I _build/default/logseq_db_types/lib/.logseq_db_types.objs/byte \
  -I "$probe_directory" -c -o "$probe_directory/block_order_contract.cmo" logseq_overlay_db/tool/block_order_contract.ml
ocamlc -o "$probe_directory/check" _build/default/logseq_db_types/lib/logseq_db_types.cma \
  "$probe_directory/outliner_order.cmo" "$probe_directory/block_order_contract.cmo"
"$probe_directory/check" logseq_overlay_db/test/fixtures/order/reference.tsv
