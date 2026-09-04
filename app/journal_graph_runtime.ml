module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Error = Logseq_db_worker.Error
module Projection = Journal_graph_projection

type worker_failure =
  { operation : string
  ; request_id : Graph.Uuid.t
  ; error : Error.t
  }

type graph_info =
  { graph_uuid : Graph.Uuid.t
  ; graph_name : string
  ; schema : Graph.schema_version
  ; admission_facts : Graph.admission_fact list
  ; generation : string
  ; projection_revision : string
  }

type failure_source =
  | Worker_failure of worker_failure
  | Projection_failure of string

type payload =
  | Graph_ready of graph_info
  | Block_captured of
      { block : Projection.block
      ; timeline_entry_update : Projection.timeline_entry option
      }
  | Child_created of
      { child : Projection.block
      ; parent_revision : int
      ; timeline_entry_update : Projection.timeline_entry
      }
  | Block_updated of
      { block : Projection.block
      ; timeline_entry_update : Projection.timeline_entry option
      }
  | Block_removed of { block_id : string }
  | Page_tree_reconciled of
      { page : Projection.page
      ; value : Projection.timeline_entry_page
      }
  | Children_reconciled of Projection.detail
  | Update_conflict of Projection.block
  | Subtree_deleted of
      { block_id : string
      ; deleted_count : int
      ; parent : Projection.block option
      ; timeline_entry_update : Projection.timeline_entry option
      }
  | Delete_conflict of Projection.block
  | Block_found of Projection.block option
  | Feed_loaded of
      { request_generation : int64
      ; feed : Projection.feed
      ; complete : bool
      }
  | Day_blocks_loaded of
      { request_generation : int64
      ; page : Projection.timeline_entry_page
      }
  | Detail_loaded of
      { request_generation : int64
      ; detail : Projection.detail
      }
  | Feed_failed of
      { request_generation : int64
      ; failure : failure_source
      }
  | Open_failed of worker_failure
  | Rejected of failure_source

type response =
  { basis : int64 option
  ; payload : payload
  }

type feed_pending =
  { generation : int64
  ; mutable remaining : int
  ; mutable days : Projection.day_feed list
  ; ordered_page_ids : string list
  ; mutable resolved_page_ids : string list
  ; mutable published : bool
  ; has_more_days : bool
  }

type feed_spec =
  { day_limit : int
  ; blocks_per_day : int
  ; slot_limit : int
  }

type refresh =
  | Captured of { block_id : string }
  | Updated of { block_id : string }
  | Update_conflict_refresh of { block_id : string }
  | Child_created_refresh of
      { child_id : string
      ; parent_id : string
      }

type page_tree_interest =
  { page : Projection.page
  ; limit : int
  }

type children_interest =
  { page : Projection.page
  ; root : Graph.block
  ; limit : int
  }

type operation =
  | Graph_info
  | Pull_changes of
      { request_generation : int64
      ; generation : string
      }
  | Acknowledge_changes
  | List_feed_pages of
      { before_day : int option
      ; day_limit : int
      ; blocks_per_day : int
      ; slot_limit : int
      ; request_generation : int64
      ; pages : Projection.page list
      }
  | Feed_page_tree of
      { page : Projection.page
      ; pending : feed_pending
      ; allocated_blocks : int
      }
  | Day_page_tree of
      { page : Projection.page
      ; generation : int64
      }
  | Detail_block of
      { generation : int64
      ; block_id : string
      ; limit : int
      }
  | Changed_block of
      { block_id : string
      ; page : Projection.page
      }
  | Find_block_result
  | Detail_children of
      { generation : int64
      ; page : Projection.page
      ; root : Graph.block
      }
  | Changed_children of children_interest
  | Capture_page of Projection.capture
  | Capture_create_page of
      { command : Projection.capture
      ; page_uuid : Graph.page_uuid
      }
  | Capture_children of
      { command : Projection.capture
      ; page : Projection.page
      ; conflict_retries : int
      }
  | Capture_insert of
      { command : Projection.capture
      ; page : Projection.page
      ; conflict_retries : int
      }
  | Capture_block of
      { command : Projection.capture
      ; page : Projection.page
      }
  | Capture_status of
      { command : Projection.capture
      ; page : Projection.page
      }
  | Refresh_page_tree of
      { page : Projection.page
      ; refresh : refresh
      }
  | Changed_page_tree of Projection.page
  | Mutation_refresh of
      { page : Projection.page
      ; refresh : refresh
      }
  | Delete_mutation of Projection.delete_subtree

type t =
  { pending : (string, operation) Hashtbl.t
  ; mutable next_request : int64
  ; mutable basis : int64
  ; mutable projection_revision : string option
  ; mutable change_generation : string option
  ; mutable change_cursor : string option
  ; block_revisions : (string, string) Hashtbl.t
  ; page_revisions : (string, string) Hashtbl.t
  ; scope_revisions : (string, string) Hashtbl.t
  ; mutable calendar : Journal_calendar.t option
  ; mutable pages : (string * Projection.page) list
  ; mutable block_pages : (string * Projection.page) list
  ; projected_blocks : (string, Projection.block) Hashtbl.t
  ; page_tree_interests : (string, page_tree_interest) Hashtbl.t
  ; children_interests : (string, children_interest) Hashtbl.t
  ; mutable initial_feed : feed_spec option
  }

type output =
  { requests : Protocol.request list
  ; responses : response list
  }

let empty = { requests = []; responses = [] }
let requests values = { empty with requests = values }
let response ?basis payload = { basis; payload }
let responses values = { empty with responses = values }

let feed_failure request_generation message =
  responses
    [ response (Feed_failed { request_generation; failure = Projection_failure message })
    ]
;;

let create () =
  { pending = Hashtbl.create 32
  ; next_request = 1L
  ; basis = 0L
  ; projection_revision = None
  ; change_generation = None
  ; change_cursor = None
  ; block_revisions = Hashtbl.create 64
  ; page_revisions = Hashtbl.create 32
  ; scope_revisions = Hashtbl.create 32
  ; calendar = None
  ; pages = []
  ; block_pages = []
  ; projected_blocks = Hashtbl.create 64
  ; page_tree_interests = Hashtbl.create 32
  ; children_interests = Hashtbl.create 32
  ; initial_feed = None
  }
;;

