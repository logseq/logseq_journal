module ID = Bonsai_flutter_spec.Id

type rejection =
  | Recovery_only
  | Editing_locked
  | Stale_calendar_generation
  | Invalid_calendar_snapshot
  | Invalid_request of string
  | Storage_unavailable

type startup_failure =
  | Restart_required
  | Configuration_unavailable

type request =
  | Get_status
  | Observe_calendar of
      { generation : int64
      ; local_day : int
      }
  | Capture of
      { calendar_generation : int64
      ; command : Journal_repository.capture
      }
  | Create_child of Journal_repository.create_child
  | Update_source of Journal_repository.update_source
  | Set_task_state of Journal_repository.set_task_state
  | Delete_subtree of Journal_repository.delete_subtree
  | Reconcile of
      { mutation_id : string
      ; block_id : string
      }
  | Find_block of string
  | Load_feed of
      { before_day : int option
      ; day_limit : int
      ; blocks_per_day : int
      ; slot_limit : int
      ; request_generation : int64
      }
  | Load_day_blocks of
      { day : int
      ; after : Journal_repository.block_cursor option
      ; limit : int
      ; request_generation : int64
      }
  | Load_detail of
      { block_id : string
      ; after : Journal_repository.block_cursor option
      ; limit : int
      ; request_generation : int64
      }

type payload =
  | Store_ready of Journal_storage.disposition
  | Status of Journal_storage.state
  | Calendar_observed of int64
  | Block_captured of Journal_repository.block
  | Child_created of
      { child : Journal_repository.block
      ; parent_revision : int
      }
  | Block_updated of Journal_repository.block
  | Update_conflict of Journal_repository.block
  | Subtree_deleted of
      { block_id : string
      ; deleted_count : int
      ; parent : Journal_repository.block option
      }
  | Delete_conflict of Journal_repository.block
  | Reconciled_applied of Journal_repository.block
  | Reconciled_not_applied
  | Reconciled_superseded of Journal_repository.block
  | Block_found of Journal_repository.block option
  | Feed_loaded of
      { request_generation : int64
      ; feed : Journal_repository.feed
      }
  | Day_blocks_loaded of
      { request_generation : int64
      ; page : Journal_repository.block_page
      }
  | Detail_loaded of
      { request_generation : int64
      ; detail : Journal_repository.detail
      }
  | Oversized_source of Journal_repository.Error.oversized_source
  | Startup_failed of startup_failure
  | Rejected of rejection

type response =
  { store_id : string
  ; basis_tx : int
  ; access_mode : Journal_startup.access_mode
  ; calendar : Journal_startup.calendar_snapshot
  ; calendar_generation : int64
  ; local_day : int
  ; payload : payload
  }

type push = Ready of response

type state =
  { storage : Journal_storage.t option
  ; mutable access_mode : Journal_startup.access_mode
  ; mutable mutation_locked : bool
  ; mutable calendar : Journal_startup.calendar_snapshot
  ; mutable calendar_generation : int64
  ; mutable local_day : int
  }

let block_bytes (block : Journal_repository.block) =
  128
  + String.length (Journal_model.id block)
  + String.length (Journal_model.page_id block)
  + String.length (Journal_model.sibling_order block)
  + String.length (Journal_model.source block)
  + String.length (Journal_model.last_mutation_id block)
;;

let page_bytes (page : Journal_repository.page) =
  64 + String.length page.id + String.length page.title
;;

let block_page_bytes (page : Journal_repository.block_page) =
  32 + List.fold_left (fun total block -> total + block_bytes block) 0 page.blocks
;;

let payload_bytes = function
  | Store_ready _
  | Status _
  | Calendar_observed _
  | Reconciled_not_applied
  | Startup_failed _
  | Rejected _ -> 64
  | Block_captured block
  | Block_updated block
  | Update_conflict block
  | Delete_conflict block
  | Reconciled_applied block
  | Reconciled_superseded block -> block_bytes block
  | Subtree_deleted { block_id; parent; _ } ->
    64 + String.length block_id + Option.fold ~none:0 ~some:block_bytes parent
  | Child_created { child; _ } -> 32 + block_bytes child
  | Block_found None -> 32
  | Block_found (Some block) -> block_bytes block
  | Feed_loaded { feed; _ } ->
    64
    + List.fold_left
        (fun total (day : Journal_repository.day_feed) ->
           total
           + page_bytes day.page
           + List.fold_left (fun total block -> total + block_bytes block) 0 day.blocks)
        0
        feed.days
  | Day_blocks_loaded { page; _ } -> block_page_bytes page
  | Detail_loaded { detail; _ } ->
    64 + block_bytes detail.root + block_page_bytes detail.children
  | Oversized_source value -> 64 + String.length value.block_id
