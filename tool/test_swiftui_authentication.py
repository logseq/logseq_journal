"""Exercise the native authentication presentation owner through public actions."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='journal-authentication-') as directory:
    executable = Path(directory) / 'auth-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6',
                    str(root / 'swift/JournalAuthentication.swift'),
                    str(root / 'apple-tests/authentication/JournalAuthenticationTests.swift'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
