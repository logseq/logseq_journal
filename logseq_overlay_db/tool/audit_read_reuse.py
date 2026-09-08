#!/usr/bin/env python3
"""Measure and assert call-local read reuse through public Database APIs.

Builds an instrumented copy using existing Dune declarations. No installed
library or repository build declaration is modified. Use --baseline to retain
all failing performance gates instead of rejecting the baseline run.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from audit_journal_pagination import INSTRUMENTATION

ROOT = Path(__file__).resolve().parents[2]


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--database-source', type=Path, help='Replay a saved baseline implementation')
    parser.add_argument('--plain', action='store_true', help='Disable instrumentation for timing samples')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = output / 'source'
    for name in ('logseq_db_types', 'logseq_db_storage', 'logseq_overlay_db',
                 'logseq_db_worker/test/fixtures/storage'):
        shutil.copytree(ROOT / name, source / name, dirs_exist_ok=True)
    shutil.copy2(ROOT / 'dune-project', source / 'dune-project')
    if args.database_source:
        shutil.copy2(args.database_source, source / 'logseq_overlay_db/lib/database.ml')
    identities = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for base in ('logseq_overlay_db/lib', 'logseq_overlay_db/tool', 'logseq_db_storage/lib')
                  for p in (ROOT / base).rglob('*') if p.is_file() and '__pycache__' not in str(p)}
    identities['logseq_overlay_db/lib/database.ml'] = hashlib.sha256((source / 'logseq_overlay_db/lib/database.ml').read_bytes()).hexdigest()
    (output / 'inputs.json').write_text(json.dumps(identities, indent=2) + '\n')
    instrumentation = INSTRUMENTATION + '''
let logical_counts () = Hashtbl.fold (fun key value acc ->
 if String.starts_with ~prefix:"physical" key then acc else (key,value)::acc) metrics [] |> List.sort compare
let get key = Option.value (Hashtbl.find_opt metrics key) ~default:(0,0)
type tracked = Tracked : 'a Weak.t -> tracked
let contexts = ref []
let track value = let weak = Weak.create 1 in Weak.set weak 0 (Some value); contexts := Tracked weak :: !contexts
let assert_released () =
 Gc.full_major ();
 if List.exists (fun (Tracked weak) -> Weak.check weak 0) !contexts then failwith "read context escaped API invocation";
 contexts := []
'''
    if args.plain:
        instrumentation = '''include Datascript
let add _ _ _ = ()
let reset () = ()
let json () = `Assoc []
let logical_counts () = []
let get _ = 0,0
let assert_released () = ()
'''
    storage = source / 'logseq_db_storage/lib'
    (storage / 'audit_datascript.ml').write_text(instrumentation)
    if not args.plain:
        for p in (source / 'logseq_overlay_db/lib').rglob('*.ml'):
            if 'Datascript' in p.read_text():
                p.write_text('module Datascript = Logseq_db_storage.Audit_datascript\n' + p.read_text())
        p = source / 'logseq_overlay_db/lib/database.ml'
        s = p.read_text()
        for marker, key, argument in [
            ('let logical_block_at ?cache ?initial (snapshot : snapshot) uuid =', 'logical_block:', 'Graph.Uuid.to_string uuid'),
            ('let logical_page_at ?cache ?initial (snapshot : snapshot) uuid =', 'logical_page:', 'Graph.Uuid.to_string uuid'),
            ('let property_definition_for_entity database property_class ident property_entity =', 'definition:', 'ident'),
        ]:
            if s.count(marker) != 1:
                raise RuntimeError('Instrumentation boundary changed: ' + marker)
            s = s.replace(marker, marker + '\n  Logseq_db_storage.Audit_datascript.add ("' + key + '" ^ ' + argument + ') 1 0;')
        for name, declaration, arguments in [
            ('hydration_cache', 'let hydration_cache ?(index_idents = true) database =', '?index_idents database'),
            ('read_context', 'let read_context snapshot =', 'snapshot'),
            ('structural_fields_reader', 'let structural_fields_reader database =', 'database'),
        ]:
            if declaration not in s:
                if name in ('read_context', 'structural_fields_reader') and args.baseline:
                    continue
                raise RuntimeError('Lifetime boundary changed: ' + name)
            start = s.index(declaration)
            end = s.index('\n;;', start) + len('\n;;')
            s = s[:end] + ('\nlet ' + name + ' ' + arguments + ' =\n'
                '  let value = allocate_' + name + ' ' + arguments + ' in\n'
                '  Logseq_db_storage.Audit_datascript.track value; value\n;;\n') + s[end:]
            s = s.replace(declaration, declaration.replace('let ' + name, 'let allocate_' + name), 1)
        p.write_text(s)
        p = storage / 'logseq_sqlite_storage.ml'
        s = p.read_text()
        marker = 'let restore_sqlite address ='
        assert s.count(marker) == 1
        p.write_text(s.replace(marker, marker + '\n          Audit_datascript.add "physical_sqlite_restore" 1 0;'))
    target = 'logseq_overlay_db/tool/performance_benchmark.exe'
    with (output / 'build.log').open('w') as log:
        run(['dune', 'build', '--root', str(source), '--profile', 'release', target], stdout=log, stderr=log)
    rules = run(['dune', 'rules', '--root', str(source), '--profile', 'release', target], capture_output=True).stdout
    command = shlex.split(rules[rules.rfind('(run\n'):].replace('(', ' ').replace(')', ' '))[1:]
    libraries = [str(source / '_build/default' / x) if not x.startswith('/') else x
                 for x in command if x.endswith('.cmxa')]
    libraries.sort(key=lambda x: 0 if x.endswith('/datascript_types.cmxa') else 1)
    includes = {str(Path(x).parent) for x in libraries}
    includes.update(str(p) for p in (source / '_build/default').glob('**/.*.objs/byte'))
    compiler = [command[0], '-thread', '-O3', '-w', '-58']
    for path in sorted(includes):
        compiler += ['-I', path]
    probe = output / 'read_reuse_probe.ml'
    shutil.copy2(ROOT / 'logseq_overlay_db/tool/read_reuse_probe.ml', probe)
    run(compiler + libraries + [str(probe), '-o', str(output / 'probe')])
    fixture = tempfile.mkdtemp(prefix='fixture-', dir=output)
    with (output / 'measurements.jsonl').open('w') as log, (output / 'process.txt').open('w') as err:
        result = subprocess.run(['/usr/bin/time', '-l', str(output / 'probe'), fixture,
                                 'plain' if args.plain else ('baseline' if args.baseline else 'check')],
                                cwd=source, stdout=log, stderr=err)
    print(output / 'measurements.jsonl')
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