let reset t =
  Hashtbl.clear t.pending;
  t.basis <- 0L;
  t.projection_revision <- None;
  t.change_generation <- None;
  t.change_cursor <- None;
  Hashtbl.clear t.block_revisions;
  Hashtbl.clear t.page_revisions;
  Hashtbl.clear t.scope_revisions;
  t.pages <- [];
  t.block_pages <- [];
  Hashtbl.clear t.projected_blocks;
  Hashtbl.clear t.page_tree_interests;
  Hashtbl.clear t.children_interests;
  t.initial_feed <- None
;;

let set_calendar t (calendar : Journal_calendar.t) =
  match t.calendar with
  | Some current when Int64.compare current.generation calendar.generation >= 0 -> ()
  | None | Some _ -> t.calendar <- Some calendar
;;

let projection_time_context t =
  match t.calendar with
  | None -> Error "The host calendar is unavailable."
  | Some calendar ->
    Ok
      Projection.
        { time_zone_id = calendar.time_zone_id
        ; utc_offset_seconds = calendar.utc_offset_seconds
        }
;;

let request_uuid t =
  let value = Printf.sprintf "f0000000-0000-4000-8000-%012Lx" t.next_request in
  t.next_request <- Int64.succ t.next_request;
  Result.get_ok (Graph.Uuid.of_string value)
;;

let uuid value = Graph.Uuid.of_string value

let make_request t operation command =
  let request_id = request_uuid t in
  Hashtbl.replace t.pending (Graph.Uuid.to_string request_id) operation;
  Protocol.{ api_version; request_id; command }
;;

let read = make_request
let mutate = make_request
let start t = read t Graph_info Protocol.V2_graph_info

let remember_page t (page : Projection.page) =
  t.pages
  <- (page.id, page) :: List.filter (fun (id, _) -> not (String.equal id page.id)) t.pages
;;

let page_by_uuid t uuid = List.assoc_opt (Graph.Uuid.to_string uuid) t.pages
let page_by_block t block_id = List.assoc_opt block_id t.block_pages

let remember_block_page t page block_id =
  t.block_pages
  <- (block_id, page)
     :: List.filter
          (fun (candidate, _) -> not (String.equal candidate block_id))
          t.block_pages
;;

let remember_entries t page entries =
  List.iter
    (fun (entry : Projection.timeline_entry) ->
       let block_id = Journal_model.id entry.block in
       remember_block_page t page block_id;
       Hashtbl.replace t.projected_blocks block_id entry.block)
    entries
;;

let remember_tree_items t page items =
  List.iter
    (fun (item : Graph.block_tree_item) ->
       remember_block_page t page (Graph.Uuid.to_string item.block.uuid))
    items
;;

let remember_blocks t page blocks =
  List.iter
    (fun (block : Graph.block) ->
       remember_block_page t page (Graph.Uuid.to_string block.uuid))
    blocks
;;

let page_by_day t day =
  List.find_map
    (fun (_, (page : Projection.page)) -> if page.day = day then Some page else None)
    t.pages
;;

let parse_uuid field value =
  match uuid value with
  | Ok value -> Ok value
  | Error message -> Error (field ^ ": " ^ message)
;;

let mutation_context (_t : t) mutation_id = parse_uuid "mutation ID" mutation_id

let scope_key = function
  | Protocol.V2_children_scope parent -> "children:" ^ Graph.Uuid.to_string parent
  | V2_page_tree_scope { page; maximum_depth } ->
    Printf.sprintf "pageTree:%s:%d" (Graph.Uuid.to_string page) maximum_depth
  | V2_journal_index_scope -> "journalIndex"
;;

let preconditions ?(blocks = []) ?(pages = []) ?(scopes = []) () =
  Protocol.{ blocks; pages; scopes }
;;

let block_preconditions t block =
  match Hashtbl.find_opt t.block_revisions (Graph.Uuid.to_string block) with
  | None -> Error "The block revision is not retained."
  | Some revision -> Ok (preconditions ~blocks:[ block, revision ] ())
;;

let page_preconditions t page =
  match Hashtbl.find_opt t.page_revisions (Graph.Uuid.to_string page) with
  | None -> Error "The page revision is not retained."
  | Some revision -> Ok (page, revision)
;;

let scope_precondition t scope =
  match Hashtbl.find_opt t.scope_revisions (scope_key scope) with
  | None -> Error "The structure revision is not retained."
  | Some revision -> Ok (scope, revision)
;;

let delete_preconditions t block =
  let block_id = Graph.Uuid.to_string block in
  match
    ( Hashtbl.find_opt t.block_revisions block_id
    , Hashtbl.find_opt t.projected_blocks block_id )
  with
  | None, _ -> Error "The block revision is not retained."
  | _, None -> Error "The delete target is not retained."
  | Some block_revision, Some projected ->
    let parent_scope =
      Option.bind (Journal_model.parent_id projected) (fun parent ->
        Option.bind
          (Result.to_option (parse_uuid "parent UUID" parent))
          (fun parent ->
             scope_precondition t (Protocol.V2_children_scope parent) |> Result.to_option))
    in
    let page_scope =
      Option.bind
        (Result.to_option (parse_uuid "page UUID" (Journal_model.page_id projected)))
        (fun page ->
           scope_precondition t (Protocol.V2_page_tree_scope { page; maximum_depth = 1 })
           |> Result.to_option)
    in
    (match parent_scope, page_scope with
     | Some scope, _ | None, Some scope ->
       Ok (preconditions ~blocks:[ block, block_revision ] ~scopes:[ scope ] ())
     | None, None -> Error "The delete structure revision is not retained.")
;;

let journal_uuid day =
  let text = Printf.sprintf "%08d" day in
  Graph.Uuid.of_string
    (Printf.sprintf
       "00000001-%s-%s-0000-000000000000"
       (String.sub text 0 4)
       (String.sub text 4 4))
;;

let journal_title day =
  Printf.sprintf "%04d-%02d-%02d" (day / 10_000) (day / 100 mod 100) (day mod 100)
;;

let reject message = responses [ response (Rejected (Projection_failure message)) ]

let take count values =
  let rec loop remaining reversed = function
    | _ when remaining = 0 -> List.rev reversed
    | [] -> List.rev reversed
    | value :: rest -> loop (remaining - 1) (value :: reversed) rest
  in
  loop count [] values
;;

let allocate_feed_page_limits ~blocks_per_day ~slot_limit pages =
  let rec allocate extra = function
    | [] -> []
    | page :: rest ->
      let additional = min (blocks_per_day - 1) extra in
      (page, 1 + additional) :: allocate (extra - additional) rest
  in
  allocate (slot_limit - (2 * List.length pages)) pages
;;

