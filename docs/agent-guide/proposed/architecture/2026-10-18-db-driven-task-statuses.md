# Database-driven task statuses

## Problem

Journal assumes a closed list of nine task statuses across application projection,
the worker protocol, database mutation commands, and durable outbox records. A
valid custom status entity without `db/ident` is projected as its UUID in a
`Default_value`; Journal rejects that value and can fail the entire initial block
detail load. Treating it as `No_status` would hide data and would not enable editing.

This work starts at main commit `49520f0da203033152f69b071eba11ffa89f131b` on
`codex/db-driven-statuses-20261018`. The block-detail typography work at `3294321`
is isolated in its original worktree and is not part of this branch.

### Repository impact inventory

| Boundary | Current assumption | Required change |
| --- | --- | --- |
| `app/journal_model.ml/.mli` | Nine constructors plus `No_status`; English labels and four categories | Selected entity UUID, resolved database title, explicit unresolved state; absence stays distinct |
| `app/journal_graph_projection.ml/.mli` | Nine canonical idents; an unknown status fails a complete detail batch | Preserve the selected UUID and resolve metadata without failing unrelated content |
| `app/application.ml` | Six fixed menu entries; string-tag selection and constructor comparisons | Graph-scoped catalog menu with UUID keys; dynamic names; explicit clear action |
| `app/journal_capture.ml/.mli`, `journal_detail.ml` | Task toggle chooses `Todo` | Use a valid database default, otherwise request an explicit catalog choice |
| `app/journal_row.ml`, `journal_symbols.ml/.mli`, `journal_visual_tokens.ml/.mli` | Fixed labels, symbols and category colors | Database title; neutral readable fallback when database semantics are unavailable |
| `app/journal_graph_request.ml/.mli`, `journal_graph_runtime.ml` | Nine-way command conversion, favorites conversion, hardcoded child `V2_todo` | UUID commands, catalog lifecycle, graph-generation guards and targeted invalidation |
| `logseq_db_types/lib/graph_types.ml/.mli` | Separate seven-constructor `task_state` and `task_filter.states` | Shared entity identity for task and filter types; the filter currently has no production consumer |
| `logseq_db_worker/contract/protocol.ml/.mli` | Nine-constructor `v2_task_status` in reads, favorites and writes; no catalog read or generic property writer | UUID status wire values plus bounded catalog and batched lookup operations/results |
| `logseq_db_worker/lib/effect_runner/effect_runner.ml` | Enum conversion in both directions | Forward public database catalog reads and UUID mutations |
| `logseq_db_worker/lib/pure_reducer/core.ml` | Command/result routing | Route catalog requests with existing scope and completion rules |
| `logseq_overlay_db/spec/types.mli`, `lib/types.ml` | Nine-constructor status in blocks, favorites, mutation commands | UUID-based status identity and catalog result types; retain an isolated legacy replay representation |
| `logseq_overlay_db/spec/database.mli`, `lib/database.ml` | Reads only recognized `db/ident`; writes `Ref_to (Ident ...)`; no status catalog API | Read actual status entities; write exact UUID references with membership validation |
| `logseq_overlay_db/lib/outliner/task_status.ml/.mli`, `overlay_planner.ml`, `overlay_effect.ml` | Enum names drive mutation identity, fingerprints and dependency shadows | UUID identity for new commands; preserve old replay identity and dependency semantics |
| `logseq_overlay_db/lib/persistence_json.ml`, `persistence_outbox_v16.ml` | Enum codecs in commands and dependency shadows | Versioned UUID codec and backward decoding of current format 17 records; filename does not indicate current format |
| Existing app/worker/overlay test modules and protocol fixtures | Enum-shaped synthetic data and JSON | Update in existing targets; no Dune changes |

No separate native Swift status implementation was found. No changes to LUI,
Swift, Dune, lock files, or the typography branch are proposed.

## Proposal

### Canonical identity and metadata

