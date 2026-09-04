module Graph = Logseq_db_types.Graph_types

val identity
  :  mutation_id:Graph.Uuid.t
  -> parent:Graph.Uuid.t
  -> tree:Types.block_tree
  -> string
