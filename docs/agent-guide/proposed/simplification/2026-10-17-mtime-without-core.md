# Mtime Without Core

## Problem

Journal uses Jane Street Core only to measure two loading delays and express a five-second notification lifetime. The application needs monotonic elapsed time for the loading gates; calendar clock adjustments must not affect them. Core also remains a declared dependency and appears in two package locks.

## Proposal

Replace the two application elapsed-time measurements with `Mtime_clock.counter` / `Mtime_clock.count`, converting `Mtime.span` nanoseconds to floating-point seconds with `Mtime.Span.to_float_ns span *. 1e-9`. Keep the notification lifetime as `5.` seconds and keep the existing `Thread.create`, `Unix.sleepf`, pump delivery, running flag and generation checks. Do not use monotonic values as calendar timestamps.

The initially approved protected-file patch was extended by the user’s explicit Base-cleanup authorization. Its final scope is:

- `app/dune`: replace library `core` with `mtime.clock` and remove unused direct library `base`.
- `dune-project`: in the `logseq_journal` package, replace `(core (= v0.17.2))` with `(mtime (= 2.1.0))` and remove unused `(base (= v0.17.3))`.
- `logseq_journal.opam`: replace `"core" {= "v0.17.2"}` with `"mtime" {= "2.1.0"}` and remove unused `"base" {= "v0.17.3"}`.
- `logseq_journal.opam.locked` and `logseq_db_worker.opam.locked`: remove Core and 52 constraints belonging exclusively to its dependency closure, including Base, Stdio and unused Core PPX packages. The exact removed-name set and per-edge dependency evidence live in the task’s external `evidence/exact-dependency-closure.json`. Both already lock Mtime 2.1.0. Preserve all retained versions and every pin; do not prune unrelated stale constraints or compiler `base-*` pseudo-packages.

No `.mli`, `spec/`, other Dune file or dependency source edit is proposed. Update the existing temporary-notice source boundary assertion and exercise timing ownership through the existing public startup and route reducers. All temporary evidence stays outside the repository.

Initial investigation used main `fc27cfd62e7fede81185c7ec0bc8807fca797b52`. The parent confirmed PR90, PR91 and PR92 merged at main `87d0cccd0d65e77958a090d4181c7b9c9bd5fb94`. This isolated branch was fast-forwarded to that exact revision. The five protected dependency files have no changes between these two main revisions, and the six Core timing references remain the only application use. The updated journal-build producer-only instructions were read; the exact five-file patch is approved, and all builds are still pending resource coordination.

## Decision

Use Mtime counters for elapsed loading time and apply the approved five-file dependency patch plus the user-authorized Base cleanup in those same files. Keep all existing timer scheduling and owner fencing.

## Alternatives considered

### Keep wall-clock elapsed measurements

Rejected because adjusting system calendar time can change elapsed loading time. Mtime 2.1.0 is already locked and its public `mtime.clock` library supports counters directly.

### Rewrite scheduling or introduce a new timer abstraction

Rejected because this task only changes elapsed-time measurement and dependency identity. The existing public reducers own cancellation and stale-result fencing; changing scheduling would expand the behavioral scope.

### Remove similarly named packages or shared switch installations

Rejected. Jane Street Base, compiler `base-*` pseudo-packages and the project-specific `Core` modules, `melange-edn-core` and `melange-transit-core` are separate dependencies. Base itself is now authorized for removal after proving it is unused; retain the unrelated names. The old global switch contains outdated Mldoc metadata and is not evidence of the current pinned dependency graph. Do not modify another owner's switch or pins.

## Acceptance criteria

- Receive explicit approval for the exact dependency/Dune/lock patch before applying it; record the response and transition to proposed before changing other repository files.
- Recheck current main and use an isolated branch with no unrelated task changes. Do not push, open a PR, merge or install on an iPhone.
- Verify dependency removal first fails against the baseline and passes after implementation; retain the existing behavioral tests for the 100ms loading boundary, ready/completed/failed/retired owners, retry and graph generations, startup background interruption and fresh resume grace. Add only missing coverage at those public pure-owner boundaries.
- Build all source targets and run the complete test suite with the prepared locked switch after the parent releases the CPU/Simulator window. Follow the current journal-build entry point and provenance checks.
- Build baseline and changed Apps with the same target, configuration, toolchain and signing inputs, record exact hashes and sizes, inspect actual link inputs and Core symbols, and perform Simulator runtime checks without creating devices or changing private graphs.
- Verify the iPhoneOS target compiles/links and preserve any host-restamp ABI limitation. Host restamping is never proof of a complete cross-compiled OCaml ABI.
- Run spec-dev-tool check --all and report remaining limitations honestly, with no predicted 2.09MB saving claim.

## Risks

- Mtime 2.1.0 uses `mach_continuous_time` on Darwin, including system sleep. Startup's foreground event retires the previous serial and resume creates a fresh grace period. Detail owns no foreground reset; its existing owner and request generation checks continue to govern a callback delivered after suspension. Preserve these semantics.
- The current global switch's old Mldoc metadata requires Core, Core_bench and Core_unix. The verified task10 prepared switch has pinned Mldoc b3e06c and no installed package depending on Core; use that switch's recorded identity, not the stale global switch, for validation.
- Official opam direct-dependency queries at every exact installed package version show no Core or Base in the Journal or Worker production/build closure. Version-ambiguous recursive queries can traverse older recipes and give misleading Base chains. Current URI/IPaddr/Macaddr references to `ppx_sexp_conv` are upstream `with-test` dependencies; their runtime libraries and Journal’s Yojson PPX driver do not require Base. Remove only Core-exclusive constraints, preserving shared `sexplib0`, `sexplib`, `parsexp` and all other live build dependencies.
- PR92 adds a producer-only native build route; wait for the parent's final main identity and resource release before selecting the baseline or building.

## Questions

- Approved. The parent relayed the human user’s explicit “允许” response to the exact five-file patch on 2026-10-17. No `.mli` or `spec/` edits are included.

## Authorization

The approved scope is `app/dune`, `dune-project`, `logseq_journal.opam`, `logseq_journal.opam.locked` and `logseq_db_worker.opam.locked` with only the replacements/deletions listed above. The original task authorizes the matching application implementation and relevant tests. The parent confirmed the Timeline performance experiment released the heavy-build/Simulator window at 09:17:40 UTC on 2026-10-17. Full tests and target builds are now authorized; only device 1446 may be used for isolated synthetic acceptance and its existing app/data must remain untouched.

## Base cleanup authorization

The parent relayed the human user’s explicit instruction: “如果能清理掉就清理，检查是不是依赖库依赖了base”. This authorizes removing the unused direct Base declarations in the same three files and handling the same two locks according to the real dependency closure, without upstream edits. No additional protected file is required. A Base-removal boundary test failed on all five existing declarations before removal.

## Validation progress

The approved implementation passes startup, route and source-boundary targeted tests, `dune build @all app/native_embed.exe.o` and full `dune runtest --force` with the original prepared switch, Release profile and two jobs. The candidate complete object has zero defined Core/Base symbols and retains Mtime/Mtime_clock. The new clone reuses the original CI pin-resolution record through a read-only ignored pointer; no pins, switch or producer proof was modified. Target App/link, size and Simulator checks follow.