let feed_request
      t
      ~before_day
      ~day_limit
      ~blocks_per_day
      ~slot_limit
      ~request_generation
      ~pages
      ~cursor
  =
  read
    t
    (List_feed_pages
       { before_day; day_limit; blocks_per_day; slot_limit; request_generation; pages })
    (Protocol.V2_list_journals
       { from_day = Option.value before_day ~default:0
       ; through_day = 99_999_999
       ; limit = Protocol.maximum_page_size
       ; cursor
       ; revision = None
       })
;;

let page_tree t operation page ?cursor limit =
  match parse_uuid "page UUID" page.Projection.id with
  | Error message -> Error message
  | Ok page_uuid ->
    Hashtbl.replace t.page_tree_interests page.id { page; limit };
    Ok
      (read
         t
         operation
         (Protocol.V2_get_page_tree
            { page = page_uuid; maximum_depth = 1; limit; cursor; revision = None }))
;;

let feed_page_id (page : Projection.page) = page.id

let feed_can_publish pending =
  if pending.published
  then true
  else (
    match pending.days with
    | [] -> false
    | days ->
      let newest =
        List.fold_left
          (fun newest (day : Projection.day_feed) -> Int.max newest day.page.day)
          min_int
          days
      in
      let rec newer_pages_resolved = function
        | [] -> true
        | page_id :: rest ->
          let day =
            List.find_map
              (fun (day : Projection.day_feed) ->
                 if String.equal day.page.id page_id then Some day.page.day else None)
              days
          in
          (match day with
           | Some day when day = newest -> true
           | Some _ -> newer_pages_resolved rest
           | None ->
             List.exists (String.equal page_id) pending.resolved_page_ids
             && newer_pages_resolved rest)
      in
      newer_pages_resolved pending.ordered_page_ids)
;;

let feed_progress ?basis pending =
  if not (feed_can_publish pending)
  then []
  else (
    pending.published <- true;
    let days =
      List.sort
        (fun left right -> Int.compare right.Projection.page.day left.page.day)
        pending.days
    in
    let slot_count =
      List.fold_left
        (fun total (day : Projection.day_feed) -> total + 1 + List.length day.entries)
        0
        days
    in
    [ response
        ?basis
        (Feed_loaded
           { request_generation = pending.generation
           ; feed = { days; slot_count; has_more_days = pending.has_more_days }
           ; complete = pending.remaining = 0
           })
    ])
;;

let submit t (request : Journal_graph_request.t) =
  match request with
  | Load_feed { before_day; day_limit; blocks_per_day; slot_limit; request_generation } ->
    if day_limit <= 0
    then feed_failure request_generation "The feed day limit must be positive."
    else if blocks_per_day <= 0
    then feed_failure request_generation "The feed block limit must be positive."
    else if slot_limit < 2
    then
      feed_failure
        request_generation
        "The feed slot limit must reserve one day and one block."
    else (
      let day_limit = min day_limit (slot_limit / 2) in
      let blocks_per_day = min Protocol.maximum_page_size blocks_per_day in
      (match before_day with
       | None -> t.initial_feed <- Some { day_limit; blocks_per_day; slot_limit }
       | Some _ -> ());
      requests
        [ feed_request
            t
            ~before_day
            ~day_limit
            ~blocks_per_day
            ~slot_limit
            ~request_generation
            ~pages:[]
            ~cursor:None
        ])
  | Load_day_blocks { day; after; limit; request_generation } ->
    (match page_by_day t day with
     | None -> reject "The requested journal page is not retained."
     | Some page ->
       let cursor = Option.bind after (fun cursor -> cursor.Projection.protocol_cursor) in
       (match
          page_tree
            t
            (Day_page_tree { page; generation = request_generation })
            page
            ?cursor
            limit
        with
        | Ok request -> requests [ request ]
        | Error message -> reject message))
  | Load_detail { block_id; request_generation; limit; _ } ->
    (match parse_uuid "block UUID" block_id with
     | Error message -> reject message
     | Ok block ->
       requests
         [ read
             t
             (Detail_block
                { generation = request_generation
                ; block_id
                ; limit = max 1 (min Protocol.maximum_page_size limit)
                })
             (Protocol.V2_get_block { block; revision = None })
         ])
  | Find_block block_id ->
    (match parse_uuid "block UUID" block_id with
     | Error message -> reject message
     | Ok block ->
       requests
         [ read t Find_block_result (Protocol.V2_get_block { block; revision = None }) ])
  | Capture { command; _ } ->
    (match journal_uuid (Journal_time.local_day command.creation_time) with
     | Error message -> reject message
     | Ok page_uuid ->
       requests
         [ read
             t
             (Capture_page command)
             (Protocol.V2_get_page { page = page_uuid; revision = None })
         ])
  | Update_source command ->
    (match
       mutation_context t command.mutation_id, parse_uuid "block UUID" command.block_id
     with
     | Ok mutation_id, Ok block ->
       (match page_by_block t command.block_id with
        | None -> reject "The block page is not retained."
        | Some page ->
          (match block_preconditions t block with
           | Error message -> reject message
           | Ok preconditions ->
             requests
               [ mutate
                   t
                   (Mutation_refresh
                      { page; refresh = Updated { block_id = command.block_id } })
                   (Protocol.V2_save_block
                      { mutation_id; block; title = command.source; preconditions })
               ]))
     | Error message, _ | _, Error message -> reject message)
  | Set_task_state command ->
    (match
       mutation_context t command.mutation_id, parse_uuid "block UUID" command.block_id
     with
     | Ok mutation_id, Ok block ->
       (match page_by_block t command.block_id with
        | None -> reject "The block page is not retained."
        | Some page
          when command.expected_revision
               <>
               if Int64.compare t.basis 1L < 0
               then 1
               else if Int64.compare t.basis (Int64.of_int max_int) > 0
               then max_int
               else Int64.to_int t.basis ->
          (match
             page_tree
               t
               (Refresh_page_tree
                  { page
                  ; refresh = Update_conflict_refresh { block_id = command.block_id }
                  })
               page
               Protocol.maximum_page_size
           with
           | Ok request -> requests [ request ]
           | Error message -> reject message)
        | Some page ->
          (match block_preconditions t block with
           | Error message -> reject message
           | Ok preconditions ->
             let mutation =
               match command.task_state with
               | Journal_model.No_status ->
                 Protocol.V2_clear_task_status { mutation_id; block; preconditions }
               | Todo ->
                 V2_set_task_status
                   { mutation_id; block; status = V2_todo; preconditions }
               | Doing ->
                 V2_set_task_status
                   { mutation_id; block; status = V2_doing; preconditions }
               | In_review ->
                 V2_set_task_status
                   { mutation_id; block; status = V2_in_review; preconditions }
               | Now ->
                 V2_set_task_status { mutation_id; block; status = V2_now; preconditions }
               | Done ->
                 V2_set_task_status
                   { mutation_id; block; status = V2_done; preconditions }
               | Canceled ->
                 V2_set_task_status
                   { mutation_id; block; status = V2_canceled; preconditions }
               | Backlog ->
                 V2_set_task_status
                   { mutation_id; block; status = V2_backlog; preconditions }
               | Waiting ->
                 V2_set_task_status
                   { mutation_id; block; status = V2_waiting; preconditions }
               | Later ->
                 V2_set_task_status
                   { mutation_id; block; status = V2_later; preconditions }
             in
             requests
               [ mutate
                   t
                   (Mutation_refresh
                      { page; refresh = Updated { block_id = command.block_id } })
                   mutation
               ]))
     | Error message, _ | _, Error message -> reject message)
  | Create_child command ->
    (match
       ( mutation_context t command.mutation_id
       , parse_uuid "child UUID" command.block_id
       , parse_uuid "parent UUID" command.parent_block_id )
     with
     | Ok mutation_id, Ok child, Ok parent ->
       (match page_by_block t command.parent_block_id with
        | None -> reject "The parent page is not retained."
        | Some page ->
          let scope = Protocol.V2_children_scope parent in
          (match
             ( Hashtbl.find_opt t.block_revisions (Graph.Uuid.to_string parent)
             , scope_precondition t scope )
           with
           | Some revision, Ok scope_revision ->
             let tree : Protocol.v2_block_tree =
               { uuid = child; title = command.source; children = [] }
             in
             requests
               [ mutate
                   t
                   (Mutation_refresh
                      { page
                      ; refresh =
                          Child_created_refresh
                            { child_id = command.block_id
                            ; parent_id = command.parent_block_id
                            }
                      })
                   (Protocol.V2_insert_blocks
                      { mutation_id
                      ; parent
                      ; roots = [ tree ]
                      ; preconditions =
                          preconditions
                            ~blocks:[ parent, revision ]
                            ~scopes:[ scope_revision ]
                            ()
                      })
               ]
           | None, _ -> reject "The parent block revision is not retained."
           | _, Error message -> reject message))
     | Error message, _, _ | _, Error message, _ | _, _, Error message -> reject message)
  | Delete_subtree command ->
    (match
       mutation_context t command.mutation_id, parse_uuid "block UUID" command.block_id
     with
     | Ok mutation_id, Ok block ->
       (match delete_preconditions t block with
        | Error message -> reject message
        | Ok preconditions ->
          requests
            [ mutate
                t
                (Delete_mutation command)
                (Protocol.V2_delete_blocks { mutation_id; root = block; preconditions })
            ])
     | Error message, _ | _, Error message -> reject message)
