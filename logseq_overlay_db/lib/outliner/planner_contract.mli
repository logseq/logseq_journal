module Graph = Logseq_db_types.Graph_types

val contains_uuid : Graph.Uuid.t -> (Graph.Uuid.t * 'revision) list -> bool

val contains_children_scope
  :  Graph.Uuid.t
  -> (Types.structure_revision_scope * Types.scope_revision) list
  -> bool
