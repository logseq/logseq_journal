# Cold-start A/B/C measurement and rejection report

## Decision and scope

Reject B and C: no established startup benefit. No production optimization, cache, layout extraction or cache-only tests remain in the review worktree. Only this report is delivered in Git; raw measurements, rejected sources, regression outputs and reproduction tools remain in the external evidence directory.

Base: `e7164b68f47f881ae51eadcb691b19125df34ad6`. Worktree: `/private/tmp/journal-cold-start-ab-review-20261113`. No commit/push. Background shell `9b27de6e-76c3-4e2d-a8e0-62df074ff4a3` exited 0 at 2026-11-13T09:15:47.097Z.

## Four prerequisite decisions

1. **Generic work: attribution not established, candidate rejected.** Six five-second Time Profiler traces do not identify the concrete dominant generic type owner. JournalList.View is an observed application owner, not proof it owns dominant framework metadata work. A conformance inclusive samples: 763/797/753 ms; B: 760/786/807 ms. Sampled CPU A: 1635/1686/1620 ms; B: 1658/1628/1701 ms. Inclusive categories overlap: do not add them. B layout extraction was reverted; absence of attribution is a negative finding, not a completed optimization premise.

2. **Non-current page: not applicable to this startup.** `review-prerequisites-round1.log` records one current Pane construction and zero non-current Pane constructions before any input. The synthetic startup has only one slot mounted; no non-current mounted owner exists to suppress. This is not evidence about multi-page sessions. The `AB_SLOT_MAKE owner=... shown=...` instrumentation and raw log are retained.

3. **Authentication: causal controls, not temporal attribution.** Same instrumented binary in all six runs, reversed order normal/suppress/toggle/toggle/suppress/normal. Suppress prevents only authenticationRequired publication, preserving the service response and other account fields; logs prove a true publication attempt was blocked. Delayed toggle changes only authenticationRequired three seconds after setup, after the initial replacements, acting as an independent positive reactivity control. All use the same synthetic offline fixture and eight-second observation window. Source is archived under review-measurement-sources.tar.gz; `review_auth_controls.py` asserts actual update and runtime-start counts. This is a state-publication intervention, not an authenticated-versus-unauthenticated account comparison or proof that all auth/session operations are isolated.

| Run | Condition | Publication attempts | Auth updates | Host evaluations | Root replacements | Runtime starts |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | normal | 1 | 1 | 5 | 2 | 1 |
| 2 | suppress | 1 | 0 | 5 | 2 | 1 |
| 3 | toggle | 2 | 2 | 6 | 2 | 1 |
| 4 | toggle | 2 | 2 | 6 | 2 | 1 |
| 5 | suppress | 1 | 0 | 5 | 2 | 1 |
| 6 | normal | 1 | 1 | 5 | 2 | 1 |

Normal and suppressed both retain exactly two replacements (initial/interactive, then style) and one runtime start. Suppression does not reduce five host evaluations: startup invalidations may coalesce, so this does not prove auth never reevaluates the host. The delayed flip yields six evaluations, no third replacement, and no second runtime start; thus the observation path detects auth-driven reevaluation while root/runtime remain stable in this fixture. The two startup replacements are not caused necessarily by this authenticationRequired publication. No auth-isolation production change is warranted by these measurements.

4. **Exact decode work: reduced, startup benefit absent.** C holds at most one successful exact UTF-8 payload/value per Chrome owner lifetime and static Properties type. Changed bytes evict before decoding; failed decodes are not retained. Pure boundary tests cover repeat, replacement, malformed JSON, canonically equivalent but byte-different Unicode, owner isolation and eviction. Red exit 133 and green logs retained; these tests validate a rejected candidate and are not left as dead production tests. Symmetric `AB_ACTUAL_DECODE` counters wrap the actual decoding engine, not cache-hit branches. Raw six-round counts:

| Run | Variant | Actual Chrome decodes | Decode path ms |
| --- | --- | ---: | ---: |
| 1 | A | 40 | 1.978456 |
| 2 | C | 23 | 2.047458 |
| 3 | C | 23 | 1.935625 |
| 4 | A | 40 | 2.142166 |
| 5 | A | 40 | 2.174626 |
| 6 | C | 23 | 1.990791 |

