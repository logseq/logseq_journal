#!/usr/bin/env bash
# Builds the journal Apple host (swift/Package.swift -> JournalApp) with the
# OCaml runtime linked in.
#
# Usage: tool/build_journal_apple.sh <macos|ios-simulator> [--app-dir DIR]
#
# Native link inputs:
#   * journal_lui_bridge.o is always compiled here from app/journal_lui_bridge.c
#     against the OCaml headers of the target toolchain — as a compile check.
#     It is NOT a link input: the dune-produced complete object already folds
#     in the app's foreign_stubs copy, and the link stub below redefines all
#     entries. Set JOURNAL_EXTRA_OBJECTS (colon-separated) to append extra
#     objects if a producer ever emits an object without the bridge stubs.
#   * The OCaml complete object (the `native_embed` product) is NOT built by
#     this script — it is produced by the dune/opam side of the workspace.
#     Point JOURNAL_OCAML_OBJECT at the artifact:
#       macOS:         dune builds app/native_embed.exe.o with the host switch.
#       iOS simulator: the shared cross toolchain at
#         ${LG_IOS_OCAML_PREFIX:-$OPAMROOT/lg-ocaml-toolchains/ocaml-<ver>/targets/arm64-apple-ios<ver>-simulator}
#         must have produced a complete object for the target triple; pass its
#         path through JOURNAL_OCAML_OBJECT.
#     Without JOURNAL_OCAML_OBJECT the script links a stub object so the Swift
#     side still verifies end-to-end (link only — the binary is not runnable).
#
# Reuses the lui mobile conventions: LG_IOS_OCAML_PREFIX /
# $OPAMROOT/lg-ocaml-toolchains (as in lui/tooling/mobile/build_components_*.sh).

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Probe harnesses (tool/lui_probe_host.py) stage an overlaid copy of swift/ + a
# probe Info.plist under a temp host and point these overrides at it.
swift_dir=${JOURNAL_SWIFT_DIR:-$repo_root/swift}
info_plist=${JOURNAL_INFO_PLIST:-$repo_root/apple/Info.plist}
entitlements_dir=${JOURNAL_ENTITLEMENTS_DIR:-$repo_root/config/entitlements}
platform=${1:-macos}
app_dir_arg=${2:-}
ocaml_version=${LG_OCAML_VERSION:-5.5.0}
opam_root=${OPAMROOT:-$(opam var root --safe 2>/dev/null || echo "$HOME/.opam")}
shared_root=${LG_OCAML_TOOLCHAIN_ROOT:-$opam_root/lg-ocaml-toolchains}

case "$platform" in
  macos)
    deployment_target=${JOURNAL_MACOS_DEPLOYMENT_TARGET:-26.0}
    triple="arm64-apple-macosx${deployment_target}"
    sdk_path=$(xcrun --sdk macosx --show-sdk-path)
    clang=$(xcrun --sdk macosx --find clang)
    # Host switch provides headers + runtime for the bridge C file.
    ocaml_prefix=${JOURNAL_OCAML_PREFIX:-$(ocamlfind printconf destdir 2>/dev/null | sed 's|/lib$||' || true)}
    [[ -n $ocaml_prefix ]] || ocaml_prefix="$opam_root/default"
    ocaml_include="$ocaml_prefix/lib/ocaml"
    ;;
  ios-simulator)
    deployment_target=${JOURNAL_IOS_DEPLOYMENT_TARGET:-26.0}
    triple="arm64-apple-ios${deployment_target}-simulator"
    sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    clang=$(xcrun --sdk iphonesimulator --find clang)
    target_prefix=${LG_IOS_OCAML_PREFIX:-$shared_root/ocaml-$ocaml_version/targets/$triple}
    if [[ -d $target_prefix/lib/ocaml ]]; then
      ocaml_include="$target_prefix/lib/ocaml"
    else
      # journal_lui_bridge.c is a compile check only (not a link input); the
      # host OCaml headers are platform-independent for it.
      ocaml_prefix=${JOURNAL_OCAML_PREFIX:-$(ocamlfind printconf destdir 2>/dev/null | sed 's|/lib$||' || true)}
      [[ -n $ocaml_prefix ]] || ocaml_prefix="$opam_root/default"
      ocaml_include="$ocaml_prefix/lib/ocaml"
    fi
    ;;
  *) echo "usage: $0 <macos|ios-simulator>" >&2; exit 2 ;;
