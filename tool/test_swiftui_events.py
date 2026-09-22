"""Verify bounded lifecycle/auth event ownership without a native runtime."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='journal-platform-events-') as directory:
    executable = Path(directory) / 'events-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6',
                    str(root / 'swift/JournalPlatformWire.swift'),
                    str(root / 'swift/JournalPlatformEvents.swift'),
                    str(root / 'apple-tests/platform-events/JournalPlatformEventsTests.swift'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
