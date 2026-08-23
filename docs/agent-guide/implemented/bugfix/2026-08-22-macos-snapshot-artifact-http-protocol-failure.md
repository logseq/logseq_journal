# macOS Snapshot Artifact HTTP Protocol Failure

## Problem

After authentication and catalog discovery, a fresh download of the encrypted
ocaml-sync-test graph failed with:

    snapshot artifact HTTP protocol failed

Catalog discovery and the small snapshot metadata requests succeeded, and the
catalog persisted the mirror as downloading. Instrumenting only the discarded
httpun error category reproduced the underlying exception:

    Failure(\"HTTP parser did not consume network input\")

Sync_http_eio.start_connection reads up to 16 KiB from the TLS flow and then loops
until Httpun.Client_connection.read consumes every byte. It treats a zero return
as a protocol failure. httpun can temporarily consume zero bytes when its response
body reader applies backpressure. A correct driver retains the unread bytes, obeys
the next Read, Yield, or Close operation, and appends more input before retrying.

The failure is size-dependent: the small JSON control requests complete, while the
snapshot artifact reaches the backpressure path. Replacing the test driver with a
Gluten.Buffer-backed loop using the same behavior as httpun-eio allowed the artifact
to download, decode, import, and open. The resulting mirror reported PRAGMA
integrity_check = ok, server cursor t=89, and 238 KVS rows.

## Decision

Add httpun-eio to the Dune library dependencies and replace the custom HTTP
connection pump with its maintained client driver. The driver must retain
unconsumed bytes, append network input through a bounded buffer, respect reader
yield/resume, and deliver EOF with any retained bytes.

Preserve the existing response-size limit, redirect policy, progress callbacks,
content-type validation, timeout, and atomic destination cleanup.

Also preserve the concrete httpun error category in diagnostics without exposing
request URLs, authorization headers, or response content.

### Implementation outcome

`Sync_http_eio` now delegates HTTP/1.1 connection driving and body scheduling to
`Httpun_eio.Client`; the custom one-shot read/write pump was removed. `httpun-eio`
is a direct pinned dependency for the library and locked opam packages. Response
and artifact reads continue to enforce bounds, redirects, authority, content type,
timeouts, progress, exclusive file creation, and cleanup. Protocol failures expose
bounded category messages and close/remove any partial destination.

The transport regression sends a 128 KiB response through 1 KiB reader/body
buffers with delayed rescheduling and verifies every byte. Real macOS snapshot
requests advanced through artifact parsing without the former HTTP protocol
failure; incompatible remote storage schemas were rejected by the later semantic
validator, and staging artifacts were removed.

## Alternatives considered

### Retry read until it consumes bytes

Rejected because a tight retry loop starves the body consumer and uses an entire CPU
core. The end-to-end diagnostic reproduced this behavior as a permanent
Authenticating screen with sustained high CPU.

### Discard the unconsumed suffix

Rejected because it silently corrupts the snapshot artifact and moves the failure
to framing, decompression, or checksum validation.

### Increase the fixed read buffer

Rejected because it changes only the artifact size at which backpressure occurs.

## Acceptance criteria

- The deployed ocaml-sync-test snapshot downloads and imports on signed macOS Debug
  and Release builds.
- The worker declares and uses httpun-eio directly instead of retaining a custom
  HTTP connection pump.
- The HTTP driver correctly handles partial and zero-byte parser consumption
  without data loss, spin, or deadlock.
- Unit tests exercise a response body larger than the read buffer with forced
  httpun backpressure.
- Redirects, body limits, timeouts, progress reporting, single/double gzip decode,
  and temporary-file cleanup remain covered.
- Protocol errors retain a safe category and message while redacting secrets.

## Consequences

- HTTP body backpressure and retained input are owned by the maintained
  `httpun-eio` driver rather than application parser loops.
- Artifact downloads retain the existing security and resource bounds while
  protocol diagnostics disclose only safe categories.
- The application now carries direct `httpun-eio` and `gluten-eio` lockfile
  dependencies.

## Risks

- Adding httpun-eio changes the explicit Dune dependency set and may require its
  version to remain aligned with httpun and Eio upgrades.
- Replacing the connection pump must preserve cancellation and resource ownership
  behavior at the worker boundary.

## Questions

- None. The implementation may add httpun-eio to the Dune library dependencies.
