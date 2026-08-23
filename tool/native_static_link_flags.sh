#!/bin/sh

set -eu

destination=${1:?usage: native_static_link_flags.sh DESTINATION}
destination_directory=$(dirname "$destination")
mkdir -p "$destination_directory"

case "${BONSAI_FLUTTER_APPLE_SDK_ROOT:-}" in
  *iPhoneOS*)
    gmp_sha256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
    opam_root=${OPAMROOT:-$(opam var root)}
    switch_prefix=${OPAM_SWITCH_PREFIX:-$(opam var prefix)}
    source_archive="$opam_root/download-cache/sha256/a3/$gmp_sha256"
    target_cc="$switch_prefix/ios-sysroot/bin/ios-cc"
    sdk_root=$BONSAI_FLUTTER_APPLE_SDK_ROOT
    deployment_target=15.0

    if test ! -f "$source_archive"; then
      printf '%s\n' "Cached GMP 6.3.0 source is missing: $source_archive" >&2
      exit 1
    fi
    actual_sha256=$(shasum -a 256 "$source_archive" | awk '{ print $1 }')
    if test "$actual_sha256" != "$gmp_sha256"; then
      printf '%s\n' "Cached GMP 6.3.0 source checksum is invalid" >&2
      exit 1
    fi
    if test ! -x "$target_cc"; then
      printf '%s\n' "iPhoneOS C compiler wrapper is missing: $target_cc" >&2
      exit 1
    fi

    temporary_directory=$(mktemp -d)
    trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
    source_root="$temporary_directory/source"
    build_directory="$temporary_directory/build"
    install_root="$temporary_directory/install"
    mkdir -p "$source_root" "$build_directory"
    tar -xf "$source_archive" -C "$source_root"
    source_directory="$source_root/gmp-6.3.0"
    if test ! -x "$source_directory/configure"; then
      printf '%s\n' "GMP 6.3.0 source archive has an invalid layout" >&2
      exit 1
    fi

    target_cflags="-O2 -arch arm64 -isysroot $sdk_root -miphoneos-version-min=$deployment_target"
    target_ldflags="-Wl,-syslibroot,$sdk_root -miphoneos-version-min=$deployment_target"
    (
      cd "$build_directory"
      CC="$target_cc" \
        CFLAGS="$target_cflags" \
        CPPFLAGS="-arch arm64 -isysroot $sdk_root -miphoneos-version-min=$deployment_target" \
        LDFLAGS="$target_ldflags" \
        "$source_directory/configure" \
          --host=aarch64-apple-darwin \
          --prefix="$install_root" \
          --disable-shared \
          --enable-static \
          --with-pic
    ) >&2
    make -C "$build_directory" -j "${JOBS:-4}" >&2
    cp "$build_directory/.libs/libgmp.a" "$destination"
    if test "$(xcrun lipo -archs "$destination")" != arm64; then
      printf '%s\n' "Built iPhoneOS GMP archive is not arm64-only" >&2
      exit 1
    fi
    ;;
  *)
    gmp_library_directory=$(pkg-config --variable=libdir gmp)
    gmp_archive="$gmp_library_directory/libgmp.a"
    if test ! -f "$gmp_archive"; then
      printf '%s\n' "Static GMP archive is missing: $gmp_archive" >&2
      exit 1
    fi
    cp "$gmp_archive" "$destination"
    ;;
esac

printf '%s\n' '(-cclib -Lapp -cclib app/libgmp.a)'
