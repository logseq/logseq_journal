module Graph = Logseq_db_types.Graph_types

let mutation_id = function
  | Types.Set_asset_reference { mutation_id; _ }
  | Types.Publish_asset { mutation_id; _ }
  | Types.Save_block { mutation_id; _ }
  | Insert_blocks { mutation_id; _ }
  | Delete_blocks { mutation_id; _ }
  | Create_journal_page { mutation_id; _ }
  | Set_task_status { mutation_id; _ }
  | Clear_task_status { mutation_id; _ } -> mutation_id
;;

let operation = function
  | Types.Set_asset_reference _ -> Types.Set_asset_reference_operation
  | Types.Publish_asset _ -> Types.Publish_asset_operation
  | Types.Save_block _ -> Types.Save_block_operation
  | Insert_blocks _ -> Insert_blocks_operation
  | Delete_blocks _ -> Delete_blocks_operation
  | Create_journal_page _ -> Create_journal_page_operation
  | Set_task_status _ -> Set_task_status_operation
  | Clear_task_status _ -> Clear_task_status_operation
;;

let identity = function
  | Types.Set_asset_reference { mutation_id; block; previous; asset } ->
    Printf.sprintf
      "asset-reference:%s:%s:%s:%s"
      (Graph.Uuid.to_string mutation_id)
      (Graph.Uuid.to_string block)
      (Option.fold ~none:"none" ~some:Graph.Uuid.to_string previous)
      (Graph.Uuid.to_string asset)
  | Types.Publish_asset { mutation_id; block; version } ->
    Printf.sprintf
      "asset-publish:%s:%s:%s:%s"
      (Graph.Uuid.to_string mutation_id)
      (Graph.Uuid.to_string block)
      version.checksum
      version.file_type
  | Types.Save_block { mutation_id; block; title } ->
    Outliner.Save_block.identity ~mutation_id ~block ~title
  | Insert_blocks { mutation_id; tree; parent; asset } ->
    let base = Outliner.Insert_blocks.identity ~mutation_id ~parent ~tree in
    (match asset with
     | None -> base
     | Some asset ->
       Printf.sprintf
         "%s:asset:%s:%s:%Ld:%s"
         base
         asset.version.checksum
         asset.version.file_type
         asset.size
         (Option.fold ~none:"append" ~some:Graph.Uuid.to_string asset.replace_reference))
  | Delete_blocks { mutation_id; root } ->
    Outliner.Delete_blocks.identity ~mutation_id ~root
  | Create_journal_page { mutation_id; page; title; journal_day } ->
    Outliner.Create_journal_page.identity ~mutation_id ~page ~title ~journal_day
  | Set_task_status { mutation_id; block; status } ->
    Outliner.Task_status.set_identity ~mutation_id ~block ~status
  | Clear_task_status { mutation_id; block } ->
    Outliner.Task_status.clear_identity ~mutation_id ~block
;;

let fingerprint mutation =
  Digestif.SHA256.digest_string (identity mutation) |> Digestif.SHA256.to_hex
;;

let validate = function
  | Types.Insert_blocks { tree; asset; _ } ->
    (match asset with
     | Some asset when tree.children <> [] || asset.size < 0L || asset.size > 104857600L
       -> Error "Asset insertion requires one block and a bounded size"
     | None | Some _ -> Outliner.Validation.validate_tree tree)
  | Set_asset_reference _
  | Publish_asset _
  | Save_block _
  | Delete_blocks _
  | Create_journal_page _
  | Set_task_status _
  | Clear_task_status _ -> Ok ()
;;
