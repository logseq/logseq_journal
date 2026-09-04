module Graph = Logseq_db_types.Graph_types

let identity ~mutation_id ~root =
  Printf.sprintf
    "delete:%s:%s"
    (Graph.Uuid.to_string mutation_id)
    (Graph.Uuid.to_string root)
;;