;;

let maximum_response_bytes = 256 * 1_024

let response state payload =
  let payload =
    if 128 + payload_bytes payload > maximum_response_bytes
    then Rejected (Invalid_request "Worker response exceeds the application budget")
    else payload
  in
  { store_id = Journal_schema.store_identity
  ; basis_tx =
      (match state.storage with
       | Some storage -> (Journal_storage.current_db storage).max_tx
       | None -> 0)
  ; access_mode = state.access_mode
  ; calendar = state.calendar
  ; calendar_generation = state.calendar_generation
  ; local_day = state.local_day
  ; payload
  }
;;

let estimated_payload_bytes response = 128 + payload_bytes response.payload

let storage_unavailable state =
  state.access_mode <- Journal_startup.Recovery_only;
  response state (Rejected Storage_unavailable)
;;

let repository_failure state error =
  match Journal_repository.Error.oversized_source error with
  | Some oversized ->
    state.mutation_locked <- true;
    response state (Oversized_source oversized)
  | None ->
    response state (Rejected (Invalid_request (Journal_repository.Error.to_string error)))
;;

let persist_block state storage ~block_id ~payload transaction =
  match Journal_storage.transact storage transaction with
  | Error _ -> storage_unavailable state
  | Ok report ->
    (match Journal_repository.find_block report.db_after ~id:block_id with
     | Ok (Some block) -> response state (payload block)
     | Ok None | Error _ -> storage_unavailable state)
;;

let init session (startup : Journal_startup.t) =
  let unavailable failure =
    let state =
      { storage = None
      ; access_mode = Journal_startup.Recovery_only
      ; mutation_locked = false
      ; calendar = startup.initial_calendar
      ; calendar_generation = startup.initial_calendar.generation
      ; local_day = startup.initial_calendar.local_day
      }
    in
    Worker.Session_context.emit
      session
      ~topic:(ID.Worker.Push_topic.of_int 0)
      (Ready (response state (Startup_failed failure)));
    Ok state
  in
  match
    Journal_storage_path.resolve
      ~support_root:startup.Journal_startup.application_support_root
      ~relative_path:Journal_startup.database_relative_path
  with
  | Error _ -> unavailable Configuration_unavailable
  | Ok canonical_path ->
    (match Journal_storage.open_store ~canonical_path with
     | Error error ->
       let failure =
         if Journal_storage.Error.is_path_quarantined error
         then Restart_required
         else Configuration_unavailable
       in
       unavailable failure
     | Ok (storage, disposition) ->
       let state =
         { storage = Some storage
         ; access_mode = startup.access_mode
         ; mutation_locked = false
         ; calendar = startup.initial_calendar
         ; calendar_generation = startup.initial_calendar.generation
         ; local_day = startup.initial_calendar.local_day
         }
       in
       Worker.Session_context.emit
         session
         ~topic:(ID.Worker.Push_topic.of_int 0)
         (Ready (response state (Store_ready disposition)));
       Ok state)
;;

let observe_calendar state generation local_day =
  if Int64.compare generation state.calendar_generation < 0
  then response state (Rejected Stale_calendar_generation)
  else if Int64.equal generation state.calendar_generation && local_day <> state.local_day
  then response state (Rejected Invalid_calendar_snapshot)
  else (
    state.calendar <- { state.calendar with generation; local_day };
    state.calendar_generation <- generation;
    state.local_day <- local_day;
    response state (Calendar_observed generation))
;;

