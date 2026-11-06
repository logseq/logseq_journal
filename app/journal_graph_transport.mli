type send_result =
  | Accepted
  | Full
  | Not_ready
  | Stopping

type delivery =
  { responses : Journal_graph_runtime.response list
  ; error : string option
  }

val deliver
  :  runtime:Journal_graph_runtime.t
  -> send:(Logseq_db_types.Graph_types.Uuid.t -> send_result)
  -> Journal_graph_runtime.output
  -> delivery
