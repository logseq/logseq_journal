module Graph = Logseq_db_types.Graph_types

let footprint_members (footprint : Overlay_effect.footprint) =
  footprint.block_uuids, footprint.page_uuids, footprint.structure_interests
;;

let bounded_summary
      ~maximum_items
      ~maximum_bytes
      ~block_uuids
      ~page_uuids
      ~structure_interests
  =
  let item_count =
    List.length block_uuids + List.length page_uuids + List.length structure_interests
  in
  let byte_count =
    List.fold_left
      (fun bytes uuid -> bytes + String.length (Graph.Uuid.to_string uuid))
      0
      (block_uuids @ page_uuids)
    + List.fold_left
        (fun bytes interest ->
           bytes
           +
           match interest with
           | Types.Children_interest uuid | Page_tree_interest uuid ->
             String.length (Graph.Uuid.to_string uuid) + 16
           | Journal_index_interest -> 16)
        0
        structure_interests
  in
  if item_count > maximum_items || byte_count > maximum_bytes
  then Types.Logical_resync_required Change_limit_exceeded
  else Exact_logical_change { block_uuids; page_uuids; structure_interests }
;;
