module Graph = Logseq_db_types.Graph_types

let identity ~mutation_id ~page ~title ~journal_day =
  Printf.sprintf
    "journal:%s:%s:%S:%d"
    (Graph.Uuid.to_string mutation_id)
    (Graph.Uuid.to_string page)
    title
    journal_day
;;
