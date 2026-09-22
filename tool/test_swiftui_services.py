"""Verify the native platform owner against isolated capability boundaries."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='journal-platform-services-') as directory:
    executable = Path(directory)/'services-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6',
                    str(root/'swift/JournalPlatformWire.swift'),
                    str(root/'swift/JournalPlatformServices.swift'),
                    str(root/'apple-tests/platform-services/JournalPlatformServicesTests.swift'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
    threading = Path(directory)/'account-threading-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6',
                    str(root/'swift/JournalPlatformWire.swift'),
                    str(root/'swift/JournalPlatformServices.swift'),
                    str(root/'swift/JournalStartupConfiguration.swift'),
                    str(root/'swift/JournalNativeServices.swift'),
                    str(root/'apple-tests/platform-services/JournalAccountThreadingTests.swift'),
                    '-o', str(threading)], check=True)
    subprocess.run([str(threading)], check=True, timeout=60)
