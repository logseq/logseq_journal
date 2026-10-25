# Today First Root Batch

## Problem

Normal Logseq journal navigation can create future journals. Their roots can fill the initial 30-root batch before Today contents are read, while the synthetic Today section says No journal entries.

## Decision

The user selected B on 2026-10-25: prioritize Today roots in the initial 30-root batch, then spend the remaining budget on the existing descending-date scan. Preserve future journals, chronological presentation and sibling ordering. Subsequent batches continue the same scan without re-reading the prioritized day or skipping deferred future dates. Each batch contains at most 30 displayed roots, with independent bounded child previews and asynchronous assets.

Separate scan continuation from display order in App projection/request types. Carry the chronological date boundary and the already-prioritized day in date continuations. Runtime retains each loaded page's following date range independently of disposable Worker structure cursors; automatic recovery, Retry and retained-page reconciliation cannot erase it. Reset clears that graph-scoped traversal state. These are App-local types; Worker protocol, protected specs and Dune files remain unchanged. Refresh and midnight start a new priority observation while preserving retained suffix identities and anchors.

## Alternatives considered

### Keep unloaded Today explicit

A would retain loading priority and display an unloaded Today message. The user explicitly selected B; A is not the final solution. Reading extra Today roots outside the 30-root budget would violate the requested quota.

## Acceptance criteria

- Normal-client source reachability plus supported isolated graph mutations reproduce the original false-empty behavior.
- Populated, empty and absent Today; Today below/at/above 30 roots; future 29/30/31 roots and multiple future dates; complete pagination preserves every root UUID exactly once.
- Keep final date/sibling order, child and asset behavior, retained history, refresh and midnight isolation, error/cursor correctness and UUID anchors.
- Use production-owner public regression boundaries, observe RED before implementation, then run appropriate final full regression and CI.

## Consequences

- Priority and date order differ: deriving the next query from the last displayed day would skip future journals. Continuations must carry query traversal state.
- Prefix refresh is no longer a contiguous chronological prefix when Today is prioritized. Retained suffix merge must treat Today and chronological coverage separately.
- Source reachability and local API probes do not establish deployed Web revision, new native acceptance or remote-server E2E.

## Questions

- Resolved: user selected B, prioritizing Today inside the first 30 roots. No remaining product decision blocks implementation.
