---
name: journal-build
description: Build and verify Journal Apple apps for macOS, iOS Simulator and iPhoneOS using the repository entry point and explicit native provenance.
---

# Journal Build

Run from the repository root with `bash tool/build_journal_apple.sh`; use `--help` for current options. It shares the existing Dune, Swift and icon helpers. Build never installs, touches a graph, updates dependencies/pins or deletes caches. Coordinate CPU/actool and borrowed inputs with any active build owner.

## Select inputs and target

All targets are arm64 with deployment target >=26.0. Choose an external `--cache-dir` and local LUI `platform/apple` package. Production LUI must be clean at its locked Git pin, including untracked files.

| Target | SDK | Mode / prerequisites |
| --- | --- | --- |
| `macos` | `macosx` | Native Dune object; explicit prepared `--switch` matching locks/pins. Adhoc signing by default. |
| `ios-simulator` | `iphonesimulator` | Explicit `--link-only` stub for Swift/link/package checks, or the experimental mode below. |
| `ios-device` | `iphoneos` | Explicit `--experimental-host-restamp --native-manifest FILE`, existing certificate SHA1/profile/entitlements. |

Default iOS runtime builds and raw `JOURNAL_OCAML_OBJECT`/extra-object injection are refused. Host ARM64 OCaml/runtime restamping is an experimental compatibility route, **not verified full iOS cross-compilation or ABI acceptance**. Real target C/Swift and signing checks do not establish full OCaml ABI or startup acceptance.

Simulator signing is adhoc. macOS development signing needs `--sign-identity` plus `JOURNAL_MACOS_TEAM_ID`; device mode requires the existing signing inputs shown below.

```sh
bash tool/build_journal_apple.sh macos --switch YOUR_SWITCH \
  --lui-package /path/to/lui/platform/apple --cache-dir ../journal-build-cache --preflight
bash tool/build_journal_apple.sh ios-simulator --link-only \
  --lui-package /path/to/lui/platform/apple --cache-dir ../journal-build-cache
bash tool/build_journal_apple.sh ios-device --experimental-host-restamp \
  --native-manifest ../native-input.json --lui-package /path/to/lui/platform/apple \
  --cache-dir ../journal-build-cache --sign-identity CERTIFICATE_SHA1 \
  --provisioning-profile /path/to/device.mobileprovision \
  --sign-entitlements /path/to/device.entitlements --build-number 1.2.3
```

`--preflight` checks without compilation; remove it for the macOS build. Unset ambient compiler/OCaml/SDK lookup overrides; SDK selection is explicit. Provision dependencies separately with the existing `tool/prepare_ci_dependencies.py` lock/resolved-pin workflow, which fetches and pins; use only an authorized switch. The builder never repairs it implicitly. Offline moving refs have no remote freshness claim.

## Experimental object provenance

The envelope references original producer records by SHA-256; paths are relative to the envelope, while producer records retain their own explicit paths:

```json
{
  "schema_version": 1,
  "source": {"path": "preflight.json", "sha256": "SHA256"},
  "link": {"path": "native-command-manifest.json", "sha256": "SHA256"},
  "xmlm_force_link": {"path": "xmlm-force-link-proof.json", "sha256": "SHA256"},
  "validated_build": {"path": "successful-build/manifest.json", "sha256": "SHA256"}
}
```

`source` binds native source hashes, producer commit, LUI/Signal/DataScript pins and complete-object hash. `link` binds compiler/dependency/archive identity, including mldoc/XMLm pins. `xmlm_force_link` proves a single XMLm unit retained its original cmx/object bytes. Recorded commands are data, never command hooks.

`validated_build` is optional: use a trusted successful experimental manifest from this entry point binding the same records, native source, compiler and object. Without it, the original producer files and XMLm proof must still verify in full. With it, consumed archives/compiler/source paths become historical hash proof and may later change or disappear. This preserves object provenance; it does not prove those paths can still rebuild it. Keep original records/object/receipt read-only; never rewrite proofs or invent a receipt to bypass mismatch.

The producer commit must be an ancestor of the builder revision. The full native source set, Dune/opam/link configuration and pins must still match exactly; Build/tool/docs commits may advance HEAD, changed native bytes need new evidence. Current object/platform/symbols, runtime headers used by fresh target C, records/receipt, SDK and Swift/signing inputs remain live checks. Reports distinguish builder `source_sha` and `native_source_sha`.

## Cache and failure handling

Identity includes source, actual dependency ABI inputs, toolchain/SDK, flags and target. Identical inputs reuse incremental state; changed inputs select another namespace. Every run leaves external phase logs and `run-*/manifest.json`. The cache has a nonblocking lock; native Dune builds also hold the switch read lock. A busy lock belongs to its active owner: coordinate or wait. Preserve existing output/rollback apps and choose a new `--app-dir`; nothing is cleared automatically.

For failure, read `failed_phase`, `error` and that phase's log. Correct target/environment or select matching prepared inputs. Source/configuration/pin/current-input mismatch requires matching provenance; a historical archive change alone can use the validated receipt contract above. Missing mldoc/XMLm retention requires linker-rule review; protected Dune/spec/lock edits still follow the repository's authorization rules. Legacy object-injecting Dune aliases/probe callers need migration to this entry point.

## Accept and hand off

Only `status: built` confirms an artifact. Check recorded revisions/dirty hashes, target/SDK/flags, bundle/executable hashes, version and signing identity. Resources/icons precede signing; device profile/certificate/team/entitlements and strict signature are checked. Experimental builds additionally check Swift object platforms, fresh target C link-map providers and runtime/mldoc/XMLm retention. Listing a `.cmxa` alone does not establish retention.

`preflight-passed` and `link-only` are not runtime acceptance. Preserve `cross_abi_validated=false` for host-restamped objects and state which compilation was reused. Carry the manifest with the App; installation and phone/graph operations are separate from build. For builder changes, use `PYTHONDONTWRITEBYTECODE=1 python3 tool/test_journal_build.py` and the existing icon test as appropriate.
