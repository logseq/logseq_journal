# Reuse Attachment Decoding

## Problem

At main b6c1c77c4cd7b94963e4729dfac55b825c838085, decode_event parses the
event and its picked branch parses the same JSON again through parse.
decode also duplicates to_import's mapping from staged picks to worker imports.

## Proposal

Share the picked conversion on an already decoded Json.event and reuse
to_import from decode. Preserve all public entry points, typed JSON/UUID
validation, request identities, error strings, batch order and
replace_reference=None. Do not change Swift picking, cancellation, staging,
security scope, ownership or cleanup behavior.

## Decision

Adopt the proposal as explicitly authorized by the user on 2026-10-22.
Implementation and verification are local; no push or PR is authorized.

## Alternatives considered

### Merge the public APIs or narrow the event vocabulary

Not selected: direct import, staged picks and batch events have existing
consumers and tests. Private reuse removes duplication without a protocol change.

## Acceptance criteria

- Existing routes/platform tests pass before and after the change.
- Temporary comparisons cover valid/invalid UUIDs, malformed JSON and typed
  fields, absent/valid request IDs, all event kinds, ordered batches and exact
  errors/import fields. Public APIs remain unchanged; temporary tests stay out
  of the repository.

## Risks

- Reordering validation or using a broader event decoder could change errors or
  accept previously invalid inputs. Reuse only the already validated record and
  identical field mapping; do not claim a measured performance improvement.

## Consequences

The private picked helper consumes a validated event, and direct decode reuses
to_import. Existing routes/platform suites pass before and after. Seventy-four
temporary inputs produce identical events, import fields and error strings through
decode_event, decode and is_dismissal; staged/direct mapping assertions pass.
Cases cover typed-field errors, UUID validation, request IDs, controls, ordered
batches and malformed inputs. Swift source and lifecycle ownership are unchanged.

## Questions

None. The user authorized implementation and temporary before/after verification
on 2026-10-22, without permanent additional tests, push or PR.
