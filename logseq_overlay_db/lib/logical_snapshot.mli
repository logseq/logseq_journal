module Graph = Logseq_db_types.Graph_types

type t =
  { mutable block_rows : (Graph.block_uuid * Types.block_record) list
  ; mutable page_rows : (Graph.page_uuid * Types.page_record) list
  }

val find : Graph.Uuid.t -> (Graph.Uuid.t * 'a) list -> 'a option
val replace : Graph.Uuid.t -> 'a -> (Graph.Uuid.t * 'a) list -> (Graph.Uuid.t * 'a) list
val remove : Graph.Uuid.t -> (Graph.Uuid.t * 'a) list -> (Graph.Uuid.t * 'a) list

val descendants
  :  (Graph.block_uuid * Types.block_record) list
  -> Graph.block_uuid
  -> Graph.block_uuid list

val apply : t -> ordinal:int -> now:int64 -> Types.local_mutation -> bool