A: decode time mean 2.098416 ms, sample SD 0.105149 ms.

C: decode time mean 1.991291 ms, sample SD 0.055918 ms.

Actual calls fall 40 to 23 in every run (17 fewer, 42.5%). Three observations per variant and roughly two ms of instrumented work do not establish latency savings. Instrumentation itself perturbs the path; this is not a launch timing comparison. The initial full-byte prerequisite recorded 52 decode calls / 6.279459 ms across all types, including 26 exact owner/type/payload repetitions. Do not compare that different scope to Chrome-only counters.

## All uninstrumented rounds and noise

Each process-cold run accepts a readable/hittable fixture row and actual tap-to-native-detail input. Metrics are XCTest launch/idleness/query/IPC/animation confirmation bounds, NOT true first-interactive application time. Order is counterbalanced, five observations per variant per round-set. OS/filesystem caches remain warm. The second A/C set was run after background build activity ended, with no task-owned build/profile workload; “idle” is not a claim of machine-wide zero load. Earlier loaded results are retained separately and not pooled. SD is sample SD; range and all observations are included to avoid hiding outliers. No significance or real-device speedup claim.

### A/B layout extraction

| Run | Variant | Ready s | Input-to-detail s | Total s |
| --- | --- | ---: | ---: | ---: |
| 1 | B | 2.821284 | 2.299554 | 5.120838 |
| 2 | A | 2.814782 | 2.315478 | 5.130260 |
| 3 | A | 2.804788 | 2.315676 | 5.120464 |
| 4 | B | 2.813303 | 2.314431 | 5.127733 |
| 5 | B | 2.792036 | 2.300501 | 5.092537 |
| 6 | A | 2.806774 | 2.303428 | 5.110202 |
| 7 | A | 2.781763 | 2.312517 | 5.094281 |
| 8 | B | 2.814929 | 2.287346 | 5.102276 |
| 9 | B | 2.798345 | 2.285475 | 5.083820 |
| 10 | A | 2.810759 | 2.295848 | 5.106607 |

| Variant | Metric | Mean s | Sample SD s | Min s | Max s |
| --- | --- | ---: | ---: | ---: | ---: |
| A | ready | 2.803773 | 0.012889 | 2.781763 | 2.814782 |
| A | input | 2.308589 | 0.008690 | 2.295848 | 2.315676 |
| A | total | 5.112363 | 0.013699 | 5.094281 | 5.130260 |
| B | ready | 2.807979 | 0.012254 | 2.792036 | 2.821284 |
| B | input | 2.297462 | 0.011700 | 2.285475 | 2.314431 |
| B | total | 5.105441 | 0.018561 | 5.083820 | 5.127733 |
### A/C first set (background activity)

| Run | Variant | Ready s | Input-to-detail s | Total s |
| --- | --- | ---: | ---: | ---: |
| 1 | C | 2.818358 | 2.300541 | 5.118899 |
| 2 | A | 2.805218 | 2.285862 | 5.091080 |
| 3 | A | 2.794028 | 2.290888 | 5.084916 |
| 4 | C | 2.821676 | 2.283220 | 5.104896 |
| 5 | C | 2.802594 | 2.372387 | 5.174981 |
| 6 | A | 2.841455 | 2.307798 | 5.149253 |
| 7 | A | 2.791912 | 2.301546 | 5.093457 |
| 8 | C | 2.984161 | 2.303983 | 5.288144 |
| 9 | C | 2.783601 | 2.280718 | 5.064318 |
| 10 | A | 2.822194 | 2.286046 | 5.108240 |

| Variant | Metric | Mean s | Sample SD s | Min s | Max s |
| --- | --- | ---: | ---: | ---: | ---: |
| A | ready | 2.810961 | 0.020849 | 2.791912 | 2.841455 |
| A | input | 2.294428 | 0.009818 | 2.285862 | 2.307798 |
| A | total | 5.105389 | 0.025973 | 5.084916 | 5.149253 |
| C | ready | 2.842078 | 0.080847 | 2.783601 | 2.984161 |
| C | input | 2.308170 | 0.037335 | 2.280718 | 2.372387 |
| C | total | 5.150248 | 0.086676 | 5.064318 | 5.288144 |
### A/C unloaded repeat

