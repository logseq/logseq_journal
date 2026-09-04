module Graph = Logseq_db_types.Graph_types

let identity ~mutation_id ~block ~title =
  Printf.sprintf
    "save:%s:%s:%S"
    (Graph.Uuid.to_string mutation_id)
    (Graph.Uuid.to_string block)
    title
;;
