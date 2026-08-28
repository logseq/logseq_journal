# App Startup and Sync Loop Not Advancing

## Problem

The macOS `logseq_journal` app could remain on `Date unavailable` and
`Loading journal` during startup. When the UI did render the selected remote
graph `ocaml-sync-test`, online synchronization could still stop advancing.

The live reproduction exposed four independent failures:

1. the app mirror stayed at `applied_server_t = 150` while the remote graph
   advanced, so neither pull nor queued local push progressed;
2. after the startup continuation was repaired, pull stopped at server
   transaction 176 with an invalid normalized `block/uuid` operation;
3. `bonsai-flutter run macos` launched the process but failed to foreground its
   main window, leaving Flutter startup work unscheduled until the window was
   activated manually.
4. a local transaction queued against the cached mirror could be deferred while
   the opening pull ran, then submitted from its stale pre-rebase payload even
   when the authoritative rebase blocked that intent.

## Proposal

Repair each failure at its narrow ownership boundary:

- distinguish cached catalog restoration from authoritative catalog
  reconciliation, and release post-presentation network work only after the
  authoritative catalog preserves the selected graph;
- decode a Transit array head before its payload so Transit cache indices are
  assigned in wire order;
- after Flutter's native launch callback completes, explicitly activate the
  macOS application and make its `MainFlutterWindow` key and visible.
- replace any deferred transaction batch with the engine's post-pull pending
  payload, and discard the deferred batch when the authoritative rebase returns
  no payload.

Add regression tests at the same boundaries. The manager tests must cover both
deferred reconciliation orderings and a cached catalog arriving before
Timeline presentation. The codec test must contain consecutive cached
`db/retractEntity` operations. The Runner test must verify both activation and
main-window presentation through a test double.

## Decision

Adopt the three boundary repairs without adding transport states, compatibility
paths, parser fallbacks, or Flutter polling.

### Implementation outcome

`Sync_manager.apply_catalog_loaded` now accepts an explicit `release_network`
decision. `Cached_catalog_loaded` updates local startup state without consuming
the future WebSocket challenge. An authoritative catalog result, including one
held until `Timeline_presented`, releases the existing idempotent
`release_post_presentation_network` continuation after the selected graph is
preserved.

`Logseq_sqlite_codec.transit_of_yojson` now resolves a two-element Transit
array's head before decoding its payload. This preserves the writer's cache
ordering and correctly resolves subsequent `^0` and `^1` references as
`db/retractEntity` and `block/uuid`.

`AppDelegate.applicationDidFinishLaunching` now invokes a small native startup
adapter that activates `NSApplication` and makes the first `MainFlutterWindow`
key and visible. The behavior is testable without embedding application-global
state in the test.

`Sync_manager` now treats the pending payload returned by an authoritative pull
as the only valid continuation for a deferred submission. A rebased payload
replaces the stale batch, a blocked or eliminated intent discards it, and a
coalesced follow-up pull keeps the latest rebased payload deferred until the
pull lane is idle.

No temporary runtime logging or diagnostic product name remains in the source.

## Root cause

### Lost authoritative-catalog continuation

The local-first startup barrier restores the account, graph, mirror, and cached
catalog before Timeline presentation. Authentication reconciliation then
requests the authoritative catalog. Before this repair, the generic catalog
handler could release network work for both cached and authoritative catalog
events.

If cached catalog restoration ran first, it created the WebSocket token
challenge before graph presentation permitted network effects. The service
correctly filtered the premature effect, but the manager had already changed
its transport state to `Awaiting_websocket_token`. The later authoritative
catalog event then saw a non-disconnected transport and emitted no replacement
challenge. In the other event ordering, the preserved-selection branch simply
returned no effects after deferred reconciliation.

Both paths left the manager in `Opening_graph` with a durable server cursor, a
disconnected or token-waiting transport, no usable challenge, and queued local
transactions that could not be submitted.

### Transit cache order inversion

Transit cache entries are allocated while values are read. For a tagged
two-element array such as
`["~:db/retractEntity", ["~:block/uuid", "~u..."]]`, the decoder read the
payload before resolving the array head. This registered `block/uuid` before
`db/retractEntity`, reversing the sender's cache order. A following operation
encoded as `["^0", ["^1", ...]]` was therefore normalized as an operation
named `block/uuid` and rejected.

### Missing native activation

The macOS process and Flutter engine were launched, but the tool's foreground
step returned an error and the generated Runner supplied no explicit launch
activation. The process could therefore exist without a key visible Flutter
window. Startup callbacks waiting for a rendered frame did not advance, so the
placeholder date and loading state remained visible until manual activation.

### Stale deferred submission survived authoritative rebase

The manager correctly deferred a pending batch while the opening pull owned the
network lane. `Sync_replay.apply_pull` then rebased durable pending intents
against the authoritative database. However, the manager retained the original
`Deferred_submission` payload and sent it after the pull whenever the socket
became initialized, ignoring the `pending_payload` returned by the engine.

