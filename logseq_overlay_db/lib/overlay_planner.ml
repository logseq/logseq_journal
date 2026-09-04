module Graph = Logseq_db_types.Graph_types

let mutation_id = function
  | Types.Save_block { mutation_id; _ }
  | Insert_blocks { mutation_id; _ }
  | Delete_blocks { mutation_id; _ }
  | Create_journal_page { mutation_id; _ }
  | Set_task_status { mutation_id; _ }
  | Clear_task_status { mutation_id; _ } -> mutation_id
;;

let operation = function
  | Types.Save_block _ -> Types.Save_block_operation
  | Insert_blocks _ -> Insert_blocks_operation
  | Delete_blocks _ -> Delete_blocks_operation
  | Create_journal_page _ -> Create_journal_page_operation
  | Set_task_status _ -> Set_task_status_operation
  | Clear_task_status _ -> Clear_task_status_operation
;;

let identity = function
  | Types.Save_block { mutation_id; block; title } ->
    Outliner.Save_block.identity ~mutation_id ~block ~title
  | Insert_blocks { mutation_id; tree; parent } ->
    Outliner.Insert_blocks.identity ~mutation_id ~parent ~tree
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
  | Types.Insert_blocks { tree; _ } -> Outliner.Validation.validate_tree tree
  | Save_block _
  | Delete_blocks _
  | Create_journal_page _
  | Set_task_status _
  | Clear_task_status _ -> Ok ()
;;
