# Finish Error Reason Propagation

## Problem

The audit lists real cause losses that do not require protected spec changes. Stopping at that inventory does not fulfill the request to expose the available safe reasons.

## Decision

Implement the remaining audited cause propagation in the existing owners and output channels. The user explicitly approved the minimal snapshot state and scoped sync/worker runner spec changes. Preserve original result variants, blocking, retry, transaction and cancellation decisions.

Use finite safe error descriptors, typed numeric HTTP/URL/OSStatus metadata and exact Int64 cursor strings. Asset causes are correlated to the exact internal request and graph/account generation, then retained across the matching terminal notification fanout. Preserve original native callback signatures and add an operation-owned finite reason getter. Versioned platform failures contain only finite reasons, tags and scope generations. Keep different current decoding causes visible and suppress only consecutive identical causes. Make Diagnostics reachable from account startup failure.

## Alternatives considered

### Stop at the detailed inventory

Rejected by the user's explicit instruction to complete remaining authorized implementation.

### Change failure categories to carry messages

Rejected: diagnostics must not change retry/recovery/sync semantics. Existing string/notice paths and safe side channels are preferred; genuine spec changes require explicit permission.

## Acceptance criteria

- Every unprotected audit point is implemented or has a concrete discovered implementation blocker; arbitrary raw exception strings remain excluded.
- Exact protected files/minimal signatures are reported before edits, then paused unless explicit permission arrives.
- Necessary owner-level tests, privacy checks, applicable existing suites and isolated native rendering pass against final source.
- No real graph/account/DB, PR, push or release operations occur.

## Risks

- Runtime bridge diagnostics need operation and generation isolation to avoid replacing a newer failure with stale context.
- Unknown external causes may only be safely summarized as finite classes; no promise of raw original messages is made.

## Questions

- The user approved snapshot state reasons and scope/request-correlated sync diagnostic callbacks on 2026-10-24. No permission extends to business failure enums or Dune files.

## Consequences

- Existing authoritative checks and persistence decisions remain unchanged. Diagnostics do not prove or fix the original user Capture failure.
- Snapshot state errors now expose all six owner branches; the guarded checkpoint branch retains finite schema/checksum subreasons. Five publicly reachable states are tested with synthetic public Database calls; no corrupted private state is fabricated.
- Current errors reach the existing diagnostics/native feedback. Secondary cleanup and revocation failures retain safe support-log causes without reversing primary success. Canceled/retired work and diagnostic-delivery fallback remain intentionally quiet/nonrecursive.
- Existing suite and owner probes provide regression evidence, including actual decoder, same-operation cause changes, scoped asset request/fanout, C/Swift ingress and protected crypto boundaries. The unchanged full ImageIO photo fixture has the same executor-dependent failure at untouched HEAD; the owner suite and actual iOS typecheck pass.
- Final App packaging and isolated native rendering use the maintained build workflow and prepared dependencies. No normal Journal installation or real graph/account is used in this completion phase. Host restamping remains experimental with cross_abi_validated=false.
- Temporary probes, reports, hashes and screenshots remain in external task evidence. No Dune, extra business spec, PR, push or release changes are authorized.