Use `Graph.Uuid.t` as the current status identity at every production boundary.
Expose a descriptor containing UUID, database title, optional canonical ident and
database order. Names never identify a status: duplicate names and renames must
remain unambiguous. Missing or recycled referenced entities retain their UUID in
an unresolved state; they must not become `No_status`. A malformed stored value
should remain visibly invalid rather than silently becoming an absent value.

Discover supported values from the status property's actual entity relationships:
`logseq.property/created-from-property`, declared closed values where present,
and database-defined built-in entities. Verify the built-in ownership convention
against synthetic fixtures and read-only schema metadata before finalizing the
query; do not replace one hardcoded nine-name list with another. An observed real
graph has zero `closed-values`, while its custom status has a UUID, title, and
`created-from-property` relationship. Exclude empty placeholders and recycled
choices. No title-based inference is permitted.

If the property declares a valid default entity, capture uses that UUID. Otherwise
the task action asks the user to choose from the catalog. Do not silently choose
the first status or infer `Todo` from its title. Preserve existing display behavior
where database metadata supplies equivalent semantics; use readable neutral
styling otherwise.

### Public database contract requiring approval

`AGENTS.md` explicitly prohibits editing OCaml under `spec/` without an explicit
request to modify those `.mli` files. The minimum protected changes are:

1. `logseq_overlay_db/spec/types.mli`: replace the closed current `task_status`
   enum with entity identity; update block/favorite reads and `Set_task_status`;
   add catalog descriptor, missing lookup and paginated result types. Legacy enum
   decoding stays isolated from the current supported choices. If replay needs a
   legacy command representation, it carries the original canonical ident and
   fingerprint semantics, never a title-derived identity.
2. `logseq_overlay_db/spec/database.mli`: add bounded snapshot reads, approximately:

   ```ocaml
   val get_task_statuses
     : snapshot
     -> limit:int
     -> cursor:Graph.Cursor.t option
     -> (Types.task_status_catalog_result, Types.read_error) result

   val get_task_status_definitions
     : snapshot
     -> Graph.Uuid.t list
     -> (Types.task_status_lookup list, Types.read_error) result
   ```

   The first returns status-property/default metadata and a bounded page of
   definitions. The second resolves a bounded batch of identities, including
   explicit missing results, for referenced values and incremental changes.
   Cursors bind to a captured projection and use existing stale-cursor errors.

The worker contract and app `.mli` changes listed above are also public interface
changes, but are outside `spec/`. No worker reducer/effect-runner protected `.mli`
change appears necessary: they already route protocol commands generically.

### Read, write and synchronization flow

1. On opening a graph, fetch the bounded catalog once per graph generation through
   worker snapshot reads. Assemble a map keyed by UUID; publish an explicit
   loading/error state. Catalog failure must not prevent block text loading.
2. Block and favorite records preserve their selected UUID independently of catalog
   availability. Resolve titles from the shared map. Coalesce unknown identities
   into bounded batched lookups, never one query per block.
3. Status selection submits the exact UUID and existing block precondition. The
   database validates that the target is an active status choice in the same
   graph and writes the `logseq.property/status` Ref to that entity. Clear is
   explicit. Preserve `propertyRefs` and all other block content.
4. Reuse change-window UUIDs to batch-check changed definitions/property metadata.
   Publish the shared UUID-keyed catalog to retained view owners so a
   rename updates labels without reloading graph blocks. Verify that
   publication includes status metadata transactions; extend the existing change
   summary only if required. Add/remove/default changes update the catalog.
5. Cancel/reset catalog work on graph switch and reject late completions by the
   existing graph generation/scope. The same UUID in another graph must not reuse
   metadata from the previous graph.

### Durable compatibility

Current outbox records use format **17** in `persistence_outbox_v16.ml`. Both
commands and dependency shadows serialize the enum. New UUID records require an
explicit version or tagged encoding; old records must remain readable. Resolve
legacy canonical idents against the captured database, never against titles, and
retain the original operation identity/fingerprint for retry and receipt matching.
Missing legacy targets must produce an explicit pending/error outcome rather
than clear or substitute a status. Existing graph files are not rewritten during
read-only acceptance. The exact migration code must follow the existing record
validation and replay boundaries after contract approval.

