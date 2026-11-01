(** Target App/Worker boundary. No production implementation satisfies it yet.
    Sessions, projections and observation handles are issued by the trusted Worker
    runner, not assembled from UI fields. Type abstraction is not authentication:
    the runner must validate the origin and ownership of incoming messages. *)

module Uuid = Logseq_db_types.Graph_types.Uuid

type account_generation
type graph_generation
type presentation_generation
type worker_incarnation
type session
type presentation

val account_generation : session -> account_generation
val graph_generation : session -> graph_generation
val presentation_generation : presentation -> presentation_generation
val presentation_session : presentation -> session
val graph_id : session -> Uuid.t
val equal_session : session -> session -> bool

(** Use the existing mailbox lifetime identities, not a second invented nonce. *)
val worker_incarnation
  :  runtime_epoch:Logseq_db_worker_lui.Journal_worker_ids.Runtime.epoch
  -> worker_generation:Logseq_db_worker_lui.Journal_worker_ids.Worker.generation
  -> worker_incarnation

(** An execution session survives focus changes while resident. Closing, reopening,
    account replacement and removal revoke its authority. Every admission and
    completion rechecks liveness; possession of an old value cannot prevent
    revocation. Presentation acknowledgements additionally match [presentation]. *)
val same_logical_graph : session -> session -> bool

type error =
  | Revoked_session
  | Invalid_input of string
  | Response_budget_exceeded
  | Protocol_mismatch of string
  | Db_error of Logseq_db_worker.Error.t
  | Service_failed of string
  | Unsupported_operation of string

type request_id
val request_id : Uuid.t -> request_id

type read_budget

(** Validates positive item/encoded-byte bounds against the session's advertised
    limits. The final enriched response must fit both bounds. An item count alone
    is insufficient; an oversized singleton fails explicitly without truncation. *)
val read_budget
  :  session
  -> maximum_items:int
  -> maximum_bytes:int
  -> (read_budget, error) result

type journal_day
val journal_day : int -> (journal_day, error) result

type page
type block

(** Read-only fields from the existing [Graph_types.page]/[Graph_types.block]
    results. UUIDs remain normalized and titles retain their stored text. These
    accessors grant no execution authority and expose no DB/storage handle. *)
val page_uuid : page -> Uuid.t
val page_title : page -> string
val block_uuid : block -> Uuid.t
val block_title : block -> string

type 'a continuation
type 'a slice = private
  { items : 'a list
  ; next : 'a continuation option
  }

(** Slices contain at most 200 items. Continuations are bound at runtime to the
    session, query parameters and projection revision; the type index alone does
    not establish any of those value equalities. *)
type _ query =
  | Journal : journal_day -> page option query
  | Children :
      { parent : Uuid.t
      ; after : block continuation option
      }
      -> block slice query

type append_intent

(** Creates an immutable durable Capture intent bound to the logical origin,
    account and graph, independent of transient session/request counters. Its
    normalized identity and complete payload are persisted before first send.
    A changed payload/status choice is a new intent; retries reuse the same one. *)
val append_intent
  :  session
  -> mutation_id:Uuid.t
  -> block_id:Uuid.t
  -> day:journal_day
  -> title:string
  -> task_status:Uuid.t option
  -> (append_intent, error) result

val encode_append_intent : append_intent -> bytes

(** Recovery may bind the same durable intent to a freshly opened session for the
    same logical graph. Reject malformed payloads and a different origin/account/
    graph. Replaying the ID with different content is a conflict, never a new write. *)
val restore_append_intent : session -> bytes -> (append_intent, error) result

type receipt
type confirmation

type mutation_progress =
  | Rejected of error
  | Outcome_unknown
  | Committed_pending_presentation of receipt
  | Confirmed of confirmation

