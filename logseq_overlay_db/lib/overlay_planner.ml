module Graph = Logseq_db_types.Graph_types

let mutation_id = function
  | Types.Set_asset_reference { mutation_id; _ }
  | Types.Publish_asset { mutation_id; _ }
  | Types.Save_block { mutation_id; _ }
  | Append_journal { mutation_id; _ }
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
  | Append_journal _ -> Append_journal_operation
  | Insert_blocks _ -> Insert_blocks_operation
  | Delete_blocks _ -> Delete_blocks_operation
  | Create_journal_page _ -> Create_journal_page_operation
  | Set_task_status _ -> Set_task_status_operation
  | Clear_task_status _ -> Clear_task_status_operation
;;

let append_nodes (root:Types.append_node) =
  let rec loop pending index =
    if index=Rrbvec.length pending then pending
    else loop(Rrbvec.append pending (Rrbvec.nth pending index).Types.children)(index+1) in
  loop(Rrbvec.singleton root)0
;;

let rec append_parent ~parent ~target (root:Types.append_node) =
  if root.uuid=target then Some(root,parent)
  else Rrbvec.find_map(append_parent ~parent:root.uuid ~target)root.children
;;

let append_children root parent =
  match append_parent ~parent:root.Types.uuid ~target:parent root with
  | Some(node,_)->node.children
  | None->Rrbvec.empty
;;

let append_identity root =
  let buffer=Buffer.create 128 in
  let rec emit (node:Types.append_node) =
    Buffer.add_string buffer(Printf.sprintf "%s:%S:%s:[" (Graph.Uuid.to_string node.uuid)node.title
      (Option.fold ~none:"none" ~some:Graph.Uuid.to_string node.task_status));
    Rrbvec.iteri(fun index child->if index>0 then Buffer.add_char buffer ';';emit child)node.children;
    Buffer.add_char buffer ']' in
  emit root;Buffer.contents buffer
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
  | Append_journal {mutation_id;page;title;journal_day;root} ->
    Printf.sprintf "append:%s:%s:%d:%S:%s" (Graph.Uuid.to_string mutation_id)
      (Graph.Uuid.to_string page) journal_day title (append_identity root)
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

let valid_day day =
  let year=day/10000 and month=day/100 mod 100 and date=day mod 100 in
  let leap=year mod 400=0 || (year mod 4=0 && year mod 100<>0) in
  let maximum=match month with 2->if leap then 29 else 28|4|6|9|11->30|_->31 in
  year>=1 && year<=9999 && month>=1 && month<=12 && date>=1 && date<=maximum
;;

module Append_ids=Set.Make(String)
let validate_append_tree ~page root =
  let rec loop pending index seen =
    if index=Rrbvec.length pending then Ok ()
    else if index>=2000 then Error "Append supports at most 2000 nodes"
    else
      let node,depth=Rrbvec.nth pending index in
      let id=Graph.Uuid.to_string node.Types.uuid in
      if depth>64 || Rrbvec.length node.children>1999 || node.uuid=page || Append_ids.mem id seen
        || String.length node.title>Logseq_db_types.Limits.maximum_request_bytes
      then Error "Append requires a bounded unique tree"
      else loop (Rrbvec.append pending (Rrbvec.map(fun child->child,depth+1)node.children))
        (index+1)(Append_ids.add id seen)
  in
  loop(Rrbvec.singleton(root,0))0 Append_ids.empty
;;

let validate = function
  | Types.Set_task_status { status = Legacy_status_ident ident; _ } ->
    if
      List.exists
        (fun (_, name) -> ident = "logseq.property/status." ^ name)
        Persistence_json.legacy_status_names
    then Ok ()
    else Error "invalid legacy status identity"
  | Types.Append_journal {root;page;journal_day;_} ->
    if not(valid_day journal_day) then Error "Append requires a valid Gregorian journal day"
    else validate_append_tree ~page root
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
