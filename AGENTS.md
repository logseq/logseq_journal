- Use spec-dev-tool to manage agent decision documents; run `spec-dev-tool --help` and follow its AGENT WORKFLOW.
- All changes must comply with `docs/ux-guidelines.md`.
- Keep temporary review and test evidence, experiments, reports, screenshots, and generated hosts outside this repository in the current task's external evidence directory. Do not create a repository `review/` directory or temporary test directories. Reusable formal test source belongs in the existing test directories.
- Before adding a bug regression test, identify the production state owner and attempt reproduction through its public pure reducer events, completions, state, and effects. If that boundary reproduces the defect, add only pure reducer regression tests for it; do not duplicate coverage in effect-runner, persistence, transport, integration, E2E, or UI tests. If it cannot, document the missing ownership boundary and test only the narrowest layer that executes the defect. Injecting an already incorrect external result is not a pure reproduction. Use deterministic public interfaces without bypassing `.mli` files or copying implementation logic. This rule does not authorize removing existing tests or moving production ownership for test classification.
- When asked to find simplifications, run `spec-dev-tool guide find-simplifications` from inside this Git worktree and follow the emitted workflow.
- When asked to find test simplifications, run `spec-dev-tool guide find-test-simplifications` from inside this Git worktree and follow the emitted workflow.
- Do not modify any ocaml files under `spec/` during development unless explicitly asked to modify the `.mli` files under `spec/`.
- Do not modify any dune file during development unless explicitly asked.
- If development is blocked because the `.mli` definitions under `spec/` are unclear or unreasonable, stop development immediately and report the specific spec issue, suggested changes, and rationale.
- Do not modify any ocaml files in bonsai_flutter repo
- Prefer native bonsai-ui/SwiftUI components and their built-in layout, scrolling, and animation behavior. Do not recreate these behaviors using per-row geometry tracking, shared observable geometry state, or repeated collection scans during scrolling. If native APIs cannot satisfy a requirement, explain the limitation and obtain explicit approval before implementing custom UI coordination.

## Build

Use `bash tool/build_journal_apple.sh --help` as the Apple build entry point. It uses the existing Dune native object, Swift package and icon packager; it never installs an app, touches a graph, changes pins, downloads dependencies, or clears caches. Provision dependencies separately in an explicitly chosen switch using the existing CI lock/resolved-pin workflow (`tool/prepare_ci_dependencies.py`); that workflow fetches and pins dependencies and must not be run against another task's shared switch without authorization.

| Target | SDK / architecture | Current support |
| --- | --- | --- |
| `macos` | `macosx` / arm64 | Native OCaml build through an explicit matching switch; default signing is adhoc. |
| `ios-simulator --link-only` | `iphonesimulator` / arm64 | Explicit stub: Swift/link/package/signature checks only; no runnable OCaml acceptance. |
| iOS `--experimental-host-restamp --native-manifest FILE` | selected `iphonesimulator` or `iphoneos` / arm64 | Explicit compatibility mode: verified producer host OCaml object, freshly compiled target DNS/crypto C and Swift. Full OCaml/runtime iOS ABI remains unvalidated. |
| iOS without either explicit mode | distinct Simulator / iPhoneOS ABI | Refused; no implicit stub or host restamp. |

Run from this worktree; choose an external cache and a local LUI `platform/apple` checkout. For native builds its clean Git HEAD must equal the LUI pin in `logseq_journal.opam.locked`.

```sh
bash tool/build_journal_apple.sh macos --switch YOUR_SWITCH \
  --lui-package /path/to/lui/platform/apple --cache-dir ../journal-build-cache --preflight
bash tool/build_journal_apple.sh macos --switch YOUR_SWITCH \
  --lui-package /path/to/lui/platform/apple --cache-dir ../journal-build-cache
bash tool/build_journal_apple.sh ios-simulator --link-only \
  --lui-package /path/to/lui/platform/apple --cache-dir ../journal-build-cache
bash tool/build_journal_apple.sh ios-device --experimental-host-restamp \
  --native-manifest ../native-input.json --lui-package /path/to/lui/platform/apple \
  --cache-dir ../journal-build-cache --sign-identity CERTIFICATE_SHA1 \
  --provisioning-profile /path/to/device.mobileprovision \
  --sign-entitlements /path/to/device.entitlements --build-number 1.2.3
python3 tool/test_journal_build.py
```

