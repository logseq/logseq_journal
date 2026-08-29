# Cached Wrapped Graph Key Unlock

## Problem

Encrypted snapshot activation fails with `invalid synced snapshot: protected
snapshot value could not be decrypted` when startup finds a cached wrapped graph
key. The cached-key platform operation verifies that the wrapped ciphertext can be
unwrapped to a 32-byte graph key, but returns the wrapped ciphertext. The effect
runner stores that value behind a `graph_key_handle` and later supplies it as the
AES-GCM key. Apple crypto rejects it because it is not a 32-byte raw key.

The pure Core state flow is correct: it requests a graph-key capability, waits for
the opaque handle, and carries that handle into encrypted mirror attachment or
snapshot activation. The contract name is misleading, however:
`Load_wrapped_graph_key` describes the input source rather than the successful
postcondition expected by Core. Core requires a handle containing an unlocked,
AES-ready graph key.

The network recovery path does not have this defect because
`Fetch_and_unlock_graph_key` explicitly unwraps the server value before storing the
handle. The regression is isolated to the cached-key fast path introduced by the
pure Core/effect-runner ownership refactor.

## Proposal

Rename the Core runner request from `Load_wrapped_graph_key` to
`Load_and_unlock_graph_key` so its successful result clearly promises an
AES-ready `graph_key_handle` rather than a handle to wrapped ciphertext.

At the secrets boundary, use the precise name `load_wrapped_graph_key` for the
operation that loads and validates cached wrapped ciphertext while still returning
that ciphertext. Implement the Core request in `Effect_runner` as an explicit
composition:

1. Load the cached wrapped graph key.
2. Unwrap it with the account's local private key.
3. Store only the resulting raw 32-byte graph key behind the scoped handle.

Add a `runner_contract` regression scenario whose fake secrets dependency returns
a recognizable wrapped value, requires that exact value in `unlock_graph_key`, and
whose AES dependency accepts only the resulting raw key. Submit the cached-key
request, then decrypt an encrypted protected value through its returned handle.
This verifies the observable integration boundary rather than the internal key
table representation.

Keep the generic snapshot error unchanged in this patch. Improving nested crypto
diagnostics is useful but independent of correcting key ownership and
representation.

## Decision

Adopt the explicit two-step cached-key implementation. Core issues
`Load_and_unlock_graph_key`, `Effect_runner` obtains wrapped ciphertext through
`load_wrapped_graph_key`, unwraps it with `unlock_graph_key`, and creates a scoped
handle only for the returned raw graph key. An unwrap error completes the typed
request with `Effect_failed` and stores no handle.

Protect both outcomes in `runner_contract`: the success scenario proves the
wrapped value reaches `unlock_graph_key` and the resulting handle decrypts a
protected value using the raw key; the failure scenario proves an unwrap error
requests E2EE recovery and leaves the would-be handle unavailable.

## Alternatives considered

### Return the raw key directly from the platform cache operation

This would also fix the immediate failure, but would combine cached ciphertext
loading, private-key unwrapping, and engine-key return semantics in a single
platform function. Keeping load and unwrap explicit in `Effect_runner` makes the
same conversion visible in both cached and network paths and permits a portable
runner contract test.

### Keep `Load_wrapped_graph_key` and only add the missing unwrap call

Rejected because the name would continue to imply that returning a wrapped value
is valid, even though the result type is `graph_key_handle` and every consumer
expects raw AES key material.

### Validate only that stored keys contain 32 bytes

Rejected as the primary fix because length validation can fail closed but cannot
turn cached wrapped ciphertext into the required graph key. The platform unwrap
already enforces the 32-byte invariant.

## Acceptance criteria

- A successful cached-key request unwraps the loaded wrapped value before creating
  a `graph_key_handle`.
- Protected AES-GCM values can be decrypted through the handle returned by the
  cached-key path.
- `Core` and its public spec use a request name whose successful postcondition is
  explicitly load-and-unlock.
- The secrets dependency uses a name that accurately states that it returns a
  wrapped value.
- The new runner regression test fails against the pre-fix implementation for
  using the wrapped value as the AES key and passes after the fix.
- Existing Core, runner, and encrypted snapshot tests continue to pass.

## Risks

- Renaming the typed request touches Core implementation, public spec, diagnostics,
  tests, and decision documentation; missing one match site will be caught by OCaml
  exhaustiveness or compilation.
- The cached path performs an unwrap after platform verification, so it decrypts
  the wrapped value twice. This is acceptable for correctness and keeps the
  platform secret contract unchanged; a later simplification may replace
  verification with structural loading if profiling shows a material cost.
- Raw graph-key bytes must remain runner-owned and must never enter Core state,
  public events, logs, or the worker contract.

## Consequences

Cached and network graph-key acquisition now share the same postcondition: every
successful graph-key request returns an opaque handle to raw 32-byte AES key
material. Core remains pure and cannot observe key bytes, while request naming
makes that runner obligation explicit.

The secrets callback name now describes the representation it returns rather than
suggesting that verification also makes the value AES-ready. Snapshot activation
can reuse the existing handle-based decryption path without special cases.

## Questions

- None. The failure, ownership boundary, requested naming improvement, and expected
  regression coverage determine the required behavior.
