module Graph = Logseq_db_types.Graph_types

val block_uuid : int -> Graph.block_uuid
val mutation_uuid : int -> Graph.Uuid.t

val seed_mirror
  :  application_support_directory:string
  -> block_count:int
  -> Graph.Uuid.t * string

val seed_outbox : database_path:string -> block_count:int -> count:int -> unit
val outbox_bytes : database_path:string -> int
val fixture_checksum : block_count:int -> string
