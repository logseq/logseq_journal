#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/journal-network-fault.XXXXXXXX")
trap 'rm -f "$out/simulator_network_fault.dylib"; rmdir "$out"' EXIT
chmod 700 "$out"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang \
  -target arm64-apple-ios26.0-simulator -isysroot "$sdk" \
  -std=c11 -Wall -Wextra -Werror -O2 -dynamiclib \
  -Wl,-no_uuid -Wl,-install_name,@rpath/simulator_network_fault.dylib \
  "$root/tool/simulator_network_fault.c" -o "$out/simulator_network_fault.dylib"
codesign --force --sign - --timestamp=none "$out/simulator_network_fault.dylib"
codesign --verify --strict "$out/simulator_network_fault.dylib"
file "$out/simulator_network_fault.dylib"
xcrun vtool -show-build "$out/simulator_network_fault.dylib"
xcrun otool -l "$out/simulator_network_fault.dylib"
xcrun nm -m "$out/simulator_network_fault.dylib"
shasum -a 256 "$root/tool/simulator_network_fault.c" "$out/simulator_network_fault.dylib"
if [ -n "${JOURNAL_TEST_DYLIB_DEST:-}" ]; then
  python3 - "$out/simulator_network_fault.dylib" "$JOURNAL_TEST_DYLIB_DEST" <<'PY'
import os, shutil, stat, sys
source, destination = sys.argv[1:]
parent = os.path.dirname(destination)
info = os.stat(parent)
if (not os.path.isabs(destination) or os.path.realpath(parent) != parent
        or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700):
    raise SystemExit("destination requires canonical private owned directory")
with open(source, "rb") as incoming:
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as outgoing:
        shutil.copyfileobj(incoming, outgoing)
PY
fi
