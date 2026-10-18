type favorite_target =
  | Page of string
  | Block of string

type favorite =
  { membership_id : string
  ; target : favorite_target
  ; title : string
  ; task_state : Journal_model.task_state
  }

module Graph = Logseq_db_types.Graph_types

type page =
  { id : string
  ; day : int
  ; title : string
  }

type block = Journal_model.t
type time_context = { localtime : float -> Unix.tm }

type capture_child =
  { mutation_id : string
  ; block_id : string
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; creation_time : Journal_time.t
  }

type capture =
  { mutation_id : string
  ; block_id : string
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; status_confirmation : bool
  ; creation_time : Journal_time.t
  ; children : capture_child list
  }

type create_child =
  { mutation_id : string
  ; calendar_generation : int64
  ; block_id : string
  ; parent_block_id : string
  ; expected_parent_revision : string
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; status_confirmation : bool
  ; creation_time : Journal_time.t
  }

type update_source =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : string
  ; source : string
  }

type set_task_state =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : string
  ; task_state : Journal_model.task_state
  }

type delete_subtree =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : string
  }

type block_cursor =
  { after_sibling_order : string
  ; after_block_id : string
  ; protocol_cursor : Graph.Cursor.t option
  }

type child_summary =
  { block_id : string
  ; source : string
  ; asset_file_type : string option
  }

type timeline_entry =
  { block : block
  ; child_summaries : child_summary list
  }

type day_feed =
  { page : page
  ; entries : timeline_entry list
  ; has_more_entries : bool
  ; continuation : block_cursor option
  }

type feed =
  { days : day_feed list
  ; slot_count : int
  ; has_more_days : bool
  }

type block_page =
  { blocks : block list
  ; continuation : block_cursor option
  }

type timeline_entry_page =
  { entries : timeline_entry list
  ; continuation : block_cursor option
  }

type detail =
  { root : block
  ; children : block_page
  }

type block_member =
  { block : Graph.block
  ; revision : string
  }

type tree_member =
  { block : Graph.block
  ; revision : string
  ; depth : int
  }

let page_of_summary (summary : Graph.page_summary) =
  match summary.kind, summary.recycled with
  | Graph.Journal_page { journal_day }, false ->
    Some
      { id = Graph.Uuid.to_string summary.uuid; day = journal_day; title = summary.title }
  | ( ( Ordinary_page
      | Class_page
      | Property_page
      | Hidden_page
      | Built_in_page
      | Journal_page _ )
    , true )
  | (Ordinary_page | Class_page | Property_page | Hidden_page | Built_in_page), false ->
    None
;;

let task_state (block : Graph.block) =
  match
    List.find_opt
      (fun (p : Graph.property_summary) -> p.ident = "logseq.property/status")
      block.properties
  with
  | None -> Ok Journal_model.No_status
  | Some { values = []; _ } -> Ok Journal_model.No_status
  | Some { values = [ Graph.Default_value value ]; _ } -> Ok (Journal_model.Status value)
  | Some { values = [ (Node_value uuid | Entity_value uuid) ]; _ } ->
    Ok (Journal_model.Status (Graph.Uuid.to_string uuid))
  | Some property ->
    Ok
      (Journal_model.Invalid_status
         (Journal_model.property_sources
            [ { property with
                ident = "invalid-status"
              ; schema = { property.schema with hidden = false }
              }
            ]
          |> List.map snd
          |> String.concat ", "))
;;

let creation_time (context : time_context) instant_unix_ms =
  Journal_time.of_instant_unix_ms_with ~localtime:context.localtime ~instant_unix_ms
;;

let asset_file_type (block : Graph.block) =
  List.find_map
    (fun (property : Graph.property_summary) ->
       if property.ident = "logseq.property.asset/type"
       then
         List.find_map
           (function
             | Graph.String_value value -> Some value
             | _ -> None)
           property.values
       else None)
    block.properties
;;

let attachment_reference (block : Graph.block) =
  List.exists
    (fun (property : Graph.property_summary) ->
       List.exists
         (function
           | Graph.Asset_value _ -> true
           | Node_value _ | Entity_value _ -> property.ident = "logseq.property/asset"
           | _ -> false)
         property.values)
    block.properties
;;

let block_in_context
      ~page_id
      ~journal_day
      ~revision
      ~child_count
      ~time_context
      (value : Graph.block)
  =
  match creation_time time_context value.created_at_ms, task_state value with
  | (Error _ as error), _ | _, (Error _ as error) -> error
  | Ok creation_time, Ok task_state ->
    let parent = Graph.Uuid.to_string value.parent in
    Journal_model.create_on_page
      ~id:(Graph.Uuid.to_string value.uuid)
      ~page_id:(Graph.Uuid.to_string value.page)
      ~journal_day
      ~parent_id:(if String.equal parent page_id then None else Some parent)
      ~sibling_order:value.order
      ~source:value.title
      ~task_state
      ~child_count
      ~creation_time
      ~revision
      ~last_mutation_id:"00000000-0000-0000-0000-000000000000"
    |> Result.map (fun block ->
      Journal_model.with_properties
        ~localtime:time_context.localtime
        block
        ~properties:value.properties
      |> fun block ->
      Journal_model.with_asset_file_type block ~asset_file_type:(asset_file_type value)
      |> fun block ->
      Journal_model.with_content_metadata
        block
        ~tags_present:(value.tags <> [])
        ~attachments_present:(attachment_reference value))
;;

let block ~page ~revision ~child_count ~time_context value =
  block_in_context
    ~page_id:page.id
    ~journal_day:(Some page.day)
    ~revision
    ~child_count
    ~time_context
    value
;;

