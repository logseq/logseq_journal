module Graph = Logseq_db_types.Graph_types

let identity ~mutation_id ~parent ~tree =
  Printf.sprintf
    "insert:%s:%s:%s"
    (Graph.Uuid.to_string mutation_id)
    (Graph.Uuid.to_string parent)
    (Tree.identity tree)
;;
