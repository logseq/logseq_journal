module Graph = Logseq_db_types.Graph_types

type error =
  | Invalid
  | Invalid_or_stale

val maximum_offset : int
val create : projection:int -> offset:int -> Graph.Cursor.t
val offset : projection:int -> Graph.Cursor.t -> (int, error) result
