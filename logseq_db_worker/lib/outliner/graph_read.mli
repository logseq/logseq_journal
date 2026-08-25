val values : Datascript.db -> int -> string -> Datascript.value list
val one : Datascript.db -> int -> string -> Datascript.value option
val string_value : Datascript.db -> int -> string -> string option
val reference_value : Datascript.db -> int -> string -> int option
val has_true : Datascript.db -> int -> string -> bool
val entities_by_uuid : Datascript.db -> Graph_types.Uuid.t -> int list
val uuid_of_entity : Datascript.db -> int -> (Graph_types.Uuid.t, string) result
val is_page : Datascript.db -> int -> bool
val children : Datascript.db -> int -> int list