let block_on_page ~(page : Graph.page) ~revision ~child_count ~time_context value =
  let journal_day =
    match page.kind with
    | Graph.Journal_page { journal_day } -> Some journal_day
    | _ -> None
  in
  block_in_context
    ~page_id:(Graph.Uuid.to_string page.uuid)
    ~journal_day
    ~revision
    ~child_count
    ~time_context
    value
;;

let property_value_block (block : Graph.block) =
  List.exists (fun (p : Graph.property_summary) ->
    p.ident = "logseq.property/created-from-property" && p.values <> []) block.properties
;;

(* Stop once three ordinary children are found; property values must not
   allocate an intermediate copy of the complete child page. *)
let preview_children children =
  let rec take remaining reversed = function
    | _ when remaining = 0 -> List.rev reversed
    | [] -> List.rev reversed
    | (child : tree_member) :: rest ->
      if property_value_block child.block then take remaining reversed rest
      else take (remaining - 1) (child :: reversed) rest
  in
  take 3 [] children
;;

let timeline_entry_page
      ?(tag_titles = fun _ -> [])
      ~page
      ~time_context
      (result : tree_member Graph.page_result)
  =
  let cursor (block : Graph.block) =
    Option.map
      (fun protocol_cursor ->
         { after_sibling_order = block.order
         ; after_block_id = Graph.Uuid.to_string block.uuid
         ; protocol_cursor = Some protocol_cursor
         })
      result.continuation
  in
  let roots =
    let children = Hashtbl.create 16 in
    List.iter
      (fun (item : tree_member) ->
         if item.depth = 1
         then (
           let parent = Graph.Uuid.to_string item.block.parent in
           let previous = Hashtbl.find_opt children parent |> Option.value ~default:[] in
           Hashtbl.replace children parent (item :: previous)))
      result.items;
    let direct_children (root : Graph.block) =
      Hashtbl.find_opt children (Graph.Uuid.to_string root.uuid)
      |> Option.value ~default:[]
      |> List.sort (fun (left : tree_member) right ->
        let order = String.compare left.block.order right.block.order in
        if order = 0 then Graph.Uuid.compare left.block.uuid right.block.uuid else order)
    in
    List.filter_map
      (fun (item : tree_member) ->
         let children = if item.depth = 0 then direct_children item.block else [] in
         if
           item.depth = 0
           && (not (property_value_block item.block))
           && (String.trim item.block.title <> ""
               || item.block.tags <> []
               || tag_titles item.block.uuid <> []
               || Option.fold
                    ~none:false
                    ~some:(fun t -> String.trim t <> "")
                    (asset_file_type item.block)
               || attachment_reference item.block)
         then Some (item, children)
         else None)
      result.items
  in
  let rec project reversed = function
    | [] ->
      Ok
        { entries = List.rev reversed
        ; continuation =
            Option.bind
              (List.fold_left
                 (fun last (item : tree_member) ->
                    if item.depth = 0 then Some item.block else last)
                 None
                 result.items)
              cursor
        }
    | ((root : tree_member), children) :: rest ->
      (match
         block
           ~page
           ~revision:root.revision
           ~child_count:(List.length children)
           ~time_context
           root.block
       with
       | Error _ as error -> error
       | Ok block ->
         let block =
           Journal_model.with_tag_titles block ~tag_titles:(tag_titles root.block.uuid)
         in
         let child_summaries =
           List.map
             (fun (child : tree_member) ->
                { block_id = Graph.Uuid.to_string child.block.uuid
                ; source = child.block.title
                ; asset_file_type = asset_file_type child.block
                })
             (* Preview only: raw tree members and child_count stay complete. *)
             (preview_children children)
         in
         project ({ block; child_summaries } :: reversed) rest)
  in
  project [] roots
;;

let project_detail
      ~project_block
      ~time_context
      ~(root : block_member)
      (children : block_member Graph.page_result)
  =
  let child_count =
    List.length children.items + if Option.is_some children.continuation then 1 else 0
  in
  match project_block ~revision:root.revision ~child_count ~time_context root.block with
  | Error _ as error -> error
  | Ok root ->
    let rec project reversed = function
      | [] ->
        Ok
          { root
          ; children =
              { blocks = List.rev reversed
              ; continuation =
                  (match reversed, children.continuation with
                   | block :: _, Some protocol_cursor ->
                     Some
                       { after_sibling_order = Journal_model.sibling_order block
                       ; after_block_id = Journal_model.id block
                       ; protocol_cursor = Some protocol_cursor
                       }
                   | [], _ | _, None -> None)
              }
          }
      | (child : block_member) :: rest ->
        (match
           project_block ~revision:child.revision ~child_count:0 ~time_context child.block
         with
         | Error _ as error -> error
         | Ok child -> project (child :: reversed) rest)
    in
    project [] children.items
;;

let detail ~page ~time_context ~root children =
  project_detail ~project_block:(block ~page) ~time_context ~root children
;;

let detail_on_page ~page ~time_context ~root children =
  project_detail ~project_block:(block_on_page ~page) ~time_context ~root children
;;

let favorite (item : Logseq_db_worker.Protocol.v2_favorite_item) =
  let module P = Logseq_db_worker.Protocol in
  let id = Logseq_db_types.Graph_types.Uuid.to_string in
  let target, title, task_state =
    match item.target with
    | P.V2_favorite_page { uuid; title; _ } ->
      Page (id uuid), title, Journal_model.No_status
    | V2_favorite_block { uuid; title; task_status; _ } ->
      let status =
        Option.fold
          ~none:Journal_model.No_status
          ~some:(fun uuid -> Journal_model.Status (id uuid))
          task_status
      in
      Block (id uuid), title, status
  in
  { membership_id = id item.membership_uuid; target; title; task_state }
;;
