module Graph = Logseq_db_types.Graph_types

val identity : Types.block_tree -> string
val uuids : Types.block_tree -> Graph.block_uuid list
val has_unique_uuids : Types.block_tree -> bool
