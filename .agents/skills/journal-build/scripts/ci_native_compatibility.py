"""Read-only compiler/native link probes for restored CI switches."""
from pathlib import Path
import re
import subprocess
import tempfile

from journal_build import sha


def capture(argv, cwd=None):
    result = subprocess.run([str(a) for a in argv], cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout or str(argv[0]))[-6000:])
    return result.stdout.strip()


def require_native_symbols(library, symbols):
    """Ask dyld to resolve every required symbol, including shared-cache libraries."""
    source = r'''
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
  void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 2; }
  int missing = 0;
  for (int i = 2; i < argc; i++) {
    dlerror(); (void)dlsym(handle, argv[i]);
    const char *error = dlerror();
    if (error) { fprintf(stderr, "missing required symbol %s: %s\n", argv[i], error); missing = 1; }
  }
  dlclose(handle); return missing;
}
'''
    with tempfile.TemporaryDirectory(prefix='journal-symbols-') as directory:
        root = Path(directory)
        (root / 'probe.c').write_text(source)
        capture(['xcrun', '--sdk', 'macosx', 'clang', root / 'probe.c', '-o', root / 'probe'])
        capture([root / 'probe', library, *sorted(set(symbols))])


SQLITE_PROGRAM = r'''
let require expected actual =
  if expected <> actual then failwith (Sqlite3.Rc.to_string actual)
let () =
  let version = Sqlite3.sqlite_version_info () in
  if not (String.starts_with ~prefix:"3." version) then failwith "SQLite version is outside the SQLite 3 API family";
  let file = Filename.temp_file "journal-ci-sqlite" ".db" in
  let db = Sqlite3.db_open ~mutex:`FULL file in
  let exec sql = require Sqlite3.Rc.OK (Sqlite3.exec db sql) in
  exec "PRAGMA foreign_keys=ON";
  let wal = ref false in
  require Sqlite3.Rc.OK (Sqlite3.exec db ~cb:(fun row _ -> wal := row.(0) = Some "wal") "PRAGMA journal_mode=WAL");
  if not !wal then failwith "SQLite WAL unavailable";
  exec "CREATE TABLE parent(id INTEGER PRIMARY KEY, payload BLOB NOT NULL)";
  exec "CREATE TABLE child(parent_id INTEGER REFERENCES parent(id))";
  exec "BEGIN IMMEDIATE";
  let insert = Sqlite3.prepare db "INSERT INTO parent VALUES (?, ?)" in
  require Sqlite3.Rc.OK (Sqlite3.bind_values insert [Sqlite3.Data.INT 42L; Sqlite3.Data.BLOB "\000fixture"]);
  require Sqlite3.Rc.DONE (Sqlite3.step insert);
  require Sqlite3.Rc.OK (Sqlite3.finalize insert);
  let query = Sqlite3.prepare db "SELECT id, payload FROM parent" in
  require Sqlite3.Rc.ROW (Sqlite3.step query);
  if Sqlite3.column_int query 0 <> 42 || Sqlite3.column_blob query 1 <> "\000fixture" then failwith "SQLite binding data mismatch";
  require Sqlite3.Rc.OK (Sqlite3.finalize query);
  exec "COMMIT";
  require Sqlite3.Rc.CONSTRAINT (Sqlite3.exec db "INSERT INTO child VALUES (99)");
  if not (Sqlite3.db_close db) then failwith "SQLite close failed";
  List.iter (fun name -> if Sys.file_exists name then Sys.remove name) [file; file ^ "-wal"; file ^ "-shm"];
  print_endline version
'''


def binding_probe(prefix, package, program):
    prefix = Path(prefix)
    with tempfile.TemporaryDirectory(prefix='journal-binding-') as directory:
        root = Path(directory)
        source = root / 'probe.ml'
        source.write_text(program)
        values = {}
        for mode, compiler, archive in [('native', 'ocamlopt.opt', 'cmxa'), ('bytecode', 'ocamlc.opt', 'cma')]:
            output = root / ('probe-' + mode)
            capture([prefix / 'bin' / compiler, '-I', prefix / 'lib' / package,
                     package + '.' + archive, source, '-o', output], cwd=root)
            argv = [output] if mode == 'native' else [prefix / 'bin/ocamlrun', '-I', prefix / 'lib/stublibs', output]
            values[mode + '_version'] = capture(argv, cwd=root)
            if mode == 'native':
                values['native_linkage'] = capture(['otool', '-L', output]).splitlines()[1:]
        return values


