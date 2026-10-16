# Capture Local Assets

## Problem

Capture drops a valid imported-file lease because its completion has no Detail route owner. The durable original is not published in the ordinary asset cache, and pending same-UUID media does not refresh its demand when metadata changes. A saved Capture can therefore show Waiting for upload despite an available original and later download its own upload.

## Proposal

Admit current Capture completions, resolve local files through the existing scoped durable upload intent, and publish verified originals into the ordinary asset cache through Core.Asset_requested and the sealed runner. Split private lookup and fetch tickets so Fetch always requires a remote version; use the exact strong spec diff approved on 2026-10-16. Refresh pending media demand when its version identity changes while preserving an already displayed file. No new persistent state, business phase, dependencies, Dune changes, or public worker callback changes.

## Decision

Use the approved strong ticket split and scoped local publication path. Keep durable upload intents as the sole persisted mapping, preserve successful displayed files, and retire temporary previews on handoff or matching cancellation.

## Alternatives considered

### Optional remote version on the shared transfer ticket

Initially approved, then superseded by explicit approval of private lookup_ticket/fetch_ticket and lookup-source variants. A shared optional version admits a Fetch without a remote version and relies on runtime guards.

### Retain the imported preview indefinitely

This does not support cold start or group eviction and leaves lease cleanup tied to a transient UI group. Use the existing durable intent and ordinary cache instead.

## Acceptance criteria

- A saved Capture displays its original before PUT completes, with no asset GET.
- Pending local assets resolve offline, including after restart, in their exact account and graph scope.
- A missing local original never causes a GET without an explicit remote version; cancelled and stale completions cannot expose another scope's file.
- Publishing an original preserves active leases, survives cache reopen, and allows staging cleanup without redownloading the original.
- Pending same-UUID metadata changes refresh demand; an already displayed file remains stable.
- An open imported preview keeps its token, path and lease until its final preview owner closes; background cache handoff must not dismiss it.
- Public owner regressions, existing lifecycle suites, and isolated synthetic Simulator checks pass. No real upload or private graph is used.

## Risks

- Local and remote checksums may differ. Local lookup must use the current checksum and remote fetch must use the explicit remote version.
- Publication and release must preserve staging pins and fenced graph/account lifecycles; publication failure must not discard the source.
- Simulator host-restamped OCaml objects provide experimental runtime evidence, not clean iOS cross-compilation or ABI acceptance.

## Consequences

- The existing upload intent remains the durable identity authority. Its existing scope reconciliation also rebuilds a private in-memory asset/checksum index; lookup does not rescan every checkpoint for every visible attachment.
- Import attempts verified cache publication before returning. A pending lookup can use the retained original when cache capacity is exhausted. Successful terminal cleanup secures ordinary residency before retiring staging; failure preserves the source for recovery.
- A preview hands off only after the ordinary controller acquires a File and no open preview still owns the imported token. Explicit close and owner cleanup finish the handoff; multiple previews retain the original until the final one closes. Cancelled notifications release an unpublished preview only for the matching scope and operation; failed or waiting uploads retain local display.
- Public owner regressions cover offline local readiness, missing local files, checksum changes, stale completions, scope mismatch, cold lookup, publication and lease lifetime, metadata refresh, preview handoff, and cancellation. Existing Application, upload, transfer, worker, cache, and sealed-interface checks pass.
- Isolated Simulator checks show both an old pending Capture and a newly saved Capture as final Timeline images before any asset PUT or GET, including after cold restart. The same installed binary later completed both encrypted PUTs and full metadata publication acknowledgements against a loopback synthetic service. Both intents reached Complete, staging was cleaned, and a subsequent cold start acquired the two ordinary cached originals with zero asset GETs. The service applied received transactions through public Database interfaces and computed acknowledgement checksums through public snapshot activation; no product completion events or persisted completion states were injected. This does not establish real cloud upload or full iOS cross-compilation/ABI acceptance.

## Questions

- May the two protected spec interfaces use the displayed strong ticket split and Publish_staged_asset request? Answered: explicitly approved by the user on 2026-10-16, replacing the optional-ticket proposal.
- May implementation use an isolated synthetic Simulator without touching private graphs or real network uploads? Answered: authorized; coordinate build and GUI windows with the other tasks.
