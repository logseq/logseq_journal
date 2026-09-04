module Graph = Logseq_db_types.Graph_types
module Types = Logseq_overlay_db.Types

type block =
  { uuid : Graph.block_uuid
  ; title : string
  ; parent : Graph.Uuid.t
  ; task_status : Types.task_status option
  ; deleted : bool
  }

type page =
  { uuid : Graph.page_uuid
  ; title : string
  ; journal_day : int option
  ; deleted : bool
  }

type t =
  { blocks : block list
  ; pages : page list
  }

let empty = { blocks = []; pages = [] }

let replace_block (block : block) (blocks : block list) =
  block
  :: List.filter
       (fun (candidate : block) -> not (Graph.Uuid.equal candidate.uuid block.uuid))
       blocks
;;

let replace_page (page : page) (pages : page list) =
  page
  :: List.filter
       (fun (candidate : page) -> not (Graph.Uuid.equal candidate.uuid page.uuid))
       pages
;;

let rec insert_tree parent blocks (tree : Types.block_tree) =
  let block =
    { uuid = tree.uuid; title = tree.title; parent; task_status = None; deleted = false }
  in
  List.fold_left (insert_tree tree.uuid) (replace_block block blocks) tree.children
;;

let apply_local model = function
  | Types.Save_block { block; title; _ } ->
    { model with
      blocks =
        List.map
          (fun (candidate : block) ->
             if Graph.Uuid.equal candidate.uuid block
             then { candidate with title }
             else candidate)
          model.blocks
    }
  | Insert_blocks { tree; parent; _ } ->
    { model with blocks = insert_tree parent model.blocks tree }
  | Delete_blocks { root; _ } ->
    let rec descendant_of_root (block : block) =
      Graph.Uuid.equal block.uuid root
      || List.exists
           (fun (parent : block) ->
              Graph.Uuid.equal block.parent parent.uuid && descendant_of_root parent)
           model.blocks
    in
    { model with
      blocks =
        List.map
          (fun (block : block) ->
             if descendant_of_root block then { block with deleted = true } else block)
          model.blocks
    }
  | Create_journal_page { page; title; journal_day; _ } ->
    { model with
      pages =
        replace_page
          { uuid = page; title; journal_day = Some journal_day; deleted = false }
          model.pages
    }
  | Set_task_status { block; status; _ } ->
    { model with
      blocks =
        List.map
          (fun (candidate : block) ->
             if Graph.Uuid.equal candidate.uuid block
             then { candidate with task_status = Some status }
             else candidate)
          model.blocks
    }
  | Clear_task_status { block; _ } ->
    { model with
      blocks =
        List.map
          (fun (candidate : block) ->
             if Graph.Uuid.equal candidate.uuid block
             then { candidate with task_status = None }
             else candidate)
          model.blocks
    }
;;

let visible_blocks model =
  List.filter (fun (block : block) -> not block.deleted) model.blocks
;;

let visible_pages model = List.filter (fun (page : page) -> not page.deleted) model.pages
