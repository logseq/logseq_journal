val initialize_database : Sqlite3.db -> (unit, string) result
val read_database : Sqlite3.db -> (string list, string) result

(** Full replacement is retained for legacy fixtures/imports. Incremental ledgers
    reject it before changing rows, so older writers cannot discard metadata. *)
val replace_database : Sqlite3.db -> string list -> (unit, string) result

type row =
  { mutation_id : string
  ; sequence : int
  ; record : string
  }

type delta =
  { expected_revision : int
  ; revision : int
  ; upserts : row list
  ; deletes : string list
  }

(** [None] denotes the legacy position-ordered ledger. New ledgers own their
    revision independently of their rows, including when the queue is empty. *)
val read_revision : Sqlite3.db -> (int option, string) result

(** Atomically verifies [expected_records] and [revision] under a writer lock,
    then upgrades a validated legacy ledger. A stale validated snapshot fails
    without changing rows. Stable identities and sequences are retained;
    old readers fail closed on the new schema. *)
val migrate_database
  :  Sqlite3.db
  -> revision:int
  -> expected_records:string list
  -> row list
  -> (unit, string) result

(** Applies a frozen write set inside the caller's transaction. The revision
    comparison, changed rows and caller-owned receipts/checkpoint commit together. *)
val apply_delta : Sqlite3.db -> delta -> (unit, string) result
