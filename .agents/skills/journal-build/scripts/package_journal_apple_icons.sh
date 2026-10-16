#!/usr/bin/env bash
# Compile the shared C4 catalog into an assembled app before code signing.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
platform=${1:?usage: package_journal_apple_icons.sh <macos|ios-simulator|ios-device> APP_DIR}
app_dir=${2:?missing app directory}
case "$platform" in
  macos)
    sdk=macosx
    deployment_target=${JOURNAL_MACOS_DEPLOYMENT_TARGET:-26.0}
    resources="$app_dir/Contents/Resources"
    info_plist="$app_dir/Contents/Info.plist"
    target_devices=(--target-device mac)
    ;;
  ios-simulator|ios-device)
    sdk=iphonesimulator
    [[ $platform != ios-device ]] || sdk=iphoneos
    deployment_target=${JOURNAL_IOS_DEPLOYMENT_TARGET:-26.0}
    resources="$app_dir"
    info_plist="$app_dir/Info.plist"
    target_devices=(--target-device iphone --target-device ipad)
    ;;
  *) echo "unsupported icon platform: $platform" >&2; exit 2 ;;
esac

# Journal assembly starts from an icon-free plist and installs only C4.
for key in CFBundleIcons 'CFBundleIcons~ipad' CFBundleIconFile CFBundleIconFiles CFBundleIconName; do
  if plutil -extract "$key" xml1 -o /dev/null "$info_plist" 2>/dev/null; then
    echo "Journal C4 packaging requires an Info.plist without existing icon declarations ($key)." >&2
    exit 2
  fi
done

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/journal-app-icon.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
mkdir -p "$resources"
xcrun --sdk "$sdk" actool "$repo_root/assets/apple/Assets.xcassets" \
  --compile "$resources" --platform "$sdk" \
  --minimum-deployment-target "$deployment_target" \
  --app-icon AppIcon "${target_devices[@]}" \
  --output-partial-info-plist "$temporary_dir/icon-info.plist"

python3 - "$info_plist" "$temporary_dir/icon-info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

info_path = Path(sys.argv[1])
info = plistlib.loads(info_path.read_bytes())
info.update(plistlib.loads(Path(sys.argv[2]).read_bytes()))
info_path.write_bytes(plistlib.dumps(info))
PY
