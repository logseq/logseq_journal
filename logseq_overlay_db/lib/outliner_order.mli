module Graph = Logseq_db_types.Graph_types

val root : sequence:int -> string
val child : index:int -> string
val compare_member : string * Graph.Uuid.t -> string * Graph.Uuid.t -> int
