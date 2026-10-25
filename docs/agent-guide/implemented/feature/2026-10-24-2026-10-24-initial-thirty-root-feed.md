# Thirty Root Timeline Batches

## Problem

The initial Timeline allocates a tree-node budget across dates. Direct children can consume a parent's allowance and disappear from its preview when a page splits that parent from its children. The user requires every initial and subsequent batch to contain 30 displayed roots across dates, excluding headings and previews from that count.

## Decision

Use one root scanner for initial, same-day and older-date requests. Enumerate journal metadata in seven-date packets, then root-only tree pages in existing date/order order until 30 visible roots or exhaustion. Read only the first three ordinary direct children independently, including asset metadata, with bounded concurrency and adaptive byte-sized requests. Retain asynchronous media and failure/retry semantics. Remove the tree-node budget allocator and its feed operations; keep the existing Worker API unchanged. Preserve loaded suffixes and UUID scroll anchors on sync refresh, and fence old graph/session/page completions. Do not change protected spec or Dune files.

## Alternatives considered

### Increase tree limits or merge all tree fragments

A larger tree budget cannot ensure 30 roots and fetching complete branches is unnecessary for three previews. Root-only reads and independent bounded child reads use existing public Worker commands without changing their semantics.

## Acceptance criteria

- Public Runtime request/completion tests cover 30 roots across dates, sparse/empty/filtered days, exhaustion, ordinary and asset previews, very wide branches, byte splitting, stale/duplicate completions, later continuation and change reconciliation.
- Initial ordering remains journal date descending and existing sibling order. No child/header consumes the 30-root budget.
- Every later request uses the same 30-root budget and fills across dates. Root-only cursors keep their query shape.
- Validate local tests and an isolated synthetic Simulator fixture without mutating user graph content. Installing a test build over a real-data App requires separate explicit user authorization.

## Consequences

- Existing Children enumeration can scan/hydrate more candidates than its returned limit. This change does not claim a hard scan bound or introduce a new database index.
- Separate existing Worker commands incur per-root reads; concurrency and byte splitting bound the burst. A future batch API is outside this minimal change.
- Native snapshot/byte/cursor failures remain explicit, never evidence of empty children.

## Validation

The final locked OCaml 5.5.0 environment passed the complete forced runtest suite, including Runtime 165, Application view 148 and sync 333 cases. Pure Timeline cases cover cross-date deduplication, sync prefix/suffix retention, inserted roots, stable visible UUIDs and failed older-date requests without retry loops.

An isolated iPhone 13 / iOS 26.1 Application fixture used 20 Today roots plus eight older dates spaced three days apart, 135 text children and two cached image children. Actual native payloads progressed 20 (partial initial), 30, 60, 90 and 116 unique roots; final exhaustion removed continuations. XCTest verified image opening/closing, child 135 after explicit Detail pagination, final-root Detail/Back and foreground position retention. Screenshots were inspected. CUA input failed window lookup; the supported XCTest path supplied the physical interaction evidence.

The fixture deliberately blocks authentication. Live remote-server synchronization was not exercised; controlled sync changes and old-result fences are validated at their public Runtime/Timeline ownership boundaries. The experimental host-restamped native build retains cross_abi_validated=false and does not establish full iOS cross ABI acceptance. No real graph was changed.

A later separately authorized read-only session used the ordinary App with an existing real graph after a data-preserving update. XCTest completed 32 upward swipes; numeric native payload statistics recorded 30, 60 and 90 unique roots across 22 descending journal dates. The full original-speed recording shows child previews and image assets. Diagnostics before and after recording reported Ready/Open/Current, zero pending records and equal local/remote transaction numbers. This verifies local-mirror progressive reads, not a fresh server transfer or server-side E2E synchronization. The experimental cross ABI limitation remains unchanged.

PR validation exposed an ambiguous fixture selector: a child preview can repeat a top-level title, so text-only lookup could compare different native nodes. Standard OCaml hash randomization reproduced the original failure. Scope the existing Composer test selectors to the stable UUID row without removing identity or feedback assertions; 30 randomized repetitions of both retained-import scenarios passed. Product sources remain identical to the native-tested inputs.
