module Graph = Logseq_db_types.Graph_types

val identity
  :  mutation_id:Graph.Uuid.t
  -> block:Graph.block_uuid
  -> title:string
  -> string
