# Repository Glossary

This glossary defines the terms used most often in this repository. It describes
the current architecture and public vocabulary; the `.mli` files under each
package's `spec/` or `lib/` directory remain the authoritative API definitions.

## Repository map

| Area | Responsibility |
| --- | --- |
| `app/` | Bonsai application state, journal presentation, navigation, and translation between UI actions and Worker requests. |
| `flutter/` | Flutter host projects, platform integration, native cryptography, and end-to-end test entry points. |
| `logseq_db_types` | Storage-independent graph values shared across package boundaries. |
| `logseq_db_storage` | Physical DataScript and SQLite persistence. |
| `logseq_overlay_db` | The UUID-addressed logical graph formed from authoritative data and pending local intent. |
| `logseq_sync` | Managed Sync policy, transport, bootstrap, encryption coordination, and server continuity. |
| `logseq_db_worker` | Serialized graph lifecycle and request routing between the App, Overlay DB, and Sync. |
| `docs/agent-guide` | Decision documents organized by lifecycle and change class. |

## Terms

### Acceptance barrier

The server cursor and checksum that confirm how far a submitted batch was
accepted. Overlay DB uses this evidence when reconciling submission responses
with authoritative history.

### Admission

Validation that work fits the configured limits before the repository commits or
transports it. Admission covers values such as response size, outbox record and
byte counts, change publication size, and wire batch size.

### Authoritative state

The locally stored graph state reconstructed from server-confirmed history through
the current checkpoint. It excludes optimistic local mutations. In Overlay DB
documentation, this state is often written as `A` or called the authoritative
root.

### Block

The primary piece of content in a Logseq graph. A block has a UUID, title, parent,
owning page, sibling order, timestamps, references, tags, and properties. Blocks
form trees through their parent relationships.

### Bonsai

The incremental OCaml framework used to model application state and derive the
widget tree. `bonsai_flutter` connects Bonsai computations to Flutter widgets and
Worker services; it is a framework dependency, not a package owned by this
repository.

### Bootstrap

Creation of a local mirror for a managed graph that is not available locally.
Bootstrap fetches metadata, downloads and validates a snapshot artifact, obtains
the graph key when E2EE is enabled, and atomically activates the staged mirror.

### Capture

The journal UI flow for creating a new top-level block, optionally with child
blocks. Capture produces one semantic local mutation so the new content appears
optimistically and can later be synchronized as a unit.

### Catalog

The managed Sync account's list of graphs. Catalog discovery supplies each
managed graph's identity, name, schema, and encryption flag and remembers the
selected graph for startup restoration.

### Change window

A bounded Worker protocol record describing one logical projection transition.
It names predecessor and successor revisions plus the affected block UUIDs, page
UUIDs, and structure interests. Consumers acknowledge change windows after
processing them.

### Checkpoint

Durable synchronization metadata describing the latest contiguous server history
applied to a mirror. It includes the graph identity, schema, applied server cursor,
checksum, status, and last error. A checkpoint is not a pagination cursor.

### Cursor

An opaque position. The repository uses two distinct kinds:

- A **server cursor** orders authoritative Sync history and submission barriers.
- A **continuation cursor** resumes a bounded journal, children, or page-tree read
  against a compatible logical projection.

Callers must not parse a cursor or use one kind in place of the other.

### DataScript

The immutable database model used for Logseq graph data. Numeric DataScript
entity IDs are internal storage details; public Overlay DB, Worker, and App
boundaries identify graph objects by UUID.

### Day feed

The App's bounded presentation of one journal page and its top-level timeline
entries. Multiple day feeds form the journal timeline; continuation cursors load
more entries or days without retaining an unbounded widget list.

### E2EE

End-to-end encryption for managed graphs. Sync coordinates graph-key retrieval,
key unlocking, encryption, and decryption. Overlay DB exposes bounded protection
or unprotection requests without taking ownership of the cryptographic provider.
A **wrapped graph key** is encrypted key material persisted by the platform; a
**graph key handle** is an opaque, scope-bound reference to unlocked key material.

### Effect

An operation requested by a pure reducer but executed outside it, such as network
I/O, storage access, cryptography, a timer, or a Worker database operation.
Request effects carry tickets, and effects carry lifecycle scopes so stale
completions can be rejected.

### Effect runner

The stateful interpreter that performs effects and reports typed completions back
to a reducer. The reducer decides policy; the effect runner owns the required I/O
resources and side effects.

### Flutter host

The platform-specific shell under `flutter/` that renders the Bonsai-produced
widget tree and provides native capabilities such as keychain-backed secrets and
cryptography. Most product behavior and state policy remains in OCaml.

### Generation

A token for a lifecycle identity, such as an account, graph, connection, logical
database, presentation, or mirror incarnation. Reopening or replacing the owned
resource changes its generation, allowing work from the previous incarnation to
be fenced off. A generation is not a change counter within the same incarnation;
that role belongs to a revision.

### Graph

A Logseq knowledge base containing pages, blocks, properties, references, and
schema metadata. A **managed graph** is the Sync catalog description of a graph:
its UUID, display name, schema, and encryption flag.

### Journal day

The integer date key stored on a journal page. Application code converts it to
and from display dates using `Journal_time` and `Journal_calendar`; it is not a
Unix timestamp.

### Journal page

