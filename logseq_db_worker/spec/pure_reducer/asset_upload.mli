(** {1 TLDR}

    Coordinate one explicit durable import independently of download demand.
    The caller owns {!t}; {!step} is pure and returns next state plus ordered
    {!instruction}s. The worker interpreter owns persistence, upload and staging
    release. {!checkpoint} exposes the last durable intent for recovery;
    cancellation requests cleanup and does not prove upload rollback.

    The dependent variants are defined below. Actual entry-point excerpts:
    {[
      val create : scope:Scope.graph_scope -> available:bool -> t
      val step : t -> event -> t * instruction list
      val checkpoint : t -> Intent.t option
      val status : t -> status option
    ]} *)

module Intent = Logseq_db_types.Asset_upload_intent

module Scope = Logseq_sync_pure_reducer.Core

type t

(** [available] admits PUT work only when foreground networking and the graph key
    are available. Local durability and cancellation remain active while paused. *)
val create : scope:Scope.graph_scope -> available:bool -> t

(** {1 Minimal usage example}

    The caller supplies the current [scope], network/key [available] flag, an
    already validated upload [intent] and the worker's [interpret]:
    {[
      let state = ref (create ~scope ~available) in
      let next, instructions = step !state (Start intent) in
      state := next;
      List.iter interpret instructions
    ]}
    [interpret] queues exact [Completed (ticket, completion)] events for later
    serialized turns. After restart, use [Restore intent] with stored durable
    evidence instead of creating a new operation identity. *)

(** {1 Capability details} *)

type failure =
  | Network
  | Authentication
  | Missing_source
  | Size_rejected
  | Revoked_access
  | Invalid_content
  | Persistence_failed of string

type status =
  | Preparing
  | Waiting
  | Sending
  | Publishing
  | Cancelling
  | Uploaded
  | Cancelled
  | Failed_upload of failure

(** {1 Lifecycle and recovery}

    The reducer issues each ticket for an exact graph scope and import operation.
    The runner holds it until completion; {!ticket_current} rejects retired or
    superseded work. Tickets are process-local; the durable intent is the recovery
    identity. [Retry] resumes retained work, and [Shutdown] cancels pending work
    and stops the reducer without certifying physical cleanup or deleting intent. *)

type ticket = private
  { id : int
  ; scope : Scope.graph_scope
  ; operation : Logseq_db_types.Graph_types.Uuid.t
  }

type observation =
  | Absent
  | Local_present
  | Metadata_present
  | Publication_acknowledged
  | Entity_cancelled

type completion =
  | Persisted
  | Inspected of observation
  | Local_applied
  | Put_succeeded
  | Metadata_applied
  | Publication_acked
  | Failed of failure

type instruction =
  | Persist of ticket * Intent.t * int option
  | Inspect of ticket * Intent.t
  | Apply_local of ticket * Intent.t
  | Put of ticket * Intent.t
  | Apply_metadata of ticket * Intent.t
  | Await_publication of ticket * Intent.t
  | Release_staging of Intent.t
  | Cancel_operation of ticket

type event =
  | Start of Intent.t
  | Restore of Intent.t
  | Completed of ticket * completion
  | Cancel
  | Retry
  | Availability_changed of bool
  | Shutdown
(** {1 Observation and helpers} *)

val checkpoint : t -> Intent.t option
val failure : t -> failure option
val step : t -> event -> t * instruction list
val ticket_current : t -> ticket -> bool
val status : t -> status option
