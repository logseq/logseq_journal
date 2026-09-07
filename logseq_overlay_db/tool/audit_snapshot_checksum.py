#!/usr/bin/env python3
"""Profile public snapshot activation on isolated source and fixture copies."""
import argparse
import hashlib
import json
import pathlib
import shlex
import shutil
import sys

sys.dont_write_bytecode = True
from audit_journal_pagination import ROOT, run

INSTRUMENTATION = r'''
include Datascript
let nodes = ref 0
let rows = ref 0
let phase = ref "setup"
let events : Yojson.Safe.t list ref = ref []
let reset () = nodes := 0; rows := 0; events := []
let measure name f =
  let n = !nodes and r = !rows in
  let allocated = Gc.allocated_bytes () in
  let started = Unix.gettimeofday () in
  Fun.protect ~finally:(fun () ->
    events := `Assoc ["operation", `String name; "phase", `String !phase;
      "ms", `Float ((Unix.gettimeofday () -. started) *. 1000.);
      "allocated_bytes", `Float (Gc.allocated_bytes () -. allocated);
      "sqlite_node_restores", `Int (!nodes - n);
      "returned_checksum_datoms", `Int (!rows - r)] :: !events) f
let datoms db index ?e ?a ?v ?tx () =
  Datascript.datoms db index ?e ?a ?v ?tx ()
  |> Seq.map (fun d -> incr rows; d)
let json () = `List (List.rev !events)
'''


def inject(path, anchor, replacement):
    content = path.read_text()
    if content.count(anchor) != 1:
        raise RuntimeError('Instrumentation anchor changed: ' + anchor)
    path.write_text(content.replace(anchor, replacement))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=pathlib.Path)
    p.add_argument('--baseline-source', type=pathlib.Path,
                   help='Directory containing captured unmodified checksum and Database sources')
    p.add_argument('--mirror-database', type=pathlib.Path)
    p.add_argument('--graph-id')
    args = p.parse_args()
    output = args.output.resolve()
    if output.exists():
        p.error('Use a fresh output directory')
    source = output / 'source'
    source.mkdir(parents=True)
    for name in ('logseq_db_types', 'logseq_db_storage', 'logseq_overlay_db'):
        shutil.copytree(ROOT / name, source / name)
    shutil.copy2(ROOT / 'dune-project', source / 'dune-project')
    fixtures = 'logseq_db_worker/test/fixtures/storage'
    shutil.copytree(ROOT / fixtures, source / fixtures)
    lib = source / 'logseq_overlay_db/lib'
    if args.baseline_source:
        for name in ('database.ml', 'authoritative_checksum.ml'):
            shutil.copy2(args.baseline_source / name, lib / name)
    environment = {'baseline': bool(args.baseline_source), 'source_sha256': {
        name: hashlib.sha256((lib / name).read_bytes()).hexdigest()
        for name in ('database.ml', 'authoritative_checksum.ml')},
        'compiler': run(['opam', 'exec', '--', 'ocamlopt', '-version'], capture_output=True).stdout.strip(),
        'profile': 'release with isolated measurement wrappers'}
    (output / 'environment.json').write_text(json.dumps(environment, indent=2) + '\n')
    storage = source / 'logseq_db_storage/lib'
    (storage / 'audit_datascript.ml').write_text(INSTRUMENTATION)
    inject(storage / 'logseq_sqlite_storage.ml', 'let restore_sqlite address =',
           'let restore_sqlite address =\n          incr Audit_datascript.nodes;')
    checksum = lib / 'authoritative_checksum.ml'
    checksum.write_text('module Datascript = Logseq_db_storage.Audit_datascript\n' + checksum.read_text())
    inject(checksum, 'let hex32 value =', '''let entities_with_uuid db =
  Datascript.measure "enumeration" (fun () -> entities_with_uuid db)
;;
let hex32 value =''')
    inject(checksum, 'let graph_e2ee db =', '''let recompute ~e2ee db =
  Datascript.measure "checksum" (fun () -> recompute ~e2ee db)
;;
let graph_e2ee db =''')
    mirror = lib / 'mirror.ml'
    inject(mirror, 'let inspect_database database_path graph_id =', '''let import_snapshot_rows ~snapshot_path ~expected_rows database_path =
  Logseq_db_storage.Audit_datascript.measure "import" (fun () ->
    import_snapshot_rows ~snapshot_path ~expected_rows database_path)
;;
let inspect_database database_path graph_id =''')
    # Wrap disk persistence separately from final checksum and plaintext application.
    content = mirror.read_text()
    anchor = next(line for line in content.splitlines() if line.startswith('let activate '))
    inject(mirror, anchor, '''let persist staged database metadata =
  Logseq_db_storage.Audit_datascript.measure "persist" (fun () -> persist staged database metadata)
;;
''' + anchor)
    target = '_build/default/logseq_overlay_db/tool/performance_benchmark.exe'
    options = ['--root', str(source), '--profile', 'release']
    with (output / 'build.log').open('w') as log:
        run(['opam', 'exec', '--', 'dune', 'build'] + options + [target], stdout=log, stderr=log)
    rules = run(['opam', 'exec', '--', 'dune', 'rules'] + options + [target], capture_output=True).stdout
    command = shlex.split(rules[rules.rfind('(run\n'):].replace('(', ' ').replace(')', ' '))[1:]
    libraries = [str(source / '_build/default' / x) if not x.startswith('/') else x
                 for x in command if x.endswith('.cmxa')]
    includes = {str(pathlib.Path(x).parent) for x in libraries}
    includes.update(str(p) for pattern in ('**/.*.objs/byte', '**/.*.objs/native')
                    for p in (source / '_build/default').glob(pattern))
    probe = output / 'snapshot_checksum_probe.ml'
    shutil.copy2(ROOT / 'logseq_overlay_db/tool/snapshot_checksum_probe.ml', probe)
    compiler = [command[0], '-thread', '-O3']
    for path in sorted(includes):
        compiler += ['-I', path]
    run(compiler + libraries + [str(probe), '-o', str(output / 'probe')])
    options = ['baseline' if args.baseline_source else 'verify', str(output)]
    if args.mirror_database:
        if not args.graph_id:
            p.error('--mirror-database requires --graph-id')
        # SQLite backup preserves a consistent read-only source, including any WAL.
        import sqlite3
        with sqlite3.connect(f'file:{args.mirror_database.resolve()}?mode=ro', uri=True) as src:
            with sqlite3.connect(output / 'mirror.sqlite') as dst:
                src.backup(dst)
        options += [str(output / 'mirror.sqlite'), args.graph_id]
    with (output / 'measurements.jsonl').open('w') as log:
        run([str(output / 'probe')] + options, cwd=source, stdout=log)
    print(output / 'measurements.jsonl')


if __name__ == '__main__':
    main()
