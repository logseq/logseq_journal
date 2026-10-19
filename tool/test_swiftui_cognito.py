"""Production owner with synthetic signed issuer; no real login, Keychain or GUI."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='journal-cognito-') as directory:
    destination = Path(directory)
    sources = ['JournalPlatformWire.swift', 'JournalPlatformServices.swift',
               'JournalAuthentication.swift', 'JournalCognitoOAuth.swift', 'JournalCognitoSession.swift']
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-Xfrontend', '-disable-sandbox', '-module-cache-path',
        str(destination/'modules'), *[str(root/'swift'/s) for s in sources],
        str(root/'apple-tests/authentication/JournalCognitoTests.swift'),
        '-o', str(destination/'tests')], check=True)
    # Generate a synthetic issuer key entirely in this private temporary
    # directory. Production only verifies imported RSA public keys; generating
    # an RSA SecKey can depend on legacy macOS keychain services even for a
    # nonpersistent key. Do not change permissions or skip real verification.
    pem, der = destination/'issuer.pem', destination/'issuer.der'
    subprocess.run(['openssl', 'genrsa', '-out', str(pem), '2048'], check=True,
                   capture_output=True)
    help_result = subprocess.run(['openssl', 'rsa', '-help'], capture_output=True, text=True)
    command = ['openssl', 'rsa', '-in', str(pem), '-outform', 'DER', '-out', str(der)]
    if '-traditional' in help_result.stdout + help_result.stderr:
        command.append('-traditional')  # PKCS#1, including OpenSSL 3.
    subprocess.run(command, check=True, capture_output=True)
    subprocess.run([str(destination/'tests'), str(der)], check=True, timeout=60)
