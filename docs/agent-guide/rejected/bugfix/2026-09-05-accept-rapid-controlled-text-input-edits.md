# Accept Rapid Controlled Text Input Edits

## Problem

The capture and detail editors accept a host edit only when
`edit.base_document_revision` is exactly equal to the current OCaml
`document_revision`. Accepting the first character increments the OCaml revision.
Several already queued host edits can still carry the previous base revision, so the
strict equality check silently drops them even though their `local_revision` values
are newer and their payloads contain the latest complete editing value.

During the macOS E2EE flow, entering a five-character password rapidly displayed all
five characters in the native field, but `unlockPrivateKey` received only one byte.
Typing one character and waiting for a UI frame between characters delivered all five
bytes and unlocked the same key successfully. This proves the crypto failure was a
controlled-text-input acknowledgement defect rather than an invalid password or
server envelope.

`app/journal_capture.ml` and `app/journal_detail.ml` duplicate the same strict check,
so normal capture text, block edits, passwords rendered through the capture input
surface, paste, IME composition, and automated input can all lose newer edits. The
bonsai_flutter reference component accepts a request when its local revision is
strictly newer and its base document revision is not in the future.

## Proposal

Adopt the bonsai_flutter controlled-input revision contract in both application
editors:

- require the same `session_id`;
- require `local_revision` to be strictly greater than
  `accepted_local_revision`;
- reject a `base_document_revision` greater than the current application revision;
  and
- accept an older or equal base revision, acknowledge the latest local revision, and
  replace the application value with the edit's complete value.

Extract the admission predicate and acknowledgement transition into one application
module used by capture and detail so the two editors cannot drift. Keep their
mode-specific rules separate: capture must not accept an edit while saving, and
detail must still accept edits only in its editing mode.

Any application-owned replacement that must invalidate queued host edits should
start a new text-input session rather than relying on strict base-revision equality.
Do not add delayed input, keystroke throttling, or host-specific retry behavior.

Add contract tests that submit multiple edits with the same base revision and
strictly increasing local revisions without rendering between them. Cover complete
value replacement, paste, Unicode scalar/UTF-16 selection boundaries, composing
ranges, duplicate/out-of-order local revisions, future base revisions, session
replacement, saving/reading modes, and parity between capture and detail.

## Questions

- Which application-owned value replacements should invalidate queued edits by
  rotating `session_id`? The recommended minimum is detail conflict resolution,
  committed-value reload, and any reset that replaces user-visible text; ordinary
  acknowledgements should retain the session.

## Acceptance criteria

- A burst of edits sharing one base document revision applies the event with the
  greatest admitted local revision and preserves its full text, selection, and
  composing range.
- Duplicate and decreasing local revisions, future document revisions, and stale
  sessions are rejected deterministically.
- Capture and detail use one admission contract while preserving their distinct mode
  restrictions and save/conflict behavior.
- Rapid typing and paste into the E2EE password surface deliver the exact UTF-8 bytes
  shown by the field without frame-sized pauses.
- Tests cover ASCII, multibyte Unicode, UTF-16 selections, and IME composition.
- Existing programmatic editor updates cannot be overwritten by edits from a session
  that the update explicitly replaced.

## Risks

- An older-base edit is safe only because it carries the host's complete latest value.
  Treating a future delta-style payload as a complete value would lose text.
- If an application-owned destructive replacement keeps the same session, an edit
  queued before that replacement could be admitted afterward. Session rotation must
  mark every such ownership boundary.
- A shared helper must not collapse the capture and detail state machines or weaken
  their mode-specific guards.

## Alternatives considered

### Require exact base revision and slow the host

Debounce, serialize, or wait for an application frame after each local edit.

This makes correctness depend on input speed and platform scheduling. It also
contradicts the host protocol, which intentionally uses monotonic local revisions and
complete editing values to acknowledge several edits based on one document revision.

### Increment the document revision only after the input queue drains

The pure reducer cannot observe when Flutter's local edit queue is empty. Delaying
acknowledgement would also leave the host unable to distinguish accepted from pending
state.

### Merge text deltas in the application

The event already carries a complete editing value. Reconstructing deltas would add
selection, composition, and UTF-16 edge cases while duplicating host behavior.

## Rejection reason

The issue has already been fixed.
