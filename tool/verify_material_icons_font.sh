#!/bin/sh

set -eu

if test "$#" -eq 0; then
  printf '%s\n' 'usage: verify_material_icons_font.sh MATERIAL_FONT...' >&2
  exit 2
fi

flutter_command=$(command -v flutter || true)
if test -z "$flutter_command"; then
  printf '%s\n' 'Flutter executable is unavailable' >&2
  exit 1
fi

flutter_root=$(CDPATH= cd -- "$(dirname "$flutter_command")/.." && pwd)
reference_font="$flutter_root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf"
if test ! -f "$reference_font"; then
  printf '%s\n' "Flutter Material font is unavailable: $reference_font" >&2
  exit 1
fi

reference_size=$(wc -c < "$reference_font" | tr -d '[:space:]')
reference_sha256=$(shasum -a 256 "$reference_font" | awk '{ print $1 }')

for candidate in "$@"; do
  if test ! -f "$candidate"; then
    printf '%s\n' "Bundled Material font is unavailable: $candidate" >&2
    exit 1
  fi
  candidate_size=$(wc -c < "$candidate" | tr -d '[:space:]')
  candidate_sha256=$(shasum -a 256 "$candidate" | awk '{ print $1 }')
  if test "$candidate_size" != "$reference_size" \
    || test "$candidate_sha256" != "$reference_sha256"; then
    printf '%s\n' "Bundled Material font does not match Flutter SDK: $candidate" >&2
    printf '%s\n' \
      "expected size=$reference_size sha256=$reference_sha256" >&2
    printf '%s\n' \
      "actual size=$candidate_size sha256=$candidate_sha256" >&2
    exit 1
  fi
  printf '%s\n' \
    "verified $candidate size=$candidate_size sha256=$candidate_sha256"
done
