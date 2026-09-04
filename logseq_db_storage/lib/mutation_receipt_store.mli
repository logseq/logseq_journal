val initialize_database : Sqlite3.db -> (unit, string) result
val read_database : Sqlite3.db -> ((string * string) list, string) result

val validate_database
  :  Sqlite3.db
  -> is_valid:(string -> string -> bool)
  -> (unit, string) result

val read_mutation : Sqlite3.db -> string -> (string option, string) result
val upsert_mutations : Sqlite3.db -> (string * string) list -> (unit, string) result
val read_terminal_batch : Sqlite3.db -> string -> (string option, string) result

val upsert_terminal_batches
  :  Sqlite3.db
  -> (string * string) list
  -> (unit, string) result
