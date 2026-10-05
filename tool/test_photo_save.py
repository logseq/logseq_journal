#!/usr/bin/env python3
"""Native save-owner and byte-preserving file tests; never invokes Photos."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="journal-photo-save-test-") as directory:
    output = pathlib.Path(directory)
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
        "-module-cache-path", str(output / "module-cache"),
        str(root / "swift/JournalPhotoSave.swift"),
        str(root / "swift/JournalPhotoSaveFile.swift"),
        str(root / "apple-tests/photo-save/JournalPhotoSaveTests.swift"),
        "-o", str(output / "tests"),
    ], check=True)
    subprocess.run([str(output / "tests")], check=True)