A page whose kind includes a journal day. The App presents journal pages as the
timeline and places their top-level blocks into day feeds.

### Local mutation

A UUID-addressed semantic edit created by the App, such as saving a block,
inserting a block tree, deleting a subtree, creating a journal page, or changing
task status. A successful local commit updates the logical projection immediately
and records the intent in the durable outbox for later synchronization.

### Logical change

A change visible through public logical reads. A storage or transport transition
that produces the same logical result is `No_logical_change`; it does not advance
the projection revision. Large or unrepresentable changes require a projection
resync instead of an exact item list.

### Logical database

The coherent graph observed by App and Worker reads. It combines the authoritative
root with all logically active local outbox effects. Callers never choose between
the two sources.

### Mirror

The durable local representation of one graph, stored under the application
support directory. A mirror contains the authoritative lineage and its Sync
metadata, outbox, and mutation receipts. Mirror inspection, attachment, opening,
closing, deletion, and garbage collection are generation-checked lifecycle
operations.

### Mutation fingerprint

A deterministic digest of a mutation's canonical semantic payload. Together with
the mutation ID, it supports idempotency checks and detects reuse of an ID for
different work.

### Mutation receipt

A compact durable terminal record for a mutation. Receipts preserve idempotency
and enough evidence to classify late Sync responses after the active outbox record
has been removed. Outcomes include applied, no change, remote won, and discarded.

### Outbox

The durable, ordered collection of local mutations that still participate in
synchronization or logical projection. The queryable outbox stores semantic intent,
normalized logical effects, transport state, and indexes used by Overlay DB reads.
Common transport states include queued, submitted, accepted pending authoritative
history, and blocked.

### Outliner

The graph operations that preserve Logseq's hierarchical block invariants,
including block insertion, editing, subtree deletion, child lookup, ordering,
references, and task-status changes. Public local writes expose a deliberately
small set of semantic outliner operations.

### Page

A named graph object that owns a tree of blocks. Page kinds include ordinary,
journal, class, property, hidden, and built-in pages. Pages and blocks have
different public UUID types even when an internal relationship accepts either.

### Projection

The result of applying logically active, ordered outbox effects to authoritative
state:

```text
Projection(A, O) = apply active normalized effects from O over A
```

The projection is a meaning, not a second retained DataScript database. A
**projection revision** advances exactly when a committed operation changes a
public logical read result. `Journal_graph_projection` uses the same general word
for the separate App-layer conversion from graph records to journal presentation
models; it does not own the Overlay DB projection.

### Pure reducer

A deterministic state machine whose `step` function maps current state plus an
event to next state plus instructions. Reducers own lifecycle and Sync policy but
perform no I/O directly, which makes transition behavior independently testable.

### Rebase

Re-evaluation of pending local intent after new authoritative history is applied.
Queued mutations may be deterministically replanned; incompatible mutations are
blocked rather than silently changing their meaning.

### Revision

A token representing change within a generation. The main forms are:

- **Projection revision:** global version of public logical results.
- **Block or page state revision:** equality token for one logical object,
  including a missing-object result.
- **Scope revision:** equality token for a children list, page tree, or journal
  index.
- **Authoritative, logical-outbox, and transport-outbox revisions:** internal
  compare-and-set versions for their respective sources.

An unrelated global change may advance the projection revision without changing
a block, page, or scope revision.

### Snapshot

This word has three deliberate uses:

- A **logical snapshot** is a short-lived read lease pinning one coherent pair of
  authoritative and outbox roots at a snapshot version.
- A **snapshot artifact** is a downloaded bootstrap file used to create an absent
  local mirror.
- A **Sync presentation snapshot** is the pure Sync reducer's UI-readable summary
  of phase, catalog, selected graph, startup state, and last error.

Logical snapshots must be released. Snapshot artifacts are parsed and validated
in staging before atomic activation.

### Structure interest

A subscription key for graph shape rather than one record's fields. Current
interests cover the children of a block, the tree of a page, and the journal
index. Projection changes publish these interests so consumers know which
bounded structures to read again.

### Submission batch

An ordered, bounded group of protected local transactions sent to the Sync
server. The batch has an opaque ID and a `t_before` server cursor. The server may
apply it only against the expected cursor, preventing an uncertain retry from
silently executing against different history.

### Sync token

An opaque compare-and-set token for the current transport view of Overlay DB.
Sync supplies the token it inspected when requesting an outbox transition, so a
stale transport decision cannot overwrite newer outbox state.

### Task status

The normalized workflow state attached to a block, such as `Todo`, `Doing`,
`In_review`, `Done`, or `Waiting`. Task status is exposed as a dedicated semantic
operation rather than as an arbitrary property write.

### UUID

The stable identity used for graphs, pages, blocks, properties, mutations, and
protocol requests. UUIDs cross package and persistence boundaries; numeric
DataScript entity IDs do not.

### Worker

The serialized boundary between the Bonsai App and graph services. Worker protocol
requests carry commands and request IDs; responses carry bounded outcomes; pushes
announce projection changes or required resynchronization. The Worker coordinates
Overlay DB and Sync but does not redefine their storage or transport semantics.

### Write precondition

The set of block, page, and structure revisions observed before a local mutation
is prepared. Overlay DB validates the set at commit time so optimistic UI work
cannot overwrite a logically changed target.
