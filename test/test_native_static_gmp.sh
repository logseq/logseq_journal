#!/bin/sh

set -eu

script=${1:?usage: test_native_static_gmp.sh SCRIPT}
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

fake_bin="$temporary_directory/bin"
opam_root="$temporary_directory/opam-root"
switch_prefix="$temporary_directory/switch"
cache_archive="$opam_root/download-cache/sha256/a3/a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
mkdir -p "$fake_bin" "$(dirname "$cache_archive")" "$switch_prefix/ios-sysroot/bin"
printf '%s\n' source >"$cache_archive"

write_executable() {
  destination=$1
  shift
  printf '%s\n' '#!/bin/sh' "$@" >"$destination"
  chmod +x "$destination"
}

write_executable "$fake_bin/opam" \
  'case "$*" in' \
  '  "var root") printf "%s\n" "$TEST_OPAM_ROOT" ;;' \
  '  "var prefix") printf "%s\n" "$TEST_SWITCH_PREFIX" ;;' \
  '  *) exit 64 ;;' \
  'esac'

write_executable "$fake_bin/shasum" \
  'printf "%s  %s\n" "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898" "$3"'

write_executable "$fake_bin/tar" \
  'destination=' \
  'while test "$#" -gt 0; do' \
  '  if test "$1" = -C; then shift; destination=$1; fi' \
  '  shift' \
  'done' \
  'mkdir -p "$destination/gmp-6.3.0"' \
  'printf "%s\n" "#!/bin/sh" "touch Makefile" >"$destination/gmp-6.3.0/configure"' \
  'chmod +x "$destination/gmp-6.3.0/configure"'

write_executable "$fake_bin/make" \
  'build_directory=' \
  'while test "$#" -gt 0; do' \
  '  if test "$1" = -C; then shift; build_directory=$1; fi' \
  '  shift' \
  'done' \
  'mkdir -p "$build_directory/.libs"' \
  'printf "%s\n" ios-static-gmp >"$build_directory/.libs/libgmp.a"'

write_executable "$fake_bin/xcrun" \
  'case "$*" in' \
  '  "--sdk iphoneos --show-sdk-version") printf "%s\n" 26.0 ;;' \
  '  "--sdk iphoneos --find ar") printf "%s\n" /usr/bin/ar ;;' \
  '  "lipo -archs "*) printf "%s\n" arm64 ;;' \
  '  *) exit 64 ;;' \
  'esac'

write_executable "$switch_prefix/ios-sysroot/bin/ios-cc" 'exit 0'

ios_archive="$temporary_directory/ios/libgmp.a"
ios_output=$(
  PATH="$fake_bin:$PATH" \
    OPAMROOT="$opam_root" \
    OPAM_SWITCH_PREFIX="$switch_prefix" \
    TEST_OPAM_ROOT="$opam_root" \
    TEST_SWITCH_PREFIX="$switch_prefix" \
    BONSAI_FLUTTER_APPLE_SDK_ROOT=/Xcode/iPhoneOS.sdk \
    "$script" "$ios_archive"
)
test "$ios_output" = '(-cclib -Lapp -cclib app/libgmp.a)'
test "$(cat "$ios_archive")" = ios-static-gmp

host_library_directory="$temporary_directory/host-gmp"
mkdir -p "$host_library_directory"
printf '%s\n' macos-static-gmp >"$host_library_directory/libgmp.a"
write_executable "$fake_bin/pkg-config" 'printf "%s\n" "$TEST_HOST_GMP_LIBDIR"'

macos_archive="$temporary_directory/macos/libgmp.a"
macos_output=$(
  PATH="$fake_bin:$PATH" \
    TEST_HOST_GMP_LIBDIR="$host_library_directory" \
    BONSAI_FLUTTER_APPLE_SDK_ROOT=/Xcode/MacOSX.sdk \
    "$script" "$macos_archive"
)
test "$macos_output" = '(-cclib -Lapp -cclib app/libgmp.a)'
test "$(cat "$macos_archive")" = macos-static-gmp

printf '%s\n' 'Native static GMP tool tests passed'
