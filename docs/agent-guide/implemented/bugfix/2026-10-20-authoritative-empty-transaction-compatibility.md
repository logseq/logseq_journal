# Authoritative Empty Transaction Compatibility

## Problem

Build 51 shows prepare / empty-transaction / transaction=1 on the phone.
The first transaction in the current authoritative batch parses as an empty
Transit array or list; the client rejects it before application. The upstream
normalized transaction log permits empty operations while advancing its cursor.
The diagnostic ordinal is not a server cursor.

## Decision

Allow an empty operation array/list only at the private codec authoritative-input
entry points. Keep strict defaults for durable outgoing-record validation and
insertion helpers. Preserve the empty transaction as one element of the batch,
using all existing candidate, origin validation, staging, replay and atomic
checkpoint/outbox/revision commit paths. No cursor shortcut or dropped batch slot.
Do not modify protected specs, Dune, sync policy, race recovery, attachments,
upstream normalization or any other suspected issue. User authorization explicitly
limits this task to the confirmed empty authoritative transaction gap and iPhone update.

The pure sync reducer stores opaque wire text and cannot originate the decoding
failure through pure events without fabricating a producer error. The previous
actual runner/database reproductions confirmed ownership in the overlay codec;
new regressions use the public Database boundary, the narrowest accessible owner.
Existing runner diagnostic regressions for empty input must change to success,
while all other existing failure/privacy cases remain intact.

## Alternatives considered

### Drop empty transactions or accept empty input globally

Rejected: dropping changes cursor/report/origin alignment; a global parser change
also loosens outgoing validation. Manually moving the checkpoint would bypass
atomicity and token/generation guards.

## Acceptance criteria

- Old source fails the public Database empty authoritative regressions; the minimal
  change passes array/list, durable reopen and empty/nonempty/empty batch cases.
- No-content changes advance the server checkpoint and sync token without an
  unnecessary logical projection change. Real mixed transactions still apply.
- Late malformed transaction and storage failure roll back the whole batch;
  stale token, empty outer batch, malformed input and outgoing-empty validation
  retain their existing rejection behavior.
- Final full checks and independent review use the final source. Correct signed
  iphoneos output is installed in place only after fresh Build 51 backup and
  rollback preservation; actual device version/startup are read back.

## Risks

- Existing origin validation can still reject an empty transaction that does not
  match an accepted local submission; this integrity guard must remain unchanged.
- This fixes client compatibility, not why upstream produced an empty transaction.
- Experimental host-restamp remains cross_abi_validated=false.

## Questions

- None. The user explicitly approved only this compatibility fix and iPhone
  update on 2026-10-20, and forbade unrelated speculative fixes.

## Consequences

The private parser/protected-value collector/decoder keep allow_empty=false by
 default, and only the three authoritative-input calls pass true. Legal empty
arrays/lists now produce empty operations through the existing candidate,
origin, storage, replay and atomic commit paths. No production storage, sync
manager, outbox, recovery, attachment, upstream or unrelated behavior changed.
The protected spec and Dune remain unchanged.

Eight public Database cases cover empty arrays/lists, mixed batch slots,
checkpoint/token persistence after reopen and subsequent cursor application,
late decode and actual SQLite metadata commit failures with disk rollback,
token guards and malformed neighbour/outer-batch rejection. Seven failed on the
old producer; all passed after the change. The late failure explicitly checks
stage=decode/transaction=3. The existing outgoing corruption fixture now also
checks [] still fails closed. Existing runner empty/second-transaction regressions
now assert actual success, checkpoint advancement and no Last error; they failed
on the old source and pass with this change. All other diagnostic failures and
privacy cases are retained. The complete storage suite (85 cases) also passes.
Final full build/test results, independent review, source and install evidence
are recorded externally before phone delivery.

No additional issue was fixed. The user authorization and excluded scope remain
as stated above; the cause of upstream empty generation and the independent
attachment error are not investigated or changed in this implementation.
