# Targeted Journal Media Subscriptions

## Problem

In frozen stage1–3 commit57b62c6 and feature-removal commitdc331ab, one visible
asset's Failed→Ready→acquired-file transition updates the shared media_views map.
The root presentation selector invalidates the entire retained Timeline twice.
Actual synthetic full-runtime N50 builds100 row descriptors; bounded N500 builds1000,
although both emit only18 patch operations. Descriptor work is not pixel painting.
The user explicitly directed: “订阅粒度不能是整个timeline，只应该订阅最小的部分”.

## Proposal

Use a Journal-local presentation store with indexed root-structure and root/item
subscriptions. Media runtime remains owner of demand, presentation and file leases.
Changed roots update the store directly on the existing UI scheduler. Root structural
changes notify only mounted dependent containers; item presentation changes notify only
mounted item regions. No model-wide row selector scan. Root/Detail subscriptions cease
depending on shared media_views identity only after their media regions read the store.
Preserve fixed image slots and native media/preview owners. Scope generation, unmount
cleanup and stale ticket handling remain explicit. Ordinary attachments and parent/child
galleries are supported; do not rewrite navigation or generic LUI reconciliation.

## Decision

Implement this local subscription boundary on feat/journal-targeted-media-updates,
based on dc331ab. User authorization includes local native/Melange/full regression and
synthetic Simulator checks, excludes remote Git writes, phone installation and user graphs.
Coordinate Simulator use with the parent because Emacs GUI acceptance is active.

## Alternatives considered

### Remove media_views from root equality alone

Rejected: currently media descriptors capture a static snapshot, so images would stop
refreshing without a replacement subscription boundary.

### Subscribe every row to the global model

Rejected: renderer cutoffs reduce builds but still run N selectors per media event.
Use a reverse subscription index keyed by the actual root/item dependency instead.

### Coalesce Opening and File into one state

Rejected: acquisition is asynchronous, can fail, and must preserve waiting feedback and
lease/cancellation semantics. Both updates may remain while their work is localized.

## Acceptance criteria

- Public mounted Application RED reproduces broad Ready propagation before source edits.
  Pure Journal_media correctly changes statuses and cannot own mounted subscription scope;
  the narrowest public defect boundary is Application.For_testing plus Worker/UI events.
- Single-image state transitions at different retainedN cause zero unrelated row, Timeline
  and root builds. Compare/notification counts depend on changed roots/items/subscribers.
- Shared-asset presentations update each actual dependent location. Metadata topology,
  parent/child galleries and ordinary nonimage attachments continue to render.
- Preserve failed/retry, stale acquisition release, cancellation/hide, graph/session reset,
  scope disposal and file leases through existing owners and public tests.
- Native and applicable Melange builds/tests pass without modifying Dune/protected spec.
  Complete current aggregate tests and coordinated final-source synthetic Simulator runs.
- Reports distinguish builder/notification/patch/decode from body/layout/paint and disclose
  untested permutations. Preserve baseline and previous deliverables outside Git.

## Risks

- Reconciliation may retire a mount scope; listeners must unregister idempotently, and
  pending Signal tasks must not publish into disposed subscribers.
- Parent-owned versus child-owned descriptors can change with metadata. Structure updates
  must recompute ownership and rebind individual item subscriptions with stable keys.
- Generation changes must clear prior cached presentation and prevent same-UUID stale data.
- Root-local shape comparison can scan the changed root's attachment group; it must not
  scan every retained Timeline row or all store roots on ordinary item publications.

## Consequences

Media updates become presentation-local while model/reducer and runtime lease ownership
stay intact. Structural row changes still rebuild their containing Timeline as before.
No total-app latency, FPS or hardware paint improvement is inferred from fewer builders.

## Questions

- Implement minimum actual media subscriptions with local-only validation? **Answered:**
  the user explicitly requested this behavior and the scoped acceptance listed above.

## Implementation record

Indexed root-structure and root/token-item subscriptions are implemented locally.
Both root and Detail now bind media regions to the presentation store, and their
model equality no longer depends on shared media_views identity. Snapshot storage
remains for existing model/static test interfaces; runtime and lease owners are unchanged.
Root-group topology comparisons exclude presentation and file-path availability.
Item changes update a fixed slot's dynamic content; no global per-row selector is added.
Each mount owns idempotent unsubscription plus Signal disposal. Graph/session reset
clears cached views and fences prior-epoch listeners.

Public Application N3/N50 single-item phases and shared-asset two-consumer phases
pass: Failed/Ready/Acquire each only updates actual item subscribers, with zero root,
Timeline or row renderer calls. Every Timeline title node and native List identity remain.
Public gallery, nonimage, token/owner rebind, topology, dispose/remount and epoch tests
pass. Full Application26 cases and semantics25 cases pass; full @all/runtest and both
original registered native macOS regression groups pass.

Melange7 compiles the exact production nested Store module with its exact public Store
signature, unchanged public Graph_types/Asset_descriptor source, and type-only public
runtime view/item/presentation declarations. Node N50/N500 tests exercise actual Store
subscribe/update/remove/reset/equality operations. This is scoped Store portability,
not full Application/Worker/LUI JS rendering. The repository's app library is native-only;
a direct compile with native dependency interfaces fails inconsistent Stdlib assumptions.
No repository Dune or protected spec changed to disguise that limitation.

Ordinary updates scan only the affected root's attachment group and union of old/new
tokens, then notify changed tokens' actual subscribers. Item subscribers currently use
List.find_opt within their root group, so S notified subscribers can add O(M*S) lookup
work for M attachments; this remains independent of unrelated retained rows. That is not a claim of one-token
comparison for a multi-attachment root. Runtime query/import groups are bounded; no
retained-row scan, eviction, generic diff change or app-latency guarantee is introduced.

Final-source synthetic iOS Simulator acceptance completed after the parent authorized
background-only execution on the independent Journal device A135D95E. Navigation used
its separate 6B86F6EE device and retained foreground ownership. Three runs completed
without failures: single-location N50, protocol-valid paged N500, and shared-asset N50.
N500 warmed seven pages to retain500 roots. Ready plus actual Worker Acquire constructs
only two media items in either single-location run: root/Timeline/row0, topology notify/build0,
item compare/notify/build2, two patch batches/18 operations, one acquired lease and one
PNG decode. Shared N50 updates two distinct row/file-image locations: four item builds,
two batches/36 operations, two leases and two initial image decodes. No shared-path decode
coalescing claim is made. Failed changes one item per actual location; duplicate Ready,
stale-generation notices and callbacks after unmount produce zero media work and patches.
After Back remount, Ready remains local and image cache hits replace fresh decodes.

All83 production hashes and70 compiled source digests match the measured final source.
The diagnostic links the real Application, C bridge, native List/file-image owners and
LUI4b06 with a synthetic serial Worker and public event driver. Existing host-arm64 OCaml
static dependencies are retagged for Simulator; this is not a new iOS OCaml cross compiler.
No screenshot, CUA, front activation, user graph, phone install or remote Git operation
was used. Actual graph replacement is covered by public Application tests, not these
native stale-notice runs. Pixel appearance, gesture hit-testing, real sync/database and
hardware FPS/latency remain unmeasured. Navigation remount behavior is outside this change.

Git-out evidence is implementation-evidence/targeted-media, targeted-media-updates/test-owner
and targeted-media-native, including raw logs, command/provenance proof and review patch.
Previous frozen stage1–3/removal evidence remains unchanged. Full-document validation
retains the preexisting unrelated bottom-lui-capsules missing-sections failure; this new
decision validates independently.
