#!/bin/sh

set -eu

repository_root=${1:?usage: test_material_icons_artifact.sh REPOSITORY_ROOT}
verifier="$repository_root/tool/verify_material_icons_font.sh"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

flutter_root="$temporary_directory/flutter"
material_fonts="$flutter_root/bin/cache/artifacts/material_fonts"
mkdir -p "$material_fonts"
touch "$flutter_root/bin/flutter"
chmod +x "$flutter_root/bin/flutter"
printf '%s' 'complete-material-icons-font' \
  > "$material_fonts/MaterialIcons-Regular.otf"

matching_font="$temporary_directory/matching.otf"
subset_font="$temporary_directory/subset.otf"
mismatched_font="$temporary_directory/mismatched.otf"
cp "$material_fonts/MaterialIcons-Regular.otf" "$matching_font"
printf '%s' 'subset' > "$subset_font"
printf '%s' 'different-material-font-data' > "$mismatched_font"

PATH="$flutter_root/bin:$PATH" "$verifier" "$matching_font"

if PATH="$flutter_root/bin:$PATH" "$verifier" "$subset_font"; then
  printf '%s\n' 'subset Material font was accepted' >&2
  exit 1
fi

if PATH="$flutter_root/bin:$PATH" "$verifier" "$mismatched_font"; then
  printf '%s\n' 'same-size mismatched Material font was accepted' >&2
  exit 1
fi

if PATH="$flutter_root/bin:$PATH" "$verifier" "$temporary_directory/missing.otf"; then
  printf '%s\n' 'missing Material font was accepted' >&2
  exit 1
fi
