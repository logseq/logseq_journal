type reason =
  | Storage_failure
  | Lifecycle_outcome_unknown

type tombstone

(** Install an irreversible process-lifetime tombstone for a canonical
    database path. Repeated calls preserve the first observed reason. *)
val quarantine : canonical_path:string -> reason -> unit

(** Find a tombstone installed by any previous service or runtime instance in
    this OS process. *)
val find_tombstone : canonical_path:string -> tombstone option

val reason : tombstone -> reason

type mutation_kind =
  | Capture
  | Create_child
  | Update_content
  | Set_task_state

type pending_command =
  { mutation_id : string
  ; affected_block_ids : string list
  ; kind : mutation_kind
  ; expected_revision : int option
  ; content : string
  }

type pending_status =
  | Accepted
  | Outcome_unknown

type pending =
  { runtime_epoch : Bonsai_flutter_spec.Id.Runtime.epoch
  ; worker_generation : Bonsai_flutter_spec.Id.Worker.generation
  ; request_id : Bonsai_flutter_spec.Id.Worker.request_id
  ; command : pending_command
  ; status : pending_status
  }

module Pending_error : sig
  type t

  val to_string : t -> string
  val is_full : t -> bool
  val is_block_busy : t -> bool
  val is_invalid : t -> bool
end

(** Check application-level mutation admission before calling [Worker.send].
    This check does not reserve capacity; domain 0 serializes check/send/record. *)
val check_admission : pending_command -> (unit, Pending_error.t) result

(** Record a command only after [Worker.send] returns [Accepted]. The registry
    enforces eight global entries, one entry touching any given block, valid
    UTF-8, and the 65,536-byte content bound. *)
val record_accepted
  :  runtime_epoch:Bonsai_flutter_spec.Id.Runtime.epoch
  -> worker_generation:Bonsai_flutter_spec.Id.Worker.generation
  -> request_id:Bonsai_flutter_spec.Id.Worker.request_id
  -> pending_command
  -> (unit, Pending_error.t) result

val find_pending : mutation_id:string -> pending option

val find_pending_by_request_id
  :  Bonsai_flutter_spec.Id.Worker.request_id
  -> pending option

(** Stable mutation-ID order for same-process startup reconciliation. *)
val pending_commands : unit -> pending list

(** Replace the obsolete Worker identity after a reconciliation request is
    accepted by a healthy replacement runtime. *)
val record_reconciliation_accepted
  :  runtime_epoch:Bonsai_flutter_spec.Id.Runtime.epoch
  -> worker_generation:Bonsai_flutter_spec.Id.Worker.generation
  -> request_id:Bonsai_flutter_spec.Id.Worker.request_id
  -> mutation_id:string
  -> (unit, Pending_error.t) result

(** Retain the command for same-process reconciliation after an outer unknown
    Worker outcome. *)
val mark_outcome_unknown : mutation_id:string -> unit

(** Remove a command only after a typed known outcome. *)
val clear_known_outcome : mutation_id:string -> unit