let capture state calendar_generation (command : Journal_repository.capture) =
  match state.storage, state.access_mode with
  | None, _ -> response state (Rejected Storage_unavailable)
  | Some _, _ when state.mutation_locked -> response state (Rejected Editing_locked)
  | Some _, Journal_startup.Recovery_only -> response state (Rejected Recovery_only)
  | Some _, Read_write
    when Int64.compare calendar_generation state.calendar_generation < 0 ->
    response state (Rejected Stale_calendar_generation)
  | Some _, Read_write
    when not (Int64.equal calendar_generation state.calendar_generation) ->
    response state (Rejected Invalid_calendar_snapshot)
  | Some _, Read_write
    when Journal_time.local_day command.creation_time <> state.local_day ->
    response state (Rejected Invalid_calendar_snapshot)
  | Some storage, Read_write ->
    (match
       Journal_repository.prepare_capture (Journal_storage.current_db storage) command
     with
     | Error error ->
       response
         state
         (Rejected (Invalid_request (Journal_repository.Error.to_string error)))
     | Ok (Already_applied block) -> response state (Block_captured block)
     | Ok (Apply transaction) ->
       persist_block
         state
         storage
         ~block_id:command.block_id
         ~payload:(fun block -> Block_captured block)
         transaction)
;;

let create_child state command =
  match state.storage, state.access_mode with
  | None, _ -> response state (Rejected Storage_unavailable)
  | Some _, _ when state.mutation_locked -> response state (Rejected Editing_locked)
  | Some _, Journal_startup.Recovery_only -> response state (Rejected Recovery_only)
  | Some storage, Read_write ->
    (match
       Journal_repository.prepare_create_child
         (Journal_storage.current_db storage)
         command
     with
     | Error error ->
       response
         state
         (Rejected (Invalid_request (Journal_repository.Error.to_string error)))
     | Ok (Child_already_applied child) ->
       (match
          Journal_repository.find_block
            (Journal_storage.current_db storage)
            ~id:command.parent_block_id
        with
        | Ok (Some parent) ->
          response
            state
            (Child_created { child; parent_revision = Journal_model.revision parent })
        | Ok None | Error _ -> response state (Rejected Storage_unavailable))
     | Ok (Create_child transaction) ->
       (match Journal_storage.transact storage transaction with
        | Error _ -> storage_unavailable state
        | Ok report ->
          (match
             ( Journal_repository.find_block report.db_after ~id:command.block_id
             , Journal_repository.find_block report.db_after ~id:command.parent_block_id )
           with
           | Ok (Some child), Ok (Some parent) ->
             response
               state
               (Child_created { child; parent_revision = Journal_model.revision parent })
           | _ -> storage_unavailable state)))
;;

let update_block state ~block_id prepare =
  match state.storage, state.access_mode with
  | None, _ -> response state (Rejected Storage_unavailable)
  | Some _, _ when state.mutation_locked -> response state (Rejected Editing_locked)
  | Some _, Journal_startup.Recovery_only -> response state (Rejected Recovery_only)
  | Some storage, Read_write ->
    (match prepare (Journal_storage.current_db storage) with
     | Error error ->
       response
         state
         (Rejected (Invalid_request (Journal_repository.Error.to_string error)))
     | Ok (Journal_repository.Update_already_applied block) ->
       response state (Block_updated block)
     | Ok (Update_conflict block) -> response state (Update_conflict block)
     | Ok (Update_block transaction) ->
       persist_block
         state
         storage
         ~block_id
         ~payload:(fun block -> Block_updated block)
         transaction)
;;

let delete_subtree state (command : Journal_repository.delete_subtree) =
  match state.storage, state.access_mode with
  | None, _ -> response state (Rejected Storage_unavailable)
  | Some _, _ when state.mutation_locked -> response state (Rejected Editing_locked)
  | Some _, Journal_startup.Recovery_only -> response state (Rejected Recovery_only)
  | Some storage, Read_write ->
    (match
       Journal_repository.prepare_delete_subtree
         (Journal_storage.current_db storage)
         command
     with
     | Error error -> repository_failure state error
     | Ok Journal_repository.Delete_already_applied ->
       response
         state
         (Subtree_deleted
            { block_id = command.block_id; deleted_count = 0; parent = None })
     | Ok (Delete_conflict latest) -> response state (Delete_conflict latest)
     | Ok (Delete_subtree { transaction; deleted_count; parent_block_id }) ->
       (match Journal_storage.transact storage transaction with
        | Error _ -> storage_unavailable state
        | Ok report ->
          (match Journal_repository.find_block report.db_after ~id:command.block_id with
           | Error _ | Ok (Some _) -> storage_unavailable state
           | Ok None ->
             let parent =
               match parent_block_id with
               | None -> Ok None
               | Some parent_id ->
                 (match Journal_repository.find_block report.db_after ~id:parent_id with
                  | Ok (Some parent) -> Ok (Some parent)
                  | Ok None | Error _ -> Error ())
             in
             (match parent with
              | Error () -> storage_unavailable state
              | Ok parent ->
                response
                  state
                  (Subtree_deleted { block_id = command.block_id; deleted_count; parent })))))
