module Graph = Logseq_db_types.Graph_types

val name : Types.task_status -> string
val ident : Types.task_status -> string

val set_identity
  :  mutation_id:Graph.Uuid.t
  -> block:Graph.block_uuid
  -> status:Types.task_status
  -> string

val clear_identity : mutation_id:Graph.Uuid.t -> block:Graph.block_uuid -> string
