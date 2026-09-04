module Graph = Logseq_db_types.Graph_types

val bounded_members
  :  maximum:int
  -> (string * Graph.Uuid.t) Seq.t
  -> (string * Graph.Uuid.t) list * int
