#!/usr/bin/env python3
"""Prepare a checksum-pinned SQLite provider for an authorized CI comparison."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

SOURCES = {
    '3.50.4': ('3500400', 'a3db587a1b92ee5ddac2f66b3edb41b26f9c867275782d46c3a088977d6a5b18'),
    '3.49.2': ('3490200', '5c6d8697e8a32a1512a9be5ad2b2e7a891241c334f56f8b0fb4fc6051e1652e8'),
}


def main():
    version = os.environ.get('CI_SQLITE_PROFILE', 'brew')
    if version == 'brew':
        return
    if version not in SOURCES:
        raise ValueError('unsupported CI SQLite profile: ' + version)
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise ValueError('comparison provider is restricted to the disposable hosted CI runner')
    root = Path(os.environ['RUNNER_TEMP']).resolve()
    prefix = root / 'journal-ci-sqlite'
    if prefix.exists():
        raise ValueError('comparison provider path already exists; refusing to replace it')
    source_id, expected = SOURCES[version]
    with tempfile.TemporaryDirectory(prefix='journal-sqlite-source-', dir=root) as directory:
        directory = Path(directory)
        archive = directory / 'source.tar.gz'
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', 'https://sqlite.org/2025/sqlite-autoconf-' + source_id + '.tar.gz', '-o', archive], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            raise ValueError('SQLite source checksum mismatch')
        subprocess.run(['tar', '-xf', archive, '-C', directory], check=True)
        source = directory / ('sqlite-autoconf-' + source_id)
        lib, include = prefix / 'lib', prefix / 'include'
        (lib / 'pkgconfig').mkdir(parents=True)
        include.mkdir()
        flags = ['-O2', '-fPIC', '-DSQLITE_THREADSAFE=1', '-DSQLITE_ENABLE_COLUMN_METADATA', '-DSQLITE_ENABLE_FTS5', '-DSQLITE_ENABLE_RTREE']
        obj = directory / 'sqlite3.o'
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', *flags, '-c', source / 'sqlite3.c', '-o', obj], check=True)
        dylib = lib / 'libsqlite3.0.dylib'
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-dynamiclib', obj, '-o', dylib, '-install_name', dylib, '-compatibility_version', '9.0.0', '-current_version', '3.0.0'], check=True)
        (lib / 'libsqlite3.dylib').symlink_to(dylib.name)
        subprocess.run(['ar', 'rcs', lib / 'libsqlite3.a', obj], check=True)
        for name in ('sqlite3.h', 'sqlite3ext.h'):
            (include / name).write_bytes((source / name).read_bytes())
        (lib / 'pkgconfig/sqlite3.pc').write_text(f'prefix={prefix}\nlibdir=${{prefix}}/lib\nincludedir=${{prefix}}/include\nName: SQLite\nDescription: Checksum-pinned CI compatibility provider\nVersion: {version}\nLibs: -L${{libdir}} -lsqlite3\nCflags: -I${{includedir}}\n')
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        print('PKG_CONFIG_PATH=' + str(lib / 'pkgconfig') + ':' + os.environ.get('PKG_CONFIG_PATH', ''), file=output)
    if version == '3.49.2':
        # A real but irrelevant PATH change must not alter the toolchain key.
        empty = root / 'journal-empty-path'
        empty.mkdir()
        with open(os.environ['GITHUB_PATH'], 'a') as output:
            print(empty, file=output)
    print('SQLite comparison provider ready: version=' + version + ', source_sha256=' + expected)


if __name__ == '__main__':
    main()
