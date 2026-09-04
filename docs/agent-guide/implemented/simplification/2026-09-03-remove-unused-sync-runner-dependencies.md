# Remove Unused Sync Runner Dependencies

## Problem

`Logseq_sync_effect_runner.Effect_runner` requires several injected capabilities
that no production execution path invokes:

- `runtime.monotonic_ns` is stored in `runtime`, touched only by an `ignore` in
  `dependencies`, and never reads time;
- `secrets.has_private_key` is stored in `secrets`, touched only by the same
  `ignore`, and never participates in graph-key acquisition;
- `crypto.decrypt_private_key` and `crypto.decrypt_graph_key` are stored in
  `crypto`, touched only by `ignore`, and never participate in protected-value
  encryption or decryption.

The Apple implementation makes the last two callbacks explicit dead ends: both
return errors because private keys intentionally never cross the platform crypto
boundary. Current graph-key acquisition instead uses `secrets.unlock_private_key`
and `secrets.unlock_graph_key`, while protected values use only
`crypto.encrypt_aes_gcm` and `crypto.decrypt_aes_gcm`.

Repository-wide call-site search found no production, generated, dynamic, or
registration-based consumer of these four capabilities. Tests and service setup
construct placeholder callbacks only because the public constructors require
them. The standalone Swift `hasPrivateKey` operation has direct platform tests,
but its only production OCaml adapter is the unused `secrets.has_private_key`
field.

This speculative surface makes the actual key-ownership boundary harder to read,
forces unrelated fixtures to define impossible operations, and suggests that the
runner supports clock-based policy and raw private-key cryptography when it does
not.

Two superficially similar unused callbacks are not part of this simplification.
`secrets.delete_wrapped_graph_key` and `secrets.delete_account_secrets` currently
have no runner call site, but the implemented Keychain lifecycle decision requires
them for local-cache deletion and sign-out. Their absence from the effect protocol
is evidence of an incomplete security behavior, not evidence that the capabilities
are obsolete.

## Proposal

Delete the four confirmed unused capabilities and all plumbing that exists only
to construct them:

1. Remove `monotonic_ns` from the Sync Effect Runner's private `runtime` record,
   public `runtime` constructor, Bonsai service wiring, and runner fixtures.
   This does not affect `logseq_overlay_db.Database.dependencies.monotonic_ns`,
   which is a separate candidate with a real generation call site.
2. Remove `has_private_key` from the Sync Effect Runner's `secrets` record and
   constructor, `apple_secrets`, runner and worker fixtures, and the OCaml
   `Platform_crypto` adapter. Also remove the Swift `hasPrivateKey` dispatch
   branch and the tests that exist only for that branch; the user confirmed that
   it is not a retained diagnostic surface.
3. Remove `decrypt_private_key` and `decrypt_graph_key` from the Sync Effect
   Runner's `crypto` record and constructor, `apple_crypto`, runner and worker
   fixtures, and the fixed-error fields in `Platform_crypto.crypto`.
4. Retain `unlock_private_key`, `unlock_graph_key`,
   `load_wrapped_graph_key`, `verify_and_save_wrapped_graph_key`,
   `encrypt_aes_gcm`, and `decrypt_aes_gcm` unchanged because each has a current
   production request path.
5. Retain the two deletion capabilities for the separately authorized bugfix that
   restores the required sign-out and graph-cache cleanup behavior. Do not
   disguise that missing behavior as dependency cleanup.

The change is a direct public-constructor cutover. Repository policy rejects
compatibility overloads, optional fallback callbacks, and deprecated aliases.

The audited production corpus is `app/`, `logseq_sync/lib` and `spec`,
`logseq_db_worker/lib`, `spec`, and `bonsai`, `logseq_overlay_db/lib` and `spec`,
`logseq_db_storage/lib`, `logseq_db_types/lib`, `flutter/lib`, and the shared Apple
crypto implementation. Tests, fixtures, benchmarks, and tools were classified as
non-production consumers and remain in the cleanup scope when they exist only to
satisfy a deleted constructor. `_build`, Flutter build products, `.dart_tool`,
locked package output, generated install manifests, and vendored dependencies are
excluded as edit targets.