(** [Rejected] requires evidence that this local intent was not applied.
    [Confirmed] requires read-back/presentation evidence for the exact receipt,
    target, session and revision; rendered Timeline membership is not evidence.
    A remote sync rejection of an already committed local intent is a separate
    sync fact and must not turn that local commit into [Rejected]. *)
type admission_error = Full | Not_ready | Stopping | Unsupported_request of string
type interruption = Cancelled | Transport_lost | Worker_stopped
type 'a reply =
  | Not_admitted of admission_error
  | Answered of ('a, error) result
  | Interrupted of interruption

(** A refusal before reservation is [Not_admitted]. After acceptance, interruption
    or an unvalidated error cannot assert that a mutation did not commit. Preserve
    an existing receipt; otherwise reconcile using the same durable intent.
    Not_admitted describes this attempt, not whether an earlier attempt committed. *)
type observation_epoch
val compare_observation_epoch : observation_epoch -> observation_epoch -> int
type 'a observation
type 'a observed = private
  { observation : 'a observation
  ; epoch : observation_epoch
  ; value : 'a
  }

(** Querying is one-shot and does not acquire, release or advance an observation.
    Observe atomically registers interest and samples its initial value/revision,
    including empty/missing pages. Only invalidation or an explicit refresh may
    advance its epoch. Updates match the exact handle and live session. Release
    also accepts an already tracked retired handle solely for cleanup; releasing
    twice is harmless and late updates are ignored. Retained suffix
    reconciliation is not superseded by an unrelated prefix query. *)
type _ request =
  | Query : read_budget * 'a query -> 'a request
  | Observe : read_budget * 'a query -> 'a observed request
  | Refresh : 'a observation -> 'a observed request
  | Release : 'a observation -> unit request
  | Append : append_intent -> mutation_progress request

(** [Append] resolves/creates the journal page and appends under Worker-owned
    transaction and outbox coordination. It does not require the App to fetch a
    children slice or whole page first. A retry returns the existing operation's
    outcome; graph changes, conflicts and byte limits remain runtime checks.
    Neither response loss nor a later read failure rolls back a durable commit.
    This is a target runtime obligation: today's separate create-page/insert
    commands do not implement it. Until a durable atomic/idempotent backend path
    exists, reject before enqueue with [Not_admitted (Unsupported_request ...)]. *)
type observation_update = Update : 'a observed -> observation_update

type projection_version
val compare_projection_version : projection_version -> projection_version -> int
type resident_phase = Opening | Open | Closing | Failed of error
type network_phase = Offline | Connecting | Current | Network_failed of error
type resident = private
  { session : session
  ; phase : resident_phase
  ; network : network_phase
  }

type removal_mode = Ordinary | Force
type removal_stage = Closing_graph | Deleting_local | Clearing_selection
type local_deletion = private
  | Removing of Uuid.t * removal_mode * removal_stage
  | Removal_failed of Uuid.t * removal_mode * removal_stage * error

type projection
val projection_incarnation : projection -> worker_incarnation
val projection_version : projection -> projection_version
val residents : projection -> resident list
val selected : projection -> presentation option
val local_deletion : projection -> local_deletion option
val equal_projection : projection -> projection -> bool

(** One immutable version covers membership, exact session phases, selection and
    deletion progress. At most three residents; selection refers to one of them.
    A newly opened session is usable from this projection without relying on an
    earlier separate open push. Older versions and revoked incarnations cannot
    replace it. Versions are ordered within the trusted Worker connection; a new
    connection revokes its predecessor before its baseline is applied. Account/
    local availability and network progress remain orthogonal.

    Removing the last graph publishes an empty resident set, no selection and
    terminal deletion progress even if there is no readable DB. Equality must
    notice those transitions, including Removing -> None and failure changes.
    Ordinary deletion preserves current/resident/account/catalog policies. Force
    removal requires fresh explicit confirmation, fences and joins target writers,
    preserves other graphs/cloud/shared credentials, and reports partial cleanup;
    interrupted or OS-refused cleanup is never represented as complete. *)
val removal_target : local_deletion -> Uuid.t

(** Signature of a connection-bound validating issuer used inside Worker_effect_runner.
    The integration factory below is the trust boundary; App rendering cannot assemble sealed
    values from UI records. Neither a module signature nor its factory proves the
    honesty of an arbitrary backend or authenticates caller-supplied identity. *)
module type ISSUER = sig
  (** Invalidate issuance and all previously issued execution authority before
      detaching the old connection. Idempotent. Only previously tracked request/
      handle cancellation, Release and their terminal ACKs remain permitted for
      cleanup; they cannot admit new data operations or reactivate a session. *)
  val revoke : unit -> unit

  (** Validate and map to the actual in-process Service request, including scoped IDs, query
      parameters/budget, observation handle and durable intent identity. This
      preserves the current OCaml transport without a fictional bytes/adapter hop. After
      revocation reject Query, Append, Refresh and new Observe; only idempotent
      Release of a handle tracked by this binding remains encodable. Mapping
      does not reserve Worker capacity or prove that a mutation was persisted.
      Unsupported target operations fail explicitly; never translate atomic Append
      into today's separate mutations or claim ordinary reads register observations. *)
  val request
    :  session -> request_id:request_id -> 'a request
    -> (Logseq_db_worker_lui.Logseq_db_worker_lui_service.request, error) result

  (** Validate one complete version and issue its sessions/presentation. Reject
      mismatched connection/account, old incarnation/version, duplicate residents,
      incoherent selection and invalid deletion transitions before construction.
      Today's Service.state and separate graph-state pushes do not carry an atomic
      versioned baseline. Return Unsupported_operation until a Worker-owned sample/
      registration or version-replay handshake can establish all required facts;
      combining independently sampled records is not that proof. *)
  val projection
    :  previous:projection option
    -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.state
    -> (projection, error) result

  (** Match the live session, request ID, request/result kind and mutation receipt
      identity. Known rejected or committed outcomes require corresponding evidence;
      an undecidable accepted write remains unknown rather than becoming rejected.
      A revoked binding may validate only tracked cleanup terminal ACKs; those
      retire resources and never construct a new live projection/session. *)
  val reply
    :  session
    -> request_id:request_id
    -> 'a request
    -> Logseq_db_worker_lui.Logseq_db_worker_lui_service.response
    -> ('a reply, error) result

  (** Validate this handle's owner, query/revision binding and current epoch. *)
  val observation
    :  session -> 'a observation -> Logseq_db_worker.Protocol.response
    -> ('a observed, error) result

  (** Validate the live session, request ID, durable mutation identity, logical
      owner and committed revisions. A differently identified receipt is rejected.
      The resulting receipt proves local durability, not cloud acceptance. *)
  val receipt
    :  session
    -> request_id:request_id
    -> intent:append_intent
    -> Logseq_db_worker.Protocol.response
    -> (receipt, error) result

  (** Issue confirmation only after exact target read-back/presentation evidence
      for this receipt, session and revision; empty Timeline text is not absence. *)
  val confirmation
    :  session -> receipt -> Logseq_db_worker.Protocol.response
    -> (confirmation, error) result
end

(** Trusted integration entry point, implemented by [Worker_api], so the runner
    can issue sealed values from validated dbworker facts. The host obtains origin/account from
    its verified local/online account binding and attach this issuer only to the
    corresponding real Worker channel. Normalization, connection lifetime and
    every message/receipt are validated; merely passing strings is not permission
    to access a graph. Worker-side ownership/authorization checks remain mandatory.
    No network authentication or filesystem operation is implied by this factory. *)
val issuer
  :  managed_origin:string
  -> user_id:string
  -> runtime_epoch:Logseq_db_worker_lui.Journal_worker_ids.Runtime.epoch
  -> worker_generation:Logseq_db_worker_lui.Journal_worker_ids.Worker.generation
  -> ((module ISSUER), error) result
