#!/usr/bin/env python3
"""Small build-boundary checks; no device, dependency install or large build."""
import importlib.util
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
import sys
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tool/build_journal_apple.sh"


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


class CacheBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / "tool/journal_build.py"
        if not path.exists():
            return
        spec = importlib.util.spec_from_file_location("journal_build", path)
        cls.build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.build)

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
                result = subprocess.run(["python3", "-c", code, str(ROOT / "tool"), str(path)],
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
