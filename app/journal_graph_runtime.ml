module Graph = Logseq_db_worker.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Error = Logseq_db_worker.Error
module Projection = Journal_graph_projection

type payload =
  | Graph_ready of Graph.graph_info
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
      }
  | Day_blocks_loaded of
      { request_generation : int64
      ; page : Projection.timeline_entry_page
      }
  | Detail_loaded of
      { request_generation : int64
      ; detail : Projection.detail
      }
  | Open_failed of Error.t
  | Rejected of string

type response =
  { basis : int64 option
  ; payload : payload
  }

type feed_pending =
  { generation : int64
  ; mutable remaining : int
  ; mutable queued_pages : (Projection.page * int) list
  ; mutable days : Projection.day_feed list
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
  | Child_created_refresh of
      { child_id : string
      ; parent_id : string
      }

type operation =
  | Graph_info
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
      }
  | Find_block_result
  | Detail_children of
      { generation : int64
      ; page : Projection.page
      ; root : Graph.block
      }
  | Capture_page of Projection.capture
  | Capture_create_page of
      { command : Projection.capture
      ; page_uuid : Graph.page_uuid
      }
  | Capture_insert of
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
  | Mutation_refresh of
      { page : Projection.page
      ; refresh : refresh
      }
  | Delete_mutation of Projection.delete_subtree

type t =
  { pending : (string, operation) Hashtbl.t
  ; mutable next_request : int64
  ; mutable basis : int64
  ; mutable calendar : Journal_calendar.t option
  ; mutable pages : (string * Projection.page) list
  ; mutable block_pages : (string * Projection.page) list
  ; mutable initial_feed : feed_spec option
  ; mutable reconciliation_basis : int64 option
  }

type output =
  { requests : Protocol.request list
  ; responses : response list
  }

let empty = { requests = []; responses = [] }
let requests values = { empty with requests = values }
let response ?basis payload = { basis; payload }
let responses values = { empty with responses = values }

let create () =
  { pending = Hashtbl.create 32
  ; next_request = 1L
  ; basis = 0L
  ; calendar = None
  ; pages = []
  ; block_pages = []
  ; initial_feed = None
  ; reconciliation_basis = None
  }
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

let read t operation command = make_request t operation (Protocol.Read command)
let mutate t operation mutation = make_request t operation (Protocol.Mutate mutation)
let start t = read t Graph_info Protocol.Graph_info

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
       remember_block_page t page (Journal_model.id entry.block))
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

let mutation_context (t : t) mutation_id =
  Result.map
    (fun mutation_id -> Protocol.{ mutation_id; expected_basis = t.basis })
    (parse_uuid "mutation ID" mutation_id)
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

let reject message = responses [ response (Rejected message) ]

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
    (Protocol.List_pages
       { kind = Graph.Only_journals; limit = Protocol.maximum_page_size; cursor })
;;

let page_tree t operation page ?cursor limit =
  match parse_uuid "page UUID" page.Projection.id with
  | Error message -> Error message
  | Ok page_uuid ->
    Ok
      (read
         t
         operation
         (Protocol.Get_page_tree { page = page_uuid; maximum_depth = 1; limit; cursor }))
;;

let next_feed_page_request t pending =
  match pending.queued_pages with
  | [] -> Ok None
  | (page, allocated_blocks) :: rest ->
    pending.queued_pages <- rest;
    page_tree t (Feed_page_tree { page; pending; allocated_blocks }) page allocated_blocks
    |> Result.map Option.some
;;

