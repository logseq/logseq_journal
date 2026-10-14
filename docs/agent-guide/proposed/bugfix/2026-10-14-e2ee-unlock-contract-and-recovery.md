# E2ee Unlock Contract And Recovery

## Problem

The live HTTP 200 graph-key object has an additional field and fails strict DTO decoding before a password challenge exists. The UI treats every E2EE failure as a password challenge, admits a password that Core ignores, and can remain pending indefinitely. Worker admission and terminal errors also lack unlock-specific cleanup.

## Proposal

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

## Risks

- Deployment identity is unknown; the fixed-field structural observation must distinguish schema support from observed live data.
- Simulator validation uses production OCaml objects and genuine Simulator C/Swift services with the previously documented host-runtime ABI limitation.
- Password success requires a fresh user submission; prior ignored submissions cannot establish password correctness.

## Questions

None. Implementation is already authorized by the user's request to add the missing field and solve the diagnosed recovery issue.
