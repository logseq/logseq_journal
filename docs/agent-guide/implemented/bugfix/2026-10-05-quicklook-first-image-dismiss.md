# Keep image paging inside its preview

## Problem

On the isolated iPhone13 iOS26.1 Simulator, actual XCTest clicks blue1, pages left to green2 and right to blue1, then sometimes closes the preview on a right gesture toward red0. One shorter center drag previously displayed red0, but an identical repeat dismissed. The repeated paging regression also reproduced the failure immediately from blue. No reliable first-item acceptance exists.

A passive diagnostic override of normal dismiss captured UIKit's _UISceneZoomTransitionDismissInteractionActionToHost path calling QuickLook.dismiss after the right gesture. Journal's explicit close event was not the initiating path. This identifies the observed native dismissal path, without proving which internal recognizer should have won. Diagnostic overrides only logged and called super; no events, private selectors or alternate input were synthesized.

## Decision

Implement the local image pager with UIPageViewController and UIScrollView, replacing only the iOS QuickLook image paging section of swift/JournalImagePreview.swift. The user explicitly approved this scoped design and publishing a nonpersonal test summary to PR47 (“可以 按建议”, in response to the proposal). All unsuccessful standard presentation experiments were reverted before implementation. Do not add a custom pull-down dismissal.

The concrete minimum design is:

- Keep the immutable URL snapshot, selected_index property, OCaml reference retention and existing one-shot dismiss event.
- Use a standard horizontal UIPageViewController with public before/after data-source methods. Each image controller carries its immutable URL/index; boundaries return nil in O(1). Instantiate adjacent controllers on demand instead of decoding/retaining every image.
- Display each image in UIImageView inside a native UIScrollView. Aspect-fit Auto Layout and the standard viewForZooming delegate provide native pinch/pan; no custom gesture recognizers, offsets, per-row geometry or shared scroll state.
- Keep existing UINavigationController Done/Save/Share chrome and JournalPhotoSave dependencies. Read the native pager's current controller URL on Save/Share rather than maintaining a second selected-index state. Close still cancels owner participation while preserving any already staged Photos write.
- Leave macOS QuickLook, generic PDF/text previews, shared LUI, OCaml owners/spec, Dune and other applications untouched.

The implementation adds one local page data source and one image/zoom controller. The single Swift file changes by +139/−43 lines (net +96), including formatting of that file; no other production file changes. Actual native interaction determines acceptance. It adds local page/image coordination and may need explicit handling for formats UIKit cannot render with equivalent behavior; original-byte Photos saving is unchanged. Native paging/zoom interaction, format handling and memory use need actual validation before publishing.

The public save owner has no UIKit paging/dismissal event and cannot reproduce this native defect. The narrow actual UI boundary therefore owns its regression; do not duplicate it across persistence/effect layers or synthesize current-item indices as acceptance.

AGENTS.md requires: “If native APIs cannot satisfy a requirement, explain the limitation and obtain explicit approval before implementing custom UI coordination.” The implemented design crosses that boundary even though the component primitives are native; the user supplied the required explicit approval.

## Alternatives considered

### Standard QuickLook and presentation settings

Actual tests of each candidate failed before reaching red0; no trial code remains:

- Unchanged baseline: right from blue dismissed the modal.
- isModalInPresentation on navigation and QuickLook: modal remained, but blue stayed visible instead of red. Done/reopen, native pinch and Share independently passed under this candidate.
- Outer navigation pop/content-pop recognizers disabled: same blue-stays failure. SDK documentation limits those recognizer properties to establishing failure requirements; disabling them is not proposed for production.
- Reload/initial selection after modal completion: same failure.
- Explicit crossDissolve preferredTransition: same failure.
- Public zoom options interactiveDismissShouldBegin returning false: same failure. The first compile used an ambiguous overload; explicit sourceViewProvider compiled and the actual test still failed.

Earlier navigation-root and direct-modal QuickLook trials also failed and were reverted; navigation-root lost the Save item. Native flags can suppress closing but have not made the valid backward page reachable reliably. [Apple's transition property](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferredtransition) controls the presentation transition; it does not promise pager gesture arbitration. No custom animator was introduced.

### Synthesize item-index events

Rejected: this bypasses actual interaction instead of validating it.

### Retain a single-item QuickLook inside each custom page

Not the minimum proposal: the recorded QuickLook dismissal gesture may still intercept the surrounding pager. A UIImageView/UIScrollView page avoids carrying that same native dismissal path into the fallback. Equivalent rendering for every supported format remains a review/validation risk.

## Acceptance criteria

- Repeated actual second→first/reverse traversals with correct red/blue/green pixels, correct clicked index, and both boundaries excluding PDFs/other blocks.
- Retained Save/Share/Done, current-image original-byte saving, native pinch/pan, close/reopen and one-shot retention cleanup.
- The failed native QuickLook candidates aborted at their first blue→red assertion. The approved native pager passed two actual five-round traversals and both boundaries; the second run used the final formatted source.
- No merge until required native acceptance and final-head CI pass.

## Validation

The original public OCaml media/save owner cannot reproduce UIKit gesture arbitration, so normal XCTest input on an isolated generated fixture is the narrow regression boundary. No current-index mutation was used as UI acceptance.

- Native pager first run: 3/3 pass, including five rounds of second↔first/reverse traversal, both boundaries, clicked blue/Done/reopen, native zoom/Share and independent group/PDF exclusion.
- Final formatted source: repeated five-round traversal and both boundaries pass again, clicked red and clicked green pass, magnified image grows and native pan changes its frame, return to fit restores paging, Share follows current green/blue.
- Actual Photos confirms current green, reverse-paged current red and single yellow as 640×420 PNG. Photos initially sorted equal source timestamps by capture date and two red checks selected older assets; selecting native Recently Added fixes the asset-selection harness, without a production save change. Preserve those failed results.
- Real Application final-source fixture: Timeline/Detail/block-Favorites Copy→system Paste matches the raw root, all135children, multiline indentation and depth3 unseen descendants. Page favorites expose no Copy. Actual Status change, subtree Delete and Undo pass. A first repeat selected the already-selected Todo and left the native picker open; selecting a different valid status is the meaningful repeat, without production changes.
- Swift6 Simulator fixture compilation, changed-file swift-format (wire-name rule disabled for the existing selected_index field), and git diff --check pass. Full-suite sandbox failures from loopback bind/cache permissions are recorded separately from the normally authorized rerun.

## Consequences

The image-only iOS preview now owns the small native page data source and zoom delegate. At minimum zoom, disable the image scroll view's native pan recognizer so horizontal input belongs to the pager; enable image pan while zoomed. Selection is read from the native current controller, not duplicated. Photos staging and OCaml retain/release remain unchanged. This architecture follows native component responsibilities, independently implemented rather than copying [WordPress reference code](https://github.com/wordpress-mobile/WordPress-iOS/blob/d3c12d46c2ddeea35af73c97fffccae6c71a539d/WordPress/Classes/ViewRelated/Media/Lightbox/LightboxImageScrollView.swift). The approved initial scope omits a custom dismissal gesture.

## Risks

- The native pager adds a local page data source and zoom delegate compared with immutable QuickLook data source alone; the user explicitly approved that coordination.
- UIImageView rendering may differ for animated or uncommon image formats. Do not silently broaden the declared support or claim equivalent rendering without evidence.
- The final pushed head still requires its own CI before merge; c5e8bc7 success does not establish the new source.

## Questions

- None: the user approved the scoped native pager/zoom coordination and a nonpersonal PR test summary. Merge remains conditional on actual acceptance and exact-head CI.
