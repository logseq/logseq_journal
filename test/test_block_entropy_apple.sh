#!/bin/sh
# Verify the OS entropy source independently of UUID transitions and UI behavior.
set -eu

platform=${1:?Usage: test_block_entropy_apple.sh macos|ios-simulator [device-id]}
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/journal-block-entropy.XXXXXX")
trap 'rm -rf "$probe_directory"' EXIT HUP INT TERM

cat > "$probe_directory/probe.c" <<'C'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
  int descriptor = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (descriptor < 0) { perror("open /dev/urandom"); return 1; }
  unsigned char bytes[16];
  size_t offset = 0;
  while (offset < sizeof(bytes)) {
    ssize_t count = read(descriptor, bytes + offset, sizeof(bytes) - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      if (count < 0) perror("read /dev/urandom");
      else fputs("Unexpected entropy EOF\n", stderr);
      close(descriptor);
      return 1;
    }
    offset += (size_t)count;
  }
  if (close(descriptor) < 0) { perror("close /dev/urandom"); return 1; }
  puts("OS entropy source: opened /dev/urandom, read 16 bytes, closed descriptor");
  return 0;
}
C

case "$platform" in
  macos)
    xcrun --sdk macosx clang -Wall -Wextra -Werror "$probe_directory/probe.c" -o "$probe_directory/probe"
    "$probe_directory/probe"
    ;;
  ios-simulator)
    simulator_device=${2:?An already booted iOS simulator device ID is required}
    simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
    xcrun --sdk iphonesimulator clang -Wall -Wextra -Werror \
      -target arm64-apple-ios15.0-simulator -isysroot "$simulator_sdk" \
      "$probe_directory/probe.c" -o "$probe_directory/probe"
    xcrun simctl spawn "$simulator_device" "$probe_directory/probe"
    ;;
  *)
    printf 'Unknown platform: %s\n' "$platform" >&2
    exit 2
    ;;
esac