;;

let page_of_graph_page (page : Graph.page) =
  let summary : Graph.page_summary =
    { uuid = page.uuid
    ; name = page.name
    ; title = page.title
    ; kind = page.kind
    ; recycled = page.recycled
    }
  in
  Projection.page_of_summary summary
;;

let request_refresh t page refresh =
  match
    page_tree t (Refresh_page_tree { page; refresh }) page Protocol.maximum_page_size
  with
  | Ok request -> requests [ request ]
  | Error message -> reject message
;;

let capture_tree (command : Projection.capture) =
  let project (child : Projection.capture_child) =
    match parse_uuid "child UUID" child.block_id with
    | Error _ as error -> error
    | Ok uuid -> Ok Protocol.{ uuid; title = child.source; children = [] }
  in
  match parse_uuid "block UUID" command.Projection.block_id with
  | Error _ as error -> error
  | Ok uuid ->
    let rec children reversed = function
      | [] -> Ok (List.rev reversed)
      | child :: rest ->
        (match project child with
         | Error _ as error -> error
         | Ok child -> children (child :: reversed) rest)
    in
    Result.map
      (fun children -> Protocol.{ uuid; title = command.source; children })
      (children [] command.children)
;;

let capture_insert t (command : Projection.capture) page conflict_retries =
  match
    ( capture_tree command
    , mutation_context t command.mutation_id
    , parse_uuid "page UUID" page.Projection.id )
  with
  | Ok tree, Ok mutation_id, Ok page_uuid ->
    let scope = Protocol.V2_children_scope page_uuid in
    (match page_preconditions t page_uuid, scope_precondition t scope with
     | Ok page_revision, Ok scope_revision ->
       requests
         [ mutate
             t
             (Capture_insert { command; page; conflict_retries })
             (Protocol.V2_insert_blocks
                { mutation_id
                ; parent = page_uuid
                ; roots = [ tree ]
                ; preconditions =
                    preconditions ~pages:[ page_revision ] ~scopes:[ scope_revision ] ()
                })
         ]
     | Error message, _ | _, Error message -> reject message)
  | Error message, _, _ | _, Error message, _ | _, _, Error message -> reject message
;;

let capture_children t command page conflict_retries =
  match parse_uuid "page UUID" page.Projection.id with
  | Error message -> reject message
  | Ok parent ->
    requests
      [ read
          t
          (Capture_children { command; page; conflict_retries })
          (Protocol.V2_get_children
             { parent
             ; limit = Protocol.maximum_page_size
             ; cursor = None
             ; revision = None
             })
      ]
;;

let capture_status t (command : Projection.capture) page =
  match command.Projection.task_state with
  | Journal_model.No_status ->
    request_refresh t page (Captured { block_id = command.block_id })
  | Todo | Doing | In_review | Now | Done | Canceled | Backlog | Waiting | Later ->
    (match
       ( mutation_context t (Graph.Uuid.to_string (request_uuid t))
       , parse_uuid "block UUID" command.block_id )
     with
     | Ok mutation_id, Ok block ->
       (match block_preconditions t block with
        | Error message -> reject message
        | Ok preconditions ->
          let status =
            match command.task_state with
            | Todo -> Protocol.V2_todo
            | Doing -> V2_doing
            | In_review -> V2_in_review
            | Now -> V2_now
            | Done -> V2_done
            | Canceled -> V2_canceled
            | Backlog -> V2_backlog
            | Waiting -> V2_waiting
            | Later -> V2_later
            | No_status -> assert false
          in
          requests
            [ mutate
                t
                (Capture_status { command; page })
                (Protocol.V2_set_task_status { mutation_id; block; status; preconditions })
            ])
     | Error message, _ | _, Error message -> reject message)