| Run | Variant | Ready s | Input-to-detail s | Total s |
| --- | --- | ---: | ---: | ---: |
| 1 | C | 2.809476 | 2.320083 | 5.129560 |
| 2 | A | 2.816191 | 2.292335 | 5.108526 |
| 3 | A | 2.789996 | 2.321006 | 5.111002 |
| 4 | C | 2.818772 | 2.317180 | 5.135951 |
| 5 | C | 2.786967 | 2.305316 | 5.092283 |
| 6 | A | 2.839541 | 2.318740 | 5.158280 |
| 7 | A | 2.773637 | 2.336920 | 5.110557 |
| 8 | C | 2.794560 | 2.321917 | 5.116477 |
| 9 | C | 2.800686 | 2.320171 | 5.120857 |
| 10 | A | 2.813427 | 2.287687 | 5.101115 |

| Variant | Metric | Mean s | Sample SD s | Min s | Max s |
| --- | --- | ---: | ---: | ---: | ---: |
| A | ready | 2.806558 | 0.025426 | 2.773637 | 2.839541 |
| A | input | 2.311338 | 0.020755 | 2.287687 | 2.336920 |
| A | total | 5.117896 | 0.022922 | 5.101115 | 5.158280 |
| C | ready | 2.802092 | 0.012452 | 2.786967 | 2.818772 |
| C | input | 2.316933 | 0.006713 | 2.305316 | 2.321917 |
| C | total | 5.119026 | 0.016752 | 5.092283 | 5.135951 |

Unloaded C total is 1.130 ms slower than A (5.119026 vs 5.117896 s), with SD 16.752/22.922 ms. C ready improves 4.466 ms but input worsens 5.596 ms: no consistent gain. Earlier C total was 44.858 ms slower with much larger SD; background activity is a confound, not grounds to discard unfavorable rounds. B total improves 6.922 ms, smaller than noise, while ready worsens 4.206 ms and CPU samples do not improve. Both candidates are rejected.

## Reproduction, provenance and regression evidence

External evidence root: `/Users/rcmerci/Library/Application Support/alma/workspaces/default/cold-start-evidence`.

- `review_run_ab.py`, `review_uitests.swift`, archived Measurement project and `review_generate_fixture.py`: synthetic fixture and uninstrumented input acceptance. App binary SHA-256 and paths are in each per-round JSON.
- `review_count_launches.py`, `review-count-results.json`, raw console logs: symmetric actual-engine count experiment. `review_auth_controls.py`, `review-auth-results.json`, raw six logs: authentication counterfactual experiment.
- `review-measurement-sources.tar.gz`: staged probe/count/auth/seeder Swift, fixture generation and Measurement host source, including interventions; no App binaries or DerivedData. `review-build-provenance.tar.gz`: task-owned build JSON/manifests/logs and hashes of removed generated files; source/runtime evidence is historical after cleanup, not a currently runnable binary.
- `review-rejected-B.patch`, `review-rejected-C.patch` plus the three `review-rejected-C-*` source/test files preserve rejected candidates. The C patch records tracked changes; the three accompanying files are required to reconstruct its added files.
- `review-source-build.log`, `review-regression-baseline.log`, `review-final-source-build.log`, `review-final-regression.log`, payload red/green logs and xcresults are retained as historical runs, not falsely relabeled as tests of final documentation. All delivered production bytes equal HEAD; final validation is document/data consistency, source equality, status and diff hygiene in `review-final-validation.log`.

Simulator evidence uses experimental host-restamped native source with `cross_abi_validated=false`; it is not real-device ABI acceptance. Task simulator BEA835FB-2040-4C23-A6F7-33D28CA34FC7 is removed only after evidence capture. No real graph, credentials or other simulator is changed. Cleanup manifest records exact task-owned removed paths; worktree and external evidence remain. Independent review is left to the user; attempted specialist delegation failed with no active model context, so no independent-review approval is claimed.

Final diff digest and exact hashing command are recorded separately in `review-final-diff.sha256` and `review-final-validation.log` to avoid a self-referential hash. The patch includes untracked report content via `git diff --no-index /dev/null docs/cold-start-measurement-review.md`; no staging or commit is performed.
