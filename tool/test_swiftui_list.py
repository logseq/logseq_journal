"""Check application row projection and explicit scroll completion ownership.

Native geometry and input retention are covered by the XCTest sources in
apple-tests/native-list against the isolated production warm-start host.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
for command in [
    ['dune', 'exec', 'test/journal_semantics_test.exe'],
    ['dune', 'exec', 'test/journal_timeline_state_test.exe'],
    ['python3', 'tool/test_macos_regressions.py', '--case', 'mutation'],
]:
    subprocess.run(command, cwd=root, check=True)
