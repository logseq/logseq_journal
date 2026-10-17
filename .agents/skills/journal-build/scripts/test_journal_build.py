#!/usr/bin/env python3
"""Small build-boundary checks; no device, dependency install or large build."""
import importlib.util
import hashlib
from contextlib import contextmanager
from functools import partial
import json
import os
import plistlib
from pathlib import Path
import re
import subprocess
import tempfile
import signal
import shutil
import sys
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[4]
SCRIPTS = ROOT / ".agents/skills/journal-build/scripts"
SCRIPT = ROOT / ".agents/skills/journal-build/scripts/build_journal_apple.sh"


class BuildBoundaryTests(unittest.TestCase):
    def cli(self, *args, env=None):
        return subprocess.run(["bash", str(SCRIPT), *args], text=True,
                              capture_output=True, env=env)

    def test_help_is_read_only_and_describes_modes(self):
        result = self.cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--link-only", result.stdout)
        self.assertIn("--preflight", result.stdout)
        self.assertIn("--experimental-host-restamp", result.stdout)

    def test_skill_entry_resolves_from_an_external_working_directory(self):
        script = ROOT / '.agents/skills/journal-build/scripts/build_journal_apple.sh'
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['bash', str(script), '--help'], cwd=directory,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('--preflight', result.stdout)

    def test_iphone_is_explicitly_blocked(self):
        result = self.cli("ios-device", "--preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cross", result.stderr)

    def test_simulator_never_silently_uses_host_runtime(self):
        result = self.cli("ios-simulator", "--preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--link-only", result.stderr)

    def test_unproven_object_is_rejected_even_when_restamped(self):
        env = dict(os.environ, JOURNAL_OCAML_OBJECT="/tmp/restamped-host.o")
        result = self.cli("ios-simulator", "--link-only", "--preflight", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("JOURNAL_OCAML_OBJECT", result.stderr)

    def test_no_implicit_switch_or_environment_mutation(self):
        result = self.cli("macos", "--preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--switch", result.stderr)

    def test_native_import_requires_both_explicit_mode_and_manifest(self):
        for args, expected in [
            (("ios-device", "--native-manifest", "/tmp/input.json"), "--experimental-host-restamp"),
            (("ios-device", "--experimental-host-restamp"), "--native-manifest"),
        ]:
            with self.subTest(args=args):
                result = self.cli(*args, "--preflight")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_probe_object_cannot_select_device_or_production_modes(self):
        for args in [('ios-device', '--probe-native-object', '/tmp/probe.o'),
                     ('macos', '--probe-native-object', '/tmp/probe.o', '--link-only'),
                     ('macos', '--probe-native-object', '/tmp/probe.o', '--switch', 'unused')]:
            with self.subTest(args=args):
                result = self.cli(*args, '--preflight')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('probe mode', result.stderr)

    def test_foreign_dune_root_and_runtime_cannot_change_provenance(self):
        for name in ("DUNE_ROOT", "DUNE_WORKSPACE", "DUNE_CROSS_TARGET", "DUNE_INSTRUMENT_WITH", "OCAMLLIB",
                     "MACOSX_DEPLOYMENT_TARGET", "CAML_LD_LIBRARY_PATH", "OCAMLFIND_COMMANDS"):
            with self.subTest(name=name):
                result = self.cli("macos", "--switch", "not-used", "--preflight",
                                  env=dict(os.environ, **{name: "/tmp/foreign-build-input"}))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)

    def test_existing_output_is_preserved_before_toolchain_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "Keep.app"
            output.mkdir()
            sentinel = output / "sentinel"
            sentinel.write_text("keep")
            result = self.cli("macos", "--link-only", "--app-dir", str(output))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exists", result.stderr)
            self.assertEqual(sentinel.read_text(), "keep")

    def test_producer_only_is_an_explicit_native_macos_mode(self):
        for args in [('ios-simulator', '--link-only'),
                     ('macos', '--link-only'),
                     ('macos', '--probe-native-object', '/tmp/probe.o'),
                     ('macos', '--experimental-host-restamp', '--native-manifest', '/tmp/input.json'),
                     ('macos', '--switch', 'unused', '--app-dir', '/tmp/unused-producer.app'),
                     ('macos', '--switch', 'unused', '--sign-identity', 'unused')]:
            with self.subTest(args=args):
                result = self.cli(*args, '--producer-only', '--preflight')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('producer-only requires', result.stderr)
        result = self.cli('macos', '--producer-only', '--preflight')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--switch', result.stderr)



class CacheBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / ".agents/skills/journal-build/scripts/journal_build.py"
        if not path.exists():
            return
        spec = importlib.util.spec_from_file_location("journal_build", path)
        cls.build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.build)

    @contextmanager
    def pinned_switch(self):
        """Real offline switch; original source metadata deliberately has no url."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            repository, checkout, journal = (root / name for name in ('repository', 'checkout', 'journal'))
            for path in (repository, checkout, journal):
                path.mkdir()
            (repository / 'repo').write_text('opam-version: "2.0"\n')
            metadata = 'opam-version: "2.0"\nversion: "dev"\nsynopsis: "Offline build fixture"\n'
            (checkout / 'fixture.opam').write_text(metadata)
            for argv in (['git', 'init', '-q', checkout], ['git', '-C', checkout, 'add', '.'],
                         ['git', '-C', checkout, '-c', 'user.name=Build test', '-c', 'user.email=build@example.invalid',
                          'commit', '-qm', 'fixture']):
                subprocess.run(argv, check=True, capture_output=True)
            commit = subprocess.check_output(['git', '-C', checkout, 'rev-parse', 'HEAD'], text=True).strip()
            expected = 'git+https://example.invalid/fixture.git#' + commit
            (journal / 'journal.opam').write_text('opam-version: "2.0"\n')
            lock = journal / 'journal.opam.locked'
            lock.write_text('depends: [ "fixture" {= "dev"} ]\npin-depends: [ [ "fixture.dev" "' + expected + '" ] ]\n')
            (journal / '.ci-reports').mkdir()
            (journal / '.ci-reports/dependencies.json').write_text(json.dumps([
                dict(package='fixture.dev', source=expected, checkout=str(checkout), resolved_sha=commit)]))
            env = dict(os.environ, OPAMROOT=str(root / 'opam'), OPAMYES='1', OPAMNOENVNOTICE='1')
            for argv in (['opam', 'init', '--bare', '--no-setup', '--no-opamrc', '--disable-sandboxing', 'local', str(repository)],
                         ['opam', 'switch', 'create', 'fixture', '--empty'],
                         ['opam', 'pin', 'add', '--switch', 'fixture', '--no-action', 'fixture.dev', str(checkout)],
                         ['opam', 'install', '--switch', 'fixture', 'fixture.dev', '--assume-depexts']):
                subprocess.run(argv, env=env, check=True, capture_output=True)
            build = self.build.Build(SimpleNamespace(link_only=False, experimental_host_restamp=False,
                native_manifest=None, switch='fixture'), root)
            build.env = env
            build.prefix = root / 'opam/fixture'
            # Keep the active pin intact while storing the original no-url opam file.
            (build.prefix / '.opam-switch/packages/fixture.dev/opam').write_text(metadata)
            with patch.object(self.build, 'ROOT', journal):
                yield SimpleNamespace(root=root, journal=journal, checkout=checkout, lock=lock, build=build)

    def test_active_switch_pin_does_not_require_raw_metadata_url(self):
        with self.pinned_switch() as f:
            dependencies = f.build.dependencies()
            self.assertEqual(dependencies['pins']['fixture.dev']['checkout'], str(f.checkout))
            metadata = f.build.prefix / '.opam-switch/packages/fixture.dev/opam'
            original = metadata.read_text()
            metadata.write_text(original + 'url { src: "git+https://example.invalid/stale" }\n')
            with self.assertRaisesRegex(RuntimeError, 'installed source'):
                f.build.dependencies()
            metadata.write_text(original)
            record_path = f.journal / '.ci-reports/dependencies.json'
            records = json.loads(record_path.read_text())
            commit = records[0]['resolved_sha']
            records[0]['resolved_sha'] = ''
            record_path.write_text(json.dumps(records))
            with self.subTest(case='invalid resolution'), self.assertRaisesRegex(RuntimeError, 'resolved'):
                f.build.dependencies()
            records[0]['resolved_sha'] = commit
            record_path.write_text(json.dumps(records))
            (f.checkout / 'other').write_text('another real commit\n')
            subprocess.run(['git', '-C', f.checkout, 'add', '.'], check=True, capture_output=True)
            subprocess.run(['git', '-C', f.checkout, '-c', 'user.name=Build test', '-c', 'user.email=build@example.invalid',
                            'commit', '-qm', 'other'], check=True, capture_output=True)
            other = subprocess.check_output(['git', '-C', f.checkout, 'rev-parse', 'HEAD'], text=True).strip()
            records[0]['resolved_sha'] = other
            record_path.write_text(json.dumps(records))
            with self.subTest(case='fixed lock'), self.assertRaisesRegex(RuntimeError, 'locked commit'):
                f.build.dependencies()
            subprocess.run(['git', '-C', f.checkout, 'reset', '--hard', commit], check=True, capture_output=True)
            records[0]['resolved_sha'] = commit
            record_path.write_text(json.dumps(records))
            f.build.opam('pin', 'add', '--no-action', 'fixture.dev', 'git+file://' + str(f.checkout) + '#' + other)
            metadata.write_text(original)
            with self.subTest(case='active pin ref'), self.assertRaisesRegex(RuntimeError, 'active local pin'):
                f.build.dependencies()
            f.lock.write_text(f.lock.read_text().replace('example.invalid/fixture', 'example.invalid/other'))
            with self.assertRaisesRegex(RuntimeError, 'differs from lock'):
                f.build.dependencies()

    def compiler_fixture(self, prefix):
        compiler = prefix / 'bin/ocamlopt.opt'
        compiler.parent.mkdir(exist_ok=True)
        compiler.write_text('#!/bin/sh\nprintf "version: 5.5.0\\narchitecture: arm64\\nsystem: macosx\\n"\n')
        compiler.chmod(0o755)
        return compiler

    def test_skill_script_bytes_participate_in_source_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / '.agents/skills/journal-build/scripts/fixture.py'
            helper.parent.mkdir(parents=True)
            helper.write_text('original helper bytes')
            name = str(helper.relative_to(root))
            with patch.object(self.build, 'ROOT', root):
                baseline = self.build.source_inputs()
                self.assertEqual(baseline.get(name), self.build.sha(helper))
                helper.write_text('changed helper bytes')
                self.assertNotEqual(baseline, self.build.source_inputs())

    def test_opam_identity_binds_absolute_prefix_and_compiler(self):
        self.assertTrue(hasattr(self.build, 'opam_identity'), 'shared absolute switch identity missing')
        with self.pinned_switch() as f:
            compiler = self.compiler_fixture(f.build.prefix)
            original = self.build.opam_identity(f.build.opam)
            self.assertEqual(original['opam_prefix'], str(f.build.prefix))
            self.assertEqual(original, self.build.opam_identity(f.build.opam))
            compiler.write_text(compiler.read_text() + '# changed compiler bytes\n')
            self.assertNotEqual(original, self.build.opam_identity(f.build.opam))
            f.build.opam('switch', 'create', 'second', '--empty')
            self.compiler_fixture(f.root / 'opam/second')
            f.build.args.switch = 'second'
            other = self.build.opam_identity(f.build.opam)
            self.assertEqual(original['compiler_sha256'], other['compiler_sha256'])
            self.assertNotEqual(self.build.fingerprint(original), self.build.fingerprint(other))

    def test_ci_identity_is_stable_and_invalidates_required_inputs(self):
        sys.path.insert(0, str(SCRIPTS))
        import prepare_ci_dependencies as ci
        self.assertTrue(hasattr(ci, 'cache_identity'), 'CI switch identity missing')
        with self.pinned_switch() as f:
            self.compiler_fixture(f.build.prefix)
            # Repository fixtures only contain inputs this boundary consumes.
            fixture_scripts = f.journal / '.agents/skills/journal-build/scripts'
            fixture_scripts.mkdir(parents=True)
            for name in ('prepare_ci_dependencies.py', 'journal_build.py'):
                (fixture_scripts / name).write_bytes((SCRIPTS / name).read_bytes())
            workflow = f.journal / '.github/workflows/ci.yml'
            workflow.parent.mkdir(parents=True)
            workflow.write_bytes((ROOT / '.github/workflows/ci.yml').read_bytes())
            env = dict(f.build.env, OPAMSWITCH='fixture', RUNNER_OS='macOS', RUNNER_ARCH='ARM64',
                       ImageOS='macos26-arm64', ImageVersion='fixture-image',
                       CI_COMPILER='ocaml-base-compiler.5.5.0', CI_OPAM_VERSION='2.6.1',
                       PKG_CONFIG_PATH=':'.join(str(Path(subprocess.check_output(
                           ['brew', '--prefix', name], text=True).strip()) / 'lib/pkgconfig')
                           for name in ('gmp', 'sqlite', 'zlib', 'zstd')),
                       CI_OPAM_REPOSITORY='git+https://github.com/ocaml/opam-repository.git#' + 'a' * 40)
            with patch.dict(os.environ, env, clear=True):
                baseline = ci.cache_identity(f.journal)
                self.assertEqual(baseline, ci.cache_identity(f.journal))
                self.assertEqual(baseline['identity']['opam_prefix'], str(f.journal / '_opam'))
                # Lookup must work before setup creates a compiler or a switch.
                compiler = f.build.prefix / 'bin/ocamlopt.opt'
                compiler.unlink()
                self.assertEqual(baseline, ci.cache_identity(f.journal))
                inputs = [f.lock, f.journal / 'journal.opam', f.journal / '.ci-reports/dependencies.json']
                for path in inputs:
                    with self.subTest(path=path):
                        data = path.read_bytes()
                        # JSON whitespace must not change resolution semantics; a new SHA does.
                        changed = data.replace(baseline['identity']['resolved'][0]['resolved_sha'].encode(), b'1' * 40) if path.suffix == '.json' else data + b'\n# changed bytes\n'
                        path.write_bytes(changed)
                        self.assertNotEqual(baseline['key'], ci.cache_identity(f.journal)['key'])
                        path.write_bytes(data)
                for path in (workflow, fixture_scripts / 'prepare_ci_dependencies.py', fixture_scripts / 'journal_build.py'):
                    original = path.read_bytes()
                    path.write_bytes(original + b'\n# unrelated comment\n')
                    self.assertEqual(baseline['key'], ci.cache_identity(f.journal)['key'])
                    path.write_bytes(original)
                with patch.dict(os.environ, {'ImageVersion': 'other-image', 'PATH': str(f.root / 'empty') + ':' + env['PATH']}):
                    moved = ci.cache_identity(f.journal)
                    self.assertEqual(baseline['key'], moved['key'])
                    self.assertEqual(baseline['native_key'], moved['native_key'])
                    self.assertNotEqual(baseline['observed'], moved['observed'])
                native = f.root / 'sqlite-provider'
                for sub in ('lib/pkgconfig', 'include'):
                    (native / sub).mkdir(parents=True)
                (native / 'lib/libsqlite3.a').write_bytes(b'fixture native archive bytes')
                for header in ('sqlite3.h', 'sqlite3ext.h'):
                    (native / 'include' / header).write_text('fixture header bytes')
                pc = native / 'lib/pkgconfig/sqlite3.pc'
                pc.write_text('prefix=' + str(native) + '\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n'
                              'Name: sqlite3\nDescription: identity fixture\nVersion: 3.54.0\n'
                              'Libs: -L${libdir} -lsqlite3\nCflags: -I${includedir}\n')
                with patch.dict(os.environ, {'PKG_CONFIG_PATH': str(pc.parent) + ':' + env['PKG_CONFIG_PATH']}):
                    first = ci.cache_identity(f.journal)
                    pc.write_text(pc.read_text().replace('3.54.0', '3.53.4'))
                    (native / 'lib/libsqlite3.a').write_bytes(b'changed fixture native archive')
                    second = ci.cache_identity(f.journal)
                    self.assertEqual(first['key'], second['key'])
                    self.assertNotEqual(first['native_key'], second['native_key'])
                empty = f.root / 'empty'
                empty.mkdir()
                wrapper = empty / 'cc'
                wrapper.write_text('#!/bin/sh\nexec /usr/bin/cc "$@"\n')
                wrapper.chmod(0o755)
                with patch.dict(os.environ, {'PATH': str(empty) + ':' + env['PATH']}):
                    self.assertNotEqual(baseline['key'], ci.cache_identity(f.journal)['key'])
                original = workflow.read_text()
                workflow.write_text(original.replace('93303b622b2522e4411e295f9e77411a24912ac7', 'f' * 40))
                self.assertNotEqual(baseline['key'], ci.cache_identity(f.journal)['key'])
                workflow.write_text(original)
                for name in ('CFLAGS', 'DEVELOPER_DIR', 'OPAMROOT', 'CI_OPAM_VERSION', 'CI_COMPILER', 'CI_OPAM_REPOSITORY'):
                    with self.subTest(environment=name), patch.dict(os.environ, {name: 'changed'}):
                        if name in ('DEVELOPER_DIR', 'CI_COMPILER', 'CI_OPAM_REPOSITORY', 'CI_OPAM_VERSION'):
                            # An unavailable selected toolchain must fail, not restore an old key.
                            with self.assertRaises((subprocess.CalledProcessError, ValueError)):
                                ci.cache_identity(f.journal)
                        else:
                            self.assertNotEqual(baseline['key'], ci.cache_identity(f.journal)['key'])
                for name, value in [('RUNNER_ARCH', 'X64'), ('RUNNER_OS', 'Linux')]:
                    with self.subTest(invalid=name), patch.dict(os.environ, {name: value}):
                        with self.assertRaises(ValueError):
                            ci.cache_identity(f.journal)
                resolution = f.journal / '.ci-reports/dependencies.json'
                records = json.loads(resolution.read_text())
                for invalid in ([], [dict(records[0], resolved_sha='moving-ref')]):
                    resolution.write_text(json.dumps(invalid))
                    with self.assertRaises(ValueError):
                        ci.cache_identity(f.journal)
                resolution.unlink()
                with self.assertRaises(FileNotFoundError):
                    ci.cache_identity(f.journal)

    def test_ci_cache_receipt_accepts_exact_state_and_rejects_mismatches(self):
        import prepare_ci_dependencies as ci
        self.assertTrue(hasattr(ci, 'cache_receipt'), 'restored cache validation missing')
        self.assertTrue(hasattr(ci, 'cache_key'), 'compatible cache family missing')
        with self.pinned_switch() as f:
            compiler = self.compiler_fixture(f.build.prefix)
            report = dict(key='a' * 64, native_key='d' * 64, observed={}, identity=dict(opam_prefix=str(f.build.prefix),
                          opam_root=str(f.root / 'opam'), compiler='ocaml-base-compiler.5.5.0',
                          opam_version=f.build.opam('--version')))
            receipt = ci.cache_receipt(report, f.build.opam)
            receipt_path = f.build.prefix / '.journal-ci-cache.json'
            receipt_path.write_text(json.dumps(receipt))
            self.assertEqual(ci.validate_restored_cache(report, True)['status'], 'accepted')
            self.assertEqual(ci.validate_restored_cache(report, False)['status'], 'rejected')
            changed = dict(report, key='b' * 64)
            self.assertEqual(ci.validate_restored_cache(changed, True)['status'], 'rejected')
            variant = dict(report, native_key='c' * 64, observed={'system_libraries': {'sqlite3': {'version': '3.49.2'}}})
            receipt['inputs']['native_key'] = 'd' * 64
            receipt['inputs']['observed'] = {'system_libraries': {'sqlite3': {'version': '3.50.4'}}}
            receipt_path.write_text(json.dumps(receipt))
            match = ci.cache_key(receipt['inputs'])
            restored = ci.validate_restored_cache(variant, False, matched_key=match)
            self.assertEqual(restored['status'], 'accepted')
            self.assertEqual(restored['source'], 'compatible')
            incompatible = dict(variant, key='f' * 64, identity=dict(variant['identity'], compiler='ocaml-base-compiler.5.4.0'))
            rejected = ci.validate_restored_cache(incompatible, False, matched_key=match)
            self.assertEqual(rejected['status'], 'rejected')
            self.assertTrue(any(d['field'].endswith('compiler') for d in rejected['differences']))
            report['observed'] = receipt['inputs']['observed']
            for path in (compiler, f.build.prefix / '.opam-switch/switch-state',
                         f.build.prefix / '.opam-switch/switch-config', f.root / 'opam/config'):
                with self.subTest(path=path):
                    original = path.read_bytes()
                    path.write_bytes(original + b'\nchanged\n')
                    rejected = ci.validate_restored_cache(report, True)
                    self.assertEqual(rejected['status'], 'rejected')
                    self.assertTrue(any(d['field'].startswith('files.') and d['cached'] != d['current'] for d in rejected['differences']))
                    path.write_bytes(original)
            self.assertEqual(ci.validate_restored_cache(report, True)['status'], 'accepted')
            for malformed in ('{}', 'invalid json'):
                receipt_path.write_text(malformed)
                self.assertEqual(ci.validate_restored_cache(report, True)['status'], 'rejected')
            for inputs in ('broken', [], None, dict(report, observed='broken')):
                receipt_path.write_text(json.dumps(dict(receipt, inputs=inputs)))
                self.assertEqual(ci.validate_restored_cache(report, True)['status'], 'rejected')
            receipt_path.write_text(json.dumps(receipt))
            compiler.unlink()
            rejected = ci.validate_restored_cache(report, True)
            self.assertEqual(rejected['status'], 'rejected')
            self.assertTrue(any(d['current'] is None and d['field'].endswith('bin/ocamlopt.opt') for d in rejected['differences']))
            receipt_path.unlink()
            self.assertEqual(ci.validate_restored_cache(report, True)['status'], 'rejected')

    def test_ci_rejection_quarantines_only_owned_runner_paths(self):
        import prepare_ci_dependencies as ci
        self.assertTrue(hasattr(ci, 'quarantine_cache'), 'safe cold fallback missing')
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory).resolve() / 'workspace'
            runner_temp = Path(directory).resolve() / 'runner-temp'
            workspace.mkdir()
            runner_temp.mkdir()
            opam_root = Path(directory).resolve() / 'opam'
            prefix = workspace / '_opam'
            for path in (opam_root, prefix):
                path.mkdir()
                (path / 'keep').write_text('owned cached state')
            report = dict(identity=dict(opam_prefix=str(prefix), opam_root=str(opam_root)))
            env = dict(GITHUB_WORKSPACE=str(workspace), RUNNER_TEMP=str(runner_temp),
                       RUNNER_ENVIRONMENT='github-hosted', GITHUB_ACTIONS='true')
            with patch.dict(os.environ, env), patch('prepare_ci_dependencies.Path.home', return_value=opam_root.parent):
                # A foreign root is refused; no caller-provided path is moved.
                with self.assertRaises(ValueError):
                    ci.quarantine_cache(report)
                self.assertTrue((prefix / 'keep').exists())
                opam_root.rename(opam_root.parent / '.opam')
                report['identity']['opam_root'] = str(opam_root.parent / '.opam')
                destination = ci.quarantine_cache(report)
                self.assertFalse(prefix.exists())
                self.assertFalse(Path(report['identity']['opam_root']).exists())
                self.assertEqual(len(list(Path(destination).glob('*/keep'))), 2)
                self.assertTrue(workspace.exists())
            with self.assertRaises(ValueError):
                ci.quarantine_cache(report)

    def test_ci_diagnostics_are_truthful_specific_and_redacted(self):
        import prepare_ci_dependencies as ci
        self.assertTrue(hasattr(ci, 'cache_diagnostics'), 'specific miss diagnostics missing')
        current = dict(key='b' * 64, native_key='c' * 64,
                       identity=dict(compiler='ocaml-base-compiler.5.5.0', environment={'CFLAGS': 'private-token-value'},
                                     workspace='/Users/private-person/project'), observed={})
        missing = ci.cache_diagnostics(current, None, 'miss', 'no accessible candidate')
        self.assertFalse(missing['comparison_available'])
        self.assertEqual(missing['differences'], [])
        for invalid in ('broken', [], dict(current, observed='broken')):
            self.assertFalse(ci.cache_diagnostics(current, invalid, 'miss', 'invalid prior record')['comparison_available'])
        cached = dict(current, key='a' * 64, identity=dict(current['identity'], compiler='ocaml-base-compiler.5.4.0'))
        result = ci.cache_diagnostics(current, cached, 'miss', 'compatibility key mismatch')
        self.assertTrue(result['comparison_available'])
        difference = next(d for d in result['differences'] if d['field'].endswith('compiler'))
        self.assertEqual(difference['cached'], 'ocaml-base-compiler.5.4.0')
        self.assertEqual(difference['current'], 'ocaml-base-compiler.5.5.0')
        rendered = json.dumps(result)
        self.assertNotIn('private-token-value', rendered)
        self.assertNotIn('/Users/private-person', rendered)
        same = ci.cache_diagnostics(current, current, 'miss', 'no archive despite matching input record')
        self.assertTrue(same['comparison_available'])
        self.assertEqual(same['differences'], [])
        self.assertEqual(same['status'], 'miss')

    def test_native_symbol_probe_uses_real_dylib_and_rejects_missing_exports(self):
        import prepare_ci_dependencies as ci
        self.assertTrue(hasattr(ci, 'require_native_symbols'), 'native symbol validation missing')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, library = root / 'fixture.c', root / 'libfixture.dylib'
            source.write_text('int sqlite3_fixture(void) { return 42; }\n')
            subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-dynamiclib', str(source), '-o', str(library)],
                           check=True, capture_output=True)
            ci.require_native_symbols(str(library), ['sqlite3_fixture'])
            with self.assertRaisesRegex(RuntimeError, 'sqlite3_missing'):
                ci.require_native_symbols(str(library), ['sqlite3_fixture', 'sqlite3_missing'])
            library.unlink()
            with self.assertRaises(RuntimeError):
                ci.require_native_symbols(str(library), ['sqlite3_fixture'])

    def test_native_reinstall_rebuilds_real_reverse_dependents_only(self):
        import prepare_ci_dependencies as ci
        self.assertTrue(hasattr(ci, 'rebuild_native_packages'), 'selective native repair missing')
        with self.pinned_switch() as f:
            metadata = f.checkout / 'fixture.opam'
            metadata.write_text(metadata.read_text() + 'build: [["sh" "-c" "echo fixture >> %{prefix}%/fixture-events"]]\n')
            subprocess.run(['git', '-C', f.checkout, 'add', '.'], check=True, capture_output=True)
            subprocess.run(['git', '-C', f.checkout, '-c', 'user.name=Build test', '-c', 'user.email=build@example.invalid',
                            'commit', '-qm', 'fixture build marker'], check=True, capture_output=True)
            f.build.opam('pin', 'add', '--no-action', 'fixture.dev', str(f.checkout))
            repo = f.root / 'repository'
            for name, dependency in [('dependent', 'depends: ["fixture"]'), ('unrelated', '')]:
                path = repo / f'packages/{name}/{name}.1/opam'
                path.parent.mkdir(parents=True)
                path.write_text('opam-version: "2.0"\nsynopsis: "Offline native repair fixture"\n' + dependency +
                                '\nbuild: [["sh" "-c" "echo ' + name + ' >> %{prefix}%/fixture-events"]]\n')
            f.build.opam('update')
            f.build.opam('install', '--assume-depexts', 'dependent', 'unrelated')
            events = f.build.prefix / 'fixture-events'
            events.write_text('')
            repaired = ci.rebuild_native_packages(['fixture', 'not-installed'], f.build.opam)
            self.assertEqual(repaired, ['fixture'])
            self.assertEqual(events.read_text().splitlines(), ['fixture', 'dependent'])
            events.write_text('')
            self.assertEqual(ci.rebuild_native_packages(['not-installed'], f.build.opam), [])
            self.assertEqual(events.read_text(), '')

    def test_sqlite_runtime_probe_reuses_installed_binding_read_only(self):
        import prepare_ci_dependencies as ci
        self.assertTrue(hasattr(ci, 'probe_sqlite_binding'), 'SQLite native/bytecode runtime probe missing')
        switch = os.environ.get('JOURNAL_TEST_SWITCH')
        if not switch:
            self.skipTest('set JOURNAL_TEST_SWITCH to an already prepared switch; this test never provisions it')
        prefix = Path(subprocess.check_output(['opam', 'var', '--safe', '--switch', switch, 'prefix'], text=True).strip())
        stubs = prefix / 'lib/sqlite3/libsqlite3_stubs.a'
        before = self.build.sha(stubs)
        result = ci.probe_sqlite_binding(prefix)
        self.assertEqual(result['status'], 'compatible')
        self.assertTrue(result['native_version'].startswith('3.'))
        self.assertEqual(result['native_version'], result['bytecode_version'])
        self.assertEqual(before, self.build.sha(stubs))
        with self.assertRaisesRegex(RuntimeError, 'version'):
            ci.probe_sqlite_binding(prefix, expected_version='4.0.0')

    def test_final_verification_rejects_changed_gmp_and_probe_input(self):
        self.assertTrue(hasattr(self.build.Build, 'verify_inputs'), 'final input verification boundary missing')
        with self.pinned_switch() as f:
            build = f.build
            build.swift_dir, build.lui, build.entitlements = (f.root / name for name in ('swift', 'lui', 'entitlements'))
            for path in (build.swift_dir, build.lui, build.entitlements):
                path.mkdir()
            build.plist = f.root / 'Info.plist'
            build.plist.write_bytes(b'plist fixture')
            gmp, probe = f.root / 'libgmp.a', f.root / 'probe.o'
            gmp.write_bytes(b'original GMP bytes')
            build.native_gmp = f.root / 'linked-libgmp.a'
            build.native_gmp.write_bytes(gmp.read_bytes())
            probe.write_bytes(b'original probe bytes')
            build.tools = {}
            build.native_files = {str(probe): self.build.sha(probe)}
            build.inputs = dict(source=self.build.source_inputs(), swift={}, lui={}, entitlements={},
                plist=self.build.sha(build.plist), signing={}, dependencies=build.dependencies(),
                toolchain=dict(hashes={}, sdk_identity={'settings': {}},
                               gmp=dict(path=str(gmp), sha256=self.build.sha(gmp))))
            build.verify_inputs()
            gmp.write_bytes(b'changed GMP bytes')
            with self.assertRaisesRegex(RuntimeError, 'GMP'):
                build.verify_inputs()
            gmp.write_bytes(b'original GMP bytes')
            build.native_gmp.write_bytes(b'different pkg-config-selected GMP copy')
            with self.assertRaisesRegex(RuntimeError, 'GMP'):
                build.verify_inputs()
            build.native_gmp.write_bytes(gmp.read_bytes())
            probe.write_bytes(b'changed probe bytes')
            with self.assertRaisesRegex(RuntimeError, 'native'):
                build.verify_inputs()

    def test_producer_final_verification_rechecks_the_selected_compiler(self):
        with self.pinned_switch() as f:
            build = f.build
            build.args.producer_only = True
            compiler = self.compiler_fixture(build.prefix)
            build.swift_dir, build.lui, build.entitlements = (f.root / name for name in ('swift', 'lui', 'entitlements'))
            for path in (build.swift_dir, build.lui, build.entitlements):
                path.mkdir()
            build.plist = f.root / 'Info.plist'
            build.plist.write_bytes(b'plist fixture')
            build.tools = {}
            build.inputs = dict(source=self.build.source_inputs(), swift={}, lui={}, entitlements={},
                plist=self.build.sha(build.plist), signing={}, dependencies=build.dependencies(),
                toolchain=dict(hashes={}, sdk_identity={'settings': {}}, **self.build.opam_identity(build.opam)))
            build.verify_inputs()
            compiler.write_text(compiler.read_text() + '# compiler changed during native phase\n')
            with self.assertRaisesRegex(RuntimeError, 'compiler|toolchain'):
                build.verify_inputs()

    def test_probe_helper_preflight_supports_stub_and_platform_matched_objects(self):
        sys.path.insert(0, str(SCRIPTS))
        import lui_probe_host
        import inspect
        self.assertIn('preflight', inspect.signature(lui_probe_host.build).parameters,
                      'probe helper has no reusable preflight path')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            lui = root / 'lui'
            lui.mkdir()
            (lui / 'Package.swift').write_text('// preflight only\n')
            for argv in (['git', 'init', '-q', lui], ['git', '-C', lui, 'add', '.'],
                         ['git', '-C', lui, '-c', 'user.name=Build test', '-c', 'user.email=build@example.invalid',
                          'commit', '-qm', 'fixture']):
                subprocess.run(argv, check=True, capture_output=True)
            source = root / 'probe.c'
            source.write_text('void caml_startup(void) {}\nvoid lui_ocaml_start(void) {}\n')
            for platform, triple in [('macos', 'arm64-apple-macosx26.0'),
                                     ('ios-simulator', 'arm64-apple-ios26.0-simulator')]:
                obj = root / (platform + '.o')
                subprocess.run(['xcrun', 'clang', '-target', triple, '-c', source, '-o', obj],
                               check=True, capture_output=True)
                for native in (None, obj):
                    host = root / (platform + ('-native' if native else '-stub'))
                    lui_probe_host.stage(host, '/* preflight only */', 'fixture.journal-probe', 'Probe')
                    lui_probe_host.build(host, platform=platform, native_object=native, preflight=True,
                        extra_env={'JOURNAL_LUI_PACKAGE_PATH': str(lui)})
                    manifest = json.loads(next((host / 'build-cache').glob('run-*/manifest.json')).read_text())
                    self.assertEqual(manifest['status'], 'preflight-passed')
                    self.assertEqual(manifest['mode'], 'probe-object' if native else 'link-only')
                if platform == 'ios-simulator':
                    with self.assertRaises(SystemExit):
                        lui_probe_host.build(root / (platform + '-native'), platform=platform,
                            native_object=root / 'macos.o', preflight=True,
                            extra_env={'JOURNAL_LUI_PACKAGE_PATH': str(lui)})
            host = root / 'production-id'
            lui_probe_host.stage(host, '/* preflight only */', 'org.logseq.journal', 'Production')
            with self.assertRaises(SystemExit):
                lui_probe_host.build(host, native_object=root / 'macos.o', preflight=True,
                    extra_env={'JOURNAL_LUI_PACKAGE_PATH': str(lui)})
            source.write_text('int unrelated_object;\n')
            subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-macosx26.0', '-c', source,
                            '-o', root / 'unrelated.o'], check=True, capture_output=True)
            host = root / 'missing-runtime'
            lui_probe_host.stage(host, '/* preflight only */', 'fixture.journal-probe', 'Probe')
            with self.assertRaises(SystemExit):
                lui_probe_host.build(host, native_object=root / 'unrelated.o', preflight=True,
                    extra_env={'JOURNAL_LUI_PACKAGE_PATH': str(lui)})

    def test_source_toolchain_dependency_flags_and_target_separate_caches(self):
        self.assertTrue(hasattr(self, "build"), "build input fingerprint missing")
        baseline = dict(source="a", dependencies="b", toolchain="c", flags=[], target="macos")
        key = self.build.fingerprint(baseline)
        self.assertEqual(key, self.build.fingerprint(dict(reversed(list(baseline.items())))))
        for field in baseline:
            changed = dict(baseline, **{field: "changed"})
            self.assertNotEqual(key, self.build.fingerprint(changed), field)

    def test_second_process_cannot_take_live_lock(self):
        self.assertTrue(hasattr(self, "build"), "cross-process build lock missing")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "resource.lock"
            with self.build.resource_lock(path):
                code = ("import sys;sys.path.insert(0,sys.argv[1]);"
                        "from journal_build import resource_lock;from pathlib import Path;"
                        "\nwith resource_lock(Path(sys.argv[2])): pass")
                result = subprocess.run(["python3", "-c", code, str(SCRIPTS), str(path)],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("busy", result.stderr)
            with self.build.resource_lock(path):
                pass

    def test_cancellation_stops_descendant_even_when_parent_exits_first(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            ready = directory / 'child.pid'
            pipe = directory / 'writer-lifetime'
            os.mkfifo(pipe)
            reader = os.open(pipe, os.O_RDONLY | os.O_NONBLOCK)
            stop = threading.Event()
            code = '''import os,signal,sys,time
from pathlib import Path
if os.fork() == 0:
 signal.signal(signal.SIGTERM, signal.SIG_IGN)
 fd = os.open(sys.argv[2], os.O_WRONLY)
 Path(sys.argv[1]).write_text(str(os.getpid()))
 time.sleep(10)
 os._exit(0)
while True: time.sleep(1)
'''
            def cancel_when_ready():
                for _ in range(300):
                    if ready.exists() and ready.read_text():
                        os.kill(os.getpid(), signal.SIGINT)
                        return
                    if stop.wait(.01):
                        return
            sender = threading.Thread(target=cancel_when_ready, daemon=True)
            build = self.build.Build(SimpleNamespace(link_only=True, experimental_host_restamp=False), directory)
            try:
                with self.build.resource_lock(directory / 'cache.lock'):
                    sender.start()
                    with self.assertRaises(KeyboardInterrupt):
                        build.run(sys.executable, '-c', code, ready, pipe)
                    closed = False
                    for _ in range(100):
                        try:
                            closed = os.read(reader, 1) == b''
                            break
                        except BlockingIOError:
                            time.sleep(.01)
                    self.assertTrue(closed, 'cancelled descendant still holds writer before lock release')
            finally:
                os.close(reader)
                stop.set()
                sender.join(timeout=1)
                if ready.exists():
                    try:
                        os.kill(int(ready.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_link_stub_defines_current_swift_runtime_entries(self):
        self.assertTrue(hasattr(self, "build"), "link stub missing")
        required = set()
        for path in (ROOT / "swift").glob("*.swift"):
            required.update(re.findall(r'@_silgen_name\("((?:lui|journal)_ocaml_[^"]+)"\)', path.read_text()))
        with tempfile.TemporaryDirectory() as directory:
            source, obj = Path(directory) / "stub.c", Path(directory) / "stub.o"
            source.write_text(self.build.STUB)
            subprocess.run(["xcrun", "clang", "-c", str(source), "-o", str(obj)], check=True,
                           capture_output=True)
            defined = subprocess.check_output(["nm", "-U", str(obj)], text=True)
            missing = sorted(name for name in required if "_" + name not in defined)
            self.assertEqual(missing, [], "stub missing current Swift bridge entries")

    def test_producer_evidence_hash_is_checked_before_reading(self):
        self.assertTrue(hasattr(self.build, "read_evidence"), "verified producer evidence reader missing")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "producer.json"
            path.write_text('{"source_sha":"first"}')
            record = {"path": path.name, "sha256": self.build.sha(path)}
            self.assertEqual(self.build.read_evidence(record, Path(directory))["source_sha"], "first")
            path.write_text('{"source_sha":"changed"}')
            with self.assertRaisesRegex(ValueError, "hash"):
                self.build.read_evidence(record, Path(directory))

    def test_simulator_object_cannot_enter_device_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            source, obj = directory / "target.c", directory / "sim.o"
            source.write_text("int target_marker = 1;\n")
            subprocess.run(["xcrun", "clang", "-target", "arm64-apple-ios26.0-simulator",
                            "-c", str(source), "-o", str(obj)], check=True, capture_output=True)
            build = self.build.Build(SimpleNamespace(link_only=False, experimental_host_restamp=True,
                                                     platform="ios-device"), directory)
            with self.assertRaisesRegex(RuntimeError, "expected IOS"):
                build.verify_target(obj)

    @contextmanager
    def producer_fixture(self):
        """A tiny real Mach-O producer; all mutable files live outside Git."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            package = root / "opam"
            compiler = package / "bin/ocamlopt.opt"
            header = package / "lib/ocaml/caml/mlvalues.h"
            header.parent.mkdir(parents=True)
            header.write_text("/* original runtime ABI header */\n")
            native = root / "host.o"
            c = root / "host.c"
            c.write_text("void caml_startup(void) {}\nint camlMldoc; int camlXmlm;\n")
            subprocess.run(["xcrun", "clang", "-target", "arm64-apple-macosx26.0", "-c", c, "-o", native],
                           check=True, capture_output=True)
            repo = root / "repo"
            (repo / "app").mkdir(parents=True)
            platform = repo / "logseq_sync/lib/effect_runner/platform"
            platform.mkdir(parents=True)
            (repo / "app/unit.ml").write_text("let value = 1\n")
            for name in ("platform_crypto_stubs.c", "platform_crypto_stubs.h"):
                (platform / name).write_text("/* target source */\n")
            pins = {"lui": "1" * 40, "signal": "2" * 40, "datascript": "3" * 40,
                    "mldoc": "4" * 40, "xmlm": "5" * 40}
            names = {"signal": "ocaml-signal", "datascript": "datascript-ocaml-native"}
            (repo / "logseq_journal.opam.locked").write_text("\n".join(
                f'"{names.get(k, k)}.dev" "git+https://example.invalid/{k}#{v}"' for k, v in pins.items()))
            subprocess.run(["git", "init", "-q", repo], check=True, capture_output=True)
            subprocess.run(["git", "-C", repo, "add", "."], check=True, capture_output=True)
            subprocess.run(["git", "-C", repo, "-c", "user.name=Build test", "-c", "user.email=build@example.invalid",
                            "commit", "-qm", "producer"], check=True, capture_output=True)
            commit = subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip()
            with patch.object(self.build, "ROOT", repo):
                source = self.build.source_inputs()
                host_hash = self.build.sha(native)
                history = root / "consumed.cmxa"
                history.write_text("original archive")
                forced = root / "xmlm-force/xmlm.cmxa"
                cmx = root / "xmlm-force/xmlm.cmx"
                effect = root / "effect/logseq_sync_effect_runner_impl.cmxa"
                dummy = "a" * 64
                inputs = {str(history): self.build.sha(history), str(compiler): dummy, str(forced): dummy,
                          str(forced.with_suffix('.a')): dummy, str(effect): dummy,
                          str(effect.with_suffix('.a')): dummy, str(native): host_hash,
                          str(header): self.build.sha(header)}
                pre = dict(commit=commit, lui=pins['lui'], signal=pins['signal'], datascript=pins['datascript'],
                           production_native_object=str(native), production_native_object_sha256=host_hash,
                           native_source_sha256={k: v for k, v in source.items() if k.endswith('.ml')},
                           installed_lui_source_sha256={})
                link = dict(command=[str(compiler), str(effect), str(forced)], compiler_sha256=dummy,
                            compiler_version="5.3.0", production_host_sha256=host_hash,
                            direct_native_input_sha256={k: v for k, v in inputs.items() if k not in (str(native), str(header))},
                            device_c_source_sha256={p.name: self.build.sha(p) for p in platform.iterdir()},
                            patched_host_stub_archive_sha256=dummy,
                            new_dependency_provenance={k: dict(pinned_commit=pins[k],
                                installed_archive=str(package / f"lib/{k}/{k}.cmxa"), archive_sha256=dummy,
                                static_archive_sha256=dummy, installed_sources_matched_to_pinned_git={})
                                for k in ('mldoc', 'xmlm')})
                xmlm = dict(command=[str(compiler), "-a", "-linkall", "-o", str(forced), str(cmx)],
                            original_cmx_sha256=dummy, local_cmx_sha256=dummy,
                            original_object_sha256=dummy, object_bytes_identical=True)
                envelope = {'schema_version': 1}
                for name, value in [('source', pre), ('link', link), ('xmlm_force_link', xmlm)]:
                    path = root / (name + '.json')
                    path.write_text(json.dumps(value))
                    envelope[name] = dict(path=str(path), sha256=self.build.sha(path))
                    inputs[str(path)] = self.build.sha(path)
                for name in ('mldoc', 'xmlm'):
                    archive = Path(link['new_dependency_provenance'][name]['installed_archive'])
                    inputs.update({str(archive): dummy, str(archive.with_suffix('.a')): dummy})
                inputs.update({str(cmx): dummy, str(package / 'lib/xmlm/xmlm.cmx'): dummy,
                               str(effect.parent / 'liblogseq_sync_effect_runner_impl_stubs.a'): dummy})
                receipt = dict(status='built', mode='experimental-host-restamp', source_sha=commit,
                    production_link=dict(runtime_mldoc_xmlm_retained=True, cross_abi_validated=False),
                    inputs=dict(source=source, dependencies=dict(producer=dict(envelope), files=inputs,
                                compiler_version='5.3.0', xmlm='single-unit force-link; original cmx/object bytes verified')))
                receipt_path = root / 'receipt.json'
                receipt_path.write_text(json.dumps(receipt))
                envelope['validated_build'] = dict(path=str(receipt_path), sha256=self.build.sha(receipt_path))
                path = root / 'input.json'
                path.write_text(json.dumps(envelope))
                build = self.build.Build(SimpleNamespace(native_manifest=path, experimental_host_restamp=True,
                                                         link_only=False, platform='ios-device'), root)
                build.run = partial(build.run, cwd=repo)
                build.report['source_sha'], build.lui_sha = commit, pins['lui']
                yield SimpleNamespace(build=build, source=source, history=history, native=native, header=header,
                                      envelope=envelope, path=path, receipt=receipt, receipt_path=receipt_path, repo=repo)

    def test_consumed_archives_may_change_or_disappear_with_fixed_object_receipt(self):
        with self.producer_fixture() as f:
            f.history.write_text("later unrelated compilation")
            imported = f.build.imported_native(f.source)
            self.assertNotIn(str(f.history), imported['files'])
            self.assertIn(str(f.history), imported['historical_inputs'])
            f.history.unlink()
            f.build.imported_native(f.source)

    @contextmanager
    def ordinary_producer_fixture(self, *, entry=None, relative=False, warnings=False):
        """Actual OCaml link: unused Xmlm archive supplied, unit legally omitted."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            repo, package, effect = root / 'repo', root / 'package', root / 'effect'
            (repo / 'app').mkdir(parents=True)
            platform = repo / 'logseq_sync/lib/effect_runner/platform'
            platform.mkdir(parents=True)
            for name in ('platform_crypto_stubs.c', 'platform_crypto_stubs.h'):
                (platform / name).write_text('/* target source */\n')
            switch = os.environ.get('JOURNAL_TEST_SWITCH')
            if switch:
                bindir = subprocess.check_output(
                    ['opam', 'var', '--safe', '--switch', switch, 'bin'], text=True).strip()
                compiler = Path(bindir) / 'ocamlopt.opt'
            else:
                selected = shutil.which('ocamlopt')
                if selected is None:
                    self.fail('set JOURNAL_TEST_SWITCH to a prepared switch or expose ocamlopt on PATH')
                compiler = Path(selected)
            compiler = compiler.resolve()
            runtime = Path(subprocess.check_output([compiler, '-where'], text=True).strip())
            effect.mkdir()
            (effect / 'effect.ml').write_text('let value = 1\n')
            def run(*argv, cwd=root):
                subprocess.run(list(map(str, argv)), cwd=cwd, check=True, capture_output=True)
            run(compiler, '-c', effect / 'effect.ml')
            effect_archive = effect / 'logseq_sync_effect_runner_impl.cmxa'
            run(compiler, '-a', '-o', effect_archive, effect / 'effect.cmx')
            (effect / 'stub.c').write_text('int harmless_stub;\n')
            run('xcrun', 'clang', '-c', effect / 'stub.c', '-o', effect / 'stub.o')
            stub = effect / 'liblogseq_sync_effect_runner_impl_stubs.a'
            run('ar', 'rcs', stub, effect / 'stub.o')
            provenance = {}
            for name, source in [('mldoc', 'let parse text = String.length text\n'),
                                 ('xmlm', 'let make_input text = text\n')]:
                checkout = root / (name + '-source')
                checkout.mkdir()
                (checkout / (name + '.ml')).write_text(source)
                run('git', 'init', '-q', checkout)
                run('git', '-C', checkout, 'add', '.')
                run('git', '-C', checkout, '-c', 'user.name=Build test', '-c', 'user.email=build@example.invalid',
                    'commit', '-qm', name)
                pinned = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
                lib = package / 'lib' / name
                lib.mkdir(parents=True)
                (lib / (name + '.ml')).write_text(source)
                run(compiler, '-c', lib / (name + '.ml'))
                archive = lib / (name + '.cmxa')
                run(compiler, '-a', '-o', archive, lib / (name + '.cmx'))
                object_bytes = subprocess.check_output(['ar', '-p', str(archive.with_suffix('.a')), name + '.o'])
                provenance[name] = dict(pinned_commit=pinned, source_checkout=str(checkout),
                    installed_archive=str(archive), archive_sha256=self.build.sha(archive),
                    static_archive_sha256=self.build.sha(archive.with_suffix('.a')),
                    installed_sources_matched_to_pinned_git={name + '.ml': dict(
                        sha256=self.build.sha(lib / (name + '.ml')), git_path=name + '.ml')},
                    original_unit=dict(cmx_sha256=self.build.sha(lib / (name + '.cmx')),
                                       object_sha256=hashlib.sha256(object_bytes).hexdigest()))
            (repo / 'app/unit.ml').write_text(entry or 'let () = ignore (Sys.opaque_identity Mldoc.parse)\n')
            run(compiler, '-I', package / 'lib/mldoc', '-c', repo / 'app/unit.ml')
            native = root / 'host.o'
            command = list(map(str, [compiler, '-output-complete-obj', '-o', native, effect_archive,
                package / 'lib/xmlm/xmlm.cmxa', package / 'lib/mldoc/mldoc.cmxa', repo / 'app/unit.cmx']))
            if relative:
                command = [command[0]] + [os.path.relpath(arg, root) if arg.startswith(str(root) + '/') else arg
                                          for arg in command[1:]]
            if warnings:
                command[1:1] = ['-w', '@1..3']
            run(*command)
            pins = dict(lui='1' * 40, signal='2' * 40, datascript='3' * 40)
            lock_names = dict(signal='ocaml-signal', datascript='datascript-ocaml-native')
            all_pins = {**pins, **{name: item['pinned_commit'] for name, item in provenance.items()}}
            (repo / 'logseq_journal.opam.locked').write_text('\n'.join(
                f'"{lock_names.get(name, name)}.dev" "git+https://example.invalid/{name}#{commit}"'
                for name, commit in all_pins.items()))
            run('git', 'init', '-q', repo)
            run('git', '-C', repo, 'add', 'app/unit.ml', 'logseq_journal.opam.locked', 'logseq_sync')
            run('git', '-C', repo, '-c', 'user.name=Build test', '-c', 'user.email=build@example.invalid',
                'commit', '-qm', 'producer')
            commit = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
            with patch.object(self.build, 'ROOT', repo):
                source = self.build.source_inputs()
                pre = dict(commit=commit, **pins, production_native_object=str(native),
                    production_native_object_sha256=self.build.sha(native),
                    native_source_sha256={'app/unit.ml': self.build.sha(repo / 'app/unit.ml')},
                    installed_lui_source_sha256={})
                inputs = [effect_archive, effect_archive.with_suffix('.a'), stub,
                    repo / 'app/unit.cmx', repo / 'app/unit.o']
                for item in provenance.values():
                    archive = Path(item['installed_archive'])
                    inputs.extend([archive, archive.with_suffix('.a')])
                link = dict(command=command, working_directory=str(root), compiler_sha256=self.build.sha(compiler),
                    compiler_version=subprocess.check_output([compiler, '-version'], text=True).strip(),
                    production_host_sha256=self.build.sha(native),
                    direct_native_input_sha256={str(p): self.build.sha(p) for p in inputs},
                    device_c_source_sha256={p.name: self.build.sha(p) for p in platform.iterdir()},
                    patched_host_stub_archive_sha256=self.build.sha(stub), new_dependency_provenance=provenance)
                envelope = dict(schema_version=2)
                path = root / 'input.json'
                def save():
                    for name, value in [('source', pre), ('link', link)]:
                        record = root / (name + '.json')
                        record.write_text(json.dumps(value))
                        envelope[name] = dict(path=str(record), sha256=self.build.sha(record))
                    path.write_text(json.dumps(envelope))
                save()
                build = self.build.Build(SimpleNamespace(native_manifest=path, experimental_host_restamp=True,
                    link_only=False, platform='ios-simulator'), root)
                build.run = partial(build.run, cwd=repo)
                build.report['source_sha'], build.lui_sha = commit, pins['lui']
                yield SimpleNamespace(build=build, source=source, link=link, pre=pre, native=native,
                    envelope=envelope, path=path, root=root, save=save, runtime=runtime, provenance=provenance)

    @contextmanager
    def native_dune_producer(self):
        """A real Dune complete-object rule, including removable host C providers."""
        with self.ordinary_producer_fixture() as f:
            repo = self.build.ROOT
            original_compiler = Path(f.link['command'][0])
            compiler = f.root / 'package/bin/ocamlopt.opt'
            compiler.parent.mkdir(exist_ok=True)
            compiler.symlink_to(original_compiler)
            (f.root / 'package/lib/ocaml').symlink_to(f.runtime)
            switch = os.environ.get('JOURNAL_TEST_SWITCH')
            dune = (Path(subprocess.check_output(['opam', 'var', '--safe', '--switch', switch, 'bin'],
                                                text=True).strip()) / 'dune') if switch else Path(shutil.which('dune'))
            effect = repo / 'logseq_sync/lib/effect_runner'
            effect.mkdir(exist_ok=True)
            original = f.root / 'effect'
            for path in original.glob('*'):
                if path.is_file():
                    shutil.copyfile(path, effect / path.name)
            c = effect / 'platform_crypto_stubs.c'
            c.write_text('int logseq_transport_dns_start(void) { return 1; }\n'
                         'int logseq_journal_crypto_call(void) { return 1; }\n')
            obj = c.with_suffix('.o')
            subprocess.run(['xcrun', 'clang', '-c', c, '-o', obj], check=True, capture_output=True)
            stub = effect / 'liblogseq_sync_effect_runner_impl_stubs.a'
            subprocess.run(['ar', 'rcs', stub, obj], check=True, capture_output=True)
            archive = effect / 'logseq_sync_effect_runner_impl.cmxa'
            subprocess.run([compiler, '-a', '-o', archive, effect / 'effect.cmx',
                            '-cclib', '-llogseq_sync_effect_runner_impl_stubs'], check=True, capture_output=True)
            # The fixture rule is opaque to the builder: it must read actual Dune argv.
            command = [str(compiler), '-output-complete-obj', '-w', '@1..3', '-o', 'app/native_embed.exe.o',
                       '-I', 'logseq_sync/lib/effect_runner', 'logseq_sync/lib/effect_runner/' + archive.name,
                       f.provenance['xmlm']['installed_archive'], f.provenance['mldoc']['installed_archive'],
                       'app/unit.cmx']
            def atom(value):
                return json.dumps(str(value))
            (repo / 'dune-project').write_text('(lang dune 3.0)\n')
            (repo / 'app/dune').write_text('(rule (target native_embed.exe.o) (deps libgmp.a unit.cmx unit.o '
                + ' '.join(atom('../logseq_sync/lib/effect_runner/' + path.name)
                           for path in effect.iterdir() if path.suffix in ('.cmxa', '.a'))
                + ') (action (chdir .. (run ' + ' '.join(map(atom, command)) + '))))\n')
            shutil.copyfile(stub, repo / 'app/libgmp.a')
            workspace = f.root / 'workspace'
            workspace.mkdir()
            dune_dir = workspace / 'dune'
            def opam(*argv):
                self.assertEqual(argv[:3], ('exec', '--', 'dune'))
                return f.build.run(dune, *argv[3:])
            f.build.opam = opam
            f.build.args = SimpleNamespace(platform='macos', configuration='release', jobs=1,
                producer_only=True, link_only=False, experimental_host_restamp=False,
                native_manifest=None, probe_native_object=None)
            f.build.report['mode'] = 'native-producer'
            f.build.tools = {'swift': '/unexpected-swift-command'}
            f.build.prefix = f.root / 'package'
            subprocess.run(['git', '-C', repo, 'add', '.'], check=True, capture_output=True)
            subprocess.run(['git', '-C', repo, '-c', 'user.name=Build test', '-c', 'user.email=build@example.invalid',
                            'commit', '-qm', 'native rule'], check=True, capture_output=True)
            f.build.report['source_sha'] = subprocess.check_output(['git', '-C', repo, 'rev-parse', 'HEAD'], text=True).strip()
            f.build.inputs = dict(source=self.build.source_inputs(), lui_sha=f.pre['lui'],
                toolchain=dict(compiler_sha256=self.build.sha(compiler),
                               opam_prefix=str(f.build.prefix)),
                dependencies=dict(pins={name + ('.0.1.0' if name == 'ocaml-signal' else '.dev'): dict(resolved_sha=commit,
                    checkout=f.provenance[name]['source_checkout'] if name in f.provenance else str(repo))
                    for name, commit in [('mldoc', f.provenance['mldoc']['pinned_commit']),
                                         ('xmlm', f.provenance['xmlm']['pinned_commit']),
                                         ('ocaml-signal', f.pre['signal']),
                                         ('datascript-ocaml-native', f.pre['datascript'])]}))
            f.build.opam('exec', '--', 'dune', 'build', '--root', repo, '--no-config',
                         '--cache=disabled', '--build-dir', dune_dir, '--profile', 'release',
                         '-j', '1', 'app/native_embed.exe.o')
            native = dune_dir / 'default/app/native_embed.exe.o'
            f.build.report['native_object'] = dict(path=str(native), sha256=self.build.sha(native), mode='native-producer')
            yield SimpleNamespace(**vars(f), workspace=workspace, original_native=native, compiler=compiler)

    def test_producer_uses_current_dune_rule_even_after_a_noop_build(self):
        self.assertTrue(hasattr(self.build.Build, 'produce_native'), 'producer-only entry is missing')
        with self.native_dune_producer() as f:
            for attempt in range(2):
                if attempt:
                    f.build.opam('exec', '--', 'dune', 'build', '--root', self.build.ROOT, '--no-config',
                        '--cache=disabled', '--build-dir', f.workspace / 'dune', '--profile', 'release',
                        '-j', '1', 'app/native_embed.exe.o')
                envelope_path = f.build.compile(f.workspace)
                envelope = json.loads(envelope_path.read_text())
                self.assertEqual(envelope['schema_version'], 2)
                self.assertNotIn('validated_build', envelope)
                source = self.build.read_evidence(envelope['source'], envelope_path.parent)
                link = self.build.read_evidence(envelope['link'], envelope_path.parent)
                self.assertEqual(link['compiler_sha256'], self.build.sha(f.compiler))
                self.assertEqual(self.build.sha(f.original_native), f.build.report['native_object']['sha256'])
                self.assertNotEqual(source['production_native_object'], str(f.original_native))
                f.build.args.native_manifest = envelope_path
                imported = f.build.imported_native(f.build.inputs['source'])
                f.build.args.native_manifest = None
                self.assertEqual(imported['ocaml_units'], dict(runtime=True, mldoc=True, xmlm=False))
                inputs = imported['files']
                for name, digest in link['direct_native_input_sha256'].items():
                    self.assertEqual(inputs[name], digest)
                self.assertNotIn('artifact', f.build.report)
                self.assertFalse(f.build.report['cross_abi_validated'])
                self.assertFalse(f.build.report['runtime_acceptance'])
                self.assertEqual(f.build.report['producer']['envelope']['sha256'], self.build.sha(envelope_path))
                if not attempt:
                    first_path = envelope_path
                    first_bytes = envelope_path.read_bytes()
                    first_mtime = envelope_path.stat().st_mtime_ns
            self.assertEqual(first_path, envelope_path)
            self.assertEqual(first_bytes, envelope_path.read_bytes())
            self.assertEqual(first_mtime, envelope_path.stat().st_mtime_ns, 'immutable producer records were overwritten')
            links = [record for record in f.build.report['commands'] if record['phase'] == 'producer-link'
                     and record['argv'][0] == str(f.compiler)]
            self.assertEqual(len(links), 1, 'hot producer unexpectedly linked again')

    def test_producer_refuses_a_rule_with_unbound_linker_inputs_before_running_it(self):
        self.assertTrue(hasattr(self.build.Build, 'produce_native'), 'producer-only entry is missing')
        with self.native_dune_producer() as f:
            path = self.build.ROOT / 'app/dune'
            path.write_text(path.read_text().replace('"-w"', '"-ccopt" "@unbound.rsp" "-w"'))
            f.build.inputs['source'] = self.build.source_inputs()
            with self.assertRaisesRegex(ValueError, 'unsupported|native.*argument'):
                f.build.produce_native(f.original_native, f.workspace)
            self.assertNotIn('producer', f.build.report)

    def test_producer_reuse_rechecks_original_object_and_immutable_records(self):
        self.assertTrue(hasattr(self.build.Build, 'produce_native'), 'producer-only entry is missing')
        for changed in ('original-object', 'evidence'):
            with self.subTest(changed=changed), self.native_dune_producer() as f:
                envelope = f.build.produce_native(f.original_native, f.workspace)
                if changed == 'original-object':
                    f.original_native.write_bytes(f.original_native.read_bytes() + b'changed')
                else:
                    record = json.loads(envelope.read_text())['link']
                    Path(record['path']).write_text('{}')
                with self.assertRaisesRegex((RuntimeError, ValueError), 'hash|changed|identity'):
                    f.build.produce_native(f.original_native, f.workspace)

    def test_producer_only_receipt_cannot_authorize_historical_target_inputs(self):
        with self.ordinary_producer_fixture() as f:
            imported = f.build.imported_native(f.source)
            receipt = dict(status='native-produced', mode='native-producer', source_sha=f.pre['commit'],
                inputs=dict(dependencies=imported), production_link=dict(ocaml_units=imported['ocaml_units']))
            receipt_path = f.root / 'producer-receipt.json'
            receipt_path.write_text(json.dumps(receipt))
            f.envelope['validated_build'] = dict(path=str(receipt_path), sha256=self.build.sha(receipt_path))
            f.save()
            with self.assertRaisesRegex(ValueError, 'receipt'):
                f.build.imported_native(f.source)

    def test_ordinary_xmlm_input_allows_dead_code_elimination(self):
        with self.ordinary_producer_fixture() as f:
            imported = f.build.imported_native(f.source)
            self.assertEqual(imported['ocaml_units'], dict(runtime=True, mldoc=True, xmlm=False))
            self.assertEqual(imported['schema_version'], 2)
            archive = f.provenance['xmlm']['installed_archive']
            self.assertEqual(imported['files'][archive], f.provenance['xmlm']['archive_sha256'])

    def test_ordinary_producer_accepts_real_warning_and_relative_argv(self):
        for option in ('warnings', 'relative'):
            with self.subTest(option=option), self.ordinary_producer_fixture(**{option: True}) as f:
                self.assertEqual(f.build.imported_native(f.source)['ocaml_units']['xmlm'], False)

    def test_ordinary_producer_rejects_unbound_source_and_linker_arguments(self):
        with self.ordinary_producer_fixture() as f:
            f.build.imported_native(f.source)
            original = list(f.link['command'])
            for args in ([str(f.root / 'unbound.ml')], [str(f.root / 'unbound.c')],
                         ['-cclib', '-lunbound'], ['-ccopt', str(f.root / 'unbound.o')]):
                with self.subTest(args=args):
                    f.link['command'] = original + args
                    f.save()
                    with self.assertRaisesRegex(ValueError, 'input|argument|unsupported|library'):
                        f.build.imported_native(f.source)

    def test_ordinary_producer_rejects_conflicting_companion_identity(self):
        with self.ordinary_producer_fixture() as f:
            f.build.imported_native(f.source)
            archive = Path(f.provenance['xmlm']['installed_archive']).with_suffix('.a')
            f.link['direct_native_input_sha256'][str(archive)] = 'f' * 64
            f.save()
            with self.assertRaisesRegex(ValueError, 'conflict|hash|identity'):
                f.build.imported_native(f.source)

    def test_ordinary_producer_rejects_split_cclib_input(self):
        with self.ordinary_producer_fixture() as f:
            f.build.imported_native(f.source)
            extra = f.root / 'unrecorded.o'
            shutil.copyfile(f.root / 'effect/stub.o', extra)
            f.link['command'].extend(['-cclib', '-L' + str(f.root) + ' ' + str(extra)])
            subprocess.run(f.link['command'], cwd=f.root, check=True, capture_output=True)
            f.pre['production_native_object_sha256'] = self.build.sha(f.native)
            f.link['production_host_sha256'] = self.build.sha(f.native)
            f.save()
            with self.assertRaisesRegex(ValueError, 'input|argument|token'):
                f.build.imported_native(f.source)

    def test_ordinary_producer_rejects_cclib_option_disguised_as_object(self):
        with self.ordinary_producer_fixture() as f:
            f.build.imported_native(f.source)
            extra = f.root / 'extra.o'
            shutil.copyfile(f.root / 'effect/stub.o', extra)
            decoy = f.root / '-lextra.o'
            decoy.write_bytes(b'not the object selected by Darwin ld\n')
            f.link['direct_native_input_sha256'][str(decoy)] = self.build.sha(decoy)
            f.link['command'].extend(['-cclib', '-L' + str(f.root), '-cclib', '-lextra.o'])
            subprocess.run(f.link['command'], cwd=f.root, check=True, capture_output=True)
            f.pre['production_native_object_sha256'] = self.build.sha(f.native)
            f.link['production_host_sha256'] = self.build.sha(f.native)
            f.save()
            with self.assertRaisesRegex(ValueError, 'input|argument|unsupported'):
                f.build.imported_native(f.source)

    def test_ordinary_receipt_survives_removed_historical_cmx_symlink(self):
        with self.ordinary_producer_fixture() as f:
            cmx = Path(f.provenance['xmlm']['installed_archive']).with_suffix('.cmx')
            saved = f.root / 'historical-xmlm.cmx'
            cmx.rename(saved)
            cmx.symlink_to(saved)
            imported = f.build.imported_native(f.source)
            receipt = dict(status='built', mode='experimental-host-restamp', source_sha=f.pre['commit'],
                production_link=dict(ocaml_units=imported['ocaml_units'], cross_abi_validated=False),
                inputs=dict(dependencies=imported))
            path = f.root / 'receipt.json'
            path.write_text(json.dumps(receipt))
            f.envelope['validated_build'] = dict(path=str(path), sha256=self.build.sha(path))
            f.path.write_text(json.dumps(f.envelope))
            f.build.imported_native(f.source)
            cmx.unlink()
            imported = f.build.imported_native(f.source)
            self.assertNotIn(str(cmx), imported['files'])
            self.assertIn(str(cmx), imported['historical_inputs'])

    def test_ordinary_producer_rejects_changed_dependency_and_actual_inputs(self):
        with self.ordinary_producer_fixture() as f:
            f.build.imported_native(f.source)  # Prove the valid baseline first.
            original = json.loads(json.dumps(f.link))
            cases = ('pin', 'compiler', 'archive', 'static_archive', 'cmx', 'object', 'source',
                     'source_git_path', 'linked_archive', 'unrecorded_input', 'extra_input')
            for case in cases:
                with self.subTest(case=case):
                    f.link.clear(); f.link.update(json.loads(json.dumps(original)))
                    item = f.link['new_dependency_provenance']['xmlm']
                    if case == 'pin': item['pinned_commit'] = 'f' * 40
                    elif case == 'compiler': f.link['compiler_sha256'] = 'f' * 64
                    elif case == 'archive': item['archive_sha256'] = 'f' * 64
                    elif case == 'static_archive': item['static_archive_sha256'] = 'f' * 64
                    elif case in ('cmx', 'object'): item['original_unit'][case + '_sha256'] = 'f' * 64
                    elif case == 'source': item['installed_sources_matched_to_pinned_git']['xmlm.ml']['sha256'] = 'f' * 64
                    elif case == 'source_git_path': item['installed_sources_matched_to_pinned_git']['xmlm.ml']['git_path'] = 'missing.ml'
                    elif case == 'linked_archive':
                        f.link['command'].remove(item['installed_archive'])
                    elif case == 'unrecorded_input':
                        f.link['direct_native_input_sha256'].pop(item['installed_archive'])
                    else:
                        other = f.root / 'unrecorded.cmxa'
                        shutil.copyfile(item['installed_archive'], other)
                        f.link['command'].append(str(other))
                    f.save()
                    with self.assertRaisesRegex((ValueError, RuntimeError), 'commit|compiler|hash|XMLm|input|archive|unit|source|path'):
                        f.build.imported_native(f.source)

    def test_ordinary_producer_still_requires_used_mldoc(self):
        with self.ordinary_producer_fixture(entry='let () = ()\n') as f:
            with self.assertRaisesRegex(ValueError, 'mldoc|Mldoc'):
                f.build.imported_native(f.source)

    def test_ordinary_producer_rejects_missing_runtime_and_unresolved_xmlm(self):
        with self.ordinary_producer_fixture() as f:
            f.build.imported_native(f.source)
            for case in ('runtime', 'unresolved Xmlm'):
                with self.subTest(case=case):
                    c = f.root / 'invalid.c'
                    c.write_text('int camlMldoc;\n' + ('' if case == 'runtime' else
                        'void caml_startup(void) {}\nextern int camlXmlm; int *reference = &camlXmlm;\n'))
                    subprocess.run(['xcrun', 'clang', '-c', c, '-o', f.native], check=True, capture_output=True)
                    f.pre['production_native_object_sha256'] = self.build.sha(f.native)
                    f.link['production_host_sha256'] = self.build.sha(f.native)
                    f.save()
                    with self.assertRaisesRegex(ValueError, 'runtime|unresolved|XMLm|Xmlm'):
                        f.build.imported_native(f.source)

    def test_ordinary_final_link_reports_xmlm_absence_without_all_retained_claim(self):
        with self.ordinary_producer_fixture() as f:
            f.build.imported_native(f.source)
            f.build.target_c = f.root / 'target.o'
            c = f.root / 'target.c'
            c.write_text('void logseq_transport_dns_start(void) {}\n'
                'void logseq_journal_crypto_call(void) {}\nint main(void) { return 0; }\n')
            subprocess.run(['xcrun', 'clang', '-c', c, '-o', f.build.target_c], check=True, capture_output=True)
            product = f.root / 'JournalApp'
            f.build.link_map = f.root / 'link-map.txt'
            subprocess.run(['xcrun', 'clang', f.native, f.build.target_c, '-o', product,
                '-Wl,-map,' + str(f.build.link_map)], check=True, capture_output=True)
            objects = f.root / 'JournalApp.product'
            objects.mkdir()
            (objects / 'Objects.LinkFileList').write_text('')
            f.build.verify_production_link(product)
            observed = f.build.report['production_link']
            self.assertEqual(observed['ocaml_units'], dict(runtime=True, mldoc=True, xmlm=False))
            self.assertNotIn('runtime_mldoc_xmlm_retained', observed)
            self.assertIs(observed['cross_abi_validated'], False)

    def test_ordinary_receipt_records_actual_retention_and_keeps_history(self):
        with self.ordinary_producer_fixture() as f:
            imported = f.build.imported_native(f.source)
            expected_units = dict(imported['ocaml_units'])
            receipt = dict(status='built', mode='experimental-host-restamp', source_sha=f.pre['commit'],
                production_link=dict(ocaml_units=imported['ocaml_units'], cross_abi_validated=False),
                inputs=dict(dependencies=imported))
            receipt_path = f.root / 'receipt.json'
            def save_receipt():
                receipt_path.write_text(json.dumps(receipt))
                f.envelope['validated_build'] = dict(path=str(receipt_path), sha256=self.build.sha(receipt_path))
                f.path.write_text(json.dumps(f.envelope))
            save_receipt()
            accepted = f.build.imported_native(f.source)
            self.assertEqual(accepted['ocaml_units']['xmlm'], False)
            receipt['production_link']['ocaml_units'] = dict(runtime=True, mldoc=True, xmlm=True)
            save_receipt()
            with self.assertRaisesRegex(ValueError, 'receipt|retention|unit'):
                f.build.imported_native(f.source)
            receipt['inputs']['dependencies']['ocaml_units'] = dict(runtime=True, mldoc=True, xmlm=True)
            save_receipt()
            with self.assertRaisesRegex(ValueError, 'receipt|retention|unit'):
                f.build.imported_native(f.source)
            receipt['production_link'].pop('ocaml_units')
            receipt['production_link']['runtime_mldoc_xmlm_retained'] = True
            save_receipt()
            with self.assertRaisesRegex(ValueError, 'receipt|retention|unit'):
                f.build.imported_native(f.source)
            receipt['production_link'].pop('runtime_mldoc_xmlm_retained')
            receipt['production_link']['ocaml_units'] = dict(expected_units)
            receipt['inputs']['dependencies']['ocaml_units'] = dict(expected_units)
            save_receipt()
            archive = Path(f.provenance['xmlm']['installed_archive'])
            archive.unlink()
            accepted = f.build.imported_native(f.source)
            self.assertIn(str(archive), accepted['historical_inputs'])
            self.assertNotIn(str(archive), accepted['files'])

    def test_builder_only_commit_keeps_exact_native_source_identity(self):
        with self.producer_fixture() as f:
            (f.repo / 'tool').mkdir()
            (f.repo / 'tool/builder.txt').write_text('new builder revision')
            subprocess.run(['git', '-C', f.repo, 'add', '.'], check=True, capture_output=True)
            subprocess.run(['git', '-C', f.repo, '-c', 'user.name=Build test', '-c', 'user.email=build@example.invalid',
                            'commit', '-qm', 'builder only'], check=True, capture_output=True)
            f.build.report['source_sha'] = subprocess.check_output(
                ['git', '-C', f.repo, 'rev-parse', 'HEAD'], text=True).strip()
            imported = f.build.imported_native(self.build.source_inputs())
            self.assertEqual(imported['source_sha'], f.receipt['source_sha'])
            f.source['app/unit.ml'] = 'f' * 64
            with self.assertRaisesRegex(ValueError, 'native sources'):
                f.build.imported_native(f.source)

    def test_production_lui_pin_rejects_untracked_swift_sources(self):
        with self.producer_fixture() as f:
            lui = f.repo.parent / 'lui'
            target = lui / 'Sources/Backend'
            target.mkdir(parents=True)
            (lui / 'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\n'
                'let package = Package(name: "Fixture", targets: [.target(name: "Backend")])\n')
            (target / 'Tracked.swift').write_text('func tracked() {}\n')
            subprocess.run(['git', 'init', '-q', lui], check=True, capture_output=True)
            subprocess.run(['git', '-C', lui, 'add', '.'], check=True, capture_output=True)
            subprocess.run(['git', '-C', lui, '-c', 'user.name=Build test', '-c', 'user.email=build@example.invalid',
                            'commit', '-qm', 'pinned LUI'], check=True, capture_output=True)
            pinned = subprocess.check_output(['git', '-C', lui, 'rev-parse', 'HEAD'], text=True).strip()
            (target / 'Unpinned.swift').write_text('func unpinned() {}\n')
            (f.repo / 'logseq_journal.opam.locked').write_text(f'"git+https://github.com/logseq/lui.git#{pinned}"')
            (f.repo / 'apple').mkdir()
            (f.repo / 'apple/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='fixture.journal',
                CFBundleExecutable='JournalApp', CFBundleVersion='1.0', CFBundleShortVersionString='1.0')))
            f.build.args.lui_package, f.build.args.deployment_target = lui, '26.0'
            f.build.args.version = f.build.args.build_number = None
            with patch.object(f.build, 'imported_native', side_effect=AssertionError('unpinned LUI reached native import')):
                with self.assertRaisesRegex(RuntimeError, 'LUI Swift checkout must be clean'):
                    f.build.preflight()

    def test_fixed_object_source_and_current_c_headers_remain_strict(self):
        for case in ('object', 'source_sha', 'native_source', 'target_c', 'target_header', 'runtime_header'):
            with self.subTest(case=case), self.producer_fixture() as f:
                if case == 'object':
                    f.native.write_bytes(f.native.read_bytes() + b'changed')
                elif case == 'source_sha':
                    f.build.report['source_sha'] = 'f' * 40
                elif case == 'runtime_header':
                    f.header.write_text('changed ABI header')
                else:
                    key = {'native_source': 'app/unit.ml', 'target_c': 'logseq_sync/lib/effect_runner/platform/platform_crypto_stubs.c',
                           'target_header': 'logseq_sync/lib/effect_runner/platform/platform_crypto_stubs.h'}[case]
                    f.source[key] = 'f' * 64
                with self.assertRaises((ValueError, RuntimeError)):
                    f.build.imported_native(f.source)

    def test_producer_and_receipt_mismatches_cannot_authorize_an_object(self):
        for case in ('producer_bytes', 'receipt_bytes', 'receipt_source', 'receipt_object', 'receipt_evidence'):
            with self.subTest(case=case), self.producer_fixture() as f:
                if case == 'producer_bytes':
                    Path(f.envelope['link']['path']).write_text('{}')
                elif case == 'receipt_bytes':
                    f.receipt_path.write_text('{}')
                else:
                    if case == 'receipt_source':
                        f.receipt['source_sha'] = 'f' * 40
                    elif case == 'receipt_object':
                        f.receipt['inputs']['dependencies']['files'][str(f.native)] = 'f' * 64
                    else:
                        f.receipt['inputs']['dependencies']['producer']['source']['sha256'] = 'f' * 64
                    f.receipt_path.write_text(json.dumps(f.receipt))
                    f.envelope['validated_build']['sha256'] = self.build.sha(f.receipt_path)
                    f.path.write_text(json.dumps(f.envelope))
                with self.assertRaises((ValueError, RuntimeError)):
                    f.build.imported_native(f.source)

    def test_device_sdk_cannot_be_replaced_by_simulator_sdk(self):
        sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip())
        version = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
        self.assertTrue(hasattr(self.build, 'sdk_identity'), 'SDK identity validator missing')
        with self.assertRaisesRegex(ValueError, 'SDK'):
            self.build.sdk_identity(sdk, 'iphoneos', version)


if __name__ == "__main__":
    unittest.main()
