# Timeline Tags Direct Delete

## Problem

Timeline tags currently follow status at the leading edge and render every title. Deleting a block waits for an Undo deadline and retains restoration state across timeline and detail owners.

## Proposal

Implement the user's requested right-aligned tags, showing the first three in existing order and the remaining count as +N, using native OCaml LUI components without additional graph reads. Keep status readable and allow native text wrapping. Remove the Undo feature under the explicitly approved three protected interface diffs; send Delete immediately, retain visible content while pending, and remove it only on successful completion. A failure keeps content and displays an error. Existing mutation and synchronization contracts remain authoritative.

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
- Full local dune runtest passes 860 Alcotest cases plus custom tests and source/package boundary checks with loopback permission for synthetic peers. The restricted run was stopped after its peer bind was denied; its logs are preserved separately.
- The old macOS toplevel runner cannot load dllapp_stubs because caml_startup is absent. The registered pure and Worker runtime sources pass as native executables linked against the current public compiled interfaces and existing Dune link inputs.
- The branch is rebased onto the PR84 merge 1e38f64644cdd49081004722cd9dd43759b2aaaf. Existing Favorites page/outline, Copy, Capture and list semantics remain; the public page owner also verifies child deletion preserves the page and its composer. Final source checks and one Simulator build run after this integration.

## Questions

None for tags: the user's design is explicit. Protected interface edits remain a separate approval gate and have not been applied.
