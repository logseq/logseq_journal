module Graph = Logseq_db_types.Graph_types

let name = function
  | Types.Todo -> "todo"
  | Doing -> "doing"
  | In_review -> "in-review"
  | Now -> "now"
  | Done -> "done"
  | Canceled -> "canceled"
  | Backlog -> "backlog"
  | Waiting -> "waiting"
  | Later -> "later"
;;

let ident status = "logseq.property/status." ^ name status

let set_identity ~mutation_id ~block ~status =
  Printf.sprintf
    "set-status:%s:%s:%s"
    (Graph.Uuid.to_string mutation_id)
    (Graph.Uuid.to_string block)
    (name status)
;;

let clear_identity ~mutation_id ~block =
  Printf.sprintf
    "clear-status:%s:%s"
    (Graph.Uuid.to_string mutation_id)
    (Graph.Uuid.to_string block)
;;
