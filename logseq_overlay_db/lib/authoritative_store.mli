module Graph = Logseq_db_types.Graph_types

val values : Datascript.db -> int -> string -> Datascript.value list
val one : Datascript.db -> int -> string -> Datascript.value option
val entity_datoms : Datascript.db -> int -> Datascript.datom list
val values_in_datoms : Datascript.datom list -> string -> Datascript.value list
val one_in_datoms : Datascript.datom list -> string -> Datascript.value option
val uuid_of_value : Datascript.value -> Graph.Uuid.t option
val string_of_value : Datascript.value -> string option
val int_of_value : Datascript.value -> int option
val bool_of_value : Datascript.value -> bool option
val ident_of_value : Datascript.value -> string option
val reference_of_value : Datascript.value -> int option
val entity_of_uuid : Datascript.db -> Graph.Uuid.t -> int option
val entity_of_ident : Datascript.db -> string -> int option
val uuid_of_entity : Datascript.db -> int -> Graph.Uuid.t option
val entity_has_ref : Datascript.db -> int -> string -> int -> bool
val referenced_entities_in_datoms : Datascript.datom list -> string -> int list
