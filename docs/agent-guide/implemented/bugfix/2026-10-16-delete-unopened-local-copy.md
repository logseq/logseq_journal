# Delete Unopened Local Copy

## Problem

A legacy local copy has no account-owner JSON until its logical database opens successfully. Deleting it requires that JSON and a readable SQLite checkpoint, so a damaged or unopened copy cannot be removed. Presence inspection also treats database readability as copy existence, preventing the confirmation from being reached.

## Decision

The user explicitly requested removing the owner JSON mechanism and allowing confirmed deletion without a successful open (Sentinel_e19003f4b390819194e5a53ccdaf79e7). Remove its creation, reads, account-owner checks, obsolete messages and dedicated tests. Keep request account/catalog/current-graph admission, operation drainage and exact graph/resource scope.

The user approved the exact protected database.mli prepare_mirror_deletion signature change (Sentinel_2eac27ac67688191bde236730fbc372b). Prepare from application-support directory and graph UUID, capture physical directory generation independently of database/schema/checkpoint contents, and return that generation with the opaque preparation for the existing coordinator journal. Do not introduce another public entry point or persistence layer. Prepare, commit and recovery use the same directory identity. Retain exclusive lifecycle ownership, durable commit receipts and targeted cleanup/replay.

Derive only the canonical selected graph path under the configured support root. Reject symlinked graph/ancestor/retirement paths and unsafe lease files before writes, revalidate physical identities before namespace commit, and unlink contained symlinks without traversing their targets. Presence means the bounded graph directory exists, not that its database is readable.

Include the separately committed journal-code-review persistence-necessity rule in the same formal PR after validation. Do not edit Dune, locks or shared opam/pins. Test only disposable synthetic data on the task's isolated AE5 Simulator; protect the A5E/A135 synchronization investigation and every personal graph/device.

## Alternatives considered

### Ask the user to open and switch first

This cannot recover an unreadable graph and is the rejected behavior.

### Fabricate a healthy mirror inspection or duplicate deletion in the worker

A healthy inspection promises checkpoint facts that a damaged copy cannot provide. Bypassing the resource producer would duplicate its namespace, ownership and recovery lifecycle. Change the one existing preparation contract instead.

## Validation

- Full repository build, native-object prerequisites, 21 suites / 843 cases and standalone source-boundary checks passed. The five worker defect cases and four unsafe-path cases were observed RED before their owner fixes, then GREEN; the pre-existing contained-link protection remained green.
- Real AE5 iPhone 13 / iOS 26.1 XCUITest confirmed legacy unopened, non-SQLite and invalid-checkpoint copies can be removed and redownloaded through the real worker and a loopback TLS fixture. Observer records verified targets were unopened/unleased before removal, corrupt bytes or checkpoint schema existed, no owner JSON appeared, and the current graph stayed present.

- Public worker requests remove a never-opened copy without an owner marker, a non-SQLite database, an invalid checkpoint schema and a directory whose database is missing, while preserving the active graph and unrelated files.
- Public producer requests reject symlinked graph/ancestor paths, preserve external targets of contained symlinks and reject replaced directories before commit. Existing busy/cancel/commit/replay/collection tests remain meaningful.
- No owner-JSON implementation, message or dedicated account-owner fixture remains. No database-content read is required by presence or deletion preparation, commit or recovery.
- Full compilation and regression/source-boundary checks pass. Real synthetic Simulator row-menu confirmation can delete unopened and corrupt copies, retains Not downloaded rows and redownloads through the controlled real-worker fixture.
- Publish one formal PR containing the skill and fix, then independently review its exact head and follow CI to terminal success; do not merge or install on a phone.

## Risks

- Without a persisted account-owner marker, local account ownership is not inferred from the contents. User-confirmed graph-directory deletion is fenced by the current authenticated request and catalog rather than a successful content load. Filesystem identities and scoped asset producers must still prevent deletion of replacements or another path.

- Pure reducer events do not access the filesystem, detect SQLite corruption, or execute pathname transitions. Supplying an already incorrect inspection result would not reproduce this bug; regressions therefore use the narrowest public executing worker/producer boundaries without bypassing interfaces. Native acceptance is separately required by the user, not duplicate defect ownership coverage.

- Host ARM64 OCaml restamping remains experimental Simulator compatibility with cross_abi_validated=false; controlled fixture execution does not validate a live remote sync service.

## Consequences

The obsolete account-owner marker is neither created nor read. A pre-existing marker is ordinary contained data and disappears when its local copy is explicitly removed; the upgrade does not sweep personal graph directories. No new persistence or public entry point was added. The existing independent retirement receipts and lease lifecycle remain necessary for cross-producer cleanup and replacement isolation.
