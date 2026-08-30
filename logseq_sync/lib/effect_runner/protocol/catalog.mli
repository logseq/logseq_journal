type schema = Logseq_db_types.Managed_graph.schema =
  { major : int
  ; minor : int
  ; exact : bool
  }

type graph = Logseq_db_types.Managed_graph.t =
  { graph_id : Graph_types.Uuid.t
  ; name : string
  ; schema : schema
  ; encrypted : bool
  }

val decode : string -> (graph list, string) result
