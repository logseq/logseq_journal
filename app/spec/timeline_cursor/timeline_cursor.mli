(** {1 TLDR}

    Timeline uses the worker's sealed snapshot-scoped paging values for dates,
    direct page roots and direct preview children. This module is the App name
    for that protocol; it owns no I/O, snapshots, cache or persistent state.
    Execute [Worker.Timeline_read] with the existing validated read budget.
    Every packet carries a receipt, including empty and exhausted packets.
    Validate a retained window through one [Worker.Timeline_check] request.
    UI request generations independently fence asynchronous installation. *)

module Worker = Journal_worker_coordination.Worker_api

(** {1 Minimal usage example}

    The caller supplies [page], a session executor [run] using the validated
    worker budget, and its current request generation:
    {[
      let query = roots ~page in
      match run (Worker.Timeline_read { query; after = None }) with
      | Ok (Ok packet) ->
        if request_is_current () then
          install packet.items packet.receipt packet.next
      | Ok (Error error) -> report_paging_error error
      | Error error -> report_worker_error error
    ]}
    [run], [request_is_current], [install] and the reporters are caller callbacks.
    A [More cursor] resumes with [after = Some cursor]; [End] has no next read.
    Retain its receipt until the query leaves the loaded window, even at [End]. *)
(** {1 Capability details} *)

include module type of struct
  include Worker.Timeline
end

(** {1 Lifecycle and recovery}

    Database and worker guarantees:

    - Dates require an authoritative journal-index version covering membership,
      day/order and returned page metadata. A single graph journal-index scope
      is intentionally sufficient; do not introduce per-date interval tracking.
      Updating existing block content must not invalidate this index scope when
      the returned page DTO is unchanged. Any change to returned page metadata,
      including [page.updated_at_ms] or [page.revision], must invalidate it.
    - Roots require a page-direct-members scope covering membership, order,
      recycling/visibility and all returned root DTO fields. Descendant payload
      changes do not affect it unless a returned root field (such as raw child
      count) changes. Preview children require the analogous direct-parent
      scope, including fields used to exclude property-value children.
    - Existing children membership revisions can contribute to those proofs,
      but alone do not prove payload freshness. Existing Tree results have no
      collection revision; current projection-bound continuations and App page
      epochs are not substitutes. The adapter needs authoritative snapshot-bound
      versions and resumable positions for these three query families.
    - Capture/local overlay application, remote sync, rebase, rollback and local
      acknowledgement must all maintain the same logical scope semantics.
      Cross-parent/page moves invalidate both source and destination scopes;
      journal reassignment also changes the journal index. Delete/recreate must
      not reuse an old version (ABA). A graph generation reset revokes owners.
    - Hydrated titles, tags, task metadata and ancestor recycling affect versions
      wherever they change returned DTOs. External presentation inputs (time
      zone, tag/status catalogs or display policy not included in these DTOs)
      remain explicit UI refresh dependencies, not hidden DB cursor proofs.
      If bounded authoritative proofs are unavailable, report that fact; do not
      fall back to full scans, a global projection stamp or a duplicate cache.

    The UI retains one receipt per retained query, including exhausted dates,
    empty days and preview reads stopped after three visible summaries. Validate
    the date receipt, retained day-root receipts and retained preview receipts
    against one borrowed snapshot when reconciling a loaded window. Validation
    is bounded by the retained window, not the graph. Existing changefeed signals
    schedule/coalesce that work; a gap/resync requires reconciliation even if
    no next-page request exists. Do not poll every scope on every render.

    On [Scope_changed], discard that scope's accumulated packets and continuation,
    and reload its retained window from the beginning in bounded packets. Do not
    append a fresh packet to an old prefix. Independent scopes may stay loaded;
    a date-index change reconciles headings by page identity and does not itself
    discard unchanged day/preview scopes. Assemble related roots/previews only
    after checking their receipts together; an invalidated in-flight assembly
    is discarded. Preserve existing refresh, visibility and scrolling policy;
    this protocol preserves existing UI behavior and does not require whole-graph reloads.

    [Owner_changed] discards all old-owner receipts, cursors and pending replies.
    Ordinary [Read_failed] retains its concrete Worker error and may be retried
    under a still-valid owner; it is not evidence of scope invalidation. Exhaustion
    is [End], never an error. Proof/budget/protocol errors remain visible and do
    not silently restart or spin. Recovery retries must use existing bounded
    caller retry policy, not an unbounded internal loop.

    UI request generations are separate from DB versions. On refresh, cancellation,
    graph switch or supersession, advance/revoke the UI request identity. Ignore
    late/duplicate completions even if their DB receipt was once valid. This
    module schedules no requests and owns no cancellation or worker admission.
    Cancellation does not imply worker termination or mutation rollback.

    Receipts/cursors contain bounded identities, versions and positions only.
    Keep one receipt per retained query and at most its active continuation;
    release them on window eviction, query replacement or owner teardown. Pending
    work and assembly buffers must use existing runner/window bounds. Release
    each borrowed snapshot on every success/error/cancellation path. Preview
    scans may span many packets to find three ordinary children, but retain only
    selected summaries and one continuation; never the entire scanned prefix.
    Dropping a cursor requires no close/ACK. Mutation commit, durable recovery
    and user-visible settlement keep their existing independent authorities. *)
