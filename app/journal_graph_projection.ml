module Graph = Logseq_db_types.Graph_types

type page =
  { id : string
  ; day : int
  ; title : string
  }

type block = Journal_model.t

type time_context =
  { time_zone_id : string
  ; utc_offset_seconds : int
  }

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
  ; block_id : string
  ; parent_block_id : string
  ; expected_parent_revision : int
  ; sibling_order : string
  ; source : string
  ; task_state : Journal_model.task_state
  ; creation_time : Journal_time.t
  }

type update_source =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  ; source : string
  }

type set_task_state =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
  ; task_state : Journal_model.task_state
  }

type delete_subtree =
  { mutation_id : string
  ; block_id : string
  ; expected_revision : int
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
  Journal_time.of_instant_unix_ms
    ~instant_unix_ms
    ~time_zone_id:context.time_zone_id
    ~utc_offset_seconds:context.utc_offset_seconds
;;

let revision basis =
  if Int64.compare basis 1L < 0
  then 1
  else if Int64.compare basis (Int64.of_int max_int) > 0
  then max_int
  else Int64.to_int basis
;;

let block ~page ~basis ~child_count ~time_context (value : Graph.block) =
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
      ~revision:(revision basis)
      ~last_mutation_id:"00000000-0000-0000-0000-000000000000"
;;

let children_of (root : Graph.block) items =
  let root_id = Graph.Uuid.to_string root.Graph.uuid in
  List.filter_map
    (fun (item : Graph.block_tree_item) ->
       if item.depth = 1 && String.equal (Graph.Uuid.to_string item.block.parent) root_id
       then Some item.block
       else None)
    items
;;

let timeline_entry_page
      ~page
      ~basis
      ~time_context
      (result : Graph.block_tree_item Graph.page_result)
  =
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
      (fun (item : Graph.block_tree_item) ->
         if item.depth = 0 && not (String.equal (String.trim item.block.title) "")
         then Some item.block
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
    | (root : Graph.block) :: rest ->
      let children = children_of root result.items in
      (match
         block ~page ~basis ~child_count:(List.length children) ~time_context root
       with
       | Error _ as error -> error
       | Ok block ->
         let child_summaries =
           List.map
             (fun (child : Graph.block) ->
                { block_id = Graph.Uuid.to_string child.uuid; source = child.title })
             children
         in
         project ({ block; child_summaries } :: reversed) rest)
  in
  project [] roots
;;

let detail ~page ~basis ~time_context ~root (children : Graph.block Graph.page_result) =
  let child_count =
    List.length children.items + if Option.is_some children.continuation then 1 else 0
  in
  match block ~page ~basis ~child_count ~time_context root with
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
      | child :: rest ->
        (match block ~page ~basis ~child_count:0 ~time_context child with
         | Error _ as error -> error
         | Ok child -> project (child :: reversed) rest)
    in
    project [] children.items
;;
