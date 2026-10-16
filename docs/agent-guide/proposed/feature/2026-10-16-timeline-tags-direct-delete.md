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

- The user approved the exact three-interface proposal on 2026-10-16 at 08:55:13 UTC (Sentinel_a55c41c2006881918699ecad3290877e). Application, Timeline, Detail and Routes no longer stage or restore deletions. Final cleanup additionally requires approval to remove the unused Journal_platform notice API and Favorites.Reveal_target event; these protected edits remain unapplied.
- Rendering has no pure reducer owner; existing public mounted-view tests are its narrowest boundary. Delete admission is private to Application and needs its existing public mounted Worker fixture unless an existing public pure boundary can reproduce it.
- Host-restamped Simulator objects do not establish full iOS cross-compilation or ABI acceptance.

## Current validation

- Tags mounted semantics: RED on the old alignment, GREEN after the OCaml-only Timeline change; 50 semantics cases pass, including unchanged complete Detail tags.
- Delete mounted boundary: old optimistic staging fails the retained-content assertion; success and failure now pass immediate submission, revision preconditions, duplicate suppression, failure Details/retry and absence of notice requests.
- Full local dune runtest passes 860 Alcotest cases plus custom tests and source/package boundary checks with loopback permission for synthetic peers. The restricted run was stopped after its peer bind was denied; its logs are preserved separately.
- The old macOS toplevel runner cannot load dllapp_stubs because caml_startup is absent. The registered pure and Worker runtime sources pass as native executables linked against the current public compiled interfaces and existing Dune link inputs.
- Final native/Apple build and Simulator acceptance remain pending final notice API cleanup, avoiding a repeated large GUI build.

## Questions

None for tags: the user's design is explicit. Protected interface edits remain a separate approval gate and have not been applied.