The experimental input is a small envelope referencing existing producer records by SHA-256. Paths below are relative to the envelope; producer records retain their explicit input paths. Keep these records and the fixed complete object read-only.

```json
{
  "schema_version": 1,
  "source": {"path": "preflight.json", "sha256": "SHA256"},
  "link": {"path": "native-command-manifest.json", "sha256": "SHA256"},
  "xmlm_force_link": {"path": "xmlm-force-link-proof.json", "sha256": "SHA256"},
  "validated_build": {"path": "successful-build/manifest.json", "sha256": "SHA256"}
}
```

`source` binds commit/LUI/Signal/DataScript, production source hashes and the host complete-object hash. `link` supplies compiler/version, archive/stub input hashes and pinned mldoc/XMLm provenance. `xmlm_force_link` describes only `ocamlopt -a -linkall -o OWN/xmlm.cmxa OWN/xmlm.cmx`, with unchanged original cmx/object hashes. The producer commit must be an ancestor of the current builder revision, and the complete native source set plus Dune/opam/link configuration must still match its bytes exactly. Thus Build/tool/docs commits can advance HEAD; native changes cannot silently reuse an older object. Reports keep both current `source_sha` and `native_source_sha`. The importer never executes recorded commands.

`validated_build` is optional and must reference a trusted successful experimental build manifest from this entry point, with the same original three producer records, native source, compiler identity and complete-object hash. Without it, a first import verifies all still-present producer files and XMLm bytes/metadata. With it, already-consumed archives/compiler/source paths are historical provenance, so subsequent builds may change or remove them without invalidating the fixed object. Their original hashes remain recorded; this does not prove that the original object can still be rebuilt from those paths. Current object bytes/platform/symbols, exact native source/configuration/pins, runtime headers used by fresh target C, evidence/receipt bytes, SDK and Swift/signing inputs remain checked. Never edit an original producer record or invent a successful receipt to bypass a mismatch. Changed native bytes require matching new producer evidence.

- `--preflight` validates without compiling. The Dune route compares the explicit switch with locks/pins; the imported route validates producer source/dependency/compiler hashes instead of requiring its private dependencies to be globally installed. Neither repairs pins or installs dependencies. Moving refs have no network freshness claim.
- Every run creates an external `run-*/manifest.json` and phase logs. Only `status: built` confirms a completed artifact; `preflight-passed` and `link-only` do not establish runtime behavior. The manifest records exact source SHA plus dirty input hashes, dependency/toolchain/SDK/target/flags, native input and final bundle hashes, signing and version. Keep it with the app when handing off for installation.
- Source, actual dependency native ABI inputs, compiler/Xcode/SDK, flags or target changes select another cache namespace. Historical producer identities remain bound to the imported object instead of the present contents of consumed archive paths. Identical inputs reuse Dune/Swift incremental state. Nothing is automatically deleted. The cache root has a nonblocking process lock; native builds also hold the opam switch read lock. Do not point at another task's legacy build/cache/signing directories; coordinate with its owner first. The script owns only its external cache and new output directory; it refuses an existing `--app-dir` instead of removing it.
- `--configuration debug|release`, `--deployment-target` (>=26.0), `--jobs`, `--version` and `--build-number` are explicit inputs. Unset ambient `SDKROOT`/compiler/OCaml lookup overrides; the Swift manifest runs on macOS and the selected target SDK is passed explicitly. Production native objects must retain mldoc and XMLm symbols: merely listing an unused `.cmxa` does not prove retention. A missing unit stops the build for linker-rule review; ask before changing protected Dune rules.
- Resources and C4 icons are packaged before signing. Device mode checks the existing iOS profile, expiration, certificate, team/bundle and allowed entitlements, then reads back the actual signature/entitlements. Simulator uses adhoc signing with entitlements in `__TEXT`; macOS development signing takes `--sign-identity` and `JOURNAL_MACOS_TEAM_ID`. Version flags affect only the generated plist. Build never installs or claims startup acceptance.
- Experimental mode checks every Swift object against the selected Mach-O platform, checks the final DNS/crypto link-map provider is its fresh target C object, and requires runtime/mldoc/XMLm symbols. Its report and generated plist explicitly mark host-restamped runtime origin and `cross_abi_validated=false`. This reproduces the existing limited route, not full OCaml iOS cross-compilation. Raw `JOURNAL_OCAML_OBJECT`/extra-object injection and the old object-injecting Dune aliases remain refused; use the explicit commands above. Any protected Dune/spec/lock edit still needs separate approval.