;;

let continue_capture t (command : Projection.capture) page =
  match command.Projection.task_state with
  | Journal_model.No_status -> capture_status t command page
  | Todo | Doing | In_review | Now | Done | Canceled | Backlog | Waiting | Later ->
    (match parse_uuid "block UUID" command.block_id with
     | Error message -> reject message
     | Ok block ->
       requests
         [ read
             t
             (Capture_block { command; page })
             (Protocol.V2_get_block { block; revision = None })
         ])
;;

let refresh_response t page refresh basis result =
  match projection_time_context t with
  | Error message -> reject message
  | Ok time_context ->
    (match Projection.timeline_entry_page ~page ~basis ~time_context result with
     | Error message -> reject message
     | Ok projected ->
       remember_entries t page projected.entries;
       let find id =
         List.find_opt
           (fun entry -> String.equal (Journal_model.id entry.Projection.block) id)
           projected.entries
       in
       (match refresh with
        | Captured { block_id } ->
          (match find block_id with
           | Some entry ->
             responses
               [ response
                   ~basis
                   (Block_captured
                      { block = entry.block; timeline_entry_update = Some entry })
               ]
           | None -> reject "The captured block was not visible after commit.")
        | Updated { block_id } ->
          (match find block_id with
           | Some entry ->
             responses
               [ response
                   ~basis
                   (Block_updated
                      { block = entry.block; timeline_entry_update = Some entry })
               ]
           | None -> reject "The updated block was not visible after commit.")
        | Update_conflict_refresh { block_id } ->
          (match find block_id with
           | Some entry -> responses [ response ~basis (Update_conflict entry.block) ]
           | None -> reject "The conflicted block was not visible during reconciliation.")
        | Child_created_refresh { child_id; parent_id } ->
          (match find parent_id with
           | None -> reject "The parent block was not visible after child creation."
           | Some parent ->
             let child =
               List.find_map
                 (fun item ->
                    if String.equal (Graph.Uuid.to_string item.Graph.block.uuid) child_id
                    then
                      Projection.block
                        ~page
                        ~basis
                        ~child_count:0
                        ~time_context
                        item.block
                      |> Result.to_option
                    else None)
                 result.Graph.items
             in
             (match child with
              | None -> reject "The child block was not visible after commit."
              | Some child ->
                responses
                  [ response
                      ~basis
                      (Child_created
                         { child
                         ; parent_revision =
                             (if Int64.compare basis (Int64.of_int max_int) > 0
                              then max_int
                              else max 1 (Int64.to_int basis))
                         ; timeline_entry_update = parent
                         })
                  ]))))
;;

let observe_projection_revision t revision =
  if not (Option.equal String.equal t.projection_revision (Some revision))
  then (
    t.projection_revision <- Some revision;
    t.basis <- Int64.succ t.basis)
;;

let append_unique equal value values =
  if List.exists (equal value) values then values else values @ [ value ]
;;

let changed_interests windows =
  List.fold_left
    (fun (blocks, pages, structures) (window : Protocol.v2_change_window) ->
       ( List.fold_left
           (fun values value -> append_unique Graph.Uuid.equal value values)
           blocks
           window.block_uuids
       , List.fold_left
           (fun values value -> append_unique Graph.Uuid.equal value values)
           pages
           window.page_uuids
       , List.fold_left
           (fun values value -> append_unique ( = ) value values)
           structures
           window.structure_interests ))
    ([], [], [])
    windows
;;

let registered_page t uuid = page_by_uuid t uuid

let registered_tree t uuid =
  Hashtbl.find_opt t.page_tree_interests (Graph.Uuid.to_string uuid)
;;

let registered_children t uuid =
  Hashtbl.find_opt t.children_interests (Graph.Uuid.to_string uuid)
;;

let hydration_for_changes t ~request_generation windows =
  let blocks, pages, structures = changed_interests windows in
  let point_reads =
    List.filter_map
      (fun block ->
         let block_id = Graph.Uuid.to_string block in
         Option.map
           (fun page ->
              read
                t
                (Changed_block { block_id; page })
                (Protocol.V2_get_block { block; revision = None }))
           (page_by_block t block_id))
      blocks
  in
  let tree_reads =
    List.filter_map
      (function
        | Protocol.V2_page_tree_interest page ->
          Option.bind (registered_tree t page) (fun interest ->
            page_tree t (Changed_page_tree interest.page) interest.page interest.limit
            |> Result.to_option)
        | V2_children_interest _ | V2_journal_index_interest -> None)
      structures
  in
  let children_reads =
    List.filter_map
      (function
        | Protocol.V2_children_interest parent ->
          Option.map
            (fun interest ->
               read
                 t
                 (Changed_children interest)
                 (Protocol.V2_get_children
                    { parent; limit = interest.limit; cursor = None; revision = None }))
            (registered_children t parent)
        | V2_page_tree_interest _ | V2_journal_index_interest -> None)
      structures
  in
  let journal_changed =
    List.exists
      (function
        | Protocol.V2_journal_index_interest -> true
        | V2_children_interest _ | V2_page_tree_interest _ -> false)
      structures
    || List.exists (fun page -> Option.is_some (registered_page t page)) pages
  in
  let journal =
    match journal_changed, t.initial_feed with
    | true, Some feed ->
      submit
        t
        (Journal_graph_request.Load_feed
           { before_day = None
           ; day_limit = feed.day_limit
           ; blocks_per_day = feed.blocks_per_day
           ; slot_limit = feed.slot_limit
           ; request_generation
           })
    | false, _ | true, None -> empty
  in
  { requests = point_reads @ tree_reads @ children_reads @ journal.requests
  ; responses = journal.responses
  }
;;

