# Cache, recovery and CI measurement


Identity includes source, actual dependency ABI inputs, toolchain/SDK, flags and target. Identical inputs reuse incremental state; changed inputs select another namespace. Every run leaves external phase logs and `run-*/manifest.json`. The cache has a nonblocking lock; native Dune builds also hold the switch read lock. A busy lock belongs to its active owner: coordinate or wait. Preserve existing output/rollback apps and choose a new `--app-dir`; nothing is cleared automatically.

For failure, read `failed_phase`, `error` and that phase's log. Correct target/environment or select matching prepared inputs. Source/configuration/pin/current-input mismatch requires matching provenance; a historical archive change alone can use the validated receipt contract above. Missing mldoc/XMLm retention requires linker-rule review; protected Dune/spec/lock edits still follow the repository's authorization rules. Legacy object-injecting Dune aliases remain refused; probe helpers use the isolated mode above.

## Reuse dependency and build state

The Apple builder consumes a prepared switch; it neither provisions it nor manages GitHub caches. Reuse its existing `run-*/manifest.json`: `inputs.toolchain.opam_prefix` is the canonical absolute switch prefix, `ocaml`/`compiler_sha256` identify its compiler, `inputs.dependencies` records checked lock versions, resolved pins and native library hashes, and `cache_key` selects the incremental Apple workspace. Re-run preflight against the same explicit inputs before building. A matching directory name or a previous `cache_reused: true` does not replace those checks. Do not relocate a switch, copy large caches between worktrees, change global pins, or mix macOS/Simulator/device objects to obtain a hit. Retain final input verification, full build/tests and the target acceptance limits above.

CI dependency caching belongs to `.github/workflows/ci.yml` and `.agents/skills/journal-build/scripts/prepare_ci_dependencies.py`. The workflow first installs the native Homebrew inputs (GMP, SQLite, zlib, zstd and pkg-config), selects their explicit pkg-config directories, and resolves locked Git pins once. `--cache-identity` then records `.ci-reports/opam-cache.json` **before setup creates a compiler or switch**. No installed compiler or opam command is needed for this lookup.

The exact `journal-opam-v3-` key binds root opam/lock bytes and resolved Git SHAs, absolute workspace/switch/root paths, native OS/architecture/build, runner image/version, selected Xcode/clang/macOS SDK, library/header bytes and flags, and compiler environment. A fixed opam-repository commit binds compiler source checksums, patches, options/build commands and package recipes; a pinned setup action and expected opam version bind provisioning behavior. These inputs live in the workflow and must be updated deliberately with toolchain changes. Missing inputs fail closed. The shared Apple builder's actual compiler binary hash remains unchanged for native provenance; generated compiler bytes are recorded in the saved-state receipt instead of used as a pre-restore lookup input.

Restore both the actual `$GITHUB_WORKSPACE/_opam` switch and `~/.opam` metadata before setup-ocaml, with its own overlapping caches disabled. Only an exact Actions hit with a matching `.journal-ci-cache.json` receipt is accepted. The receipt checks input identity, compiler binary bytes and critical switch/root metadata without running the restored compiler. A miss, partial restoration, absent receipt or corrupt state is recorded in `.ci-reports/cache-restore.json`; only the disposable GitHub-hosted runner's exact switch/root paths are moved to `RUNNER_TEMP/journal-rejected-cache-*` before clean setup. Local/foreign paths and symlinks are refused. setup-ocaml initializes or reuses this switch and does not compile a second compiler for an accepted restore.

On every run, setup re-pins local project packages, the preparer re-pins exact resolved checkouts, and `opam install . --deps-only --with-test --locked --ignore-pin-depends --depext-only --yes` verifies system requirements. The ordinary locked install, `dune build @all app/native_embed.exe.o` and `dune runtest --force` remain unconditional. After success, `--seal-cache` rechecks native inputs and actual compiler configuration/version/architecture, absolute prefix and opam version, then writes `.ci-reports/cache-receipt.json` and the switch receipt. The setup action's expected opam executable PATH prefix is normalized for this final comparison; actual selected toolchain/library inputs and other compiler flags are reobserved. A changed final input is an error and cannot be saved. Save a new cache only after all checks pass.

Caches are immutable. If an exact key contains corrupt state, the run records/rejects it and safely cold-builds, but cannot replace that entry. Bump the namespace on an authorized CI change (or delete only that identified cache with explicit authorization), then rerun. Never change another owner's switch, relax ABI identity, rewrite locks, or skip final checks to obtain a hit. GitHub PR merge-ref caches are scoped to that PR: sibling PR misses are normal until a matching default-branch cache exists. Image/SDK/library/repository/lock or resolved moving-ref changes also correctly select a cold cache.

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

Save each attempt's `journal-ci-evidence` artifact immediately after it completes (including the cold artifact before rerunning); it contains `dependencies.json`, `opam-cache.json`, `cache-restore.json`, `cache-receipt.json` and `packages.txt`. Select the real attempt numbers if not 1/2. Compare the identity JSON/key, resolved SHAs, image/version, compiler, absolute prefix and installed package lists. A changed identity or absent exact hit is a miss, not a hot sample. Record setup/bootstrap, system-dependency preparation, restore, re-pin, locked-install elapsed time and installed/recompiled package counts, final build/test time, cache save time and total job duration. Count setup/compiler cost as well as dependency-install cost; strict matching may trade hit rate for correctness. Keep full build/tests in both attempts. Report measured seconds and counts; do not infer a saving percentage from the earlier two runs, which both installed 170 packages despite a root-cache hit.
