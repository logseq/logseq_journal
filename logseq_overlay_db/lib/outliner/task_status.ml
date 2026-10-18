module Graph = Logseq_db_types.Graph_types

let name = function
  | Types.Status_uuid uuid -> Graph.Uuid.to_string uuid
  | Legacy_status_ident ident ->
    let prefix = "logseq.property/status." in
    String.sub ident (String.length prefix) (String.length ident - String.length prefix)
;;

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