let rehydrate_current_interests t ~request_generation ~generation =
  t.change_generation <- Some generation;
  t.change_cursor <- None;
  let graph_info = read t Graph_info Protocol.V2_graph_info in
  let journal =
    match t.initial_feed with
    | None -> empty
    | Some feed ->
      submit
        t
        (Journal_graph_request.Load_feed
           { before_day = None
           ; day_limit = feed.day_limit
           ; blocks_per_day = feed.blocks_per_day
           ; slot_limit = feed.slot_limit
           ; request_generation
           })
  in
  let tree_requests =
    Hashtbl.to_seq_values t.page_tree_interests
    |> List.of_seq
    |> List.filter_map (fun (interest : page_tree_interest) ->
      match parse_uuid "page UUID" interest.page.Projection.id with
      | Error _ -> None
      | Ok page ->
        Some
          (read
             t
             (Changed_page_tree interest.page)
             (Protocol.V2_get_page_tree
                { page
                ; maximum_depth = 1
                ; limit = interest.limit
                ; cursor = None
                ; revision = None
                })))
  in
  let children_requests =
    Hashtbl.to_seq t.children_interests
    |> List.of_seq
    |> List.filter_map (fun (parent_id, (interest : children_interest)) ->
      match parse_uuid "parent UUID" parent_id with
      | Error _ -> None
      | Ok parent ->
        Some
          (read
             t
             (Changed_children interest)
             (Protocol.V2_get_children
                { parent; limit = interest.limit; cursor = None; revision = None })))
  in
  { requests = (graph_info :: journal.requests) @ tree_requests @ children_requests
  ; responses = journal.responses
  }
;;

let remember_block_revision t uuid revision =
  Hashtbl.replace t.block_revisions (Graph.Uuid.to_string uuid) revision
;;

let remember_page_revision t uuid revision =
  Hashtbl.replace t.page_revisions (Graph.Uuid.to_string uuid) revision
;;

let remember_scope_revision t scope revision =
  let scope =
    match scope with
    | Protocol.V2_children_revision parent -> Protocol.V2_children_scope parent
    | V2_page_tree_revision { page; maximum_depth } ->
      V2_page_tree_scope { page; maximum_depth }
    | V2_journal_index_revision -> V2_journal_index_scope
  in
  Hashtbl.replace t.scope_revisions (scope_key scope) revision
;;

let operation_name = function
  | Graph_info -> "graphInfo"
  | Pull_changes _ -> "pullChanges"
  | Acknowledge_changes -> "ackChanges"
  | List_feed_pages _ -> "listFeedPages"
  | Feed_page_tree _ -> "loadFeedPageTree"
  | Day_page_tree _ -> "loadDayPageTree"
  | Detail_block _ -> "loadDetailBlock"
  | Changed_block _ -> "reconcileChangedBlock"
  | Find_block_result -> "findBlock"
  | Detail_children _ -> "loadDetailChildren"
  | Changed_children _ -> "refreshChildren"
  | Capture_page _ -> "findCapturePage"
  | Capture_create_page _ -> "createCapturePage"
  | Capture_children _ -> "refreshCaptureChildren"
  | Capture_insert _ -> "insertCaptureBlock"
  | Capture_block _ -> "readCapturedBlock"
  | Capture_status _ -> "setCaptureStatus"
  | Refresh_page_tree _ -> "refreshPageTree"
  | Changed_page_tree _ -> "reconcileChangedPageTree"
  | Mutation_refresh _ -> "refreshMutation"
  | Delete_mutation _ -> "deleteSubtree"
;;

let worker_error request_id message =
  Error.create ~code:Unsupported_semantics ~message ~details:[]
  |> Result.fold ~ok:Fun.id ~error:(fun _ ->
    Error.create
      ~code:Unsupported_semantics
      ~message:"The Worker request failed."
      ~details:[]
    |> Result.get_ok)
  |> fun error -> request_id, error
;;

let failure_output t operation request_id message =
  let request_id, error = worker_error request_id message in
  let worker_failure = { operation = operation_name operation; request_id; error } in
  match operation with
  | List_feed_pages { request_generation; _ } ->
    responses
      [ response
          (Feed_failed { request_generation; failure = Worker_failure worker_failure })
      ]
  | Feed_page_tree { pending; page; _ } ->
    pending.remaining <- pending.remaining - 1;
    pending.resolved_page_ids <- feed_page_id page :: pending.resolved_page_ids;
    { requests = []
    ; responses =
        feed_progress pending
        @ [ response
              (Feed_failed
                 { request_generation = pending.generation
                 ; failure = Worker_failure worker_failure
                 })
          ]
    }
  | Mutation_refresh { page; refresh = Updated { block_id } } ->
    request_refresh t page (Update_conflict_refresh { block_id })
  | Graph_info -> responses [ response (Open_failed worker_failure) ]
  | Pull_changes _ | Acknowledge_changes ->
    responses [ response (Rejected (Worker_failure worker_failure)) ]
  | Day_page_tree _
  | Detail_block _
  | Changed_block _
  | Find_block_result
  | Detail_children _
  | Changed_children _
  | Capture_page _
  | Capture_create_page _
  | Capture_children _
  | Capture_insert _
  | Capture_block _
  | Capture_status _
  | Refresh_page_tree _
  | Changed_page_tree _
  | Mutation_refresh _
  | Delete_mutation _ -> responses [ response (Rejected (Worker_failure worker_failure)) ]
;;

let tree_result items continuation : Graph.block_tree_item Graph.page_result =
  { items =
      List.map
        (fun (item : Protocol.v2_tree_member) ->
           Graph.{ block = item.value.block; depth = item.depth })
        items
  ; continuation
  }
;;

let children_result items continuation : Graph.block Graph.page_result =
  { items = List.map (fun (item : Protocol.v2_child_member) -> item.value.block) items
  ; continuation
  }
;;

let feed_pages_response
      t
      ~basis
      ~before_day
      ~day_limit
      ~blocks_per_day
      ~slot_limit
      ~request_generation
      ~retained
      items
      continuation
  =
  let pages =
    retained
    @ List.filter_map
        (fun (item : Protocol.v2_journal_item) -> page_of_graph_page item.page)
        items
    |> List.filter (fun (page : Projection.page) ->
      match before_day with
      | None -> true
      | Some before -> page.day < before)
    |> List.sort (fun left right -> Int.compare right.Projection.day left.day)
  in
  if List.length pages < day_limit && Option.is_some continuation
  then
    requests
      [ feed_request
          t
          ~before_day
          ~day_limit
          ~blocks_per_day
          ~slot_limit
          ~request_generation
          ~pages
          ~cursor:continuation
      ]
  else (
    let has_more_days = Option.is_some continuation || List.length pages > day_limit in
    let pages = take day_limit pages in
    List.iter (remember_page t) pages;
    let queued_pages = allocate_feed_page_limits ~blocks_per_day ~slot_limit pages in
    let pending =
      { generation = request_generation
      ; remaining = List.length queued_pages
      ; days = []
      ; ordered_page_ids = List.map (fun (page, _) -> feed_page_id page) queued_pages
      ; resolved_page_ids = []
      ; published = false
      ; has_more_days
      }
    in
    if pages = []
    then
      responses
        [ response
            ~basis
            (Feed_loaded
               { request_generation
               ; feed = { days = []; slot_count = 0; has_more_days }
               ; complete = true
               })
        ]
    else (
      let rec enqueue reversed = function
        | [] -> requests (List.rev reversed)
        | (page, allocated_blocks) :: rest ->
          (match
             page_tree
               t
               (Feed_page_tree { page; pending; allocated_blocks })
               page
               allocated_blocks
           with
           | Ok request -> enqueue (request :: reversed) rest
           | Error message -> feed_failure request_generation message)
      in
      enqueue [] queued_pages))
