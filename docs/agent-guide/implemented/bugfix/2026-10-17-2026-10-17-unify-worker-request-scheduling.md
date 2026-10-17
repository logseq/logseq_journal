# Unify Worker Request Scheduling

## Problem

A Favorite block completion drains hydration internally and the public receive boundary drains the same output again. Requests become active without reaching transport; four completed outline dependencies can strand UUID title lookups and subsequent background work. Favorite Page titles and detail Page root titles also miss shared reference discovery/rendering.

## Proposal

The user approved unified App-to-DB-Worker scheduling on 2026-10-17. Internal runtime transitions produce demands and mark their priority without dispatching. Public runtime entry points alone enqueue and drain once; queued and active identity sets are disjoint and deduplicated. Retain the shared four-read background bound and existing foreground admission. Transport delivers each output once and retires rejected unsent demands explicitly without retrying Worker.send. Application shares graph request admission and ownership routing instead of separate Favorites/admission/general delivery loops; Copy/media/assets retain their own state machines. Include Page titles in the existing reference observer and use the same title renderer.

## Decision

Use private Planned/Queued/Dispatched delivery state in the existing graph runtime, one public dispatch boundary and one Application Worker adapter. Route admission, Favorites and ordinary graph outputs through the same transport and typed completion path. Complete the existing Page title observer and shared renderer wiring without changing the public protocol or protected interfaces.

## Alternatives considered

### Increase the background or Worker limit

Rejected: it masks lost delivery and cannot bound arbitrary graph fan-out.

### Add another resolver or retry loop

Rejected: one graph-session owner already controls reference epochs and cache. Rejection must settle ownership explicitly, not silently resubmit work.

## Consequences

Every background slot now corresponds to a request returned for delivery. Refusal retires unsent ownership, including work released by failure completions, without another send attempt. Copy, media and asset state machines keep their domain ownership while sharing physical Worker admission. Graph scope cancellation and duplicate protocol-ID protection live in the adapter. The background limit remains four and Worker concurrency remains two.

Page-first lookup still falls back to an outline block only after an explicit missing Page result. UUID references expand to ordinary non-clickable text. No deprecated double-parenthesis reference syntax, new resolver, Dune change, dependency pin change, graph edit or phone operation is included.

## Acceptance criteria

- Public Runtime regressions drain at least four Favorite block dependencies and queued references exactly once; failures, cancellation, duplicate completions, reset and epoch changes preserve capacity and fencing.
- Foreground reads remain admitted while four background demands are outstanding; only explicit missing Page results trigger outline fallback.
- Transport refusal releases all unsent ownership and reports failure without hidden send retries.
- Favorite Page titles and detail Page roots discover references; display uses shared lookup and creates no reference link.
- Existing targeted tests and full build/tests pass; validate controlled fixtures and the existing A135 Lambda RTC read-only flow with identified artifacts.
- Do not modify Dune, protected spec interfaces, real graph data or the phone. Any required protected interface change needs a precise separately approved diff.
- Open a formal PR, run an independent review session using journal-code-review, address valid findings and follow CI. Do not merge.

## Risks

- Priority inheritance must preserve initial foreground feed loads and bounded background refreshes.
- Worker rejection can produce more failure completions; settlement must remain bounded and must not send retries.
- Experimental host-restamped Simulator artifacts retain cross_abi_validated=false and require fresh source provenance after changes.

## Questions

- None. The user explicitly approved this scope; no protected interface change is currently proposed.

## Verification

New public Runtime and narrow mounted Application owner regressions failed before the production changes and pass afterward. A fresh private locked switch passed the full Release build and tests: 21 Alcotest suites with 906 cases, plus 87 standalone PASS records. A complete Application/Worker replay of a consistent real-data copy sent and received the target once and resolved both Favorites and detail titles.

A135 was updated in place to the formal Simulator build 1.5877.34, source/native revision 6ab0ead. A cold-start test explicitly selected the existing Lambda RTC graph, opened Favorites and the original target detail, and returned normally: both title hashes matched the resolved result, rawToken=false, links=0, and the detail was static text. The single UI case passed in 17.992 seconds; graph outbox counts were zero before and after. No credentials were entered and no graph edit was performed. Favorite Page-specific cases are covered at the public owner boundary, not claimed as a separate real-graph Page example.

The Simulator uses experimental Host ARM64 restamping with cross_abi_validated=false; it does not establish a fully cross-compiled OCaml iOS ABI. Formal PR review and exact-head CI are the remaining publication gates. Two new documents validate individually; the all-document check retains three previously recorded unrelated format failures.
