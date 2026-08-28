val initialize_database : Sqlite3.db -> (unit, string) result
val read_database : Sqlite3.db -> (string list, string) result
val replace_database : Sqlite3.db -> string list -> (unit, string) result