;;

let find_block state id =
  match state.storage with
  | None -> response state (Rejected Storage_unavailable)
  | Some storage ->
    (match Journal_repository.find_block (Journal_storage.current_db storage) ~id with
     | Ok block -> response state (Block_found block)
     | Error error -> repository_failure state error)
;;

let reconcile state ~mutation_id ~block_id =
  if not (Journal_validation.is_uuid mutation_id)
  then response state (Rejected (Invalid_request "reconciliation mutation ID is invalid"))
  else (
    match state.storage with
    | None -> response state (Rejected Storage_unavailable)
    | Some storage ->
      (match
         Journal_repository.find_block (Journal_storage.current_db storage) ~id:block_id
       with
       | Error error ->
         response
           state
           (Rejected (Invalid_request (Journal_repository.Error.to_string error)))
       | Ok None -> response state Reconciled_not_applied
       | Ok (Some block)
         when String.equal (Journal_model.last_mutation_id block) mutation_id ->
         response state (Reconciled_applied block)
       | Ok (Some block) -> response state (Reconciled_superseded block)))
;;

let load_feed state ~before_day ~day_limit ~blocks_per_day ~slot_limit ~request_generation
  =
  match state.storage with
  | None -> response state (Rejected Storage_unavailable)
  | Some storage ->
    (match
       Journal_repository.load_feed
         (Journal_storage.current_db storage)
         ~before_day
         ~day_limit
         ~blocks_per_day
         ~slot_limit
     with
     | Ok feed -> response state (Feed_loaded { request_generation; feed })
     | Error error -> repository_failure state error)
;;

let repository_response state request_generation load payload =
  match state.storage with
  | None -> response state (Rejected Storage_unavailable)
  | Some storage ->
    (match load (Journal_storage.current_db storage) with
     | Ok value -> response state (payload request_generation value)
     | Error error -> repository_failure state error)
;;

let handle _context state = function
  | Get_status ->
    let status =
      match state.storage with
      | None -> Journal_storage.Terminal
      | Some storage -> Journal_storage.state storage
    in
    response state (Status status)
  | Observe_calendar { generation; local_day } ->
    observe_calendar state generation local_day
  | Capture { calendar_generation; command } -> capture state calendar_generation command
  | Create_child command -> create_child state command
  | Update_source command ->
    update_block state ~block_id:command.block_id (fun db ->
      Journal_repository.prepare_update_source db command)
  | Set_task_state command ->
    update_block state ~block_id:command.block_id (fun db ->
      Journal_repository.prepare_set_task_state db command)
  | Delete_subtree command -> delete_subtree state command
  | Reconcile { mutation_id; block_id } -> reconcile state ~mutation_id ~block_id
  | Find_block id -> find_block state id
  | Load_feed { before_day; day_limit; blocks_per_day; slot_limit; request_generation } ->
    load_feed state ~before_day ~day_limit ~blocks_per_day ~slot_limit ~request_generation
  | Load_day_blocks { day; after; limit; request_generation } ->
    repository_response
      state
      request_generation
      (fun db -> Journal_repository.load_day_blocks db ~day ~after ~limit)
      (fun request_generation page -> Day_blocks_loaded { request_generation; page })
  | Load_detail { block_id; after; limit; request_generation } ->
    repository_response
      state
      request_generation
      (fun db -> Journal_repository.load_detail db ~block_id ~after ~limit)
      (fun request_generation detail -> Detail_loaded { request_generation; detail })
;;

let shutdown state =
  match state.storage with
  | None -> ()
  | Some storage ->
    ignore (Journal_storage.close storage : (unit, Journal_storage.Error.t) result)
;;

let service =
  Worker.Service.create
    ~push_topic_count:1
    ~concurrency:Worker.Service.Serial
    ~init
    ~handle:(fun context state request -> Ok (handle context state request))
    ~shutdown
    ()
;;
