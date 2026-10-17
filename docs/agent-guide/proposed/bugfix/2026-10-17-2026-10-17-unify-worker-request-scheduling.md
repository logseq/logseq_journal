# Unify Worker Request Scheduling

## Problem

A Favorite block completion drains hydration internally and the public receive boundary drains the same output again. Requests become active without reaching transport; four completed outline dependencies can strand UUID title lookups and subsequent background work. Favorite Page titles and detail Page root titles also miss shared reference discovery/rendering.

## Proposal

The user approved unified App-to-DB-Worker scheduling on 2026-10-17. Internal runtime transitions produce demands and mark their priority without dispatching. Public runtime entry points alone enqueue and drain once; queued and active identity sets are disjoint and deduplicated. Retain the shared four-read background bound and existing foreground admission. Transport delivers each output once and retires rejected unsent demands explicitly without retrying Worker.send. Application shares graph request admission and ownership routing instead of separate Favorites/admission/general delivery loops; Copy/media/assets retain their own state machines. Include Page titles in the existing reference observer and use the same title renderer.

## Alternatives considered

### Increase the background or Worker limit

Rejected: it masks lost delivery and cannot bound arbitrary graph fan-out.

### Add another resolver or retry loop

Rejected: one graph-session owner already controls reference epochs and cache. Rejection must settle ownership explicitly, not silently resubmit work.

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
