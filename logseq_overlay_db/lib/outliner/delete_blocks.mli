module Graph = Logseq_db_types.Graph_types

val identity : mutation_id:Graph.Uuid.t -> root:Graph.block_uuid -> string
