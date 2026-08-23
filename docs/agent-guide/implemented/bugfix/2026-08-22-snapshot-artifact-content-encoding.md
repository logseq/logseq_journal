# Snapshot Artifact Content Encoding

## Problem

The deployed `Lambda RTC` snapshot reaches the macOS host as nested gzip: the
outer HTTP entity decodes to another gzip stream, and only the second decode
produces the framed snapshot bytes expected by the OCaml importer. The current
host performs at most one gzip decode. Download progress completes and metadata
becomes ready, but the importer reads gzip magic where it expects a frame length,
deletes the failed staging directory, and the application reports corrupt or
incomplete graph storage.

## Decision

Decode snapshot artifacts by content signature after the raw HTTP transfer.
Peel at most two consecutive gzip layers into separate atomic temporary files,
then pass only the non-gzip result to the OCaml bootstrap. Reject an artifact
that remains gzip after two layers rather than performing unbounded recursive
decompression. Keep progress measured against the outer HTTP entity bytes and
clean every raw or decoded temporary file on failure.

Apply the same bounded content decoding to the in-memory network implementation
used by integration tests so the `JournalSyncNetwork` contract is consistent.
No OCaml protocol, `.mli`, `spec/`, dune, authentication, or E2EE change is in
scope.

## Alternatives considered

### Trust response and metadata encoding

Rejected because the deployed response describes only one transport layer while
the resulting content is itself gzip. Header-driven single decoding reproduced
the corrupt mirror.

### Decode gzip recursively without a bound

Rejected because attacker-controlled or malformed artifacts could force
unbounded decompression passes. Two layers cover the deployed representation
while preserving a clear rejection boundary.

## Acceptance criteria

- Single- and double-gzip snapshot artifacts produce identical framed bytes.
- A snapshot that remains gzip after two layers fails visibly and leaves no raw
  or decoded temporary files.
- Download progress continues to report the outer HTTP entity byte count.
- The full Flutter suite and analyze pass.
- A signed macOS Release ingests all 65,145 framed snapshot rows, creates a valid
  E2EE-materialized local SQLite mirror, and renders the graph without a storage
  error.

## Consequences

The deployed nested-gzip `Lambda RTC` artifact reaches the worker as a framed
snapshot. More than two gzip layers fail explicitly instead of reaching the
importer, and decoding can temporarily require space for the current input and
output layers.

## Risks

- Decoding requires temporary disk space for the raw entity and each active
  decoded layer. Completed intermediate files are deleted before activation.
- Artifacts with more than two legitimate gzip layers are intentionally rejected.

## Questions

- None.