### Implementation and test order

After approval, write all required behavioral tests in existing test modules and
observe relevant failures before implementation. Use public pure owners wherever
they execute the behavior. Projection owns the unknown-status detail regression;
catalog lifecycle and mutation scheduling belong to public runtime/reducer
events and completions. Database query/membership and durable codec behavior
cannot be proved by injecting results into the UI owner; cover only their narrow
public boundaries without duplicating the same regression across layers.

Implement shared identity/contracts, database catalog/read-write behavior and
codec compatibility, worker routing, then application catalog state and UI.
Run checks against final source, coordinate the Simulator resource window, perform
read-only original Lambda RTC acceptance, and obtain an independent review.
The user authorized a formal PR on 2026-10-18 at 14:40 UTC after final tests, Simulator acceptance and independent review. Track CI for its exact head; merge and phone installation remain unauthorized.

## Alternatives considered

### Unknown status becomes `No_status`

Rejected: hides valid data, loses identity and leaves selection/write/sync broken.

### Add a tenth enum constructor or arbitrary title string

Rejected: does not support N database-defined entities and cannot distinguish
duplicate names or preserve identity through rename.

### Query metadata separately for every block

Rejected: repeats reads, increases detail load latency and complicates graph
isolation. Use one shared catalog and coalesced missing/change batches.

### Mutate status through an existing generic worker property operation

Not available: the current worker protocol has no generic property writer or
status catalog reader. A UI-only replacement cannot correctly save a custom UUID.

## Acceptance criteria

- Synthetic catalogs cover zero, one, nine and more than nine values; built-in
  and custom choices are selected by UUID, including duplicate display names.
- A custom status without `db/ident` opens at the root and at depth three of a
  ten-level detail tree; no sibling content is discarded.
- Long names, missing/empty titles, placeholders, recycled entities and missing
  references preserve correct identity and have explicit readable outcomes.
- Rename/add/delete/default changes update menus and affected loaded rows;
  graph switches and late completions cannot mix catalogs.
- UUID selection, clearing, capture and child creation preserve the exact status
  property reference; invalid or wrong-graph selection is rejected explicitly.
- Current and legacy outbox round trips retain status references, dependency
  shadows, replay identity, fingerprints and duplicate-submission behavior.
- Changes use bounded catalog pages and batched delta/missing lookups, with no
  per-block catalog query or full graph/block refresh on rename.
- Existing loading/back navigation, rich text, references, tags and properties
  continue to work. Light/dark mode and dynamic fonts remain readable.
- Final-source tests and independent review pass; real original Lambda RTC is
  checked read-only, with any remaining build or acceptance limitation stated.

## Risks

- Built-in ownership/default/order metadata may differ from custom entities;
  validate actual schema conventions before locking down enumeration.
- A physically missing entity may no longer expose its UUID through a raw Ref;
  preserve all identity available and never invent a replacement.
- Backward outbox decoding must preserve old fingerprint semantics; changing only
  the enum type would invalidate persisted commands and dependency shadows.
- A status rename may not currently publish a block UUID change for every owner;
  targeted catalog invalidation must account for metadata transactions.
- LUI and existing Swift presentation are reused; no new native components or
  typography changes are included.
- Protected interfaces prevent implementation until the precise approval below.

## Questions

- Resolved: the user explicitly authorized the two protected `.mli` changes on
  2026-10-18 at 14:30:26 UTC, in reply to the exact file list. The parent task
  relayed that authorization and requested implementation, tests and independent
  review. No other protected interface or Dune change is authorized.


## Implementation notes

- Current worker values and writes use UUIDs. The database discovers values from
  property ownership/closed-value indexes, orders by database order and UUID,
  pages at 200 with a byte bound, and caches one immutable catalog per projection.
  Batched lookup is limited to 200. The application retains N definitions in
  Rrbvec and a UUID map; native menus show 100 choices per page.