## Decision

Adopt the direct cutover in full. Remove `runtime.monotonic_ns`,
`secrets.has_private_key`, `crypto.decrypt_private_key`, and
`crypto.decrypt_graph_key` from the Sync Effect Runner interfaces,
implementations, production wiring, and fixtures. Remove the unsupported
`hasPrivateKey` Apple dispatch operation and its remaining test usage. Retain the
wrapped-key and account-secret deletion callbacks for the separately implemented
lifecycle cleanup paths.

## Alternatives considered

### Keep the callbacks as future extension points

Rejected. There is one production implementation, no alternate backend, no
dynamic registration mechanism, and no current instruction that can reach these
callbacks. Keeping them preserves obligations rather than behavior.

### Start using every currently unused callback

Rejected as a simplification. Adding clock policy, preliminary private-key probes,
or raw private-key operations would add observable behavior. Wiring the deletion
callbacks is valuable but belongs to a separate bugfix governed by the existing
Keychain lifecycle decision.

### Merge `secrets` and `crypto` into one platform interface

Not selected. The remaining interfaces express distinct ownership: `secrets`
operates on Keychain-backed account and wrapped-key state, while `crypto` operates
on a runner-owned in-memory graph-key handle. Merging them would relocate rather
than remove complexity.

## Acceptance criteria

- The Sync Effect Runner `runtime` constructor requires only `fork` and `sleep`.
- No Sync Effect Runner record, constructor, Apple adapter, production service
  wiring, or fixture refers to `runtime.monotonic_ns`, `secrets.has_private_key`,
  `crypto.decrypt_private_key`, or `crypto.decrypt_graph_key`.
- Cached and remote graph-key acquisition still use the same platform-owned
  unlock operations and return the same scoped opaque handles.
- Protected-value encryption and decryption still use the same AES-GCM operations.
- `delete_wrapped_graph_key` and `delete_account_secrets` remain available for the
  separately authorized lifecycle bugfix.
- `dune runtest logseq_sync/test`, `dune runtest logseq_db_worker/test`,
  `dune build @all`, `dune build @fmt`, `git diff --check`, and
  `spec-dev-tool check --all` pass.

## Risks

- The `logseq_sync` Effect Runner constructors are public package interfaces.
  Repository evidence shows only in-worktree consumers and the repository forbids
  compatibility layers, but an unknown out-of-tree consumer would need to update
  in the same cutover.
- Removing the native `hasPrivateKey` operation also removes its directly testable
  diagnostic probe. The user accepted this loss because it is not a supported
  production surface.
- Treating every unused secret callback alike would accidentally remove required
  deletion behavior. The implementation must keep the deletion pair visibly out
  of scope and preserve the existing Apple implementation.

## Consequences

The Sync Effect Runner runtime constructor now requires only `fork` and `sleep`.
Its secrets and crypto constructors expose only capabilities reached by current
typed requests, including the two deletion operations restored by the companion
bugfix. Production service wiring and test fixtures no longer manufacture clock,
private-key probe, or raw private-key decryption callbacks.

The Apple crypto adapter no longer exports or dispatches `hasPrivateKey`, and its
crypto record contains only AES-GCM operations. Repository-wide source audits
found no remaining reference to the four removed capabilities. The runner source
contract also prevents placeholder ignores from returning.

Implementation completed on 2026-09-03. The focused sync and worker suites, root
tests including the Apple crypto lane, `dune build @all`, `dune build @fmt`, and
`git diff --check` passed.

## Questions

None.

The user confirmed that the native Swift `hasPrivateKey` operation, its unused
OCaml adapter, and tests dedicated only to that operation may be deleted.

The user also authorized a separate bugfix decision for the missing invocation of
`delete_wrapped_graph_key` and `delete_account_secrets` during graph-cache deletion
and sign-out.
