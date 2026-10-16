# Timeline Tags Direct Delete

## Problem

Timeline tags currently follow status at the leading edge and render every title. Deleting a block waits for an Undo deadline and retains restoration state across timeline and detail owners.

## Proposal

Implement the user's requested right-aligned tags, showing the first three in existing order and the remaining count as +N, using native OCaml LUI components without additional graph reads. Keep status readable and allow native text wrapping. Remove the Undo feature after explicit approval of the three protected interface diffs; send Delete immediately, retain visible content while pending, and remove it only on successful completion. A failure keeps content and displays an error. Existing mutation and synchronization contracts remain authoritative.

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

- Undo removal is blocked on explicit approval of app/journal_timeline_state.mli, app/journal_detail.mli and app/journal_routes.mli. The exact proposal is retained outside the repository. Independent tags work can proceed.
- Rendering has no pure reducer owner; existing public mounted-view tests are its narrowest boundary. Delete admission is private to Application and needs its existing public mounted Worker fixture unless an existing public pure boundary can reproduce it.
- Host-restamped Simulator objects do not establish full iOS cross-compilation or ABI acceptance.

## Questions

None for tags: the user's design is explicit. Protected interface edits remain a separate approval gate and have not been applied.
