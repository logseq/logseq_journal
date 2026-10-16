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

Default iOS runtime builds and raw `JOURNAL_OCAML_OBJECT`/extra-object injection are refused. Existing `lui_probe_host.py` callers keep `--native-object`: the helper selects isolated `--probe-native-object` or explicit `--link-only` when absent, with its own host-local cache. Probe import requires external staged Swift/plist, a distinct `-probe` bundle ID, a matching macOS/Simulator object and runtime/bridge symbols; it hashes the object before/after building. It never restamps, accepts device builds or claims production source/ABI proof. Warm-start Simulator inputs must already match Simulator.

Host ARM64 OCaml/runtime restamping is an experimental compatibility route, **not verified full iOS cross-compilation or ABI acceptance**. Real target C/Swift and signing checks do not establish full OCaml ABI or startup acceptance.

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

`--preflight` checks without compilation; remove it for the macOS build. Unset ambient compiler/OCaml/SDK lookup overrides; SDK selection is explicit. Pins come from active switch state; raw source metadata may omit `url`, while any recorded installed source must still agree. CI local pins require their matching resolution record and clean resolved commit. Provision dependencies separately with `tool/prepare_ci_dependencies.py`, which fetches and pins; use only an authorized switch. The builder never repairs it implicitly. Offline moving refs have no remote freshness claim.

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

For failure, read `failed_phase`, `error` and that phase's log. Correct target/environment or select matching prepared inputs. Source/configuration/pin/current-input mismatch requires matching provenance; a historical archive change alone can use the validated receipt contract above. Missing mldoc/XMLm retention requires linker-rule review; protected Dune/spec/lock edits still follow the repository's authorization rules. Legacy object-injecting Dune aliases remain refused; probe helpers use the isolated mode above.

## Reuse dependency and build state

The Apple builder consumes a prepared switch; it neither provisions it nor manages GitHub caches. Reuse its existing `run-*/manifest.json`: `inputs.toolchain.opam_prefix` is the canonical absolute switch prefix, `ocaml`/`compiler_sha256` identify its compiler, `inputs.dependencies` records checked lock versions, resolved pins and native library hashes, and `cache_key` selects the incremental Apple workspace. Re-run preflight against the same explicit inputs before building. A matching directory name or a previous `cache_reused: true` does not replace those checks. Do not relocate a switch, copy large caches between worktrees, change global pins, or mix macOS/Simulator/device objects to obtain a hit. Retain final input verification, full build/tests and the target acceptance limits above.

CI dependency caching belongs to `.github/workflows/ci.yml` and `tool/prepare_ci_dependencies.py`. After setup, resolution and a fresh `--depext-only` system-dependency preparation, `python3 tool/prepare_ci_dependencies.py --cache-identity` records `.ci-reports/opam-cache.json` without installing or pinning. It reuses the builder's compiler identity helper; this report describes compatibility, not installed dependency validation. The workflow caches the actual `opam var prefix` (normally `$GITHUB_WORKSPACE/_opam`), not just `~/.opam`. The setup action's overlapping caches are disabled. Only exact keys are restored; there are no broad `restore-keys`.

The CI key binds all root opam/lock bytes and resolved Git SHAs, compiler configuration/binary, opam version/root, OS/architecture, runner image/version, selected Xcode/clang/macOS SDK, GMP/SQLite/zlib versions, flags and available library/header bytes, relevant compiler environment, absolute workspace/prefix and the provisioning recipe. Missing or incompatible identity is an error. For a miss or a recoverable restore failure, the fresh setup switch plus unconditional re-pin and `opam install . --deps-only --with-test --locked --ignore-pin-depends --yes` remains the rebuild path. A cache hit never skips those commands, `dune build @all app/native_embed.exe.o`, or `dune runtest --force`.

If the restored switch is corrupt or pin/lock checks fail, preserve the identity, action logs and package list; do not accept the old state, rewrite locks or force a different-platform cache. On an authorized subsequent CI change, bump the workflow's `journal-opam-v2-` namespace (or remove only the identified corrupt Actions cache with explicit authorization) and rerun on a fresh hosted runner. Setup and locked installation then reconstruct it. Locally, use a separate explicitly authorized prepared switch at its own absolute prefix; the Apple builder reports mismatches and never repairs an existing owner's switch. A busy switch/cache lock still requires coordination.

### Measure cold and hot CI runs

Run this experiment only when publishing/rerunning CI is authorized. The local lightweight checks do not measure remote cache effectiveness. Use a new cache namespace for a cold run of one exact revision; complete the job successfully so the dependency cache is saved. Then rerun that same run/revision once, with no workflow/source/dependency changes. Do not delete an active owner's cache or use the different existing PR80 worktree.

```sh
# First select the completed, authorized cold run; this command only lists runs.
gh run list --repo logseq/logseq_journal --workflow ci.yml --limit 10
COLD_RUN_ID=REPLACE_WITH_COLD_RUN_ID
# Execute the hot measurement only after authorization; this triggers CI.
gh run rerun "$COLD_RUN_ID" --repo logseq/logseq_journal
gh run watch "$COLD_RUN_ID" --repo logseq/logseq_journal --exit-status
# Keep evidence outside the repository. Reruns increment attempt numbers.
EVIDENCE_DIR=/absolute/external/evidence/ci-cache
mkdir -p "$EVIDENCE_DIR"
gh run view "$COLD_RUN_ID" --repo logseq/logseq_journal --attempt 1 --log > "$EVIDENCE_DIR/cold.log"
gh run view "$COLD_RUN_ID" --repo logseq/logseq_journal --attempt 2 --log > "$EVIDENCE_DIR/hot.log"
gh run download "$COLD_RUN_ID" --repo logseq/logseq_journal \
  --name journal-ci-evidence --dir "$EVIDENCE_DIR/hot-artifact"
```

Save each attempt's `journal-ci-evidence` artifact immediately after it completes (including the cold artifact before rerunning); it contains `dependencies.json`, `opam-cache.json` and `packages.txt`. Select the real attempt numbers if not 1/2. Compare the identity JSON/key, resolved SHAs, image/version, compiler, absolute prefix and installed package lists. A changed identity or absent exact hit is a miss, not a hot sample. Record setup/bootstrap, system-dependency preparation, restore, re-pin, locked-install elapsed time and installed/recompiled package counts, final build/test time, cache save time and total job duration. Count setup/compiler cost as well as dependency-install cost; strict matching may trade hit rate for correctness. Keep full build/tests in both attempts. Report measured seconds and counts; do not infer a saving percentage from the earlier two runs, which both installed 170 packages despite a root-cache hit.

## Accept and hand off

Only `status: built` confirms an artifact. Check recorded revisions/dirty hashes, target/SDK/flags, bundle/executable hashes, version and signing identity. Resources/icons precede signing; device profile/certificate/team/entitlements and strict signature are checked. Current GMP archives are rehashed before native macOS acceptance. Experimental builds additionally check Swift object platforms, fresh target C link-map providers and runtime/mldoc/XMLm retention. Listing a `.cmxa` alone does not establish retention.

`preflight-passed` and `link-only` are not runtime acceptance. Preserve `cross_abi_validated=false` for host-restamped objects and state which compilation was reused. Carry the manifest with the App; installation and phone/graph operations are separate from build. For builder changes, use `PYTHONDONTWRITEBYTECODE=1 python3 tool/test_journal_build.py` and the existing icon test as appropriate.
