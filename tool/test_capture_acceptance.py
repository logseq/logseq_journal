#!/usr/bin/env python3
"""Synthetic filesystem/command-boundary coverage; never operates Apple devices."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tool/capture_acceptance.py'
UDID = '11111111-1111-4111-8111-111111111111'
GRAPH = '22222222-2222-4222-8222-222222222222'
OTHER_GRAPH = '22222222-2222-4222-8222-222222222223'
DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
SECRET = 'private-token-and-graph-body-never-print'


def digest(data):
    return hashlib.sha256(data).hexdigest()


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(TOOL.is_file(), 'Missing acceptance tool: strict identity behavior is absent')
        spec = importlib.util.spec_from_file_location('capture_acceptance', TOOL)
        self.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.api)
        self.temp = tempfile.TemporaryDirectory(prefix='journal-acceptance-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.source = self.base / 'source'
        self.source.mkdir()
        self.source_files = {'app/application.ml': b'(* synthetic source *)\n',
                             '.agents/skills/journal-build/scripts/journal_build.py': b'# synthetic builder\n'}
        for name, data in self.source_files.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        for argv in (['init', '-q'], ['config', 'user.name', 'Synthetic Test'],
                     ['config', 'user.email', 'test@example.invalid'], ['add', '.'],
                     ['commit', '-qm', 'synthetic']):
            subprocess.run(['git', *argv], cwd=self.source, check=True, capture_output=True)
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.source, text=True).strip()
        self.expected = dict(udid=UDID, device_type=DEVICE_TYPE, bundle_id='example.synthetic.journal',
                             version='1.2.3', build='42', source_sha=sha, graph_id=GRAPH)
        self.app = self.base / 'built.app'
        self.app.mkdir()
        self.info = dict(CFBundleIdentifier=self.expected['bundle_id'], CFBundleExecutable='JournalApp',
                         CFBundleShortVersionString='1.2.3', CFBundleVersion='42',
                         JournalSourceRevision=sha, JournalBuildMode='experimental-host-restamp',
                         JournalCrossABIValidated=False, JournalOCamlRuntimeOrigin='host-arm64-restamp')
        self.inputs = dict(source={n: digest(b) for n, b in self.source_files.items()},
                           target='arm64-apple-ios26.0-simulator', flags={'mode': 'experimental-host-restamp'})
        self.native_input = self.base / 'production-host.o'
        self.native_input.write_bytes(b'synthetic host object')
        self.target_c = self.base / 'target-c.o'
        self.target_c.write_bytes(b'synthetic target C')
        self.linkmap = self.base / 'link-map.txt'
        self.linkmap.write_bytes(b'synthetic final link map')
        self.producer_source = self.base / 'producer-source.json'
        self.producer_source.write_text(json.dumps(dict(commit=sha,
            native_source_sha256={'app/application.ml': digest(self.source_files['app/application.ml'])},
            production_native_object=str(self.native_input), production_native_object_sha256=digest(self.native_input.read_bytes()))))
        self.producer_link = self.base / 'producer-link.json'
        self.producer_link.write_text(json.dumps(dict(production_host_sha256=digest(self.native_input.read_bytes()), device_c_source_sha256={})))
        self.inputs['dependencies'] = dict(source_sha=sha, schema_version=2,
            producer=dict(schema_version=2, source={'path': self.producer_source.name, 'sha256': digest(self.producer_source.read_bytes())},
                          link={'path': self.producer_link.name, 'sha256': digest(self.producer_link.read_bytes())}),
            files={str(p): digest(p.read_bytes()) for p in (self.producer_source, self.producer_link, self.native_input)})
        self.cache_key = digest(json.dumps(self.inputs, sort_keys=True).encode())
        self.info['JournalBuildInputDigest'] = self.cache_key
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info))
        (self.app / 'JournalApp').write_bytes(b'synthetic executable')
        (self.app / 'Assets.car').write_bytes(b'synthetic resources')
        self.installed = self.base / 'CoreSimulator/Devices' / UDID / 'data/Containers/Bundle/Application' / 'synthetic' / 'Journal.app'
        self.installed.mkdir(parents=True)
        for p in self.app.iterdir():
            (self.installed / p.name).write_bytes(p.read_bytes())
        self.manifest = dict(status='built', mode='experimental-host-restamp', cross_abi_validated=False,
                             source_sha=sha, source_status='', cache_key=self.cache_key,
                             sdk_name='iphonesimulator', target=self.inputs['target'], inputs=self.inputs,
                             artifact=dict(app=str(self.app), info=copy.deepcopy(self.info),
                                           files={p.name: digest(p.read_bytes()) for p in self.app.iterdir()},
                                           executable_sha256=digest((self.app / 'JournalApp').read_bytes())))
        self.manifest.update(native_source_sha=sha,
            native_object={'path': str(self.native_input), 'sha256': digest(self.native_input.read_bytes()), 'mode': 'experimental-host-restamp'},
            production_link=dict(link_map=str(self.linkmap), link_map_sha256=digest(self.linkmap.read_bytes()),
                target_c={'path': str(self.target_c), 'sha256': digest(self.target_c.read_bytes())},
                swift_objects={str(self.target_c): digest(self.target_c.read_bytes())}, cross_abi_validated=False))
        self.binary_platform = 'IOSSIMULATOR'
        self.manifest_path = self.base / 'manifest.json'
        self.output = self.base / 'evidence'
        self.device = dict(udid=UDID, state='Booted', isAvailable=True,
                           deviceTypeIdentifier=DEVICE_TYPE, name='Synthetic iPhone')
        self.observations = []
        self.commands = []
        self.capture_action = None
        self.command_failure = None
        self.container_resolutions = 0
        fixture = self

        class FixtureSimulator(self.api.Simulator):
            def observe(self, identity, challenge):
                value = dict(schema_version=1, challenge=challenge, udid=UDID,
                             bundle_id=fixture.expected['bundle_id'],
                             executable_sha256=fixture.manifest['artifact']['executable_sha256'],
                             source_sha=fixture.expected['source_sha'], graph_id=GRAPH,
                             graph_generation=7, presentation_generation=7, phase='open',
                             foreground=True, pid=123, process_instance='33333333-3333-4333-8333-333333333333')
                if fixture.observations:
                    value.update(fixture.observations.pop(0))
                return value
        self.backend = FixtureSimulator()

    def command(self, argv, **kwargs):
        self.commands.append(argv)
        self.assertTrue(0 < kwargs['timeout'] <= 30)
        self.assertTrue(kwargs.get('capture_output'))
        if self.command_failure:
            raise self.command_failure
        args = argv[1:]
        if args == ['simctl', 'list', 'devices', '--json']:
            result = json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [self.device]}})
        elif args == ['simctl', 'get_app_container', UDID, self.expected['bundle_id'], 'app']:
            self.container_resolutions += 1
            result = str(self.installed) + '\n'
        elif args[:2] == ['lipo', '-archs']:
            result = 'arm64'
        elif args[:2] == ['vtool', '-show-build']:
            result = 'platform ' + self.binary_platform
        elif args[:4] == ['simctl', 'io', UDID, 'screenshot']:
            if self.capture_action:
                self.capture_action(Path(args[-1]))
            else:
                # Real minimal PNG fixture, decoded and checked by the capture tool.
                import base64
                Path(args[-1]).write_bytes(base64.b64decode(
                    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='))
            result = ''
        else:
            self.fail('Unexpected system command: ' + repr(argv))
        return subprocess.CompletedProcess(argv, 0, result, '')

    def capture(self, backend=None):
        self.manifest_path.write_text(json.dumps(self.manifest))
        with patch.object(self.api.subprocess, 'run', side_effect=self.command) as run:
            # Git remains real and read-only; only xcrun is a synthetic boundary.
            def dispatch(argv, **kwargs):
                if argv[0] == 'xcrun':
                    return self.command(argv, **kwargs)
                return ORIGINAL_RUN(argv, **kwargs)
            run.side_effect = dispatch
            return self.api.capture(self.manifest_path, self.source, self.expected,
                                    self.output, backend=backend or self.backend)

    def rejects(self, code):
        with self.assertRaises(self.api.Rejected) as raised:
            self.capture()
        self.assertEqual(raised.exception.code, code)
        self.assertNotIn(SECRET, str(raised.exception))
        self.assertFalse((self.output / 'acceptance.json').exists())
        self.assertFalse(any(self.output.glob('*.png')) if self.output.exists() else False)

    def reseal(self):
        # Keep cheap stamps internally consistent, forcing tests to exercise the
        # deeper source/installed-byte boundary rather than only a stale digest.
        self.manifest['cache_key'] = digest(json.dumps(self.manifest['inputs'], sort_keys=True).encode())
        self.info['JournalBuildInputDigest'] = self.manifest['cache_key']
        self.manifest['artifact']['info'] = copy.deepcopy(self.info)
        for directory in (self.app, self.installed):
            (directory / 'Info.plist').write_bytes(plistlib.dumps(self.info))
        self.manifest['artifact']['files']['Info.plist'] = digest((self.app / 'Info.plist').read_bytes())

    def test_resealed_producer_source_must_still_match_actual_source(self):
        value = json.loads(self.producer_source.read_text())
        value['native_source_sha256']['app/application.ml'] = 'a' * 64
        self.producer_source.write_text(json.dumps(value))
        new_hash = digest(self.producer_source.read_bytes())
        deps = self.manifest['inputs']['dependencies']
        deps['files'][str(self.producer_source)] = new_hash
        deps['producer']['source']['sha256'] = new_hash
        self.reseal()
        self.rejects('build-evidence-mismatch')

    def test_capture_binds_bytes_graph_and_limits(self):
        record = self.capture()
        saved = json.loads((self.output / 'acceptance.json').read_text())
        self.assertEqual(record, saved)
        self.assertEqual(record['expected'], self.expected)
        self.assertEqual(record['observed']['graph_id'], GRAPH)
        self.assertEqual(record['observed']['executable_sha256'], self.manifest['artifact']['executable_sha256'])
        self.assertFalse(record['cross_abi_validated'])
        self.assertEqual(record['platform'], 'ios-simulator')
        self.assertEqual(record['screenshot_sha256'], digest((self.output / 'screenshot.png').read_bytes()))
        self.assertGreaterEqual(self.container_resolutions, 2)

    def test_similar_graph_names_cannot_replace_uuid(self):
        self.observations = [dict(graph_id=OTHER_GRAPH)]
        self.rejects('runtime-identity-mismatch')

    def test_graph_name_or_unknown_uuid_is_rejected(self):
        for value in ('Synthetic graph', '', None, 'booted'):
            with self.subTest(value=value):
                self.expected['graph_id'] = value
                self.rejects('invalid-expectation')

    def test_device_udid_and_type_are_exact(self):
        for changes in (dict(udid=OTHER_GRAPH), dict(deviceTypeIdentifier='com.apple.CoreSimulator.SimDeviceType.iPad'),
                        dict(state='Shutdown'), dict(isAvailable=False)):
            with self.subTest(changes=changes):
                self.device.update(changes)
                self.rejects('device-mismatch')
                self.device.update(udid=UDID, deviceTypeIdentifier=DEVICE_TYPE, state='Booted', isAvailable=True)

    def test_physical_device_and_ambiguous_alias_rejected(self):
        for value in ('booted', '00008110-000000000000001E'):
            with self.subTest(value=value):
                self.expected['udid'] = value
                self.rejects('invalid-expectation')

    def test_missing_expected_identity_is_rejected(self):
        original = copy.deepcopy(self.expected)
        for key in original:
            with self.subTest(key=key):
                self.expected = {k: v for k, v in original.items() if k != key}
                self.rejects('invalid-expectation')

    def test_stale_install_binary_and_resources_rejected(self):
        for filename in ('JournalApp', 'Assets.car', 'Info.plist'):
            with self.subTest(filename=filename):
                path = self.installed / filename
                data = path.read_bytes()
                path.write_bytes(b'stale ' + data)
                self.rejects('installed-artifact-mismatch')
                path.write_bytes(data)

    def test_changed_bundle_version_source_in_manifest_not_trusted(self):
        for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion', 'JournalSourceRevision'):
            with self.subTest(key=key):
                self.manifest['artifact']['info'][key] = 'forged'
                self.rejects('build-evidence-mismatch')
                self.manifest['artifact']['info'][key] = self.info[key]

    def test_missing_version_or_source_fails_closed(self):
        for key in ('source_sha', 'source_status', 'inputs', 'artifact', 'cache_key'):
            with self.subTest(key=key):
                value = self.manifest.pop(key)
                self.rejects('build-evidence-mismatch')
                self.manifest[key] = value

    def test_wrong_or_unaccepted_build_target(self):
        for key, values in {'status': ['preflight-passed', 'native-produced'], 'mode': ['link-only', 'probe-object'],
                            'sdk_name': ['iphoneos', 'macosx'], 'target': ['arm64-apple-ios26.0']}.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    old = self.manifest[key]
                    self.manifest[key] = value
                    self.rejects('build-evidence-mismatch')
                    self.manifest[key] = old

    def test_source_strings_need_matching_git_and_files(self):
        self.expected['source_sha'] = 'a' * 40
        self.manifest['source_sha'] = 'a' * 40
        self.rejects('build-evidence-mismatch')

    def test_source_files_and_manifest_coverage_cannot_be_omitted(self):
        (self.source / 'app/application.ml').write_bytes(b'changed')
        self.rejects('build-evidence-mismatch')
        (self.source / 'app/application.ml').write_bytes(self.source_files['app/application.ml'])
        self.manifest['inputs']['source'].pop('app/application.ml')
        self.reseal()
        self.rejects('build-evidence-mismatch')

    def test_package_missing_or_changed_rejected(self):
        (self.app / 'JournalApp').write_bytes(b'old build')
        self.rejects('build-evidence-mismatch')

    def test_manifest_paths_cannot_traverse_or_use_symlinks(self):
        for name in ('../outside', '/absolute', 'nested/../../outside'):
            with self.subTest(name=name):
                self.manifest['artifact']['files'][name] = 'a' * 64
                self.rejects('build-evidence-mismatch')
                del self.manifest['artifact']['files'][name]
        (self.installed / 'JournalApp').unlink()
        (self.installed / 'JournalApp').symlink_to(self.app / 'JournalApp')
        self.rejects('installed-artifact-mismatch')

    def test_manual_actual_fields_and_unknown_fields_are_rejected(self):
        self.expected['actual_graph_id'] = GRAPH
        self.rejects('invalid-expectation')

    def test_runtime_protocol_rejects_missing_or_unbound_values(self):
        for change in (dict(challenge='replay'), dict(udid=OTHER_GRAPH), dict(pid=0),
                       dict(source_sha='a' * 40), dict(executable_sha256='b' * 64),
                       dict(bundle_id='wrong'), dict(graph_id=None), dict(phase='opening'),
                       dict(foreground=False), dict(graph_generation=-1),
                       dict(presentation_generation=6), dict(schema_version=2),
                       dict(process_instance=''), dict(token=SECRET)):
            with self.subTest(change=change):
                self.observations = [change]
                self.rejects('runtime-identity-mismatch')

    def test_graph_or_process_transition_during_capture_discards_pixels(self):
        for change in (dict(graph_id=OTHER_GRAPH), dict(graph_generation=8, presentation_generation=8),
                       dict(pid=124), dict(process_instance='44444444-4444-4444-8444-444444444444')):
            with self.subTest(change=change):
                self.observations = [{}, change]
                self.rejects('runtime-identity-mismatch')

    def test_reinstall_during_capture_is_detected(self):
        previous = self.installed
        def replace(path):
            # Simulate a fresh container with identical bytes after preflight.
            self.capture_action = None
            self.command(['xcrun', 'simctl', 'io', UDID, 'screenshot', str(path)], timeout=30, capture_output=True)
            self.installed = self.base / 'replacement.app'
            self.installed.mkdir()
            for p in previous.iterdir():
                (self.installed / p.name).write_bytes(p.read_bytes())
        self.capture_action = replace
        self.rejects('installed-artifact-mismatch')

    def test_empty_or_non_png_capture_rejected(self):
        for content in (b'', b'not a PNG', b'\x89PNG\r\n\x1a\n' + b'x' * 40):
            with self.subTest(content=content):
                self.capture_action = lambda p: p.write_bytes(content)
                self.rejects('screenshot-failed')

    def test_failed_and_timed_out_capture_do_not_leave_evidence(self):
        for error in (subprocess.CalledProcessError(1, ['xcrun'], output=SECRET, stderr=SECRET),
                      subprocess.TimeoutExpired(['xcrun'], 30, output=SECRET, stderr=SECRET)):
            with self.subTest(error=type(error).__name__):
                def fail_after_write(path):
                    path.write_bytes(b'partial capture')
                    raise error
                self.capture_action = fail_after_write
                self.rejects('command-failed' if isinstance(error, subprocess.CalledProcessError) else 'command-timeout')

    def test_command_output_never_leaks_sensitive_data(self):
        self.command_failure = subprocess.CalledProcessError(1, ['xcrun'], output=SECRET, stderr=SECRET)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.rejects('command-failed')
        self.assertNotIn(SECRET, output.getvalue())

    def test_manifest_secrets_and_graph_body_are_not_copied_to_record(self):
        self.manifest['ignored_environment'] = {'credential': SECRET}
        self.manifest['commands'] = [{'stdout': SECRET}]
        self.capture()
        self.assertNotIn(SECRET, (self.output / 'acceptance.json').read_text())

    def test_native_producer_and_final_link_evidence_is_required(self):
        for field in ('native_source_sha', 'native_object', 'production_link'):
            with self.subTest(field=field):
                self.output = self.base / ('evidence-' + field)
                value = self.manifest.pop(field, None)
                self.rejects('build-evidence-mismatch')
                if value is not None:
                    self.manifest[field] = value

    def test_native_input_or_producer_source_change_is_rejected(self):
        self.native_input.write_bytes(b'stale producer')
        self.rejects('build-evidence-mismatch')

    def test_actual_macho_target_is_checked(self):
        self.binary_platform = 'IOS'
        self.rejects('installed-artifact-mismatch')

    def test_default_runtime_observer_blocks_without_capture(self):
        with self.assertRaises(self.api.Rejected) as raised:
            self.capture(backend=self.api.Simulator())
        self.assertEqual(raised.exception.code, 'runtime-identity-unavailable')
        self.assertFalse(any('screenshot' in argv for argv in self.commands))
        self.assertFalse(self.output.exists())

    def test_output_inside_repository_or_existing_output_is_rejected(self):
        original = self.output
        self.output = ROOT / 'forbidden-acceptance-output'
        self.rejects('unsafe-output')
        self.output = original
        self.output.mkdir()
        (self.output / 'keep.txt').write_text('keep')
        self.rejects('unsafe-output')
        self.assertEqual((self.output / 'keep.txt').read_text(), 'keep')

    def test_invalid_cli_arguments_never_echo_values(self):
        for argv in (["--token", SECRET], ["--manifest", SECRET], ["--udid", SECRET]):
            with self.subTest(argv=argv[:1]):
                result = ORIGINAL_RUN([sys.executable, str(TOOL), *argv], capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)['reason'], 'invalid-arguments')
                self.assertNotIn(SECRET, result.stdout + result.stderr)

    def test_cli_has_no_identity_bypass_and_reports_bridge_gap(self):
        self.manifest_path.write_text(json.dumps(self.manifest))
        fakebin = self.base / 'bin'
        fakebin.mkdir()
        xcrun = fakebin / 'xcrun'
        xcrun.write_text('#!' + sys.executable + '\nimport json, sys\n'
                         'args=sys.argv[1:]\n'
                         'if args == ["simctl","list","devices","--json"]:\n'
                         ' print(' + repr(json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [self.device]}})) + ')\n'
                         'elif args[:2] == ["simctl","get_app_container"]:\n'
                         ' print(' + repr(str(self.installed)) + ')\n'
                         'elif args[:2] == ["lipo","-archs"]: print("arm64")\n'
                         'elif args[:2] == ["vtool","-show-build"]: print("platform IOSSIMULATOR")\n'
                         'else: raise SystemExit(99)\n')
        xcrun.chmod(0o755)
        argv = [sys.executable, str(TOOL), '--manifest', str(self.manifest_path),
                '--source-root', str(self.source), '--output', str(self.output)]
        for key, value in self.expected.items():
            argv += ['--' + key.replace('_', '-'), value]
        env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ['PATH'])
        result = ORIGINAL_RUN(argv, capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)['reason'], 'runtime-identity-unavailable')
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertFalse(self.output.exists())
        bypass = ORIGINAL_RUN(argv + ['--actual-graph-id', GRAPH, '--token', SECRET], capture_output=True, text=True, env=env)
        self.assertNotEqual(bypass.returncode, 0)
        self.assertNotIn(SECRET, bypass.stdout + bypass.stderr)


ORIGINAL_RUN = subprocess.run
if __name__ == '__main__':
    unittest.main()
