# E2ee Unlock Contract And Recovery

## Problem

The live HTTP 200 graph-key object has an additional field and fails strict DTO decoding before a password challenge exists. The UI treats every E2EE failure as a password challenge, admits a password that Core ignores, and can remain pending indefinitely. Worker admission and terminal errors also lack unlock-specific cleanup.

## Decision

Declare the official optional nullable encrypted-aes-key-base64 string explicitly in the strict PPX DTO. Preserve encrypted-aes-key as the current bounded Transit input and retain unknown-field rejection. The official schema is pinned to logseq/logseq 015cc9fcc79f3d57304a89ee6bf07337b59e05bc; user-key response has no additional declared fields. Observe only the fixed public base64 field's presence/type to confirm the actual response, without recording values.

Core owns challenge validity and key-preparation retries: failure clears an invalidated challenge, private-key rejection restores a valid retry challenge, and E2EE preparation retry restarts graph-key acquisition. Startup projection chooses network recovery when no challenge exists. Application admits only advertised challenges and clears its pending operation on matching queue/terminal failure or account/graph generation replacement; acknowledgement alone must not release a running unlock.

The decoder is private and cannot be exercised through Core; use the existing public Runner API and independent TLS peer as its narrowest accessible boundary, without changing Dune or spec interfaces. Core failure/recovery tests use public events/completions only. Startup projection and Application queue/pending ownership have separate public-interface tests because Core does not own those adapters.

## Alternatives considered

### Disable strict decoding or switch crypto formats

Rejected: the user requested explicit missing fields, and no evidence requires changing the existing cryptographic envelope.

### Delete local graph or account state

Rejected: response decoding precedes graph opening and deletion would not repair the contract; unsynchronized data could be lost.

## Acceptance criteria

- Regression tests fail on the preserved diagnostic HEAD and pass after the smallest repair.
- Strict parsing accepts optional absent/null/string base64 and still rejects unrelated fields and wrong types.
- Preparation failures restart key acquisition; a rejected password remains retryable, and invalidated challenges are not advertised.
- Failed worker submission cannot leave the unlock form indefinitely disabled.
- The owned full Simulator reaches a valid challenge and, after the user submits their password, validates success or records the remaining failure stage with sanitized evidence.
- Preserve PR72 and all diagnostic commits; no Dune/spec changes, pushes, merges, phone installation, credential access, or destructive graph/account/keychain/outbox operations.

## Validation

The repair code is pinned to 69df7223d88e9deaf56099f9985472af68995f45. Eleven added cases failed at the correct production boundaries before implementation. GREEN verification passed 55 pure Core cases, 82 Application cases, 19 transport/diagnostic cases, 24 Runner cases, startup tests and the native build; the final owner-fencing refinement also passed all four unlock Application cases.

Full production Simulator 1.5877.27, owned device A5E68F24-A072-49D8-BE55-A72B82CDCA03, was updated in place. Live sanitized metadata confirms encrypted-aes-key-base64 is a string, two declared graph response fields and no unknown fields, HTTP 200 and successful graph/user key decoding. The user personally submitted their password on the newly valid challenge. Operation 7 completed private-key derivation/open/validation/storage successfully; operation 8 completed graph-key unwrap/verification/storage successfully. The actual native UI then displayed the Journal timeline and existing entries, with no password form or Unlocking spinner. No password or key values were recorded or typed by the agent. Evidence is preserved in the task's external e2ee-unlock-fix directory.

## Consequences

The current legacy encrypted-aes-key remains the cryptographic input. Adding the base64 field repairs the confirmed live contract while retaining rejection of unrelated response fields. Invalid challenges are no longer offered as password recovery; failed worker submissions release pending and show a retryable error, scoped to their owning account/graph generations. No Dune/protected spec interface or Swift files changed. PR72 and all diagnostic commits remain ancestors; no push, new PR, merge or phone install occurred. No graph/account/keychain/outbox deletion or sign-out occurred.

## Risks

- Deployment identity is unknown; the fixed-field structural observation must distinguish schema support from observed live data.
- Simulator validation uses production OCaml objects and genuine Simulator C/Swift services with the previously documented host-runtime ABI limitation.
- Live cryptographic success is now confirmed from the fresh user submission; the earlier ignored submission did not execute crypto.

## Questions

None. Implementation is already authorized by the user's request to add the missing field and solve the diagnosed recovery issue.
