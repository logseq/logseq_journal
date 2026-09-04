let event ~generation ~before_revision ~after_revision = function
  | Types.No_logical_change -> None
  | Exact_logical_change { block_uuids; page_uuids; structure_interests } ->
    Some
      (Types.Exact
         { generation
         ; before_revision
         ; after_revision
         ; block_uuids
         ; page_uuids
         ; structure_interests
         })
  | Logical_resync_required reason ->
    Some (Types.Projection_resync_required { generation; after_revision; reason })
;;
