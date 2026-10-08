"""Production owner with synthetic signed issuer; no real login, Keychain or GUI."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='journal-cognito-') as directory:
    destination = Path(directory)
    sources = ['JournalPlatformWire.swift', 'JournalPlatformServices.swift',
               'JournalAuthentication.swift', 'JournalCognitoOAuth.swift', 'JournalCognitoSession.swift']
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path',
        str(destination/'modules'), *[str(root/'swift'/s) for s in sources],
        str(root/'apple-tests/authentication/JournalCognitoTests.swift'),
        '-o', str(destination/'tests')], check=True)
    subprocess.run([str(destination/'tests')], check=True, timeout=60)