- Incremental changes use batched metadata reads. Missing ordinary block IDs do
  not become negative cache entries. Lookup epochs live only while requests are
  outstanding; catalog reset, failures and cancellation fence older results.
  Resync reloads the catalog, including database default metadata.
- New outbox writes use format 18. Format 17 commands and dependency shadows
  decode with legacy canonical identity and keep their original fingerprints.
  The storage header accepts both formats. The checked-in synthetic fixture was
  emitted by the unmodified format-17 producer and includes submitted records.
- Capture and Append retain the original insertion identity after an ambiguous
  task write failure. Changing or clearing status updates that pending attempt;
  Retry confirms it. Body/attachment editing is temporarily held until the
  attempt is confirmed, with an explicit native recovery message. This prevents
  inserting a second block after a late status deletion.
- Existing Diagnostics now displays the Worker graph UUID and generation from
  the observed Worker graph state. It never substitutes the manager's selected
  graph, a catalog name or a disk record. With Ready/Open and an independent
  expected UUID, these rows support manual identity checks before and after
  device acceptance; they are not authenticated IPC or full iOS ABI evidence.


### Source validation before Simulator acceptance

The final source build passes `@all`. Targeted final runs pass 90 overlay sync
cases (including rejected metadata rollback), 23 mutation cases, 152 Runtime
cases, 122 mounted Application cases, and the route/semantics programs. An
independent reader reviewed the final logical changes with no remaining finding.
An initial ordinary-sandbox run was blocked by Swift synthetic RSA creation and
loopback bind EPERM. On October 19 the user explicitly requested broader shell
permissions; normal approval allowed the maintained build and complete local
regression. The unchanged checkpoint then passed `@all` and full `runtest --force`
(21 Alcotest suites / 919 cases, plus the standalone programs), and both ordinary
and complete-Worker test-host Simulator Apps built with strict signature checks.
They use experimental host restamping with `cross_abi_validated=false`.

The added read-only identity rows were tested first: the unmodified presenter
failed to show the actual Worker UUID; the implementation preserves actual versus
selected identity, generation and the explicit unavailable state. The matching
`c983bee` source passes `@all` and full `runtest --force` (21 reported Alcotest
suites / 920 cases, plus standalone programs), and its ordinary Simulator App
built and passed strict signature verification.

After explicit user authorization accepting normal background synchronization,
the ordinary App was installed and launched on A135. Its observed Worker is Open
at generation 1, but startup remains Restoring local. No original page acceptance
or accepted screenshot is claimed.

The first 1446 fixture omitted the complete WAL/SHM transfer documented in the
warm-start README. Public mirror inspection and a system SQLite schema-query
comparison both returned `unable to open database file`; that error is discarded
by the existing service. This fixture packaging mistake was corrected using the
public Storage API: verify and restore each synthetic database, checkpoint it,
keep its preparation connection quiescent during an explicit db/WAL/SHM copy,
then close it. No sidecar was hand-crafted and no storage behavior was changed.

With this complete package, the clean `c983bee` native object and unmodified
existing warm-start entry open the expected synthetic Worker UUID at generation
1, but the initial screen still waits. A separate read-only observer records the
same scope progressing from an unauthenticated manager to Worker Open, then an
unauthenticated attached manager with timeline presentation pending, then an
authenticated manager still awaiting presentation; no initial graph response is
observed. This supports investigating the existing Application scope-retirement
path, but does not by itself prove cancellation or establish the ordinary App's
cause.

An existing independent local-restoration repair is preserved on
`codex/fix-local-restore-auth-order-20261017` at `e5b9b2b`, and the separate
Graph-restoration task is implementing the startup dependency. Neither repair
has been copied into this status branch. All temporary observers, logs and
synthetic data remain outside this product worktree. At that checkpoint actual
Simulator acceptance and exact-head CI were still pending.


### Combined-source Simulator acceptance on October 19

