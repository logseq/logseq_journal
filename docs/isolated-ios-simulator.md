# Build and launch on a new isolated iOS Simulator

Run from a prepared macOS Apple Silicon environment. Read the repository's
journal-build skill first. Requirements: Xcode with an installed iOS >=26 runtime,
Python 3, bash, git, opam, pkg-config/GMP, and an already provisioned locked switch
with matching clean LUI sources. The builder checks Swift, SDK, compiler, pins and
native provenance; this command never installs or repairs dependencies.

Inspect available identifiers with `xcrun simctl list runtimes -j` and
`xcrun simctl list devicetypes -j`. Use explicit identifiers, not `booted`.

```sh
python3 .agents/skills/journal-build/scripts/run_isolated_simulator.py \
  --evidence-dir "$HOME/Library/Application Support/Journal isolated evidence" \
  --switch logseq-journal-lui \
  --lui-package "$HOME/.opam/logseq-journal-lui/.opam-switch/sources/lui/platform/apple" \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-1 \
  --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  --jobs 4
```

Paths containing spaces are supported without relocation or symlink workarounds.
All subprocess arguments are arrays, not shell strings. Jobs must be 1–64. The
evidence directory must be external to the repository. Missing prerequisites,
unavailable runtime/device type, failed build or failed simctl command stop the
pipeline with nonzero exit; no stale manifest/App is selected as a fallback.
Build commands have a 30-minute timeout; other commands have a five-minute limit.

Each invocation creates an `isolated-*` evidence directory and a **new device**.
Only the explicitly returned new UDID is booted, installed or launched. Existing
devices, graphs, logins and caches are not erased. The shared external `build cache`
retains normal locked, hash-validated incremental reuse; the current invocation's
producer and target manifests are read from their command output, never by a
latest-directory glob. Builds run native producer first, then experimental
Simulator import. Before installation the script checks current HEAD/local diff
and all packaged file hashes against the accepted target manifest. It also compares
both manifests' source hashes to the current worktree (including untracked build
inputs), repeats that check immediately before installation, and records the
verified source map. HEAD equality alone is not source provenance.

`session.json` records success/failure, exact commands, return codes, tooling
hashes, source HEAD, manifest hashes, App path, bundle identifier and new UDID.
Adjacent stdout/stderr files, diff and device inventory preserve raw evidence.
The launch screenshot may capture the initial splash rather than settled UI;
`status: launched` proves installation/launch commands, **not onboarding or sync**.
Observe the UI separately using this UDID. Stop at authentication and request user
sign-in; never reuse an existing device's credentials or select a real remote
graph without authorization. Host restamping remains experimental with
`cross_abi_validated=false`, not full iOS cross-compilation or device ABI proof.

Repeat the same command to check warm builds and isolation: it must create a new
UDID and session while revalidating current inputs. Keep failed sessions for
investigation; do not resume them by guessing a previously built App. Devices are
left available for manual UI review even after later failure, with their UDID
recorded immediately after creation. When review is finished, explicitly clean up
**only** devices created by these sessions:

```sh
xcrun simctl shutdown "$OWNED_SESSION_UDID"
xcrun simctl delete "$OWNED_SESSION_UDID"
```

Inspect the session first; never substitute `all` or an existing user's UDID.
Delete only task-owned external caches/evidence when no longer needed. Nothing is
automatically pruned because those artifacts and devices may be under review.

## Regression checks

```sh
PYTHONDONTWRITEBYTECODE=1 python3 .agents/skills/journal-build/scripts/test_journal_build.py
```

The native Dune producer fixture links real objects with `-cclib -Lrelative` and
`-cclib app/libgmp.a`, generates receipts in a physical workspace containing spaces
and apostrophes, imports them and repeats the producer without relinking. The
importer still rejects split options, unbound providers, response files and
conflicting hashes. There is no app reducer that owns this compiler argv boundary;
the regression belongs at the maintained producer/importer boundary.
