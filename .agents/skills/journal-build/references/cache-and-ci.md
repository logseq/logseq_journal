# Cache, recovery and CI measurement


Identity includes source, actual dependency ABI inputs, toolchain/SDK, flags and target. Identical inputs reuse incremental state; changed inputs select another namespace. Every run leaves external phase logs and `run-*/manifest.json`. The cache has a nonblocking lock; native Dune builds also hold the switch read lock. A busy lock belongs to its active owner: coordinate or wait. Preserve existing output/rollback apps and choose a new `--app-dir`; nothing is cleared automatically.

For failure, read `failed_phase`, `error` and that phase's log. Correct target/environment or select matching prepared inputs. Source/configuration/pin/current-input mismatch requires matching provenance; a historical archive change alone can use the validated receipt contract above. Missing mldoc/XMLm retention requires linker-rule review; protected Dune/spec/lock edits still follow the repository's authorization rules. Legacy object-injecting Dune aliases remain refused; probe helpers use the isolated mode above.

## Reuse dependency and build state

The Apple builder consumes a prepared switch; it neither provisions it nor manages GitHub caches. Reuse its existing `run-*/manifest.json`: `inputs.toolchain.opam_prefix` is the canonical absolute switch prefix, `ocaml`/`compiler_sha256` identify its compiler, `inputs.dependencies` records checked lock versions, resolved pins and native library hashes, and `cache_key` selects the incremental Apple workspace. Re-run preflight against the same explicit inputs before building. A matching directory name or a previous `cache_reused: true` does not replace those checks. Do not relocate a switch, copy large caches between worktrees, change global pins, or mix macOS/Simulator/device objects to obtain a hit. Retain final input verification, full build/tests and the target acceptance limits above.

CI dependency caching belongs to `.github/workflows/ci.yml` and `.agents/skills/journal-build/scripts/prepare_ci_dependencies.py`. After setup, resolution and a fresh `--depext-only` system-dependency preparation, `python3 .agents/skills/journal-build/scripts/prepare_ci_dependencies.py --cache-identity` records `.ci-reports/opam-cache.json` without installing or pinning. It reuses the builder's compiler identity helper; this report describes compatibility, not installed dependency validation. The workflow caches the actual `opam var prefix` (normally `$GITHUB_WORKSPACE/_opam`), not just `~/.opam`. The setup action's overlapping caches are disabled. Only exact keys are restored; there are no broad `restore-keys`.

The CI key binds all root opam/lock bytes and resolved Git SHAs, compiler configuration/binary, opam version/root, OS/architecture, runner image/version, selected Xcode/clang/macOS SDK, GMP/SQLite/zlib versions, flags and available library/header bytes, relevant compiler environment, absolute workspace/prefix and the provisioning recipe. Missing or incompatible identity is an error. For a miss or a recoverable restore failure, the fresh setup switch plus unconditional re-pin and `opam install . --deps-only --with-test --locked --ignore-pin-depends --yes` remains the rebuild path. A cache hit never skips those commands, `dune build @all app/native_embed.exe.o`, or `dune runtest --force`.

If the restored switch is corrupt or pin/lock checks fail, preserve the identity, action logs and package list; do not accept the old state, rewrite locks or force a different-platform cache. On an authorized subsequent CI change, bump the workflow's `journal-opam-v2-` namespace (or remove only the identified corrupt Actions cache with explicit authorization) and rerun on a fresh hosted runner. Setup and locked installation then reconstruct it. Locally, use a separate explicitly authorized prepared switch at its own absolute prefix; the Apple builder reports mismatches and never repairs an existing owner's switch. A busy switch/cache lock still requires coordination.

### Measure cold and hot CI runs

Run this experiment only when publishing/rerunning CI is authorized. The local lightweight checks do not measure remote cache effectiveness. Use a new cache namespace for a cold run of one exact revision; complete the job successfully so the dependency cache is saved. Then rerun that same run/revision once, with no workflow/source/dependency changes. Do not delete an active owner's cache or use another owner's worktree.

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
