#!/usr/bin/env python3
"""Probe public Page_tree reads on isolated copies, without changing Dune files."""
import argparse
import pathlib
import shlex
import shutil
import sys

sys.dont_write_bytecode = True

from audit_journal_pagination import INSTRUMENTATION, ROOT, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--mirror-support', type=pathlib.Path)
    parser.add_argument('--graph-id')
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--release', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    source = output / 'source'
    source.mkdir(parents=True, exist_ok=True)
    for name in ('logseq_db_types', 'logseq_db_storage', 'logseq_overlay_db'):
        shutil.copytree(ROOT / name, source / name, dirs_exist_ok=True)
    shutil.copy2(ROOT / 'dune-project', source / 'dune-project')
    fixtures = 'logseq_db_worker/test/fixtures/storage'
    shutil.copytree(ROOT / fixtures, source / fixtures, dirs_exist_ok=True)
    storage = source / 'logseq_db_storage/lib'
    instrumentation = INSTRUMENTATION + '''
let q ?inputs db query = add "query" 1 0; Datascript.q ?inputs db query
'''
    if args.release:
        instrumentation = '''
let reset () = ()
let json () : Yojson.Safe.t = `Assoc []
let metrics : (string, int * int) Hashtbl.t = Hashtbl.create 0
'''
    (storage / 'audit_datascript.ml').write_text(instrumentation)
    if not args.release:
        for name in ('database.ml', 'authoritative_store.ml'):
            path = source / 'logseq_overlay_db/lib' / name
            path.write_text('module Datascript = Logseq_db_storage.Audit_datascript\n' + path.read_text())
        path = source / 'logseq_overlay_db/lib/database.ml'
        content = path.read_text()
        for signature, counter in [
            ('let logical_block_at ?cache ?initial (snapshot : snapshot) uuid =', 'logical_block_hydration'),
            ('let logical_block_revision uuid value =', 'block_revision'),
            ('let block_record_of_datoms_with_cache database cache datoms =', 'authoritative_block_hydration'),
            ('let page_record_of_entity_with_class ?cache database property_class entity =', 'page_hydration'),
        ]:
            if signature not in content:
                raise RuntimeError('instrumentation anchor changed: ' + signature)
            content = content.replace(signature, signature + '\n  Logseq_db_storage.Audit_datascript.add "' + counter + '" 1 0;')
        path.write_text(content)
        path = storage / 'logseq_sqlite_storage.ml'
        content = path.read_text()
        anchor = 'let restore_sqlite address ='
        if anchor not in content:
            raise RuntimeError('SQLite instrumentation anchor changed')
        path.write_text(content.replace(anchor, anchor + '\n          Audit_datascript.add "sqlite_restore" 1 0;'))
    target = '_build/default/logseq_overlay_db/tool/performance_benchmark.exe'
    options = ['--root', str(source), '--profile', 'release']
    with (output / 'build.log').open('w') as log:
        run(['dune', 'build'] + options + [target], stdout=log, stderr=log)
    rules = run(['dune', 'rules'] + options + [target], capture_output=True).stdout
    command = shlex.split(rules[rules.rfind('(run\n'):].replace('(', ' ').replace(')', ' '))[1:]
    libraries = [str(source / '_build/default' / x) if not x.startswith('/') else x
                 for x in command if x.endswith('.cmxa')]
    includes = {str(pathlib.Path(x).parent) for x in libraries}
    includes.update(str(p) for pattern in ('**/.*.objs/byte', '**/.*.objs/native')
                    for p in (source / '_build/default').glob(pattern))
    compiler = [command[0], '-thread', '-O3']
    for path in sorted(includes):
        compiler += ['-I', path]
    probe = output / 'page_tree_probe.ml'
    shutil.copy2(ROOT / 'logseq_overlay_db/tool/page_tree_probe.ml', probe)
    run(compiler + libraries + [str(probe), '-o', str(output / 'probe')])
    mode = 'release' if args.release else ('baseline' if args.baseline else 'verify')
    if args.mirror_support:
        if not args.graph_id:
            parser.error('--mirror-support requires --graph-id')
        mirror = output / 'mirror-support'
        shutil.copytree(args.mirror_support, mirror, dirs_exist_ok=True)
        options = [mode, 'mirror', str(mirror), args.graph_id]
    else:
        fixtures = output / 'fixtures'
        fixtures.mkdir(exist_ok=True)
        options = [mode, 'synthetic', str(fixtures)]
    with (output / 'measurements.jsonl').open('w') as log:
        run([str(output / 'probe')] + options, cwd=source, stdout=log)
    print(output / 'measurements.jsonl')


if __name__ == '__main__':
    main()
