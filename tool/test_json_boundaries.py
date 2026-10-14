"""Public native owner and internal decoder tests; synthetic bytes, no App or credentials."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='journal-json-boundaries-') as directory:
    output = Path(directory) / 'tests'
    sources = ['JournalInternalJSON.swift', 'JournalPlatformWire.swift',
               'JournalPlatformServices.swift', 'JournalLocalAccountBindingStore.swift',
               'JournalCognitoOAuth.swift']
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path',
                    str(Path(directory)/'modules'),
                    *[str(root/'swift'/name) for name in sources],
                    str(root/'apple-tests/platform-wire/JournalJSONBoundaryTests.swift'),
                    '-o',str(output)],check=True)
    subprocess.run([str(output)],check=True,timeout=60)
