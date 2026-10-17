# Targets and prerequisites


All targets are arm64 with deployment target >=26.0. Choose an external `--cache-dir` and local LUI `platform/apple` package. Production LUI must be clean at its locked Git pin, including untracked files.

| Target | SDK | Mode / prerequisites |
| --- | --- | --- |
| `macos` | `macosx` | Native Dune object; explicit prepared `--switch` matching locks/pins. Adhoc signing by default. |
| `ios-simulator` | `iphonesimulator` | Explicit `--link-only` stub for Swift/link/package checks, or the experimental mode below. |
| `ios-device` | `iphoneos` | Explicit `--experimental-host-restamp --native-manifest FILE`, existing certificate SHA1/profile/entitlements. |

Default iOS runtime builds and raw `JOURNAL_OCAML_OBJECT`/extra-object injection are refused. Existing `lui_probe_host.py` callers keep `--native-object`: the helper selects isolated `--probe-native-object` or explicit `--link-only` when absent, with its own host-local cache. Probe import requires external staged Swift/plist, a distinct `-probe` bundle ID, a matching macOS/Simulator object and runtime/bridge symbols; it hashes the object before/after building. It never restamps, accepts device builds or claims production source/ABI proof. Warm-start Simulator inputs must already match Simulator.

Host ARM64 OCaml/runtime restamping is an experimental compatibility route, **not verified full iOS cross-compilation or ABI acceptance**. Real target C/Swift and signing checks do not establish full OCaml ABI or startup acceptance.

Simulator signing is adhoc. macOS development signing needs `--sign-identity` plus `JOURNAL_MACOS_TEAM_ID`; device mode requires the existing signing inputs shown below.

```sh
bash .agents/skills/journal-build/scripts/build_journal_apple.sh macos --switch YOUR_SWITCH \
  --lui-package /path/to/lui/platform/apple --cache-dir ../journal-build-cache --preflight
bash .agents/skills/journal-build/scripts/build_journal_apple.sh ios-simulator --link-only \
  --lui-package /path/to/lui/platform/apple --cache-dir ../journal-build-cache
bash .agents/skills/journal-build/scripts/build_journal_apple.sh ios-device --experimental-host-restamp \
  --native-manifest ../native-input.json --lui-package /path/to/lui/platform/apple \
  --cache-dir ../journal-build-cache --sign-identity CERTIFICATE_SHA1 \
  --provisioning-profile /path/to/device.mobileprovision \
  --sign-entitlements /path/to/device.entitlements --build-number 1.2.3
```

To produce native evidence without an unrelated macOS App build:

```sh
bash .agents/skills/journal-build/scripts/build_journal_apple.sh macos --producer-only \
  --switch YOUR_SWITCH --lui-package /path/to/lui/platform/apple --cache-dir ../journal-build-cache
# Use the printed native-input.json path; keep its immutable source/link records and object.
bash .agents/skills/journal-build/scripts/build_journal_apple.sh ios-simulator \
  --experimental-host-restamp --native-manifest /printed/path/native-input.json \
  --lui-package /path/to/lui/platform/apple --cache-dir ../journal-build-cache
```

`--producer-only` requires native macOS inputs and rejects App output/signing modes. It keeps cache/switch locks, locked preflight, real Dune rule/input identity, original dependency bytes, runtime/mldoc and final source/compiler/dependency revalidation. It does not run macOS Swift, icons, packaging or signing. `status: native-produced` confirms only the host object and schema-2 producer evidence; it cannot be used as `validated_build` to make inputs historical. The target Simulator build still performs target C, Swift, final provider/platform checks and signing. Host restamping remains experimental with `cross_abi_validated=false`.

`--preflight` checks without compilation; remove it for the macOS build. Unset ambient compiler/OCaml/SDK lookup overrides; SDK selection is explicit. Pins come from active switch state; raw source metadata may omit `url`, while any recorded installed source must still agree. CI local pins require their matching resolution record and clean resolved commit. Provision dependencies separately with `.agents/skills/journal-build/scripts/prepare_ci_dependencies.py`, which fetches and pins; use only an authorized switch. The builder never repairs it implicitly. Offline moving refs have no remote freshness claim.

## Accept and hand off


Only `status: built` confirms an App. Check recorded revisions/dirty hashes, target/SDK/flags, bundle/executable hashes, version and signing identity. Resources/icons precede signing; device profile/certificate/team/entitlements and strict signature are checked. Current GMP archives are rehashed before native macOS acceptance. Experimental builds additionally check Swift object platforms, fresh target C link-map providers and runtime/mldoc retention. Record XMLm's actual retention separately from its locked input identity: schema 2 allows its unused unit to be omitted and rejects unresolved references; legacy schema 1 still requires its force-link proof and retention. Listing a `.cmxa` alone does not establish retention.

`preflight-passed` and `link-only` are not runtime acceptance. Preserve `cross_abi_validated=false` for host-restamped objects and state which compilation was reused. Carry the manifest with the App; installation and phone/graph operations are separate from build. For builder changes, use `PYTHONDONTWRITEBYTECODE=1 python3 .agents/skills/journal-build/scripts/test_journal_build.py` and the existing icon test as appropriate.
