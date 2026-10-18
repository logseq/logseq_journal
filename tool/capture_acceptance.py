#!/usr/bin/env python3
"""Fail-closed Simulator acceptance capture. See docs/acceptance-capture.md.

The runtime observer is Simulator-only and explicitly enabled by its owner.
Absent, unready or unauthenticated observers block capture; no identity file or
caller-supplied actual UUID can substitute for the live process.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import socket
import stat
import subprocess
import struct
import zlib
import uuid

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_KEYS = {'udid', 'device_type', 'bundle_id', 'version', 'build', 'source_sha', 'graph_id'}
OBSERVED_KEYS = {'schema_version', 'challenge', 'udid', 'bundle_id', 'executable_sha256',
                 'source_sha', 'graph_id', 'graph_generation', 'presentation_generation',
                 'phase', 'foreground', 'pid', 'process_instance'}
SOURCE_DIRS = {'app', 'swift', 'apple', 'assets', 'config', 'tool'}
BUILDER = '.agents/skills/journal-build/scripts'


class Rejected(Exception):
    """A fixed public reason, never a command's output or an untrusted value."""
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise Rejected(code)


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def fullmatch(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def valid_uuid(value):
    return fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', value)


def command(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, check=True, timeout=30).stdout.strip()
    except subprocess.TimeoutExpired:
        raise Rejected('command-timeout') from None
    except (subprocess.CalledProcessError, OSError, UnicodeError):
        raise Rejected('command-failed') from None


def safe_name(name):
    return (isinstance(name, str) and bool(name) and not PurePosixPath(name).is_absolute()
            and '..' not in PurePosixPath(name).parts and '\\' not in name
            and str(PurePosixPath(name)) == name)


def tree_files(directory):
    """Same source scope as journal-build, rejecting symbolic links outright."""
    ignored = {'.git', '.build', '_build', 'node_modules', '__pycache__'}
    result = {}
    require(not directory.is_symlink(), 'build-evidence-mismatch')
    for parent, dirs, names in os.walk(directory):
        dirs[:] = sorted(d for d in dirs if d not in ignored and not d.startswith('.ci-'))
        for name in dirs + names:
            if (Path(parent) / name).is_symlink():
                raise ValueError('symlink')
        for name in names:
            path = Path(parent) / name
            if path.is_file() and not name.endswith('.pyc'):
                result[path.relative_to(directory).as_posix()] = sha(path)
    return result


def source_files(directory):
    result = {}
    for path in directory.iterdir():
        if path.name in SOURCE_DIRS or path.name.startswith('logseq_'):
            if path.is_dir():
                result.update({path.name + '/' + n: h for n, h in tree_files(path).items()})
            elif path.is_file():
                result[path.name] = sha(path)
        elif path.name in {'dune', 'dune-project', 'dune-workspace'} and path.is_file():
            result[path.name] = sha(path)
    result.update({BUILDER + '/' + n: h for n, h in tree_files(directory / BUILDER).items()})
    return result


class Simulator:
    def device(self, expected):
        try:
            devices = json.loads(command(['xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
            matches = [(runtime, d) for runtime, rows in devices.items() for d in rows
                       if d.get('udid') == expected['udid']]
            require(len(matches) == 1, 'device-mismatch')
            runtime, device = matches[0]
            require(runtime.startswith('com.apple.CoreSimulator.SimRuntime.iOS-')
                    and device['deviceTypeIdentifier'] == expected['device_type']
                    and device['state'] == 'Booted' and device['isAvailable'] is True, 'device-mismatch')
            return {'udid': device['udid'], 'device_type': device['deviceTypeIdentifier'], 'runtime': runtime}
        except (KeyError, ValueError, TypeError):
            raise Rejected('device-mismatch') from None

    def container(self, expected):
        value = command(['xcrun', 'simctl', 'get_app_container', expected['udid'], expected['bundle_id'], 'app'])
        path = Path(value)
        require(path.is_absolute() and path.suffix == '.app' and path.is_dir()
                and not path.is_symlink() and path == path.resolve(), 'installed-artifact-mismatch')
        # Reject a container from another device or data-container namespace.
        require('/Devices/' + expected['udid'] + '/data/Containers/Bundle/Application/' in str(path),
                'installed-artifact-mismatch')
        return path

    def observe(self, identity, challenge):
        executable = self.container(identity) / 'JournalApp'
        path = Path('/tmp') / ('lj-identity-' + str(os.geteuid()) + '-' + identity['udid'].lower()) / 'identity.sock'
        return query_identity_socket(path, executable, challenge)

    def screenshot(self, udid, path):
        command(['xcrun', 'simctl', 'io', udid, 'screenshot', str(path)])


def query_identity_socket(path, executable, challenge, *, timeout=2):
    """Authenticate the kernel peer before reading any identity claim."""
    try:
        parent = path.parent.lstat()
        endpoint = path.lstat()
        require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.geteuid()
                and stat.S_IMODE(parent.st_mode) == 0o700
                and stat.S_ISSOCK(endpoint.st_mode) and endpoint.st_uid == os.geteuid()
                and stat.S_IMODE(endpoint.st_mode) == 0o600, 'runtime-peer-mismatch')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.settimeout(timeout)
            peer.connect(str(path))
            pid = struct.unpack('i', peer.getsockopt(0, 2, 4))[0]  # Darwin SOL_LOCAL/LOCAL_PEERPID
            uid, gid = ctypes.c_uint(), ctypes.c_uint()
            libc = ctypes.CDLL(None)
            libc.getpeereid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
            libc.getpeereid.restype = ctypes.c_int
            require(pid > 0 and libc.getpeereid(peer.fileno(), ctypes.byref(uid), ctypes.byref(gid)) == 0
                    and uid.value == os.geteuid(), 'runtime-peer-mismatch')
            libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
            libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            libproc.proc_pidpath.restype = ctypes.c_int
            image = ctypes.create_string_buffer(4096)
            require(libproc.proc_pidpath(pid, image, len(image)) > 0
                    and Path(os.fsdecode(image.value)).resolve() == executable.resolve(), 'runtime-peer-mismatch')
            executable_hash = sha(executable)
            peer.sendall(json.dumps({'schema_version': 1, 'challenge': challenge}).encode() + b'\n')
            data = b''
            while len(data) <= 4096 and not data.endswith(b'\n'):
                block = peer.recv(min(4097 - len(data), 1024))
                if not block:
                    break
                data += block
            require(len(data) <= 4096 and data.endswith(b'\n'), 'runtime-identity-mismatch')
            value = json.loads(data)
            if value == {'status': 'unavailable'}:
                raise Rejected('runtime-identity-unavailable')
            require(isinstance(value, dict) and set(value) == OBSERVED_KEYS
                    and value['pid'] == pid and value['challenge'] == challenge
                    and value['executable_sha256'] == executable_hash, 'runtime-identity-mismatch')
            # Confirm that the authenticated process is still the same image.
            again = ctypes.create_string_buffer(4096)
            require(libproc.proc_pidpath(pid, again, len(again)) > 0 and again.value == image.value
                    and sha(executable) == executable_hash, 'runtime-peer-mismatch')
            return value
    except (FileNotFoundError, ConnectionRefusedError, TimeoutError, PermissionError):
        raise Rejected('runtime-identity-unavailable') from None
    except (OSError, ValueError, TypeError, UnicodeError):
        raise Rejected('runtime-identity-mismatch') from None


def validate_expected(expected):
    require(isinstance(expected, dict) and set(expected) == EXPECTED_KEYS, 'invalid-expectation')
    require(valid_uuid(expected['udid']) and valid_uuid(expected['graph_id'])
            and fullmatch(r'com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9-]+', expected['device_type'])
            and fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', expected['bundle_id'])
            and all(fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', expected[k]) for k in ('version', 'build'))
            and fullmatch(r'[0-9a-f]{40}', expected['source_sha']), 'invalid-expectation')


def build_evidence(manifest_path, source_root, expected):
    code = 'build-evidence-mismatch'
    try:
        manifest_bytes = manifest_path.read_bytes()
        m = json.loads(manifest_bytes)
        require(m['status'] == 'built' and m['mode'] == 'experimental-host-restamp'
                and m['cross_abi_validated'] is False and m['source_status'] == ''
                and m['source_sha'] == expected['source_sha'] and m['sdk_name'] == 'iphonesimulator'
                and fullmatch(r'arm64-apple-ios[0-9]+\.[0-9]+-simulator', m['target'])
                and m['inputs']['target'] == m['target'], code)
        require(m['cache_key'] == fingerprint(m['inputs']), code)
        require(command(['git', '-C', str(source_root), 'rev-parse', '--show-toplevel']) == str(source_root)
                and command(['git', '-C', str(source_root), 'rev-parse', 'HEAD']) == expected['source_sha']
                and command(['git', '-C', str(source_root), 'status', '--porcelain', '--untracked-files=all']) == '', code)
        actual_source = source_files(source_root)
        require('app/application.ml' in actual_source and BUILDER + '/journal_build.py' in actual_source
                and actual_source == m['inputs']['source'], code)
        require(tree_files(source_root / 'swift') == m['inputs']['swift']
                and sha(source_root / 'apple/Info.plist') == m['inputs']['plist']
                and tree_files(source_root / 'config/entitlements') == m['inputs']['entitlements'], code)
        artifact = m['artifact']
        app = Path(artifact['app'])
        require(app.is_absolute() and app.is_dir() and app == app.resolve(), code)
        files = artifact['files']
        require(files and all(safe_name(n) and fullmatch(r'[0-9a-f]{64}', h) for n, h in files.items())
                and tree_files(app) == files, code)
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        require(info == artifact['info'] and info['CFBundleExecutable'] == 'JournalApp'
                and info['CFBundleIdentifier'] == expected['bundle_id']
                and info['CFBundleShortVersionString'] == expected['version']
                and info['CFBundleVersion'] == expected['build']
                and info['JournalSourceRevision'] == expected['source_sha']
                and info['JournalBuildInputDigest'] == m['cache_key']
                and info['JournalBuildMode'] == m['mode']
                and info['JournalCrossABIValidated'] is False
                and info['JournalOCamlRuntimeOrigin'] == 'host-arm64-restamp'
                and artifact['executable_sha256'] == files['JournalApp'], code)
        native_evidence(m)
        return {'files': files, 'executable_sha256': files['JournalApp'],
                'manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(), 'cache_key': m['cache_key'],
                'mode': m['mode']}
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        raise Rejected(code) from None


def native_evidence(m):
    """Recheck retained producer records and final link bytes, never execute argv."""
    code = 'build-evidence-mismatch'
    deps = m['inputs']['dependencies']
    envelope = deps['producer']
    require(deps['schema_version'] == envelope['schema_version']
            and envelope['schema_version'] in (1, 2), code)
    retained = deps['files']
    require(retained and all(Path(p).is_absolute() and fullmatch(r'[0-9a-f]{64}', h)
                            and sha(Path(p)) == h for p, h in retained.items()), code)
    def record(name):
        entry = envelope[name]
        candidates = [Path(p) for p, h in retained.items()
                      if Path(p).name == Path(entry['path']).name and h == entry['sha256']]
        require(len(candidates) == 1, code)
        return json.loads(candidates[0].read_bytes())
    producer = record('source')
    link = record('link')
    require(m['native_source_sha'] == deps['source_sha'] == producer['commit'], code)
    require(fullmatch(r'[0-9a-f]{40}', producer['commit']), code)
    native_sources = dict(producer['native_source_sha256'])
    for name, digest in link['device_c_source_sha256'].items():
        native_sources['logseq_sync/lib/effect_runner/platform/' + name] = digest
    required = {name: h for name, h in m['inputs']['source'].items()
                if Path(name).suffix in {'.ml', '.mli', '.c', '.h'}
                and not {'tool', 'test', 'apple-tests'}.intersection(Path(name).parts)}
    require(required == native_sources
            and producer['production_native_object_sha256'] == link['production_host_sha256']
            and retained[producer['production_native_object']] == link['production_host_sha256'], code)
    native = m['native_object']
    final = m['production_link']
    require(native['mode'] == m['mode'] and Path(native['path']).is_absolute()
            and sha(Path(native['path'])) == native['sha256']
            and final['cross_abi_validated'] is False
            and sha(Path(final['link_map'])) == final['link_map_sha256']
            and sha(Path(final['target_c']['path'])) == final['target_c']['sha256']
            and final['swift_objects']
            and all(sha(Path(p)) == h for p, h in final['swift_objects'].items()), code)


def installed_artifact(backend, expected, build):
    path = backend.container(expected)
    try:
        require(tree_files(path) == build['files'], 'installed-artifact-mismatch')
    except (OSError, ValueError):
        raise Rejected('installed-artifact-mismatch') from None
    require(command(['xcrun', 'lipo', '-archs', str(path / 'JournalApp')]) == 'arm64'
            and re.search(r'platform\s+IOSSIMULATOR\b',
                          command(['xcrun', 'vtool', '-show-build', str(path / 'JournalApp')])),
            'installed-artifact-mismatch')
    return path


def observation(backend, identity):
    challenge = str(uuid.uuid4())
    value = backend.observe(identity, challenge)
    code = 'runtime-identity-mismatch'
    require(isinstance(value, dict) and set(value) == OBSERVED_KEYS, code)
    require(value['schema_version'] == 1 and value['challenge'] == challenge
            and all(value[k] == identity[k] for k in ('udid', 'bundle_id', 'executable_sha256', 'source_sha', 'graph_id'))
            and value['phase'] == 'open' and value['foreground'] is True
            and type(value['pid']) is int and value['pid'] > 0
            and valid_uuid(value['process_instance'])
            and type(value['graph_generation']) is int and value['graph_generation'] >= 0
            and type(value['presentation_generation']) is int
            and value['presentation_generation'] == value['graph_generation'], code)
    return {k: v for k, v in value.items() if k != 'challenge'}


def valid_png(path):
    """Reject partial/empty captures with PNG chunk framing and CRC checks."""
    if not path.is_file() or path.is_symlink() or not 32 < path.stat().st_size <= 64 * 1024 * 1024:
        return False
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        return False
    offset, image_data = 8, False
    while offset + 12 <= len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            return False
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:end - 4]
        if zlib.crc32(kind + payload) != struct.unpack('>I', data[end - 4:end])[0]:
            return False
        if offset == 8 and (kind != b'IHDR' or length != 13
                            or min(struct.unpack('>II', payload[:8])) == 0):
            return False
        image_data |= kind == b'IDAT' and length > 0
        if kind == b'IEND':
            return length == 0 and end == len(data) and image_data
        offset = end
    return False


def capture(manifest_path, source_root, expected, output, *, backend=None):
    """Capture only after system/build checks and a live observation on both sides.

    backend is a test seam, not a command-line provider or accepted evidence file.
    No production implementation currently overrides Simulator.observe.
    """
    validate_expected(expected)
    output = Path(output).resolve()
    source_root = Path(source_root).resolve()
    require(output != ROOT and ROOT not in output.parents and output != source_root
            and source_root not in output.parents and not output.exists(), 'unsafe-output')
    build = build_evidence(Path(manifest_path), source_root, expected)
    backend = backend or Simulator()
    device = backend.device(expected)
    container = installed_artifact(backend, expected, build)
    identity = {**expected, 'executable_sha256': build['executable_sha256']}
    before = observation(backend, identity)
    created = False
    try:
        output.mkdir(parents=True, exist_ok=False, mode=0o700)
        created = True
        screenshot = output / 'screenshot.png'
        backend.screenshot(expected['udid'], screenshot)
        require(valid_png(screenshot), 'screenshot-failed')
        after = observation(backend, identity)
        require(after == before, 'runtime-identity-mismatch')
        require(backend.device(expected) == device, 'device-mismatch')
        require(installed_artifact(backend, expected, build) == container, 'installed-artifact-mismatch')
        # Recheck retained bytes/source at the end so a changing build cannot be accepted.
        require(build_evidence(Path(manifest_path), source_root, expected) == build, 'build-evidence-mismatch')
        record = {'schema_version': 1, 'status': 'accepted', 'platform': 'ios-simulator',
                  'captured_at': datetime.now(timezone.utc).isoformat(), 'expected': dict(expected),
                  'observed': before, 'device': device, 'build_mode': build['mode'],
                  'cross_abi_validated': False, 'real_device_acceptance': False,
                  'manifest_sha256': build['manifest_sha256'], 'build_input_digest': build['cache_key'],
                  'screenshot_sha256': sha(screenshot)}
        (output / 'acceptance.json').write_text(json.dumps(record, indent=2) + '\n')
        return record
    except BaseException:
        if created:
            shutil.rmtree(output)
        raise


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default includes unrecognized argv values in stderr.
        raise Rejected('invalid-arguments')


def main(argv=None):
    parser = SafeParser(description=__doc__)
    for name in ('manifest', 'source-root', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    for name in sorted(EXPECTED_KEYS):
        parser.add_argument('--' + name.replace('_', '-'), required=True)
    try:
        args = parser.parse_args(argv)
        capture(args.manifest, args.source_root, {k: getattr(args, k) for k in EXPECTED_KEYS}, args.output)
        print(json.dumps({'status': 'accepted'}))
        return 0
    except Rejected as error:
        print(json.dumps({'status': 'blocked', 'reason': error.code}))
        return 1
    except Exception:
        # Never echo malformed manifests, command stderr, local paths or secrets.
        print(json.dumps({'status': 'blocked', 'reason': 'capture-failed'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
