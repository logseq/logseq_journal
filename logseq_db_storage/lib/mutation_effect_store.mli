(** Durable write-ahead intent bytes and immutable local commit evidence.
    Namespace keys are lowercase SHA-256 values for the logical origin/account/
    graph. Payload/evidence codecs and authorization belong to the database owner.
    These opaque stored bytes do not grant execution or presentation authority. *)
module Uuid = Logseq_db_types.Graph_types.Uuid

type error =
  | Invalid_input of string
  | Identity_conflict
  | Storage_failure of string

type record = private
  { sequence : int64
  ; namespace : string
  ; mutation_id : Uuid.t
  ; payload : string
  ; evidence : string option
  ; acknowledged : bool
  }

type page = private
  { items : record list
  ; next : int64 option
  }

val initialize_database : Sqlite3.db -> (unit, error) result

(** Idempotent insert. The complete bytes must match an existing identity. *)
val prepare
  :  Sqlite3.db
  -> namespace:string
  -> mutation_id:Uuid.t
  -> payload:string
  -> (record, error) result

val read
  :  Sqlite3.db
  -> namespace:string
  -> mutation_id:Uuid.t
  -> (record option, error) result

(** Joins the caller's existing SQLite transaction; it does not COMMIT. The
    database owner must atomically commit this evidence with its logical outbox
    change. Existing evidence is immutable, including after acknowledgement. *)
val commit
  :  Sqlite3.db
  -> namespace:string
  -> mutation_id:Uuid.t
  -> payload:string
  -> evidence:string
  -> (record, error) result

(** Acknowledgement removes an item from recovery enumeration, retaining its
    exact evidence for same-intent idempotency. It requires matching evidence. *)
val acknowledge
  :  Sqlite3.db
  -> namespace:string
  -> mutation_id:Uuid.t
  -> evidence:string
  -> (unit, error) result

(** At most 256 items and 4 MiB of payload/evidence bytes per page, with an
    explicit continuation when either bound leaves more rows. Rows are stepped
    individually; excess blobs are not materialized into the OCaml page. No total
    count is inferred from a page. Namespace and sequence predicates are indexed. *)
val pending
  :  Sqlite3.db
  -> namespace:string
  -> after:int64 option
  -> limit:int
  -> (page, error) result
