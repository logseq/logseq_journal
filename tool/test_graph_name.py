"""Verify the native graph-name feedback owner without a runtime or device."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='journal-graph-name-') as directory:
    executable = Path(directory) / 'graph-name-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-module-cache-path', str(Path(directory) / 'modules'),
                    str(root / 'swift/JournalGraphName.swift'),
                    str(root / 'apple-tests/native-list/JournalGraphNameStateTests.swift'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
