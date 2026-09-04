module Graph = Logseq_db_types.Graph_types

let rec identity (tree : Types.block_tree) =
  Printf.sprintf
    "%s:%S:[%s]"
    (Graph.Uuid.to_string tree.uuid)
    tree.title
    (String.concat ";" (List.map identity tree.children))
;;

let rec uuids (tree : Types.block_tree) = tree.uuid :: List.concat_map uuids tree.children

let has_unique_uuids tree =
  let uuids = uuids tree in
  List.length uuids = List.length (List.sort_uniq Graph.Uuid.compare uuids)
;;
