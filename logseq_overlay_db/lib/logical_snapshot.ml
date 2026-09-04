module Graph = Logseq_db_types.Graph_types

type t =
  { mutable block_rows : (Graph.block_uuid * Types.block_record) list
  ; mutable page_rows : (Graph.page_uuid * Types.page_record) list
  }

let find uuid values =
  List.find_opt (fun (candidate, _) -> Graph.Uuid.equal uuid candidate) values
  |> Option.map snd
;;

let replace uuid value values =
  (uuid, value)
  :: List.filter (fun (candidate, _) -> not (Graph.Uuid.equal uuid candidate)) values
;;

let remove uuid values =
  List.filter (fun (candidate, _) -> not (Graph.Uuid.equal uuid candidate)) values
;;

let rec descendants rows root =
  let children =
    List.filter_map
      (fun (uuid, (record : Types.block_record)) ->
         if Graph.Uuid.equal record.block.parent root then Some uuid else None)
      rows
  in
  root :: List.concat_map (descendants rows) children
;;

let page_title view page =
  find page view.page_rows
  |> Option.map (fun (record : Types.page_record) -> record.page.title)
  |> Option.value ~default:""
;;

let rec add_tree view ~parent ~page ~order ~now (tree : Types.block_tree) =
  let record =
    Types.
      { block =
          Graph.
            { uuid = tree.uuid
            ; title = tree.title
            ; parent
            ; page
            ; order
            ; created_at_ms = now
            ; updated_at_ms = now
            ; refs = []
            ; tags = []
            ; properties = []
            }
      ; task_status = None
      ; rendered_page_title = page_title view page
      }
  in
  view.block_rows <- replace tree.uuid record view.block_rows;
  List.iteri
    (fun index child ->
       add_tree
         view
         ~parent:tree.uuid
         ~page
         ~order:(Outliner_order.child ~index)
         ~now
         child)
    tree.children
;;

let apply view ~ordinal ~now = function
  | Types.Save_block { block; title; _ } ->
    (match find block view.block_rows with
     | None -> false
     | Some record ->
       let updated =
         Types.
           { record with block = Graph.{ record.block with title; updated_at_ms = now } }
       in
       view.block_rows <- replace block updated view.block_rows;
       true)
  | Insert_blocks { tree; parent; _ } ->
    let page =
      match find parent view.block_rows with
      | Some record -> record.Types.block.page
      | None -> parent
    in
    add_tree view ~parent ~page ~order:(Outliner_order.root ~sequence:ordinal) ~now tree;
    true
  | Delete_blocks { root; _ } ->
    (match find root view.block_rows with
     | None -> false
     | Some _ ->
       List.iter
         (fun uuid -> view.block_rows <- remove uuid view.block_rows)
         (descendants view.block_rows root);
       true)
  | Create_journal_page { page; title; journal_day; _ } ->
    let record =
      Types.
        { page =
            Graph.
              { uuid = page
              ; name = String.lowercase_ascii title
              ; title
              ; kind = Journal_page { journal_day }
              ; created_at_ms = now
              ; updated_at_ms = now
              ; tags = []
              ; properties = []
              ; recycled = false
              }
        }
    in
    view.page_rows <- replace page record view.page_rows;
    true
  | Set_task_status { block; status; _ } ->
    (match find block view.block_rows with
     | None -> false
     | Some record ->
       view.block_rows
       <- replace block Types.{ record with task_status = Some status } view.block_rows;
       true)
  | Clear_task_status { block; _ } ->
    (match find block view.block_rows with
     | None -> false
     | Some record ->
       view.block_rows
       <- replace block Types.{ record with task_status = None } view.block_rows;
       true)
;;
