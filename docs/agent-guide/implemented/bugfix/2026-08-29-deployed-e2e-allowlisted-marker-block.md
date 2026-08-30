# Deployed E2e Allowlisted Marker Block

## Problem

The deployed managed-sync E2E reaches `Current`, then asks the public worker
interface to create an ordinary page. Managed sync deliberately rejects
`Create_ordinary_page`, page recycling, and permanent page deletion because the
first-release mutation allowlist is limited to capture/insert, supported saves,
child creation, journal-page creation, and subtree deletion. The test therefore
fails before producing an outbox record with `unsupportedSemantics: This
mutation is outside the managed sync allowlist.`

The implemented E2E decision incorrectly requires an ordinary-page lifecycle.
It contradicts the managed-sync architecture and cannot exercise deployed
submission or independent recovery without broadening worker product behavior.

## Proposal

Use one unique marker block under an existing non-recycled journal page. Discover
the journal parent only through `Graph_request List_pages`, insert the marker via
the allowlisted `Insert_blocks` mutation, verify it in the independent receiver
through `Get_block`, and remove it via the allowlisted `Delete_blocks` mutation.

Retain the fresh UUID and bounded non-secret marker title, exact parent/title
verification, sender and receiver cursor/checksum/outbox assertions, supervised
cleanup, and public-interface-only boundary. Update the deployed E2E decision to
describe this actual allowlisted lifecycle.

## Decision

Replace the unsupported ordinary-page lifecycle with one allowlisted marker-block
lifecycle under an existing active journal page. Do not broaden the worker's
managed-sync mutation allowlist for test convenience.

## Alternatives considered

### Expand the managed sync allowlist

Allow ordinary-page creation and page deletion only to satisfy the test. This
would change product and wire behavior beyond the first-release contract and is
not justified by an E2E fixture need.

### Create a disposable journal page

Journal-page creation is allowlisted, but page deletion is not. This would leave
permanent test pages or require an unsupported cleanup operation.

## Acceptance criteria

- The sender selects an existing non-recycled journal page through public reads.
- The sender inserts exactly one uniquely marked block through `Insert_blocks`,
  observes authoritative cursor advancement, and closes with an empty outbox.
- A receiver with an independent mirror reads the exact block UUID, title, and
  journal parent after cold bootstrap.
- The receiver deletes the marker through `Delete_blocks`, observes authoritative
  cursor advancement, and closes with an empty outbox.
- Best-effort cleanup targets only the exact marker UUID, title, and parent.
- No ordinary-page or page-delete mutation remains in the deployed E2E.
- Focused tests, the online command, formatting, and decision checks pass.

## Risks

- The scenario proves one allowlisted structural mutation rather than ordinary
  page mutation behavior, which managed sync intentionally does not expose.
- The dedicated graph must contain at least one non-recycled journal page. The
  test fails before mutation when that prerequisite is absent.

## Implementation outcome

Implemented on 2026-08-29.

- The E2E now selects an active journal through `List_pages`, inserts one marker
  block through `Insert_blocks`, and reports structured mutation failure codes.
- The independent receiver verifies the block UUID, title, and exact journal
  parent through `Get_block`, then removes it through `Delete_blocks`.
- Best-effort cleanup uses the same exact UUID/title/parent boundary.
- The deployed run completed sender and receiver authoritative cursor advances,
  durable checksum updates, empty outboxes, and remote marker cleanup.

## Consequences

- The E2E exercises the same capture/insert and subtree-delete surface exposed to
  the application.
- The test no longer claims or depends on ordinary-page mutation support in
  managed sync.
- A dedicated graph without an active journal fails before any mutation.

## Verification

- The RED deployed run failed with `unsupportedSemantics` before creating an
  outbox record.
- The GREEN deployed run passes sender mutation, receiver recovery, cleanup,
  durable cursor/checksum advancement, and empty-outbox assertions.
- The focused E2E executable, complete OCaml test suite, and all build targets
  pass successfully.

## Questions

- None.
