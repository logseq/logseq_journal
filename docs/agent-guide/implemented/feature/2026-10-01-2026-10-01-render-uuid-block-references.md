# Render UUID block references

## Problem

Journal block labels currently expose `[[uuid]]` rather than the referenced block title.

## Proposal

Recognize canonical UUID-shaped double-bracket tokens with the existing UUID validator. Preserve page links and escaped tokens. Use the existing Worker V2 indexed block reads and change-window subscription, with a shared graph-session source cache, deduplicated bounded hydration, and generation reset. Render through OCaml/LUI in timeline roots, child summaries, block favorites and detail. Keep persisted/editor source unchanged. Preserve missing, cyclic and bounded-expansion tokens as literal source.

## Decision

Adopt the shared runtime reference cache and bounded OCaml/LUI title rendering for the authorized local implementation.

## Alternatives considered

### Per-row database lookup

Rejected because repeated lookup, cache ownership and change subscriptions belong to the graph runtime, not UI items.

## Consequences

Original source and editor behavior are preserved; display consumers share indexed hydration and incremental invalidation. Tokens beyond explicit resource budgets remain literal. Full Markdown transclusion, per-row interest eviction, cloud-peer acceptance and physical-device acceptance remain outside this change. Baseline harness and repository-check failures are documented separately from the verified UUID behavior.

## Acceptance criteria

- UUID links display referenced content, including nested references, without modifying source.
- Page names, malformed tokens, escaped tokens, missing targets and cycles remain readable.
- Target edits, deletions, recreation and resync refresh labels. Reset fences old responses.
- Reads use UUID indexes; repeated targets share one request. Hydration and expansion have explicit resource bounds.
- Pure model/runtime tests, integration checks, native compilation and an isolated simulator fixture are exercised with honest evidence.

## Risks

- Reference expansion uses bounded depth/work/output and graph-session retained targets; tokens outside the budget remain literal.
- The current literal-text renderer does not implement full Markdown code or alias semantics.

## Questions

None. User authorized local implementation and simulator validation; no push, PR, physical-device deployment or personal graph changes.

## Verification

Implemented and verified locally. The 48 public runtime cases, model checks, ten mounted LUI cases, fourteen existing integration cases and workspace/native build pass. Actual dedicated-simulator feature and clean-main negative-control screenshots verify nested cross-page references, child summaries and literal fallbacks. Full runtest and decision-document checks retain documented main-baseline failures. The warm-start harness banner fails on both feature and clean main; this is not claimed as startup acceptance. See `docs/test-reports/2026-10-01-uuid-block-references/README.md` for limits, exact evidence and cached dependency build provenance. No push, PR or physical-device deployment occurred.