esac

build_dir="$repo_root/_build/apple/$platform"
mkdir -p "$build_dir"

# --- journal_lui_bridge.o -------------------------------------------------
"$clang" \
  -target "$triple" \
  -isysroot "$sdk_path" \
  -fPIC \
  -I "$ocaml_include" \
  -c "$repo_root/app/journal_lui_bridge.c" \
  -o "$build_dir/journal_lui_bridge.o"

# --- OCaml complete object ------------------------------------------------
ocaml_object=${JOURNAL_OCAML_OBJECT:-}
if [[ -z $ocaml_object ]]; then
  echo "warning: JOURNAL_OCAML_OBJECT unset; linking a stub object (link-only build)" >&2
  cat > "$build_dir/ocaml_stub.c" <<'STUB'
// Link-validation stub matching app/journal_lui_bridge.c's exported entries.
// Replace via JOURNAL_OCAML_OBJECT for a runnable binary.
#include <stdint.h>
typedef void (*patch_cb)(const char *);
typedef void (*wakeup_cb)(void);
typedef void (*platform_request_cb)(const char *, int32_t);
int32_t lui_ocaml_start(patch_cb cb, int32_t p, int32_t h, const char *d, int32_t l)
  { (void)p; (void)h; (void)d; (void)l; if (cb) cb(""); return 1; }
