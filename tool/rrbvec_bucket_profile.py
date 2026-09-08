#!/usr/bin/env python3
"""Measure bucket copies and replay visits in a disposable diagnostic worktree.

Timing comparisons must use the uninstrumented owner probe. This diagnostic build
forces minor collections around bucket appends to count allocation independently
of pending minor-arena accounting; it preserves public owner entry points.
"""
import argparse
from pathlib import Path
import subprocess

SOURCE = Path(__file__).resolve().parent.parent
PREFIX = '''let profile_copies = Hashtbl.create 3
let profile_visits = ref 0
let profile_words f =
  Gc.minor ();
  let before = Gc.quick_stat () in
  let result = f () in
  Gc.minor ();
  let after = Gc.quick_stat () in
  result, (after.minor_words -. before.minor_words)
    +. (after.major_words -. before.major_words)
    -. (after.promoted_words -. before.promoted_words)
;;
let profile_overhead = snd (profile_words (fun () -> ()))
let profile_append kind f =
  let result, words = profile_words f in
  let count, total = Hashtbl.find_opt profile_copies kind |> Option.value ~default:(0, 0.) in
  Hashtbl.replace profile_copies kind (count + 1, total +. words -. profile_overhead);
  result
;;
'''


def instrument(source):
    for start, end in [('let logical_page_at', 'let logical_block_at'),
                       ('let logical_block_at', 'let get_blocks')]:
        a, b = source.index(start), source.index(end)
        region = source[a:b]
        old = '(fun current (record : outbox_record) ->'
        assert region.count(old) == 1
        region = region.replace(old, old + '\n       incr profile_visits;', 1)
        source = source[:a] + region + source[b:]
    a, b = source.index('let replan_queued_ordinary'), source.index('let settle_stale_records')
    region = source[a:b]
    region = region.replace('records =\n', 'records =\n  Hashtbl.clear profile_copies;\n  profile_visits := 0;\n', 1)
    region = region.replace('let add_indexed_record ', 'let add_indexed_record ~kind ', 1)
    if '(preceding @ [ record ])' in region:
        region = region.replace('(preceding @ [ record ])', '(profile_append kind (fun () -> preceding @ [ record ]))')
        region = region.replace('add_indexed_record records block_effects', 'add_indexed_record ~kind:"block" records block_effects')
        region = region.replace('add_indexed_record [] page_effects', 'add_indexed_record ~kind:"page" [] page_effects')
        region = region.replace('add_indexed_record\n          []', 'add_indexed_record ~kind:"children"\n          []')
    else:
        region = region.replace('(append preceding record)', '(profile_append kind (fun () -> append preceding record))')
        for kind in ['block', 'page', 'children']:
            start = region.index(f'let {kind}_effects,')
            pos = region.index('add_indexed_record', start) + len('add_indexed_record')
            region = region[:pos] + f' ~kind:"{kind}"' + region[pos:]
    old = '  loop [] Uuid_map.empty Uuid_map.empty Uuid_map.empty [] [] [] [] records\n;;'
    assert old in region
    region = region.replace(old, '''  let result = loop [] Uuid_map.empty Uuid_map.empty Uuid_map.empty [] [] [] [] records in
  Printf.printf "BUCKET_PROFILE records=%d replay_visits=%d" (List.length records) !profile_visits;
  List.iter (fun kind ->
    let count, words = Hashtbl.find_opt profile_copies kind |> Option.value ~default:(0, 0.) in
    Printf.printf " %s_memberships=%d %s_words=%.0f" kind count kind words)
    ["block"; "page"; "children"];
  Printf.printf "\\n%!";
  result
;;''')
    return PREFIX + source[:a] + region + source[b:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worktree', type=Path, required=True)
    parser.add_argument('--size', type=int, default=128)
    args = parser.parse_args()
    root = args.worktree.resolve()
    if root == SOURCE:
        parser.error('use a disposable worktree, not the implementation worktree')
    path = root / 'logseq_overlay_db/lib/database.ml'
    before = path.read_text()
    try:
        path.write_text(instrument(before))
        subprocess.run(['python3', str(SOURCE / 'tool/rrbvec_owner_probe.py'),
                        '--worktree', str(root), '--owner', 'overlay',
                        '--size', str(args.size), '--shared'], cwd=SOURCE, check=True)
    finally:
        path.write_text(before)


if __name__ == '__main__':
    main()
