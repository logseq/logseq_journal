type t

type disposition =
  | Initialized
  | Restored

type state =
  | Ready
  | Terminal
  | Closed

module Error : sig
  type t

  val to_string : t -> string
  val is_path_quarantined : t -> bool
end

(** Open one generic DataScript SQLite session at an already resolved
    canonical app-private path. A new store receives an explicit first full
    snapshot; an existing store is restored and admitted before use. *)
val open_store : canonical_path:string -> (t * disposition, Error.t) result

val canonical_path : t -> string
val state : t -> state

(** The current database is Worker-confined. Repository code may consume it,
    but callers must never send it across the Worker boundary. *)
val current_db : t -> Datascript.db

(** Persist one transaction and install [db_after] only after the storage call
    returns successfully. Any surfaced backend exception quarantines the path
    and enters [Terminal]. *)
val transact : t -> Datascript.tx_op list -> (Datascript.tx_report, Error.t) result

(** Operational storage diagnostic used to prove tail behavior without
    exposing callbacks or raw journal content. *)
val tail_datom_count : t -> (int, Error.t) result

(** Mark a durability or lifecycle outcome as unknown before cleanup. *)
val quarantine : t -> Journal_process_recovery.reason -> unit

(** Close the generic session. A surfaced close exception tombstones the path.
    After a clean close, publish an atomic basis-keyed backup and retain the
    latest three. Backup failure is reported but does not quarantine the
    already-closed canonical store. The pinned backend does not expose a
    checked native-close result. *)
val close : t -> (unit, Error.t) result
