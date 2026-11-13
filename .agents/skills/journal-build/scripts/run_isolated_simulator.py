#!/usr/bin/env python3
"""Build current Journal inputs and launch only on a newly created Simulator."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from journal_build import source_inputs

ROOT = Path(__file__).resolve().parents[4]
BUILDER = Path(__file__).with_name('build_journal_apple.sh')


def jobs(value):
    number = int(value)
    if not 1 <= number <= 64:
        raise argparse.ArgumentTypeError('jobs must be between 1 and 64')
    return number


def verify_manifest_sources(manifest, current):
    if manifest.get('inputs', {}).get('source') != current:
        raise RuntimeError('build manifest does not match current worktree inputs')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence-dir', type=Path, required=True)
    parser.add_argument('--switch', required=True)
    parser.add_argument('--lui-package', type=Path, required=True)
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--device-type', required=True)
    parser.add_argument('--jobs', type=jobs, default=4)
    args = parser.parse_args()
    evidence = args.evidence_dir.expanduser().resolve()
    if evidence == ROOT or ROOT in evidence.parents:
        parser.error('--evidence-dir must be outside the repository')
    if not args.lui_package.is_dir():
        parser.error('--lui-package must be an existing directory')
    for executable in ('bash', 'python3', 'opam', 'xcrun', 'git', 'pkg-config'):
        if not shutil.which(executable):
            parser.error(f'missing dependency: {executable}')
    evidence.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='isolated-', dir=evidence))
    report = dict(status='running', commands=[], cross_abi_validated=False,
                  tooling_sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in (Path(__file__), BUILDER, BUILDER.with_name('journal_build.py'))})

    def save():
        (run / 'session.json').write_text(json.dumps(report, indent=2) + '\n')

    def command(label, *argv, cwd=ROOT):
        argv = list(map(str, argv))
        report['commands'].append(dict(label=label, argv=argv))
        save()
        result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True,
                                timeout=1800 if label in {'producer', 'simulator'} else 300)
        (run / (label + '.stdout')).write_text(result.stdout)
        (run / (label + '.stderr')).write_text(result.stderr)
        report['commands'][-1]['returncode'] = result.returncode
        save()
        if result.returncode:
            raise RuntimeError(f'{label} failed ({result.returncode}); see {run}')
        return result

    def build(label, *options):
        result = command(label, 'bash', BUILDER, *options,
                         '--lui-package', args.lui_package.resolve(),
                         '--cache-dir', evidence / 'build cache', '--jobs', args.jobs)
        matches = re.findall(r'^manifest: (.+)$', result.stderr, re.MULTILINE)
        if len(matches) != 1:
            raise RuntimeError(f'{label}: missing unique current manifest')
        path = Path(matches[0])
        manifest = json.loads(path.read_text())
        report[label] = dict(manifest=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        return manifest

    try:
        report['head'] = command('head', 'git', 'rev-parse', 'HEAD').stdout.strip()
        command('diff', 'git', 'diff', 'HEAD', '--binary')
        command('status', 'git', 'status', '--porcelain')
        devices = json.loads(command('devices-before', 'xcrun', 'simctl', 'list', '-j').stdout)
        if not any(item['identifier'] == args.runtime and item.get('isAvailable')
                   for item in devices['runtimes']):
            raise RuntimeError('requested runtime is not installed/available')
        if not any(item['identifier'] == args.device_type for item in devices['devicetypes']):
            raise RuntimeError('requested device type is not installed')
        producer = build('producer', 'macos', '--producer-only', '--switch', args.switch)
        if producer['status'] != 'native-produced' or producer['source_sha'] != report['head']:
            raise RuntimeError('producer did not accept current HEAD')
        native = producer['producer']['envelope']['path']
        target = build('simulator', 'ios-simulator', '--experimental-host-restamp', '--native-manifest', native)
        if target['status'] != 'built' or target['source_sha'] != report['head']:
            raise RuntimeError('Simulator did not accept current HEAD')
        app = Path(target['artifact']['app'])
        report['app'] = str(app)
        report['bundle_id'] = target['artifact']['info']['CFBundleIdentifier']
        for name, digest in target['artifact']['files'].items():
            if hashlib.sha256((app / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError(f'artifact changed after build: {name}')
        if command('head-after', 'git', 'rev-parse', 'HEAD').stdout.strip() != report['head']:
            raise RuntimeError('HEAD changed during build')
        if command('diff-after', 'git', 'diff', 'HEAD', '--binary').stdout != (run / 'diff.stdout').read_text():
            raise RuntimeError('local diff changed during build')
        current_sources = source_inputs()
        verify_manifest_sources(producer, current_sources)
        verify_manifest_sources(target, current_sources)
        report['verified_worktree_sources'] = current_sources
        udid = command('create', 'xcrun', 'simctl', 'create', 'Journal Isolated ' + run.name,
                       args.device_type, args.runtime).stdout.strip()
        report['simulator_udid'] = udid
        save()
        command('boot', 'xcrun', 'simctl', 'boot', udid)
        command('bootstatus', 'xcrun', 'simctl', 'bootstatus', udid, '-b')
        verify_manifest_sources(target, source_inputs())
        command('install', 'xcrun', 'simctl', 'install', udid, app)
        command('launch', 'xcrun', 'simctl', 'launch', udid, report['bundle_id'])
        command('container', 'xcrun', 'simctl', 'get_app_container', udid, report['bundle_id'], 'app')
        command('screenshot', 'xcrun', 'simctl', 'io', udid, 'screenshot', run / 'launch.png')
        report['status'] = 'launched'
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        report.update(status='failed', error=str(error))
        print(str(error), file=sys.stderr)
    finally:
        save()
        print(run / 'session.json')
    return 0 if report['status'] == 'launched' else 1


if __name__ == '__main__':
    sys.exit(main())
