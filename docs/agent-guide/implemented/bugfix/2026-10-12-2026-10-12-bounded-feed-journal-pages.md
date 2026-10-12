# Limit journal reads to the remaining feed days

## Problem

The initial feed needs seven days, but feed_request requested 200 complete journal page records. Property metadata can make that unnecessary batch exceed the unchanged 262144-byte encoded response budget before the first feed renders.

## Decision

Each V2_list_journals request asks for the remaining valid feed days, capped at the protocol maximum. Filtering and opaque-cursor continuations continue across recycled pages until the requested window is complete or the query ends. Complete page fields, date bounds, slot limits and has_more_days remain unchanged.

## Alternatives considered

### Raise the byte limit

Rejected: it preserves excessive reads and conceals the caller's over-fetching.

### Remove properties from page records

Rejected: it changes complete protocol records and can silently discard data.

### General byte-aware Worker pagination

Deferred: this change corrects demand planning. A general solution requires the enumeration/encoding owner to return a complete bounded prefix with its exact opaque continuation, plus an explicit policy for indivisible oversized records.

## Consequences

- feed_request uses min maximum_page_size (day_limit - retained_page_count).
- Public Runtime.submit/receive regressions cover rich metadata budget, recycled-page continuation, remaining-day count, slot/protocol bounds and explicit singleton failure.
- No protected spec, Dune, authentication, transport or byte-limit definitions changed.
- A requested window can still exceed 256 KiB cumulatively, or one complete page can independently exceed it. Existing explicit errors remain; no records are silently omitted.

## Ownership

The public feed reducer retains day_limit but does not select protocol read limits. The defect reproduces at Journal_graph_runtime's public request-planning boundary. Formal regression tests therefore live only in its existing suite. Separate one-off acceptance uses public Runtime, Worker and Overlay interfaces with a disposable constructed graph; its scratch host and evidence remain outside the repository.

## Verification

All three new regressions failed before implementation due to over-fetching. The complete 101-case Runtime suite passes, as do Timeline, Application, Routes and source-boundary checks. Full @all/native_embed compilation succeeds with OCAMLPATH unset against the lock-aligned switch. The forced full run has one external-compilation failure because its existing root detector cannot find .git from an external build directory; the unchanged test passes when rerun from the repository with the same public compiled interfaces. All other full-run cases pass.

The disposable constructed graph contains 201 distinct journal dates and seven complete property definitions/values per page. The old limit-200 request returns responseTooLarge. New seven-day windows use at most seven records and at most 47435 encoded bytes; 29 windows return all 201 dates in order, with no duplicates, missing dates or property truncation. Exactly 201 successful journal records are returned, so later windows are not fetched early. The indexed database query is unchanged; no retry-by-rehydration or full-graph scan was added.

No successful personal-graph GUI acceptance is claimed. An initial Simulator attempt did not relink an overwritten external native object; the workflow was corrected to use a content-addressed native link input and verified relinking. Final user authorization accepts the constructed graph instead of requiring personal graph GUI checks.

## Risks

This is not a general byte-aware pagination solution. Equal-date ordering and filtering preserve existing semantics; the acceptance graph uses distinct dates. The 256 KiB cap remains unchanged, including for legitimate oversized singleton records.

## Authorization

The user authorized this scoped fix, constructed-graph validation, retaining 256 KiB, branch push and a formal pull request. Merge and phone installation are not authorized. No personal graph mutations or credential access were performed.
