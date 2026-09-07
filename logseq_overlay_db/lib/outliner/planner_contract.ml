module Graph = Logseq_db_types.Graph_types

let contains_uuid uuid values =
  List.exists (fun (candidate, _) -> Graph.Uuid.equal candidate uuid) values
;;

let contains_children_scope parent scopes =
  List.exists
    (fun (scope, _) ->
       match scope with
       | Types.Children_revision candidate -> Graph.Uuid.equal candidate parent)
    scopes
;;