On `ocaml-sync-test`, the cached mirror did not yet contain the current journal
page when capture created its local intent. The authoritative pull found the
existing page and blocked the rebased create-page intent, but the stale payload
was still submitted. The server resolved the deterministic journal UUID to the
existing entity and the stale encrypted cardinality-one updates retracted its
current `block/name` and `block/title`, leaving the remote projection invalid.

## Evidence

The original live mirror remained at transaction 150 while the remote graph
reached transaction 179. A local block remained in the pending-intent queue and
was absent from `logseq-cli`. The exact manager startup sequence reproduced an
empty final effect list and zero usable token challenges.

After separating cached and authoritative catalog behavior, the same macOS
mirror advanced through transaction 182, its pending intent was submitted, and
`logseq search block --graph ocaml-sync-test --content 11111` returned the
app-created block.

The next live pull exposed server transaction 176. Its source contained two
consecutive retract-entity operations, with the second encoded through `^0`
and `^1`. The regression fixture failed before the cache-order repair with
`unsupported normalized transaction operation: block/uuid` and passes after
the repair.

A block created by `logseq-cli` on the `2026-08-26` journal advanced both the
remote graph and app mirror to transaction 183. This proves that the repaired
transport and decoder can consume the reverse-direction transaction; final UI
projection verification is performed as part of the acceptance workflow.

The stale-deferred regression fails before the manager repair because the
opening pull sends the original batch even when `pending_payload = None`. It
passes after the repair. Companion cases verify that a non-empty rebased payload
replaces the original batch after both opening and foreground-probe pulls.

The damaged test journal was repaired after creating a `logseq-cli` backup. The
app mirror pulled the repairs through transaction 185. A clean macOS launch then
rendered `Today`, `Wed, Aug 26`, and the existing CLI-authored entries without
manual activation. A new app capture, `APP -> CLI verified 20260826-2319`, was
visible from `logseq-cli`, and a new CLI block, `CLI -> APP live
20260826-2320`, appeared in the same running app without restart. Both clients
advanced through transaction 187 with no pending transactions.

Finally, an authoritative `logseq sync download` rebuilt the previously
divergent CLI mirror. `logseq sync status` then reported local and remote
transaction 187 with the same checksum, `92c0fce971e89e19`.

The native startup regression test failed to compile before the activation
contract existed. The complete hosted RunnerTests suite passes through the
`bonsai-flutter` macOS execution context, and the unlocked-desktop visual check
confirms the window activates and renders the current journal.

## Alternatives considered

### Release the WebSocket before authoritative catalog reconciliation

This could connect and submit against a graph that the authoritative catalog
is about to revoke, weakening the catalog fence.

### Add another challenge in `Timeline_presented`

This covers only one event ordering and can race catalog reconciliation. The
continuation belongs after authoritative graph preservation.

### Reset the transport when a challenge is filtered

This would couple the service's presentation filtering back into manager state
and introduce a recovery path for an effect that should never have been
created. Cached restoration instead remains side-effect free.

### Special-case the malformed normalized operation

Treating `block/uuid` as `db/retractEntity` would hide a general Transit cache
ordering defect and corrupt other cached symbols. The reader must follow wire
order.

### Poll for Flutter frame eligibility

The runtime already reported frame eligibility while the callback remained
pending. Polling Dart state would mask the native window lifecycle defect and
add another startup state machine.

### Send the deferred batch after any successful pull

This was the previous behavior and treats transport readiness as proof that the
payload is still authoritative. Only the engine can determine the intent's
post-pull transaction, so the manager must consume the engine's rebased payload
instead of retaining serialized transaction data across the pull.

## Acceptance criteria

- A warm start with cached catalog data emits no premature WebSocket challenge.
- Authoritative catalog preservation emits exactly one WebSocket challenge
  after Timeline presentation for both deferred event orderings.
- Opening pull completes before queued local transactions are released.
- Opening pull discards a deferred transaction when authoritative rebase blocks
  it, and submits only the replacement payload when rebase succeeds.
- Consecutive cached Transit retract-entity operations decode to the intended
  normalized operations.
- The macOS host activates and presents its main Flutter window after launch.
- A fresh macOS launch renders the current journal date without manual window
  activation.
- An app-created block becomes visible through `logseq-cli` on
  `ocaml-sync-test`.
- A `logseq-cli`-created block is pulled and rendered by the running app.
- Focused and full automated checks pass with no temporary diagnostic code.

## Consequences

- Cached startup state remains fast and local but cannot consume online
  transport state before presentation.
- Authoritative catalog reconciliation remains the revocation fence and now
  reliably resumes WebSocket-only pull and push.
- Deferred transaction bytes never survive an authoritative rebase; the engine's
  pending result is the sole source of the next submission.
- Transit decoding matches the sender's cache allocation order.
- macOS startup no longer depends on the launcher successfully foregrounding
  the generated Runner window.

## Risks

- Test graph mutations are real remote data and must not be mistaken for
  fixture-only behavior.
- Real graph verification can expose historical invalid transactions that must
  be repaired or redownloaded before projection-level UI acceptance can pass.

## Questions

None.
