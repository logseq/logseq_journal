# Deployed E2e Isolated Keychain Host

## Problem

The deployed managed-sync E2E injects the production Swift crypto provider into
an ad-hoc linker-signed standalone OCaml executable. On macOS, the provider uses
the Data Protection Keychain. That Keychain derives access groups from the main
executable's authorized signing entitlements, but the standalone executable has
no application identifier, provisioning profile, or Keychain access group.

The deployed E2E therefore authenticates successfully and decrypts the E2EE
private-key envelope, then `SecItemAdd` fails with `errSecMissingEntitlement`
while persisting the private key. Public state reports `cryptoOperationFailed`
before graph attachment or any remote mutation. An isolated probe confirms that
Data Protection Keychain add, update, and delete fail with `-34018` in this host,
while the same operations succeed in a temporary file-based Keychain.

## Proposal

Keep the production provider's E2EE derivation, AES-GCM, RSA-OAEP, validation,
and secret lifecycle code. Add an explicit DEBUG-only storage mode that creates
one temporary file-based macOS Keychain at a harness-supplied absolute path. The
provider must target that Keychain explicitly with `kSecUseKeychain` for adds and
`kSecMatchSearchList` for reads, updates, and deletes.

The deployed E2E compiles the injected provider with `-D DEBUG`, supplies a fresh
path inside its existing private temporary provider directory, and removes the
Keychain after the supervised child exits. Sender and receiver remain in the
same child process and share that isolated Keychain. Do not enable the existing
memory stores, access the ambient file-based Keychain, or change production app
storage behavior.

## Decision

Add one DEBUG-only file-based Keychain storage mode selected by an internal test
environment variable. Scope every Security-framework query explicitly to that
Keychain and keep production Data Protection Keychain behavior unchanged.

## Alternatives considered

### Run the E2E executable as a provisioned application

A Data Protection Keychain host requires an app-like bundle, authorized
provisioning profile, and matching signing identity. The test command cannot
assume that mutable developer-account state or signing material exists on every
runner, and the E2E executable is not currently an application target.

### Enable the existing DEBUG memory stores

This bypasses all Security-framework persistence and was explicitly excluded by
the deployed E2E decision. It would also make sender/receiver recovery depend on
process memory rather than an actual Keychain implementation.

### Use the ambient legacy file-based Keychain

This could persist test secrets outside the temporary directory, interact with
developer entries, and prompt for ACL access. The test must instead name and own
one disposable Keychain file.

## Acceptance criteria

- Without the internal test-Keychain environment variable, macOS provider queries
  continue to use `kSecUseDataProtectionKeychain`.
- The test mode rejects an empty, relative, NUL-containing, oversized, or already
  existing Keychain path.
- Configuring test-memory storage together with the temporary file Keychain is an
  error rather than an ambiguous precedence rule.
- Private-key and wrapped-graph-key save, load, update, and delete operations are
  scoped only to the created temporary Keychain.
- The deployed E2E reaches graph attachment without `errSecMissingEntitlement` and
  continues through sender mutation, independent receiver recovery, and cleanup.
- The temporary Keychain and injected provider library are removed after success
  and failure.
- Production Swift tests, OCaml tests, `dune build @all`, formatting checks, and
  `spec-dev-tool check --all` pass.

## Risks

- The online lane no longer exercises the production app's Data Protection
  Keychain entitlement configuration. Existing signed Runner tests remain the
  authority for that host capability.
- `SecKeychain` is a macOS-only legacy API. Its use is confined to the explicit
  DEBUG test-host path and must not become a production fallback.
- A process crash can leave the disposable file in the private temporary
  directory until operating-system temporary-file cleanup.

## Implementation outcome

Implemented on 2026-08-29.

- `JournalE2EECrypto.swift` selects a freshly created file-based Keychain only
  when the DEBUG-only internal environment variable is present. Its add, search,
  update, and delete queries are explicitly scoped to that Keychain; production
  queries retain Data Protection Keychain behavior.
- The deployed harness compiles the provider from `DUNE_SOURCEROOT` with DEBUG,
  injects a unique Keychain path inside its private provider directory, and
  removes the provider, Keychain, and Security-framework sidecar files on exit.
- A standalone provider smoke probe completed private-key install, lookup, and
  account-secret deletion through the isolated Keychain.
- The deployed test authenticated, unlocked the encrypted graph, restored cursor
  229, completed sender mutation and independent receiver recovery, and removed
  the marker mutation without `errSecMissingEntitlement`.

## Consequences

- The standalone E2E exercises real Security-framework persistence without
  requiring an application signing identity or touching developer Keychains.
- Production builds reject the internal environment variable and retain the
  Data Protection Keychain as their only storage path.
- The E2E provider directory owns every temporary Keychain artifact and removes
  it after both success and supervised failure.

## Verification

- DEBUG and release Swift provider compilation pass without warnings.
- A DEBUG provider smoke probe passes private-key save, lookup, and deletion.
- The signed macOS RunnerTests suite passes through the bonsai-flutter profile
  context; its opt-in ambient real-Keychain test remains intentionally skipped.
- The deployed managed-sync E2E passes against the encrypted test graph.

## Questions

- None.
