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
  let status =
    List.find_opt
      (fun (property : Graph.property_summary) ->
         String.equal property.ident "logseq.property/status")
      block.properties
  in
  let status_ident =
    Option.bind status (fun property ->
      List.find_map
        (function
          | Graph.Default_value value -> Some value
          | Number_value _
          | Date_value _
          | Datetime_value _
          | Checkbox_value _
          | Url_value _
          | Node_value _
          | Asset_value _
          | Keyword_value _
          | Map_value _
          | Collection_value _
          | Any_value _
          | Entity_value _
          | Class_value _
          | Page_value _
          | Property_value _
          | String_value _
          | Json_value _
          | Raw_number_value _ -> None)
        property.values)
  in
  match status_ident with
  | None -> Ok Journal_model.No_status
  | Some "logseq.property/status.todo" -> Ok Journal_model.Todo
  | Some "logseq.property/status.doing" -> Ok Journal_model.Doing
  | Some "logseq.property/status.in-review" -> Ok Journal_model.In_review
  | Some "logseq.property/status.now" -> Ok Journal_model.Now
  | Some "logseq.property/status.done" -> Ok Journal_model.Done
  | Some "logseq.property/status.canceled" -> Ok Journal_model.Canceled
  | Some "logseq.property/status.backlog" -> Ok Journal_model.Backlog
  | Some "logseq.property/status.waiting" -> Ok Journal_model.Waiting
  | Some "logseq.property/status.later" -> Ok Journal_model.Later
  | Some ident -> Error ("Unknown Logseq block status: " ^ ident)
;;

let creation_time (context : time_context) instant_unix_ms =
  Journal_time.of_instant_unix_ms_with ~localtime:context.localtime ~instant_unix_ms
;;

let block ~page ~revision ~child_count ~time_context (value : Graph.block) =
  match creation_time time_context value.created_at_ms, task_state value with
  | (Error _ as error), _ | _, (Error _ as error) -> error
  | Ok creation_time, Ok task_state ->
    let parent = Graph.Uuid.to_string value.parent in
    Journal_model.create
      ~id:(Graph.Uuid.to_string value.uuid)
      ~page_id:(Graph.Uuid.to_string value.page)
      ~journal_day:page.day
      ~parent_id:(if String.equal parent page.id then None else Some parent)
      ~sibling_order:value.order
      ~source:value.title
      ~task_state
      ~child_count
      ~creation_time
      ~revision
      ~last_mutation_id:"00000000-0000-0000-0000-000000000000"
;;

let children_of (root : Graph.block) items =
  let root_id = Graph.Uuid.to_string root.Graph.uuid in
  List.filter_map
    (fun (item : tree_member) ->
       if item.depth = 1 && String.equal (Graph.Uuid.to_string item.block.parent) root_id
       then Some item
       else None)
    items
;;

let timeline_entry_page ~page ~time_context (result : tree_member Graph.page_result) =
  let cursor block =
    Option.map
      (fun protocol_cursor ->
         { after_sibling_order = Journal_model.sibling_order block
         ; after_block_id = Journal_model.id block
         ; protocol_cursor = Some protocol_cursor
         })
      result.continuation
  in
  let roots =
    List.filter_map
      (fun (item : tree_member) ->
         if item.depth = 0 && not (String.equal (String.trim item.block.title) "")
         then Some item
         else None)
      result.items
  in
  let rec project reversed = function
    | [] ->
      Ok
        { entries = List.rev reversed
        ; continuation =
            (match reversed with
             | [] -> None
             | entry :: _ -> cursor entry.block)
        }
    | (root : tree_member) :: rest ->
      let children = children_of root.block result.items in
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
         let child_summaries =
           List.map
             (fun (child : tree_member) ->
                { block_id = Graph.Uuid.to_string child.block.uuid
                ; source = child.block.title
                })
             children
         in
         project ({ block; child_summaries } :: reversed) rest)
  in
  project [] roots
;;

let detail
      ~page
      ~time_context
      ~(root : block_member)
      (children : block_member Graph.page_result)
  =
  let child_count =
    List.length children.items + if Option.is_some children.continuation then 1 else 0
  in
  match block ~page ~revision:root.revision ~child_count ~time_context root.block with
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
           block ~page ~revision:child.revision ~child_count:0 ~time_context child.block
         with
         | Error _ as error -> error
         | Ok child -> project (child :: reversed) rest)
    in
    project [] children.items
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
        match task_status with
        | None -> Journal_model.No_status
        | Some P.V2_todo -> Todo
        | Some V2_doing -> Doing
        | Some V2_in_review -> In_review
        | Some V2_now -> Now
        | Some V2_done -> Done
        | Some V2_canceled -> Canceled
        | Some V2_backlog -> Backlog
        | Some V2_waiting -> Waiting
        | Some V2_later -> Later
      in
      Block (id uuid), title, status
  in
  { membership_id = id item.membership_uuid; target; title; task_state }
;;
