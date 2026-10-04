# Detail and Preview Media Lifetime

## Problem

Independent review R2 shows that collapsing a Detail child removes its native media node but leaves its presentation demand/file owner live. R3 shows an open file-preview keeps a path after its row releases the last file reference. Both reproduce through real mounted Application events on aaea1c4 and precede the navigation fix.

## Decision

Retire per-Detail media root ownership when the rendered outline structurally removes rows and when its native visible range excludes them. Validate late callbacks against retained entry and current outline roots while retaining covered entries. Give an open preview a separate ownership reference on its media controller, independent of row visibility; retire that reference on dismissal, replacement, mount disposal, graph or entry retirement. Preserve shared assets, lazy actual appearance, lease/ticket fences and R1 early-return handoff.

Pure boundary attempt: Journal_detail collapse publicly removes child rows but owns no media demand/effects. Journal_media Hide correctly releases when there is no remaining consumer; it has no preview Press or native row lifecycle input. Injecting Hide or a stale path would manufacture the upstream defect. The narrow mounted Application boundary executes both missing handoffs, so import the independently proven public probes here and extend their lifecycle checks without duplicate lower-layer regressions.

## Alternatives considered

### Release on every native onDisappear

Navigation covering and interactive transition can disappear without retiring the retained presentation; this would regress R1.

### Keep all row leases while any preview is open

Pins unrelated assets and does not model which resource the preview consumes.

### Always close preview on row offscreen

The user requested an independent valid resource reference for the open preview. Preserve that consumer until its actual lifecycle ends.

## Acceptance criteria

- Independent R2 collapse probe is RED before and releases only the removed child's last ownership after.
- Preview offscreen probe is RED before; after an open preview has a valid resource reference, and closing it releases the final reference exactly once.
- Cover collapse/reopen, same asset with other owners, pending Acquire completion, navigation and graph invalidation, preview close/replacement/invalidation and PNG/PDF/file behavior through public mounted events.
- Appropriate full regressions and isolated actual native collapse/QuickLook verification; explicitly distinguish public-event controls from UI gestures.
- Freeze a local after commit and Git-external evidence; no push/PR/merge/phone or user graph changes.

## Risks

- Structural row retirement must not confuse a navigation-covered page with an unmounted child.
- Preview references must stay bounded by live preview consumers and release on stale descriptor/session transitions.
- Existing independent tests use synthetic Worker paths; native verification supplies actual files and QuickLook where feasible.

## Questions

- Answered: parent provided the user's explicit approval to fix R2 and R3 in addition to R1, including local tests and commit. No additional product tradeoff is needed.

## Consequences

Application prunes each retained Detail scope against current rendered outline roots on structural route changes and actual Native List ranges. Late root/asset callbacks are checked against the current outline, without unconditional onDisappear retirement. Runtime preview slots participate independently in the existing controller/root owner union and reuse its valid file lease; parent presentation retirement and graph reset clear them. Media view closes and unsubscribes on dismissal, disposal or item invalidation. Replacement is atomic, so repeated offscreen selection does not drop its only lease first. Imported previews keep their existing receipt reference and pin the group against eviction while open. Spec, Dune, native backend and UI simplification plans remain unchanged.

## Implementation evidence

Both verbatim independent probes are RED on aaea1c4. The final archive has all 72 production App inputs equal to that commit and exactly the same final test as after. The preview assertion implements the requested independent consumer: offscreen releases no selected file while preview is open; closing the last preview releases the file and demand once. The original probe's invalid URL evidence is retained outside Git.

All 29 targeted cases and all 55 Application cases pass, including R1, collapse/reopen, shared Timeline owner, Detail offscreen, pending Acquire, graph retirement, child preview disposal, preview navigation/pop/reset, availability and descriptor invalidation, repeated open/close and repeated offscreen selection. The last case exposed an implementation-stage replacement gap; RED evidence is retained. Forced full dune runtest exits0 with the frozen dependency closure. Initial sandbox networking stalled the sync test; its interrupted log is retained, and the identical suite passes with authorized local network/native access. No teardown workaround is added.

Actual native before reproduces collapse release delta0 and PNG/PDF/TXT QuickLook continuing to hold a URL after real background UICollectionView programmatic scrolling naturally retires all row leases. Native after collapse releases only the child file+demand once, keeps root leases and reacquires a fresh child on reopening. PNG/PDF/TXT QuickLook after each retains its original lease through natural offscreen range and releases it once on native dismissal. Exact source hashes are in the Git-external final report/manifests; taps, swipe and combined cache-pressure coverage are not claimed. Before is frozen aaea1c45207abb576ffc40e32b104232fceabccd; parent arranges independent review of the final clean local after SHA.

## Queue pressure followup

Final public Runtime verification on frozen0798a5c exposes a queue-admission boundary: preview attempts to join an already acquired/shown controller while pending release commands fill the outgoing queue; its ownership is rejected, so row retirement drops the last file. The pure media reducer has no admission queue and its equal Show correctly emits no new request. This distinct boundary is tested only through Runtime's public methods/send backpressure, without private state or a duplicate mounted pressure test.

Accept owner joins for already shown controllers regardless of outgoing request capacity. Keep admission for new Show/demand work. The preview reuses a current lease, adds no request, and must remain valid until dismissal. Preserve0798a5c and its native evidence; final after gets a separate local commit, the full related tests and native after source verification. UI simplification remains deferred.

The same final public Runtime test is RED (business assertion, exit2) on a production archive of0798a5c and GREEN (exit0) after this one-line guard change; the independent reviewer separately reproduces the same admission defect. Final targeted29, Application55 and forced full dune runtest pass. Five newly compiled native after runs cover Detail collapse/reopen, PNG/PDF/TXT QuickLook with natural background native scrolling, and two ordinary UIKit Back transitions; all pass against the original aaea before records. These native runs verify the new source but do not inject a saturated queue. Their manifests and final commit source proof are separate from the preserved0798 evidence.
