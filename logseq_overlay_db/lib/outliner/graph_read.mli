module Graph = Logseq_db_types.Graph_types

val page_for_parent : parent:Graph.Uuid.t -> Types.block_record option -> Graph.page_uuid
