#!/usr/bin/env python3
"""Real Unix peer/process boundary tests with a compiled synthetic Swift server.

No Simulator, account, database or graph is opened. The boundary owner is the
native IPC adapter; an App reducer cannot execute peer credentials or sockets.
"""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import select
import threading
import time
import stat
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / 'swift/JournalAcceptanceIdentity.swift'
FIXTURE = ROOT / 'apple-tests/acceptance-identity/ServerFixture.swift'


class IPCIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.external = tempfile.TemporaryDirectory(prefix='journal-identity-ipc-', dir='/tmp')
        cls.base = Path(cls.external.name).resolve()
        cls.binary = cls.base / 'identity-server'
        cls.compile_result = None
        if SERVER.exists() and FIXTURE.exists():
            cls.compile_result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6',
                '-module-cache-path', str(cls.base / 'module-cache'), '-D', 'JOURNAL_ACCEPTANCE_TESTING', str(SERVER), str(FIXTURE), '-o', str(cls.binary)],
                capture_output=True, text=True, timeout=60)
        spec = importlib.util.spec_from_file_location('capture_acceptance', ROOT / 'tool/capture_acceptance.py')
        cls.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.api)

    @classmethod
    def tearDownClass(cls):
        cls.external.cleanup()

    def setUp(self):
        self.assertIsNotNone(self.compile_result, 'Simulator-only IPC implementation is missing')
        self.assertEqual(self.compile_result.returncode, 0, self.compile_result.stderr)
        self.temp = tempfile.TemporaryDirectory(prefix='case-', dir=self.base)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.path = self.directory / 'identity.sock'
        self.process = None
        self.challenge = '44444444-4444-4444-8444-444444444444'

    def start(self, mode='normal'):
        self.process = subprocess.Popen([str(self.binary), str(self.path), mode],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop)
        self.assertEqual(self.process.stdout.readline().strip(), 'ready', self.process.stderr.read() if self.process.poll() is not None else '')

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        if self.process:
            self.process.stdout.close();self.process.stderr.close()
            self.process = None

    def query(self, **kwargs):
        return self.api.query_identity_socket(self.path, self.binary, self.challenge, **kwargs)

    def test_real_peer_pid_uid_image_and_nonce(self):
        self.start()
        response = self.query()
        self.assertEqual(response['pid'], self.process.pid)
        self.assertEqual(response['challenge'], self.challenge)
        self.assertEqual(response['executable_sha256'], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)

    def test_wrong_executable_rejected_even_if_json_claims_correct_identity(self):
        self.start()
        with self.assertRaises(self.api.Rejected) as error:
            self.api.query_identity_socket(self.path, Path(sys.executable), self.challenge)
        self.assertEqual(error.exception.code, 'runtime-peer-mismatch')

    def test_replay_wrong_pid_and_extra_secret_fields_rejected(self):
        for mode in ('replay', 'wrong-pid', 'extra-field'):
            with self.subTest(mode=mode):
                self.start(mode)
                with self.assertRaises(self.api.Rejected) as error:
                    self.query()
                self.assertEqual(error.exception.code, 'runtime-identity-mismatch')
                self.assertNotIn('synthetic-secret', str(error.exception))
                self.stop()
                self.path.unlink(missing_ok=True)

    def test_missing_listener_unavailable_and_insecure_socket_rejected(self):
        with self.assertRaises(self.api.Rejected) as error:
            self.query()
        self.assertEqual(error.exception.code, 'runtime-identity-unavailable')
        self.start()
        self.path.chmod(0o666)
        with self.assertRaises(self.api.Rejected) as error:
            self.query()
        self.assertEqual(error.exception.code, 'runtime-peer-mismatch')

    def test_timeout_and_oversized_response_fail_without_raw_output(self):
        for mode in ('timeout', 'oversize'):
            with self.subTest(mode=mode):
                self.start(mode)
                with self.assertRaises(self.api.Rejected) as error:
                    self.query(timeout=0.2)
                self.assertIn(error.exception.code, {'runtime-identity-unavailable', 'runtime-identity-mismatch'})
                self.assertNotIn('synthetic-secret', str(error.exception))
                self.stop()
                self.path.unlink(missing_ok=True)

    def test_server_refuses_malformed_oversized_and_unknown_request_fields(self):
        self.start()
        for request in (b'not json\n', b'x' * 2048 + b'\n',
                        json.dumps({'schema_version': 1, 'challenge': self.challenge, 'token': 'synthetic-secret'}).encode()+b'\n'):
            with self.subTest(size=len(request)):
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(3);client.connect(str(self.path));client.sendall(request)
                    try:
                        response = client.recv(4096)
                    except ConnectionResetError:
                        response = b''
                    self.assertNotIn(b'synthetic-secret', response)
                    self.assertNotIn(self.challenge.encode(), response)

    def test_start_refuses_symlink_and_live_socket_is_not_deleted(self):
        target = self.directory / 'keep'
        target.write_text('keep')
        self.path.symlink_to(target)
        result = subprocess.run([str(self.binary), str(self.path), 'normal'], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), 'keep')
        self.path.unlink()
        self.start()
        other = subprocess.run([str(self.binary), str(self.path), 'normal'], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(other.returncode, 0)
        self.assertEqual(self.query()['pid'], self.process.pid)

    def test_partial_request_has_total_deadline_and_stop_never_waits_for_peer(self):
        self.start('stop-reading')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(self.path))
            client.sendall(b' ')
            readable, _, _ = select.select([self.process.stdout], [], [], 0.7)
            self.assertTrue(readable, 'main-actor stop blocked behind an incomplete peer request')
            self.assertEqual(self.process.stdout.readline().strip(), 'stopped')
        self.stop(); self.path.unlink(missing_ok=True)
        self.start()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(2);client.connect(str(self.path))
            start = time.monotonic()
            closed = False
            for _ in range(8):
                try:
                    client.sendall(b' ')
                    ready, _, _ = select.select([client], [], [], 0.2)
                    if ready:
                        client.recv(4096);closed = True;break
                except (BrokenPipeError, ConnectionResetError):
                    closed = True;break
            self.assertTrue(closed, 'slow peer exceeded absolute request deadline')
            self.assertLess(time.monotonic() - start, 1.5)

    def test_disabled_mode_does_not_create_endpoint(self):
        result = subprocess.run([str(self.binary), str(self.path), 'disabled'], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.path.exists())


if __name__ == '__main__':
    unittest.main()
