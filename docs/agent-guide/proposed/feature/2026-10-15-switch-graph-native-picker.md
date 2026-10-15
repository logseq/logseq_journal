# Switch Graph Native Picker

## Problem

The graph picker uses uneven capsule buttons and loses the active graph when opened. It has no per-row local-copy management or durable presence observation.

## Proposal

Implement the user's selected concept A with native equal-width list rows, a soft header, close/refresh/existing account actions, an inline current marker and a separate row menu. Keep picker and request ownership in OCaml. Query one graph's mirror presence on demand with an account-generation fence; cache observations outside rendering.

The user explicitly permits discarding unsynchronized local content after confirmation (Sentinel_3c2ff0ee96f88191ab349fca7f7befe9). The confirmation must explain this loss, device-only deletion and the retained cloud copy. The active graph requires switching first. Deletion-owner semantics remain gated on separate approval for the existing protected Core contract comment; this document does not grant that approval.

## Alternatives considered

### Reuse the existing graph-picker transition unchanged

It detaches the current graph and clears its identity. Keep an application-owned picker presentation instead, and use the existing Select_graph lifecycle only for an actual switch.

## Acceptance criteria

- Uniform native rows preserve catalog order, expose the current marker and support long names and Dynamic Type.
- Close returns to the retained current graph; name activation switches through the worker.
- Row menus are independently reachable; current graph deletion is disabled with an explanation.
- Presence is bounded and requested only for the relevant graph, with stale and cancelled results ignored.
- Confirmation names the graph, warns that unsynchronized changes/drafts/attachments will be lost and says the cloud copy remains downloadable.
- Isolated synthetic Simulator acceptance covers cancellation, deletion, failure recovery and redownload before PR publication.

## Risks

- Presence can be unknown or fail; expose a clear retry/status rather than assuming a downloaded copy.
- The protected deletion contract approval is separate from this UI/presence implementation.

## Questions

- Design A, Simulator verification, discard semantics and PR publication are already answered by the user's recorded instructions. No unanswered UI/presence question blocks this scope.
