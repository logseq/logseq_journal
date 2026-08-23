# E2ee User Keys Current Response Contract

## Problem

The signed physical-iPhone build can authenticate, discover the deployed
`ocaml-sync-test` graph, and fetch its encrypted graph key, but opening the graph
then fails with:

    E2EE response must contain exactly one encrypted-private-key string

A read-only diagnostic against the same authenticated session captured the current
deployed endpoint shapes without logging key material. The graph-key endpoint
returned HTTP 200 with one `encrypted-aes-key` string. The user-key endpoint
returned HTTP 200 with exactly two strings: `public-key` and
`encrypted-private-key`.

`Sync_e2ee_session.object_string` currently requires every E2EE response object to
contain exactly one field. That is correct for the graph-key endpoint but rejects
the current user-key response solely because its required `public-key` sibling is
present. The failure prevents E2EE graph bootstrap and therefore also blocks
physical-device foreground revalidation testing.

## Decision

Replace the shared one-field decoder with endpoint-specific strict decoders.

- The graph-key response must contain exactly one bounded non-empty UTF-8
  `encrypted-aes-key` string.
- The user-key response must contain exactly two bounded non-empty UTF-8 strings:
  `public-key` and `encrypted-private-key`.
- The E2EE session retains only `encrypted-private-key`, because public-key use is
  outside this password-unlock transition, but it still validates the complete
  deployed response contract before changing phase.
- Empty, oversized, malformed, missing, duplicated, or additional fields are
  rejected.
- The obsolete single-field user-key response is removed rather than accepted as a
  compatibility path.

No key material may be added to errors, logs, fixtures, or decision documents.

## Implementation evidence

Endpoint-specific strict decoders now model the one-field graph-key response and
the two-field user-key response. Unit and manager tests reject the obsolete
single-field user-key shape and malformed or additional fields without containing
deployed key material.

After the auth-session refresh fix allowed normal bootstrap to proceed, the signed
physical-iPhone app passed the former decoder failure, completed E2EE graph open,
and rendered the populated journal.

## Alternatives considered

### Ignore additional user-key fields

Rejected because accepting arbitrary sibling fields would weaken the endpoint
contract and allow unreviewed server changes to pass silently.

### Continue accepting the old single-field response

Rejected because the repository does not preserve obsolete wire paths. The client
should model and test the current deployed response exactly.

### Store or use the returned public key in this session

Rejected because graph-key decryption only requires the encrypted private-key
package. Adding public-key state would expand the E2EE session without a consumer.

## Acceptance criteria

- The captured two-field user-key response shape advances an E2EE session from
  `Fetching_user_keys` to `Awaiting_password`.
- A one-field user-key response and responses with missing, empty, incorrectly typed,
  or additional fields are rejected.
- The existing one-field graph-key response remains accepted, and graph-key
  responses with sibling fields remain rejected.
- No test, log, or error contains deployed key material.
- The signed physical-iPhone app can pass the former decoder failure and continue to
  the existing password/private-key unlock path for `ocaml-sync-test`.

## Consequences

- A future deployed endpoint field addition will fail closed until its contract is
  reviewed and represented explicitly.
- The public key is validated but intentionally discarded by this state machine.

## Questions

None.