def probe_sqlite_binding(prefix, expected_version=None):
    stubs = Path(prefix) / 'lib/sqlite3/libsqlite3_stubs.a'
    before = sha(stubs)
    result = binding_probe(prefix, 'sqlite3', SQLITE_PROGRAM)
    if result['native_version'] != result['bytecode_version']:
        raise RuntimeError('native and bytecode SQLite runtime version differ')
    if expected_version is not None and result['native_version'] != expected_version:
        raise RuntimeError('SQLite runtime version differs from selected provider: ' + result['native_version'] + ' / ' + expected_version)
    if before != sha(stubs):
        raise RuntimeError('SQLite runtime probe changed the installed binding')
    return dict(status='compatible', stub_sha256=before, **result)


def probe_zarith_binding(prefix):
    program = '''
let () =
  let x = Z.of_string "123456789012345678901234567890123456789" in
  let square = Z.mul x x in
  if not (Z.equal (Z.sqrt square) x) || not (Z.equal (Z.divexact square x) x) then failwith "GMP arithmetic mismatch";
  print_endline "GMP arithmetic passed"
'''
    return dict(status='compatible', **binding_probe(prefix, 'zarith', program))


def probe_compiler(prefix):
    prefix = Path(prefix)
    with tempfile.TemporaryDirectory(prefix='journal-compiler-') as directory:
        root = Path(directory)
        source = root / 'probe.ml'
        source.write_text('let () = if Array.length [|21;21|] <> 2 then exit 1; print_int (21+21)\n')
        for mode, compiler in [('native', 'ocamlopt.opt'), ('bytecode', 'ocamlc.opt')]:
            output = root / ('probe-' + mode)
            capture([prefix / 'bin' / compiler, source, '-o', output], cwd=root)
            argv = [output] if mode == 'native' else [prefix / 'bin/ocamlrun', output]
            if capture(argv, cwd=root) != '42':
                raise RuntimeError('restored compiler/runtime smoke result differs')
    return dict(status='compatible', compiler_sha256=sha(prefix / 'bin/ocamlopt.opt'))


SYMBOL_GROUPS = {
    'sqlite3': re.compile(r'^sqlite3_'), 'gmp': re.compile(r'^__gmp'),
    'libzstd': re.compile(r'^ZSTD_'),
    'zlib': re.compile(r'^(?:zlibVersion|adler32|crc32|compress|uncompress|inflate|deflate|gz)'),
}
LIBRARY_GROUPS = {'sqlite3': 'sqlite3', 'gmp': 'gmp', 'zstd': 'libzstd', 'z': 'zlib'}


def native_link_checks(prefix, libraries):
    """Check actual installed C stubs, not just current pkg-config declarations."""
    prefix = Path(prefix)
    owners = {}
    for install in (prefix / '.opam-switch/install').glob('*.install'):
        for quoted in re.findall(r'"([^"\n]+)"', install.read_text()):
            owners.setdefault(Path(quoted).name, set()).add(install.stem)
    candidates = set((prefix / 'lib/stublibs').glob('*.so'))
    candidates.update(p for p in (prefix / 'lib').rglob('*.a') if '_stubs' in p.name or p.name == 'libzarith.a')
    checks, rebuild = [], set()
    for path in sorted(candidates):
        undefined = capture(['nm', '-u', path]).splitlines()
        groups = {name: sorted({line.strip()[1:] for line in undefined if pattern.match(line.strip()[1:])})
                  for name, pattern in SYMBOL_GROUPS.items()}
        groups = {name: symbols for name, symbols in groups.items() if symbols}
        if not groups:
            continue
        owner = owners.get(path.name, set())
        if not owner and path.parent.name in {'sqlite3', 'zarith'}:
            owner = {path.parent.name}
        linked = capture(['otool', '-L', path]).splitlines()[1:] if path.suffix == '.so' else []
        for name, symbols in groups.items():
            selected = [p for p in libraries[name]['files'] if p.endswith('.dylib')]
            if not selected:
                raise RuntimeError('no dynamic provider for native validation: ' + name)
            providers = {min(selected, key=len)}
            for line in linked:
                library = line.strip().split(' (', 1)[0]
                if any(re.fullmatch(r'lib' + re.escape(stem) + r'(?:\.[0-9]+)*\.dylib', Path(library).name)
                       for stem, group in LIBRARY_GROUPS.items() if group == name):
                    providers.add(library)
            try:
                for provider in sorted(providers):
                    require_native_symbols(provider, symbols)
                checks.append(dict(file=str(path.relative_to(prefix)), group=name, symbols=len(symbols),
                                   providers=sorted(providers), status='compatible'))
            except RuntimeError as error:
                if not owner:
                    raise RuntimeError('cannot identify native rebuild owner for ' + str(path.relative_to(prefix))) from error
                rebuild.update(owner)
                checks.append(dict(file=str(path.relative_to(prefix)), group=name, packages=sorted(owner),
                                   status='rebuild', reason=str(error)))
    return checks, sorted(rebuild)
