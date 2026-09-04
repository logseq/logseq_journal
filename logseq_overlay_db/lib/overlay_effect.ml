module Graph = Logseq_db_types.Graph_types

type footprint =
  { block_uuids : Graph.block_uuid list
  ; page_uuids : Graph.page_uuid list
  ; structure_interests : Types.structure_interest list
  }

type delete_block_patch =
  { block_uuid : Graph.block_uuid
  ; title : string
  ; refs : Graph.block_uuid list
  ; updated_at_ms : int64
  }

type delete_page_patch =
  { page_uuid : Graph.page_uuid
  ; updated_at_ms : int64
  }

type delete_property_patch =
  { holder_uuid : Graph.block_uuid
  ; property_ident : string
  ; replacement_uuid : Graph.Uuid.t
  ; updated_at_ms : int64
  }

type delete_property_guard =
  { property_uuid : Graph.property_uuid
  ; property_ident : string
  ; replacement_uuid : Graph.Uuid.t
  }

type delete_artifacts =
  { frontier : Graph.block_uuid list
  ; block_patches : delete_block_patch list
  ; page_patches : delete_page_patch list
  ; property_guard : delete_property_guard option
  ; property_patches : delete_property_patch list
  }

type dependency_block_shadow =
  { shadow_block_uuid : Graph.block_uuid
  ; shadow_title : string
  ; shadow_parent : Graph.Uuid.t
  ; shadow_page : Graph.page_uuid
  ; shadow_order : string
  ; shadow_created_at_ms : int64
  ; shadow_updated_at_ms : int64
  ; shadow_task_status : Types.task_status option
  }

type dependency_page_shadow =
  { shadow_page_uuid : Graph.page_uuid
  ; shadow_name : string
  ; shadow_page_title : string
  ; shadow_page_kind : Graph.page_kind
  ; shadow_page_created_at_ms : int64
  ; shadow_page_updated_at_ms : int64
  ; shadow_recycled : bool
  }

type dependency_shadows =
  { shadow_blocks : dependency_block_shadow list
  ; shadow_pages : dependency_page_shadow list
  }

let empty_dependency_shadows = { shadow_blocks = []; shadow_pages = [] }

let equal_footprint left right =
  List.equal Graph.Uuid.equal left.block_uuids right.block_uuids
  && List.equal Graph.Uuid.equal left.page_uuids right.page_uuids
  && List.equal ( = ) left.structure_interests right.structure_interests
;;

let equal_delete_artifacts left right =
  match left, right with
  | None, None -> true
  | Some left, Some right ->
    List.equal Graph.Uuid.equal left.frontier right.frontier
    && List.equal
         (fun left right ->
            Graph.Uuid.equal left.block_uuid right.block_uuid
            && String.equal left.title right.title
            && List.equal Graph.Uuid.equal left.refs right.refs
            && Int64.equal left.updated_at_ms right.updated_at_ms)
         left.block_patches
         right.block_patches
    && List.equal
         (fun left right ->
            Graph.Uuid.equal left.page_uuid right.page_uuid
            && Int64.equal left.updated_at_ms right.updated_at_ms)
         left.page_patches
         right.page_patches
    && (match left.property_guard, right.property_guard with
        | None, None -> true
        | Some left, Some right ->
          Graph.Uuid.equal left.property_uuid right.property_uuid
          && String.equal left.property_ident right.property_ident
          && Graph.Uuid.equal left.replacement_uuid right.replacement_uuid
        | None, Some _ | Some _, None -> false)
    && List.equal
         (fun left right ->
            Graph.Uuid.equal left.holder_uuid right.holder_uuid
            && String.equal left.property_ident right.property_ident
            && Graph.Uuid.equal left.replacement_uuid right.replacement_uuid
            && Int64.equal left.updated_at_ms right.updated_at_ms)
         left.property_patches
         right.property_patches
  | None, Some _ | Some _, None -> false
;;
