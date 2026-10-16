# Timeline Tags Direct Delete

## Problem

Timeline tags currently follow status at the leading edge and render every title. Deleting a block waits for an Undo deadline and retains restoration state across timeline and detail owners.

## Proposal

Implement the user's requested right-aligned tags, showing the first three in existing order and the remaining count as +N, using native OCaml LUI components without additional graph reads. Keep status readable and allow native text wrapping. Remove the Undo feature under the explicitly approved three protected interface diffs; send Delete immediately, retain visible content while pending, and remove it only on successful completion. A failure keeps content and displays an error. Existing mutation and synchronization contracts remain authoritative.

## Decision

Adopt the native OCaml Timeline tag layout and immediate deletion flow described above. The exact protected API removals are approved; implementation and synthetic acceptance are complete.

## Alternatives considered

### Keep Undo API as unused compatibility wrappers

Rejected because the user explicitly requires removing the complete feature and its obsolete tests, with no compatibility wrappers.

## Acceptance criteria

- Tags: 0, 1, 3, 4 and more; correct remaining count and stable title order.
- Native trailing alignment and wrapping work with long names, narrow screens and accessibility text sizes, alongside status and assets.
- No increased graph-query scope or hidden-title rendering.
- After interface approval, no Undo UI, events, deadlines, restoration state or compatibility API remains.
- Synthetic fixtures verify successful delete, failure feedback and duplicate suppression without touching personal graphs.
- Use the narrowest existing public owner tests and coordinate a real Simulator screenshot; reuse prepared dependencies and incremental build inputs.

## Risks

- The user approved the exact three-interface proposal on 2026-10-16 at 08:55:13 UTC (Sentinel_a55c41c2006881918699ecad3290877e). Application, Timeline, Detail and Routes no longer stage or restore deletions. The user additionally approved removal of the notice API and Favorites.Reveal_target on 2026-10-16 at 09:11 UTC (Sentinel_e1cc9f8dab808191abd16e0f60c651dd). Both interfaces and their sole-purpose implementations and obsolete tests are removed.
- Rendering has no pure reducer owner; existing public mounted-view tests are its narrowest boundary. Delete admission is private to Application and needs its existing public mounted Worker fixture unless an existing public pure boundary can reproduce it.
- Host-restamped Simulator objects do not establish full iOS cross-compilation or ABI acceptance.

## Current validation

- Tags mounted semantics: RED on the old alignment, GREEN after the OCaml-only Timeline change; 50 semantics cases pass, including unchanged complete Detail tags.
- Delete mounted boundary: old optimistic staging fails the retained-content assertion; success and failure now pass immediate submission, revision preconditions, duplicate suppression, failure Details/retry and absence of notice requests.
- Full local dune runtest after PR83 integration passes 876 Alcotest cases plus 87 custom PASS checks and source/package boundary checks with loopback permission for synthetic peers. The restricted run was stopped after its peer bind was denied; its logs are preserved separately.
- The old macOS toplevel runner cannot load dllapp_stubs because caml_startup is absent. The registered pure and Worker runtime sources pass as native executables linked against the current public compiled interfaces and existing Dune link inputs.
- The branch is rebased onto main bb2b9fbd8d0e090e90b5ab7f1b0e990ce0e09169 after PR83, PR84 and PR85 integration. PR85 changes only CI/build documentation and tests; all native-source hashes remain identical to the completed 876-case run. Existing Favorites page/outline, Copy, Capture and list semantics remain; the public page owner also verifies child deletion preserves the page and its composer. Final source hashes are checked; the current-main Simulator app has a successful unified-builder manifest and all five native XCTest scenarios pass (67.439 seconds, zero failures).

- Final native Simulator evidence covers narrow tags 0/1/3/4/9, long names, status/image layout, successful direct deletion, visible failure Details/retry, one request under repeated pending actions, and largest accessibility text wrapping. All fixtures are in memory on a new device; no personal graph was deleted. The initial UI positioning failure was corrected only in the external driver and the final full run passes.
- The final actual screenshot is Library libfile_01b78e91e8ec81918a5f1d672cca0943; additional final screenshots and the test result are in the external task evidence. The probe remains cross_abi_validated=false and does not claim a production iOS cross-compile.
- This decision validates. Full spec-dev-tool check --all still reports three unchanged pre-existing main documents missing required sections.

## Consequences

Timeline now displays at most three existing tag titles and an exact remainder, without widening reads. Delete submits immediately with existing revision/sync semantics; while pending, content remains visible and duplicate deletion is disabled. Successful completion removes it, while failure keeps authoritative content and explains recovery. Undo backup state, events, timer/notice wire and Swift presenter are removed rather than wrapped. Both protected interface edits followed their explicit exact-diff approvals.

## Questions

None. Both exact protected interface proposals were explicitly approved and applied within that scope.