int32_t lui_ocaml_stop(void) { return 1; }
int32_t lui_ocaml_appear(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_press(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_long_press(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_text_changed(int64_t n, const char *t) { (void)n; (void)t; return 1; }
int32_t lui_ocaml_submit(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_dismiss(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_double_press(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_toggle_changed(int64_t n, int32_t c) { (void)n; (void)c; return 1; }
int32_t lui_ocaml_radio_changed(int64_t n) { (void)n; return 1; }
int32_t lui_ocaml_slider_changed(int64_t n, double v) { (void)n; (void)v; return 1; }
int32_t journal_ocaml_extension_event(int64_t n, const char *name, const char *p)
  { (void)n; (void)name; (void)p; return 1; }
int32_t journal_ocaml_pump(void) { return 1; }
void journal_ocaml_platform_event(const char *d, int32_t l) { (void)d; (void)l; }
void journal_ocaml_platform_response(const char *d, int32_t l) { (void)d; (void)l; }
void journal_ocaml_set_wakeup_callback(wakeup_cb cb) { (void)cb; }
void journal_ocaml_set_platform_request_callback(platform_request_cb cb) { (void)cb; }
STUB
  "$clang" -target "$triple" -isysroot "$sdk_path" -fPIC \
    -c "$build_dir/ocaml_stub.c" -o "$build_dir/journal_complete_stub.o"
  ocaml_object="$build_dir/journal_complete_stub.o"
fi

# --- deterministic link-input staging (mirrors the lui script) ------------
fingerprint=$(shasum -a 256 "$ocaml_object" "$build_dir/journal_lui_bridge.o" \
  | shasum -a 256 | cut -d ' ' -f 1)
link_dir="$build_dir/native-link-inputs/$fingerprint"
mkdir -p "$link_dir"
cp -f "$ocaml_object" "$link_dir/journal_complete.o"

extra_inputs=""
if [[ -n ${JOURNAL_EXTRA_OBJECTS:-} ]]; then
  extra_inputs=":${JOURNAL_EXTRA_OBJECTS}"
fi

# --- SwiftPM --------------------------------------------------------------
swift_args=(
  build
  --package-path "$swift_dir"
  --product JournalApp
)
if [[ $platform == ios-simulator ]]; then
  swift_args+=(--triple "$triple" --sdk "$sdk_path")
  # Simulator binaries exec on the host macOS kernel, so entitlements baked
  # into the code signature are validated as macOS entitlements and the exec
  # is killed (error 163) no matter what identity signed them. The sim reads
  # its entitlements from the __TEXT,__entitlements section instead — embed
  # them at link time like Xcode does, then sign adhoc. This is what makes
  # keychain (Amplify sign-in, localAccount) work on the sim.
  ios_entitlements="$build_dir/ios-sim-entitlements.plist"
  cp "$entitlements_dir/ios-debug-profile.entitlements" "$ios_entitlements"
  bundle_id=$(plutil -extract CFBundleIdentifier raw "$info_plist")
  ios_team_id=${JOURNAL_IOS_TEAM_ID:-K378MFWK59}
  plutil -replace keychain-access-groups -json \
    "[\"$ios_team_id.$bundle_id\"]" "$ios_entitlements"
  plutil -insert application-identifier -string \
    "$ios_team_id.$bundle_id" "$ios_entitlements"
  swift_args+=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements
    -Xlinker "$ios_entitlements")
fi

JOURNAL_LUI_PACKAGE_PATH=${JOURNAL_LUI_PACKAGE_PATH:-$repo_root/../lui/platform/apple} \
JOURNAL_NATIVE_LINK_INPUTS="$link_dir/journal_complete.o$extra_inputs" \
swift "${swift_args[@]}"

# --- .app assembly ---------------------------------------------------------
product_dir="$swift_dir/.build/$triple/debug"
[[ -f $product_dir/JournalApp ]] || product_dir="$swift_dir/.build/debug"
app_dir=${app_dir_arg:-$build_dir/LogseqJournal.app}
rm -rf "$app_dir"
if [[ $platform == macos ]]; then
  mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
  cp "$info_plist" "$app_dir/Contents/Info.plist"
  cp "$product_dir/JournalApp" "$app_dir/Contents/MacOS/JournalApp"
  # keychain-access-groups needs a real team id; without one the group is
  # invalid and AMFI kills the binary, so drop the key for local builds. With a
  # team id, sign with the Apple Development identity so the entitlement is
  # honored (Amplify/keychain then work on macOS too).
  macos_entitlements="$build_dir/macos-entitlements.plist"
  cp "$entitlements_dir/macos-debug-profile.entitlements" "$macos_entitlements"
  bundle_id=$(plutil -extract CFBundleIdentifier raw "$info_plist")
  if [[ -n ${JOURNAL_MACOS_TEAM_ID:-} ]]; then
    plutil -replace keychain-access-groups -json \
      "[\"$JOURNAL_MACOS_TEAM_ID.$bundle_id\"]" "$macos_entitlements"
    # macOS rejects the iOS-style `application-identifier` entitlement key;
    # the application id is implied by the signature + keychain-access-groups.
    plutil -remove application-identifier "$macos_entitlements" 2>/dev/null || true
    codesign --force --sign "${JOURNAL_MACOS_SIGN_IDENTITY:-Apple Development}" \
      --timestamp=none --entitlements "$macos_entitlements" "$app_dir" || true
  else
    plutil -remove keychain-access-groups "$macos_entitlements"
    codesign --force --sign - --timestamp=none \
      --entitlements "$macos_entitlements" \
      "$app_dir" || true
  fi
else
  # iOS bundles are flat; an empty Contents/ dir breaks install + codesign.
  mkdir -p "$app_dir"
  cp "$info_plist" "$app_dir/Info.plist"
  cp "$product_dir/JournalApp" "$app_dir/JournalApp"
  # Plain adhoc signature — the sim's entitlements already live in the
  # __TEXT,__entitlements section embedded at link time above. Do NOT pass
  # --entitlements here: a signature-level entitlements blob is validated by
  # the host kernel as macOS entitlements and the exec is killed.
  codesign --force --sign - --timestamp=none "$app_dir" || true
fi

echo "$app_dir"