;;

let receive t (protocol_response : Protocol.response) =
  let (Protocol.V2_response { request_id; outcome; _ }) = protocol_response in
  let key = Graph.Uuid.to_string request_id in
  match Hashtbl.find_opt t.pending key with
  | None -> empty
  | Some operation ->
    Hashtbl.remove t.pending key;
    (match outcome with
     | Protocol.V2_failed { code; message } ->
       (match operation with
        | Capture_insert { command; page; conflict_retries }
          when String.equal code (Error.code_string Error.Conflict)
               && conflict_retries < 2 ->
          capture_children t command page (conflict_retries + 1)
        | _ -> failure_output t operation request_id message)
     | V2_resync_required { generation; reason } ->
       (match operation with
        | Pull_changes { request_generation; _ } ->
          rehydrate_current_interests t ~request_generation ~generation
        | _ -> failure_output t operation request_id reason)
     | V2_graph_info_outcome
         { graph_uuid
         ; graph_name
         ; schema
         ; admission_facts
         ; generation
         ; projection_revision
         ; _
         } ->
       observe_projection_revision t projection_revision;
       (match operation with
        | Graph_info ->
          responses
            [ response
                ~basis:t.basis
                (Graph_ready
                   { graph_uuid
                   ; graph_name
                   ; schema
                   ; admission_facts
                   ; generation
                   ; projection_revision
                   })
            ]
        | _ -> failure_output t operation request_id "Unexpected graph-info response.")
     | V2_journals_outcome { revision_scope; scope_revision; items; next_cursor } ->
       remember_scope_revision t revision_scope scope_revision;
       List.iter
         (fun (item : Protocol.v2_journal_item) ->
            remember_page_revision t item.page.uuid item.revision)
         items;
       (match operation with
        | List_feed_pages
            { before_day
            ; day_limit
            ; blocks_per_day
            ; slot_limit
            ; request_generation
            ; pages
            } ->
          feed_pages_response
            t
            ~basis:t.basis
            ~before_day
            ~day_limit
            ~blocks_per_day
            ~slot_limit
            ~request_generation
            ~retained:pages
            items
            next_cursor
        | _ -> failure_output t operation request_id "Unexpected journal response.")
     | V2_page_outcome lookup ->
       (match lookup, operation with
        | V2_present_page { page; revision }, Capture_page command ->
          remember_page_revision t page.uuid revision;
          (match page_of_graph_page page with
           | None -> reject "The target journal page is unavailable."
           | Some page ->
             remember_page t page;
             capture_children t command page 0)
        | V2_missing_page { uuid; revision }, Capture_page command ->
          remember_page_revision t uuid revision;
          let journal_day = Journal_time.local_day command.creation_time in
          requests
            [ mutate
                t
                (Capture_create_page { command; page_uuid = uuid })
                (Protocol.V2_create_journal_page
                   { mutation_id = request_uuid t
                   ; page = uuid
                   ; journal_day
                   ; title = journal_title journal_day
                   ; preconditions = preconditions ~pages:[ uuid, revision ] ()
                   })
            ]
        | _ -> failure_output t operation request_id "Unexpected page response.")
     | V2_block_outcome lookup ->
       (match lookup, operation with
        | V2_present_block { value; revision }, Detail_block { generation; limit; _ } ->
          remember_block_revision t value.block.uuid revision;
          (match page_by_uuid t value.block.page with
           | None -> reject "The block page is not retained."
           | Some page ->
             let interest = { page; root = value.block; limit } in
             Hashtbl.replace
               t.children_interests
               (Graph.Uuid.to_string value.block.uuid)
               interest;
             requests
               [ read
                   t
                   (Detail_children { generation; page; root = value.block })
                   (Protocol.V2_get_children
                      { parent = value.block.uuid; limit; cursor = None; revision = None })
               ])
        | V2_present_block { value; revision }, Find_block_result ->
          remember_block_revision t value.block.uuid revision;
          (match page_by_uuid t value.block.page, projection_time_context t with
           | Some page, Ok time_context ->
             (match
                Projection.block
                  ~page
                  ~basis:t.basis
                  ~child_count:0
                  ~time_context
                  value.block
              with
              | Ok block ->
                responses [ response ~basis:t.basis (Block_found (Some block)) ]
              | Error message -> reject message)
           | None, _ -> responses [ response ~basis:t.basis (Block_found None) ]
           | _, Error message -> reject message)
        | V2_missing_block _, Find_block_result ->
          responses [ response ~basis:t.basis (Block_found None) ]
        | V2_present_block { value; revision }, Changed_block { block_id; page } ->
          remember_block_revision t value.block.uuid revision;
          let child_count =
            Hashtbl.find_opt t.projected_blocks block_id
            |> Option.map Journal_model.child_count
            |> Option.value ~default:0
          in
          (match projection_time_context t with
           | Error message -> reject message
           | Ok time_context ->
             (match
                Projection.block
                  ~page
                  ~basis:t.basis
                  ~child_count
                  ~time_context
                  value.block
              with
              | Error message -> reject message
              | Ok block ->
                remember_block_page t page block_id;
                Hashtbl.replace t.projected_blocks block_id block;
                responses
                  [ response
                      ~basis:t.basis
                      (Block_updated { block; timeline_entry_update = None })
                  ]))
        | V2_missing_block { uuid; revision }, Changed_block { block_id; _ } ->
          remember_block_revision t uuid revision;
          t.block_pages
          <- List.filter
               (fun (candidate, _) -> not (String.equal candidate block_id))
               t.block_pages;
          Hashtbl.remove t.projected_blocks block_id;
          responses [ response ~basis:t.basis (Block_removed { block_id }) ]
        | V2_present_block { value; revision }, Capture_block { command; page } ->
          remember_block_revision t value.block.uuid revision;
          capture_status t command page
        | V2_missing_block _, Capture_block _ ->
          reject "The captured block is unavailable."
        | _ -> failure_output t operation request_id "Unexpected block response.")
     | V2_children_outcome { revision_scope; scope_revision; items; next_cursor; _ } ->
       remember_scope_revision t revision_scope scope_revision;
       List.iter
         (fun (item : Protocol.v2_child_member) ->
            remember_block_revision t item.value.block.uuid item.revision)
         items;
       (match operation with
        | Detail_children { generation; page; root } ->
          let children = children_result items next_cursor in
          remember_block_page t page (Graph.Uuid.to_string root.uuid);
          remember_blocks t page children.items;
          (match projection_time_context t with
           | Error message -> reject message
           | Ok time_context ->
             (match
                Projection.detail ~page ~basis:t.basis ~time_context ~root children
              with
              | Ok detail ->
                responses
                  [ response
                      ~basis:t.basis
                      (Detail_loaded { request_generation = generation; detail })
                  ]
              | Error message -> reject message))
        | Changed_children { page; root; _ } ->
          let children = children_result items next_cursor in
          remember_block_page t page (Graph.Uuid.to_string root.uuid);
          remember_blocks t page children.items;
          (match projection_time_context t with
           | Error message -> reject message
           | Ok time_context ->
             (match
                Projection.detail ~page ~basis:t.basis ~time_context ~root children
              with
              | Ok detail ->
                responses [ response ~basis:t.basis (Children_reconciled detail) ]
              | Error message -> reject message))
        | Capture_children { command; page; conflict_retries } ->
          let children = children_result items next_cursor in
          remember_blocks t page children.items;
          capture_insert t command page conflict_retries
        | _ -> failure_output t operation request_id "Unexpected children response.")
     | V2_page_tree_outcome { revision_scope; scope_revision; items; next_cursor; _ } ->
       remember_scope_revision t revision_scope scope_revision;
       List.iter
         (fun (item : Protocol.v2_tree_member) ->
            remember_block_revision t item.value.block.uuid item.revision)
         items;
       let result = tree_result items next_cursor in
       (match operation with
        | Feed_page_tree { page; pending; allocated_blocks } ->
          pending.remaining <- pending.remaining - 1;
          pending.resolved_page_ids <- feed_page_id page :: pending.resolved_page_ids;
          let roots =
            List.fold_left
              (fun count (item : Graph.block_tree_item) ->
                 if item.depth = 0 then count + 1 else count)
              0
              result.items
          in
          if roots > allocated_blocks
          then
            feed_failure
              pending.generation
              "The Worker page response exceeded its budget."
          else (
            remember_tree_items t page result.items;
            match projection_time_context t with
            | Error message -> feed_failure pending.generation message
            | Ok time_context ->
              (match
                 Projection.timeline_entry_page ~page ~basis:t.basis ~time_context result
               with
               | Error message -> feed_failure pending.generation message
               | Ok projected ->
                 remember_entries t page projected.entries;
                 pending.days
                 <- { Projection.page
                    ; entries = projected.entries
                    ; has_more_entries = Option.is_some projected.continuation
                    ; continuation = projected.continuation
                    }
                    :: pending.days;
                 { requests = []; responses = feed_progress ~basis:t.basis pending }))
        | Day_page_tree { page; generation } ->
          remember_tree_items t page result.items;
          (match projection_time_context t with
           | Error message -> reject message
           | Ok time_context ->
             (match
                Projection.timeline_entry_page ~page ~basis:t.basis ~time_context result
              with
              | Ok page ->
                responses
                  [ response
                      ~basis:t.basis
                      (Day_blocks_loaded { request_generation = generation; page })
                  ]
              | Error message -> reject message))
        | Refresh_page_tree { page; refresh } ->
          remember_tree_items t page result.items;
          refresh_response t page refresh t.basis result
        | Changed_page_tree page ->
          remember_tree_items t page result.items;
          (match projection_time_context t with
           | Error message -> reject message
           | Ok time_context ->
             (match
                Projection.timeline_entry_page ~page ~basis:t.basis ~time_context result
              with
              | Error message -> reject message
              | Ok value ->
                remember_entries t page value.entries;
                responses
                  [ response ~basis:t.basis (Page_tree_reconciled { page; value }) ]))
        | _ -> failure_output t operation request_id "Unexpected page-tree response.")
     | V2_mutation_committed { after_projection_revision; _ } ->
       observe_projection_revision t after_projection_revision;
       (match operation with
        | Capture_create_page { command; page_uuid } ->
          requests
            [ read
                t
                (Capture_page command)
                (Protocol.V2_get_page { page = page_uuid; revision = None })
            ]
        | Capture_insert { command; page; _ } -> continue_capture t command page
        | Capture_status { command; page } ->
          request_refresh t page (Captured { block_id = command.block_id })
        | Mutation_refresh { page; refresh } -> request_refresh t page refresh
        | Delete_mutation command ->
          responses
            [ response
                ~basis:t.basis
                (Subtree_deleted
                   { block_id = command.block_id
                   ; deleted_count = 1
                   ; parent = None
                   ; timeline_entry_update = None
                   })
            ]
        | _ -> failure_output t operation request_id "Unexpected mutation response.")
     | V2_changes { generation; through; windows; _ } ->
       (match operation with
        | Pull_changes { request_generation; _ } ->
          t.change_generation <- Some generation;
          t.change_cursor <- Some through;
          let acknowledgement =
            read t Acknowledge_changes (Protocol.V2_ack_changes { generation; through })
          in
          let hydration = hydration_for_changes t ~request_generation windows in
          { requests = acknowledgement :: hydration.requests
          ; responses = hydration.responses
          }
        | _ -> failure_output t operation request_id "Unexpected changes response.")
     | V2_changes_acknowledged _ ->
       (match operation with
        | Acknowledge_changes -> empty
        | _ ->
          failure_output t operation request_id "Unexpected acknowledgement response."))
;;

let abandon t (request : Protocol.request) =
  Hashtbl.remove t.pending (Graph.Uuid.to_string request.request_id)
;;

let reconcile_push t ~request_generation = function
  | Protocol.V2_changes_available { generation; _ } ->
    let after =
      match t.change_generation with
      | Some current when String.equal current generation -> t.change_cursor
      | None | Some _ -> None
    in
    requests
      [ read
          t
          (Pull_changes { request_generation; generation })
          (Protocol.V2_pull_changes { generation; after; limit = 256 })
      ]
  | V2_resync_required_push { generation; _ } ->
    rehydrate_current_interests t ~request_generation ~generation
;;