let submit t (request : Journal_graph_request.t) =
  match request with
  | Load_feed { before_day; day_limit; blocks_per_day; slot_limit; request_generation } ->
    if day_limit <= 0
    then reject "The feed day limit must be positive."
    else if blocks_per_day <= 0
    then reject "The feed block limit must be positive."
    else if slot_limit < 2
    then reject "The feed slot limit must reserve one day and one block."
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
  | Load_detail { block_id; request_generation; _ } ->
    (match parse_uuid "block UUID" block_id with
     | Error message -> reject message
     | Ok block ->
       requests
         [ read
             t
             (Detail_block { generation = request_generation; block_id })
             (Protocol.Get_block { block })
         ])
  | Find_block block_id ->
    (match parse_uuid "block UUID" block_id with
     | Error message -> reject message
     | Ok block -> requests [ read t Find_block_result (Protocol.Get_block { block }) ])
  | Capture { command; _ } ->
    (match journal_uuid (Journal_time.local_day command.creation_time) with
     | Error message -> reject message
     | Ok page_uuid ->
       requests
         [ read
             t
             (Capture_page command)
             (Protocol.Get_page { page = Graph.Page_by_uuid page_uuid })
         ])
  | Update_source command ->
    (match
       mutation_context t command.mutation_id, parse_uuid "block UUID" command.block_id
     with
     | Ok context, Ok block ->
       (match page_by_block t command.block_id with
        | None -> reject "The block page is not retained."
        | Some page ->
          requests
            [ mutate
                t
                (Mutation_refresh
                   { page; refresh = Updated { block_id = command.block_id } })
                (Protocol.Structural
                   (Protocol.Save_block { block; title = command.source; context }))
            ])
     | Error message, _ | _, Error message -> reject message)
  | Set_task_state command ->
    (match
       mutation_context t command.mutation_id, parse_uuid "block UUID" command.block_id
     with
     | Ok context, Ok block ->
       (match page_by_block t command.block_id with
        | None -> reject "The block page is not retained."
        | Some page ->
          let property = Graph.Property_by_ident "logseq.property/status" in
          let mutation =
            match command.task_state with
            | Journal_model.Not_a_task ->
              Protocol.Remove_property { block; property; context }
            | Todo ->
              Set_property
                { block; property; value = Graph.Default_value "Todo"; context }
            | Done ->
              Set_property
                { block; property; value = Graph.Default_value "Done"; context }
          in
          requests
            [ mutate
                t
                (Mutation_refresh
                   { page; refresh = Updated { block_id = command.block_id } })
                (Protocol.Property mutation)
            ])
     | Error message, _ | _, Error message -> reject message)
  | Create_child command ->
    (match
       ( mutation_context t command.mutation_id
       , parse_uuid "child UUID" command.block_id
       , parse_uuid "parent UUID" command.parent_block_id )
     with
     | Ok context, Ok child, Ok parent ->
       (match page_by_block t command.parent_block_id with
        | None -> reject "The parent page is not retained."
        | Some page ->
          let tree : Protocol.block_tree =
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
                (Protocol.Structural
                   (Insert_blocks
                      { roots = [ tree ]
                      ; position = Relative (Last_child parent)
                      ; context
                      }))
            ])
     | Error message, _, _ | _, Error message, _ | _, _, Error message -> reject message)
  | Delete_subtree command ->
    (match
       mutation_context t command.mutation_id, parse_uuid "block UUID" command.block_id
     with
     | Ok context, Ok block ->
       requests
         [ mutate
             t
             (Delete_mutation command)
             (Protocol.Structural (Delete_blocks { roots = [ block ]; context }))
         ]
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

let capture_insert t (command : Projection.capture) page =
  match
    ( capture_tree command
    , mutation_context t command.mutation_id
    , parse_uuid "page UUID" page.Projection.id )
  with
  | Ok tree, Ok context, Ok page_uuid ->
    requests
      [ mutate
          t
          (Capture_insert { command; page })
          (Protocol.Structural
             (Insert_blocks
                { roots = [ tree ]; position = Relative (Last_child page_uuid); context }))
      ]
  | Error message, _, _ | _, Error message, _ | _, _, Error message -> reject message
;;

let capture_status t (command : Projection.capture) page =
  match command.Projection.task_state with
  | Journal_model.Not_a_task ->
    request_refresh t page (Captured { block_id = command.block_id })
  | Todo | Done ->
    (match
       ( mutation_context t (Graph.Uuid.to_string (request_uuid t))
       , parse_uuid "block UUID" command.block_id )
     with
     | Ok context, Ok block ->
       let value =
         match command.task_state with
         | Todo -> Graph.Default_value "Todo"
         | Done -> Default_value "Done"
         | Not_a_task -> assert false
       in
       requests
         [ mutate
             t
             (Capture_status { command; page })
             (Protocol.Property
                (Set_property
                   { block
                   ; property = Property_by_ident "logseq.property/status"
                   ; value
                   ; context
                   }))
         ]
     | Error message, _ | _, Error message -> reject message)
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

let receive t (protocol_response : Protocol.response) =
  let request_id =
    match protocol_response with
    | Protocol.Succeeded { request_id; _ } -> request_id
    | Failed failure -> failure.request_id
  in
  let key = Graph.Uuid.to_string request_id in
  match Hashtbl.find_opt t.pending key with
  | None -> empty
  | Some operation ->
    Hashtbl.remove t.pending key;
    (match protocol_response with
     | Failed failure ->
       (match operation, failure.phase, Error.code failure.error with
        | Capture_page command, Execute, Not_found ->
          (match journal_uuid (Journal_time.local_day command.creation_time) with
           | Error message -> reject message
           | Ok page_uuid ->
             let context =
               Protocol.{ mutation_id = request_uuid t; expected_basis = t.basis }
             in
             requests
               [ mutate
                   t
                   (Capture_create_page { command; page_uuid })
                   (Protocol.Page
                      (Create_page
                         { title =
                             journal_title (Journal_time.local_day command.creation_time)
                         ; kind =
                             Create_journal_page
                               { journal_day =
                                   Journal_time.local_day command.creation_time
                               ; supplied_uuid = Some page_uuid
                               }
                         ; context
                         }))
               ])
        | _, Open, _ -> responses [ response (Open_failed failure.error) ]
        | _, Execute, _ -> reject (Error.message failure.error))
     | Succeeded { basis; success; _ } ->
       t.basis <- Int64.max t.basis basis;
       (match t.reconciliation_basis with
        | Some expected when Int64.compare t.basis expected >= 0 ->
          t.reconciliation_basis <- None
        | None | Some _ -> ());
       (match operation, success with
        | Graph_info, Graph_info_result info ->
          responses [ response ~basis (Graph_ready info) ]
        | ( List_feed_pages
              { before_day
              ; day_limit
              ; blocks_per_day
              ; slot_limit
              ; request_generation
              ; pages = retained
              }
          , Pages_result result ) ->
          let pages =
            retained @ List.filter_map Projection.page_of_summary result.items
            |> List.filter (fun (page : Projection.page) ->
              match before_day with
              | None -> true
              | Some before -> page.day < before)
            |> List.sort (fun left right -> Int.compare right.Projection.day left.day)
          in
          if List.length pages < day_limit && Option.is_some result.continuation
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
                  ~cursor:result.continuation
              ]
          else (
            let has_more_days =
              Option.is_some result.continuation || List.length pages > day_limit
            in
            let pages = take day_limit pages in
            List.iter (remember_page t) pages;
            let queued_pages =
              allocate_feed_page_limits ~blocks_per_day ~slot_limit pages
            in
            let pending =
              { generation = request_generation
              ; remaining = List.length queued_pages
              ; queued_pages
              ; days = []
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
                       })
                ]
            else (
              match next_feed_page_request t pending with
              | Ok (Some request) -> requests [ request ]
              | Ok None -> reject "The feed page queue is empty."
              | Error message -> reject message))
        | Feed_page_tree { page; pending; allocated_blocks }, Page_tree_result result ->
          pending.remaining <- pending.remaining - 1;
          let projected_roots =
            List.fold_left
              (fun count (item : Graph.block_tree_item) ->
                 if item.depth = 0 then count + 1 else count)
              0
              result.items
          in
          if projected_roots > allocated_blocks
          then (
            pending.queued_pages <- [];
            reject "The Worker page response exceeded its allocated feed budget.")
          else (
            remember_tree_items t page result.items;
            match projection_time_context t with
            | Error message -> reject message
            | Ok time_context ->
              (match Projection.timeline_entry_page ~page ~basis ~time_context result with
               | Error message -> reject message
               | Ok projected ->
                 remember_entries t page projected.entries;
                 pending.days
                 <- { Projection.page
                    ; entries = projected.entries
                    ; has_more_entries = Option.is_some projected.continuation
                    ; continuation = projected.continuation
                    }
                    :: pending.days;
                 if pending.remaining > 0
                 then (
                   match next_feed_page_request t pending with
                   | Ok (Some request) -> requests [ request ]
                   | Ok None -> reject "The feed page queue ended before completion."
                   | Error message -> reject message)
                 else (
                   let days =
                     List.sort
                       (fun left right ->
                          Int.compare right.Projection.page.day left.page.day)
                       pending.days
                   in
                   let slot_count =
                     List.fold_left
                       (fun total (day : Projection.day_feed) ->
                          total + 1 + List.length day.entries)
                       0
                       days
                   in
                   responses
                     [ response
                         ~basis
                         (Feed_loaded
                            { request_generation = pending.generation
                            ; feed =
                                { days
                                ; slot_count
                                ; has_more_days = pending.has_more_days
                                }
                            })
                     ])))
        | Day_page_tree { page; generation }, Page_tree_result result ->
          remember_tree_items t page result.items;
          (match projection_time_context t with
           | Error message -> reject message
           | Ok time_context ->
             (match Projection.timeline_entry_page ~page ~basis ~time_context result with
              | Ok page ->
                responses
                  [ response
                      ~basis
                      (Day_blocks_loaded { request_generation = generation; page })
                  ]
              | Error message -> reject message))
        | Detail_block { generation; block_id = _ }, Block_result root ->
          (match page_by_uuid t root.page with
           | None -> reject "The block page is not retained."
           | Some page ->
             requests
               [ read
                   t
                   (Detail_children { generation; page; root })
                   (Protocol.Get_children
                      { parent = root.uuid; limit = 64; cursor = None })
               ])
        | Find_block_result, Block_result block ->
          (match page_by_uuid t block.page with
           | None -> responses [ response ~basis (Block_found None) ]
           | Some page ->
             (match projection_time_context t with
              | Error message -> reject message
              | Ok time_context ->
                (match
                   Projection.block ~page ~basis ~child_count:0 ~time_context block
                 with
                 | Ok block -> responses [ response ~basis (Block_found (Some block)) ]
                 | Error message -> reject message)))
        | Detail_children { generation; page; root }, Children_result children ->
          remember_block_page t page (Graph.Uuid.to_string root.uuid);
          remember_blocks t page children.items;
          (match projection_time_context t with
           | Error message -> reject message
           | Ok time_context ->
             (match Projection.detail ~page ~basis ~time_context ~root children with
              | Ok detail ->
                responses
                  [ response
                      ~basis
                      (Detail_loaded { request_generation = generation; detail })
                  ]
              | Error message -> reject message))
        | Capture_page command, Page_result graph_page ->
          (match page_of_graph_page graph_page with
           | None -> reject "The target journal page is unavailable."
           | Some page ->
             remember_page t page;
             capture_insert t command page)
        | Capture_create_page { command; page_uuid }, Mutation_result _ ->
          requests
            [ read
                t
                (Capture_page command)
                (Protocol.Get_page { page = Page_by_uuid page_uuid })
            ]
        | Capture_insert { command; page }, Mutation_result _ ->
          capture_status t command page
        | Capture_status { command; page }, Mutation_result _ ->
          request_refresh t page (Captured { block_id = command.block_id })
        | Mutation_refresh { page; refresh }, Mutation_result _ ->
          request_refresh t page refresh
        | Refresh_page_tree { page; refresh }, Page_tree_result result ->
          remember_tree_items t page result.items;
          refresh_response t page refresh basis result
        | Delete_mutation command, Mutation_result success ->
          responses
            [ response
                ~basis
                (Subtree_deleted
                   { block_id = command.block_id
                   ; deleted_count = List.length success.changed_uuids
                   ; parent = None
                   ; timeline_entry_update = None
                   })
            ]
        | _, _ -> reject "The Worker returned an unexpected graph response."))
;;

let abandon t (request : Protocol.request) =
  Hashtbl.remove t.pending (Graph.Uuid.to_string request.request_id)
;;

let reconcile_invalidation t ~request_generation (invalidation : Protocol.invalidation) =
  let already_requested =
    match t.reconciliation_basis with
    | Some basis -> Int64.compare invalidation.basis basis <= 0
    | None -> false
  in
  if Int64.compare invalidation.basis t.basis <= 0 || already_requested
  then empty
  else (
    t.reconciliation_basis <- Some invalidation.basis;
    match t.initial_feed with
    | None -> requests [ read t Graph_info Protocol.Graph_info ]
    | Some feed ->
      submit
        t
        (Journal_graph_request.Load_feed
           { before_day = None
           ; day_limit = feed.day_limit
           ; blocks_per_day = feed.blocks_per_day
           ; slot_limit = feed.slot_limit
           ; request_generation
           }))
;;
