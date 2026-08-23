# Graph Download Progress

## Problem

The macOS graph bootstrap screen currently shows only an indeterminate spinner
and a generic sentence while a remote snapshot is fetched. A large graph can
therefore appear stuck even though bytes are arriving, and the user cannot tell
whether the client is discovering the snapshot, downloading it, or preparing
the local mirror.

## Proposal

Report snapshot bootstrap stages from the sync transport to the account shell.
During the artifact transfer, report the received HTTP entity bytes and the
server-provided content length when it is available. Render the active stage,
human-readable byte counts, and a determinate linear progress bar only when the
total is known. Keep the progress indeterminate when the response is chunked or
does not declare a valid total. Show the server-declared snapshot row count as
the exact datom count; do not estimate partial datoms from transferred bytes.

The scope is the initial synced-graph snapshot download on the Flutter host.
The progress callback is observational: it must not change authentication or
the OCaml bootstrap protocol. Preserve atomic `.part` file behavior and decode
gzip artifacts before bootstrap even when upstream omits encoding metadata, by
recognizing the gzip signature after the raw entity transfer completes.
The upstream bootstrap baseline `GET /pull` remains internal to Flutter and has
a separate 64 MiB response bound; ordinary responses that can enter an LJP2
platform envelope retain the 256 KiB protocol bound.

## Decision

Implement the proposal in the Flutter account shell and sync transport. Use one
immutable progress value for stage, raw received bytes, optional total bytes,
and optional server-declared datom count. Fence callbacks by the selected graph
generation, and decode downloaded gzip artifacts by declared encoding or gzip
signature before passing their paths to the OCaml runtime.

## Alternatives considered

### Poll the temporary file

Polling `.part` file size was rejected because it introduces timers, can miss
short transfers, and still cannot provide a reliable total. Reporting at the
network stream boundary observes every received chunk directly.

### Simulated percentage by stage

Assigning fixed percentages to request and validation stages was rejected
because it would present invented progress. Stages are shown as text, while a
percentage is shown only for measured bytes with a known content length.

## Acceptance criteria

- The snapshot screen names the graph and current bootstrap stage.
- A transfer with a valid content length shows received bytes, total bytes, and
  a determinate progress bar derived from those values.
- A transfer without a valid content length shows received bytes and an
  indeterminate progress bar without inventing a percentage.
- The UI shows the exact snapshot datom count when the artifact response
  provides `x-snapshot-row-count`, and identifies it as downloaded only after
  the transfer completes.
- Progress reflects raw HTTP entity bytes even when the artifact is decoded
  before being written to disk.
- A gzip artifact without response or metadata encoding is recognized by its
  signature and decoded before the OCaml bootstrap receives it.
- Existing atomic download, validation, and mirror bootstrap behavior remains
  covered by automated tests.
- A baseline pull larger than 256 KiB can bootstrap a snapshot, while ordinary
  HTTP platform responses still fail above 256 KiB and the baseline remains
  bounded at 64 MiB.
- A signed macOS build can download `Lambda RTC` and report its measured entity
  bytes and server-declared datom count.

## Risks

- `Content-Length` describes transferred entity bytes and may differ from the
  decoded snapshot size. The UI labels this as download progress and reports
  the same raw byte domain for both numerator and denominator.
- The deployed `Lambda RTC` artifact omitted usable gzip encoding metadata in
  acceptance testing. Signature detection avoids passing compressed bytes to
  the framed snapshot importer without changing progress accounting.
- Very small network chunks can generate frequent notifications. The first
  implementation accepts stream cadence because Flutter coalesces rebuilds;
  throttling can be added later if profiling demonstrates a problem.
- Upstream currently returns the complete transaction history for the baseline
  pull even though bootstrap needs only `t` and `checksum`. The dedicated 64 MiB
  bound permits existing large graphs without removing memory limits; a future
  server endpoint should return bounded snapshot baseline metadata directly.

## Consequences

- Snapshot preparation now exposes transport stages to the account UI, while
  the runtime bootstrap payload remains unchanged.
- Snapshot downloads may require temporary disk space for both the raw gzip
  entity and its decoded `.part` file before atomic activation.
- Exact datom progress depends on the upstream `x-snapshot-row-count` header;
  the client intentionally does not infer partial datom counts from bytes.

## Questions

None.
