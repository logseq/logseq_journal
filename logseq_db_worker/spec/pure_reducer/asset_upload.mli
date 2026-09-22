(** One durable explicit import, owned by the worker and independent of download demand. *)
module Intent = Logseq_db_types.Asset_upload_intent

module Scope = Logseq_sync_pure_reducer.Core

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

type t

(** [available] admits PUT work only when foreground networking and the graph key
    are available. Local durability and cancellation remain active while paused. *)
val create : scope:Scope.graph_scope -> available:bool -> t

val checkpoint : t -> Intent.t option
val failure : t -> failure option
val step : t -> event -> t * instruction list
val ticket_current : t -> ticket -> bool
val status : t -> status option
