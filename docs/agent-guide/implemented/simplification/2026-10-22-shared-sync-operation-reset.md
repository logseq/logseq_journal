# Shared Sync Operation Reset

## Problem

At main b6c1c77c4cd7b94963e4729dfac55b825c838085, six transitions in
logseq_sync/lib/pure_reducer/core.ml repeat the same nineteen operation-state
resets: authenticate_new_account, restore_local, sign_out,
select_graph_transition, clear_selected_graph_for_catalog and
return_to_graph_picker. Maintaining these identical assignments separately
obscures which resets are common and which lifecycle policies differ.

## Proposal

Extract only those identical assignments into a private pure helper. Keep all
caller-specific account/graph/presentation generations, pending-effect filtering,
mirror inspection, websocket ownership, cancellation, detach and publication
ordering at each caller. Do not apply the helper to fail, whose retained state
differs. No public interface, protected spec, Dune, dependency or wire changes.

## Decision

Adopt the proposal as explicitly authorized by the user on 2026-10-22.
Implementation and verification are local; no push or PR is authorized.

## Alternatives considered

### Generalize every teardown

Not selected: failure, graph selection and account replacement have different
ownership and cancellation policies. A configurable reset framework would hide
those differences and add policy instead of sharing identical assignments.

## Acceptance criteria

- Existing pure core and recovery tests pass before and after the refactor.
- Temporary public-API traces compare inputs, visible state, admitted graph scope,
  asset context and complete ordered effects for all six reset paths, including
  stale completions after replacement. Evidence stays outside Git.
- No tests are removed, weakened or added permanently for the mechanical change.

## Risks

- Sharing a non-common reset would alter lifecycle behavior. Verify the exact
  nineteen-field intersection and preserve every caller-specific assignment.

## Consequences

The six transitions now share one private nineteen-field reset. Every remaining
caller statement, including effect order, matches the baseline after extracting
those assignments; fail is byte-for-byte unchanged. Existing pure core (87 cases)
and recovery (21 cases) pass before and after. Temporary fixture replay covers
121 pure core/recovery/asset cases, with 1,972 identical public input/state/context/
ordered-effect records across builds. No abstract state was inspected.

## Questions

None. On 2026-10-22 the user authorized these three audited simplifications and
actual before/after verification, with temporary evidence only and no push or PR.
