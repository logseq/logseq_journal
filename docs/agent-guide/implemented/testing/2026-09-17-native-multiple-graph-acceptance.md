# Native Multiple Graph Acceptance

## Problem

The real native acceptance host has verified cached same-graph reselection but
contains only one graph. That does not prove switching between distinct graphs,
per-graph draft isolation, or restoration of the most recently selected graph.
The iPhone is unavailable; shared behavior can still be exercised on macOS.

## Decision

Extend the existing isolated fixture generator to produce a bounded number of
independent encrypted graphs. Parameterize the existing storage fixture helper
with graph identity so directory, database identity and checkpoint agree. Use
public storage transactions and catalog encoding. Give graph content and catalog
names explicit ordinal labels; retain identical block UUIDs across graphs to
exercise graph scoping. Replace the single-graph fixture schema with a required
list of graph descriptors, without a legacy parser or migration.

The Swift host installs one memory-only account private key and saves the same
fixture wrapped key for every graph through existing crypto operations. It must
not create a fresh private key for each graph, which would invalidate prior keys.
The selected first graph remains the missing-key case when that flag is used.
Expose a bounded --graphs builder argument and document the native acceptance.

Exercise two-way native graph selection, independent Capture drafts and saving,
then restart with the last selected graph. Retain the actual native observations,
read-only outbox summaries and source hashes. This is acceptance of existing
production behavior, not new regression coverage or proof of remote services.

## Alternatives considered

### Inject a selected graph into Application state

Rejected: this bypasses actual catalog selection, closing and opening worker
sessions, local keys and graph draft dispatch.

### Use the user's account graphs

Rejected: generated graphs permit scoped mutations without changing user notes
or requiring credentials. Blocked authentication remains explicit.

## Acceptance criteria

- Two generated graph identities agree across catalog, database and checkpoint.
- Both encrypted local graphs open through the production native application.
- A draft from graph A never appears in graph B; returning to A restores it.
- Saves appear only in their originating graph and corresponding local outbox.
- Restart opens the last selected graph without requiring the graph picker.
- Source hashes, native results and macOS/remote-service limits are recorded.
- No Dune, protected spec or SDK source edits occur; Undo/Redo remains deferred.

## Consequences

The host builds and opens both generated encrypted graphs. Native two-way
selection preserves independent Capture drafts: graph 2 starts empty, graph 1
restores its earlier Chinese draft, and graph 2 restores its separate Arabic
draft after graph 1 saves. Each local outbox contains exactly one insertion with
only its own expected title. Restart directly presents the last selected graph
2 and its saved content. Both cooperative shutdowns pass.

The generator uses the parameterized existing fixture helper, with matching
graph identity in the database, directory, checkpoint and catalog. Its first
compile attempt used an incorrect qualified record field; that fixture compile
error was corrected before native acceptance. No application defect or failing
application regression is claimed. The existing 30 storage tests and registered
macOS regression suites pass. No production UI, Dune, protected spec or SDK
source changed. Evidence and source hashes are recorded in batch 28 of the
[implementation ledger](../../../test-reports/2026-09-16-native-swiftui-standardization/implementation.md).

Local graph selection and Capture isolation are now verified through the native
application. Remote authentication, password unlock, remote synchronization and
physical iPhone acceptance were outside the evidence produced in batch 28.

Batch 36 subsequently executes the same graph ownership acceptance on a physical
iPhone 13 using the production Release runtime and native views. Both Capture
and Append drafts, including Capture Task state, remain independent during
two-way graph switching with repeated parent UUIDs. Exact outbox readback finds
three intended operations in graph 1 and two in graph 2, without crossed writes.
Restart selects graph 2 directly and preserves its saved Append content. These
results extend the bounded local acceptance to UIKit; they do not prove remote
authentication/synchronization, unsaved draft persistence across restart or the
remaining physical accessibility/performance matrix. See batch 36 in the same
implementation ledger.

## Risks

- One account key must serve every generated wrapped key consistently.
- A stale fixture file should fail decoding and be regenerated; it must not be
  silently interpreted as the new multi-graph schema.
- Native acceptance does not replace existing public pure draft-owner regressions
  or close physical iPhone gesture/keyboard/accessibility/performance gates.

## Questions

- None. Distinct graph selection and draft ownership are in the authorized scope.