The final independent startup repair is PR97 at
`cd25b81fc5512413398d66ee9f85491bc75eaad6`; its owner reports exact-head CI
39204306865 completed successfully. The separate diagnostics repair is PR96 at
`900326be3009b39103cd6fb8ed5d8f5396d0a765`. Both remain independent, unmerged
PRs. Neither dependency was copied into this status branch.

A local acceptance worktree combines this status branch at `939a149`, all five
PR96 commits and the final PR97 commit. It preserves PR96 failure reporting and
PR97 typed startup failures/network-owned cancellation. Two compile fixes add a
snapshot type annotation and the new startup fields to the status identity test.
The resulting clean integration commit is
`4e0a425e6d8e8cfe31033ca43258829267564f80`. The corresponding source passes
`@all` and forced full `runtest`: 21 reported Alcotest suites / 939 cases,
including Sync 295 and Application 131, plus standalone programs. That local run
preceded committing the two fixes; byte comparison binds its source to the final
commit. It is not exact-head remote CI proof. Independent final-source review
found no remaining issue.

The maintained producer/importer built and strictly verified the matching
isolated Simulator App. Its installed executable SHA-256 is
`e11267dff149a0416f1608b3bfd6944b70f66eca4b0d128faab8301b722e34aa`.
The native object is production code without overrides; the Swift entry is the
unmodified existing warm-start fixture, with the remaining Swift files matching
production. Authentication is deliberately blocked by that fixture. This remains
experimental host restamping with `cross_abi_validated=false`, and does not
establish real authentication, server synchronization or ordinary App acceptance.

On existing Simulator 1446, only the separate
`org.logseq.journal.db-status-runtime-probe` bundle and fresh synthetic directories
were used. Production Diagnostics reported Ready/Open, actual graph UUID
`60000000-0000-4000-8000-000000000001` / generation 1; after graph selection it
reported graph `...0002` / generation 2. Restart restored graph 2 at generation 1
in the new process. The host's first Timeline observation recorded zero token
requests. These are manual UI identity checks, not authenticated IPC capture.

Actual native interactions and public Overlay API readback confirm:

- 17 available database choices, stable UUID option identifiers, long CJK labels,
  applying a long custom status and clearing it without changing block content.
- Capture and Append in graph 1 use its configured default UUID `...0100`.
  Graph 2 has no default, opens the explicit chooser, and its Capture retains the
  selected UUID `...0102`. Readback contains exactly one of each created block,
  no cross-graph leakage, and the expected six/two local outbox records.
- Fresh metadata variants show a renamed status, exclude recycled choices, show
  an empty title as Unnamed status, and admit an added UUID `...0112`. A newly
  captured task uses that changed database default, exactly once.
- An empty catalog retains an existing recycled UUID as Unavailable status,
  explicitly reports no available choices, and offers Clear. Clearing it creates
  one local outbox record and readback confirms no remaining block status.
- The ten-level synthetic tree, rich Markdown/reference/link content, properties,
  detail navigation, link return, Append, light mode and dark maximum window
  Dynamic Type were exercised. All fixture changes use public APIs and complete
  WAL packages; no real graph was read for examples or mutated.

Nine actual screenshots and hash-bound manifests/readbacks are retained outside
Git under the task evidence directory `db-status/integration-20261019`. Maximum
Dynamic Type visual inspection passed for visible content, but the UI tool's
scroll/drag calls returned windowNotFoundAtPosition. Full list scrolling at that
size and high-contrast/VoiceOver behavior remain unverified. Metadata variants
verify restart loading, not live server metadata delivery; reducer/runtime tests
cover incremental invalidation and generation fencing. A135 was not changed in
this round and its original page acceptance is still pending. Phone 47 was not
touched. The independent probe is stopped and Simulator 1446 has been released.

The status PR keeps this status-only source and names PR96/97 as integration
prerequisites. Its exact-head remote CI remains a separate release gate; the
combined acceptance commit must not be represented as the status-only PR head.
No PR is merged or configured for automatic merge by this work.
