type write =
  { address : string
  ; payload : string
  ; addresses : string list
  }

type batch = { writes : write list }

type garbage_stats =
  { total_address_count : int
  ; reachable_address_count : int
  ; unreachable_address_count : int
  ; database_size_bytes : int64
  }

type error =
  | Pragma_mismatch of string
  | Corrupt_storage of string
  | Begin_failed of string
  | Write_failed of
      { address : string
      ; message : string
      }
  | Commit_failed of string
  | Checkpoint_failed of string
  | Close_failed of string

type callbacks =
  { storage : Datascript.storage
  ; initial_root_metadata : Logseq_sqlite_codec.root_index_metadata option
  ; begin_staging : unit -> (unit, string) result
  ; finish_staging :
      Logseq_sqlite_codec.root_index_metadata option
      -> (string * Datascript.storage_payload) list
      -> (batch, string) result
  ; abort_staging : unit -> unit
  ; begin_immediate : unit -> (unit, string) result
  ; upsert : write -> (unit, string) result
  ; commit : unit -> (unit, string) result
  ; rollback : unit -> unit
  ; unreachable_address_count : unit -> int
  ; database_size_bytes : unit -> int64
  ; checkpoint : unit -> (unit, string) result
  ; close : unit -> (unit, string) result
  }

type connection

type startup_metadata =
  { schema : Datascript.schema
  ; basis : int64
  }

val open_database : string -> (connection, error) result
val datascript_storage : connection -> Datascript.storage
val connection_callbacks : connection -> callbacks
val startup_metadata : connection -> (startup_metadata, error) result
val verify_connection_pragmas : connection -> (unit, error) result
val validate_storage_header : connection -> (unit, error) result
val restore_database : connection -> (Datascript.db, error) result
val verify_writable_pragmas : Sqlite3.db -> (unit, error) result
val commit_batch : callbacks -> batch -> (unit, error) result
val garbage_stats : callbacks -> (garbage_stats, error) result
val collect_garbage : callbacks -> (unit, error) result
val checkpoint : callbacks -> (unit, error) result
val close : callbacks -> (unit, error) result
