module Core = Logseq_db_worker_pure_reducer.Core
module Database = Logseq_overlay_db.Database
module Overlay = Logseq_overlay_db.Types
module Protocol = Logseq_db_worker_contract.Protocol
module Graph = Logseq_db_types.Graph_types
module Sync = Logseq_sync_pure_reducer.Core
module Transit = Transit_core.Json
module Transit_codec = Transit_native.Transit.Json

type token_owner =
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; account_generation : int
  }
[@@warning "-69"]

type id_token_request =
  { challenge_id : string
  ; owner : token_owner
  ; epoch : int
  }

type token_entry =
  { owner : token_owner
  ; token : string
  ; reuse_deadline_ns : int64
  }

type token_flight =
  { request : id_token_request
  ; outcome : (string, string) result Eio.Promise.t
  ; resolve : (string, string) result Eio.Promise.u
  }

type id_token_cache =
  { wall_clock_s : unit -> float
  ; monotonic_ns : unit -> int64
  ; request : id_token_request -> unit
  ; lock : Eio.Mutex.t
  ; mutable authenticated_user : string option
  ; mutable entry : token_entry option
  ; mutable flight : token_flight option
  ; mutable next_challenge : int
  ; mutable epoch : int
  ; mutable stopped : bool
  }

let id_token_request_id request = request.challenge_id

let id_token_cache ~wall_clock_s ~monotonic_ns ~request =
  { wall_clock_s
  ; monotonic_ns
  ; request
  ; lock = Eio.Mutex.create ()
  ; authenticated_user = None
  ; entry = None
  ; flight = None
  ; next_challenge = 1
  ; epoch = 0
  ; stopped = false
  }
;;

let token_owner (account : Sync.account_scope) =
  { managed_sync_origin = account.managed_sync_origin
  ; user_id = account.user_id
  ; account_generation = account.account_generation
  }
;;

let base64url_value = function
  | 'A' .. 'Z' as character -> Some (Char.code character - Char.code 'A')
  | 'a' .. 'z' as character -> Some (Char.code character - Char.code 'a' + 26)
  | '0' .. '9' as character -> Some (Char.code character - Char.code '0' + 52)
  | '-' -> Some 62
  | '_' -> Some 63
  | _ -> None
;;

let base64url_decode value =
  let length = String.length value in
  if length = 0 || length mod 4 = 1
  then None
  else (
    let output = Buffer.create (length * 3 / 4) in
    let rec decode offset =
      if offset = length
      then Some (Buffer.contents output)
      else (
        let count = min 4 (length - offset) in
        if count = 1
        then None
        else (
          let decoded = Array.make 4 0 in
          let rec read index =
            if index = count
            then true
            else (
              match base64url_value value.[offset + index] with
              | None -> false
              | Some byte ->
                decoded.(index) <- byte;
                read (index + 1))
          in
          if not (read 0)
          then None
          else (
            Buffer.add_char
              output
              (Char.chr ((decoded.(0) lsl 2) lor (decoded.(1) lsr 4)));
            if count >= 3
            then
              Buffer.add_char
                output
                (Char.chr (((decoded.(1) land 0x0f) lsl 4) lor (decoded.(2) lsr 2)));
            if count = 4
            then
              Buffer.add_char
                output
                (Char.chr (((decoded.(2) land 0x03) lsl 6) lor decoded.(3)));
            decode (offset + count))))
    in
    decode 0)
;;

let token_expiration token =
  if String.length token = 0 || String.length token > 1024 * 1024
  then Error "ID token response is invalid."
  else (
    match String.split_on_char '.' token with
    | [ header; payload; signature ]
      when String.length header > 0 && String.length signature > 0 ->
      (match base64url_decode payload with
       | None -> Error "ID token response is invalid."
       | Some decoded ->
         (try
            match Yojson.Safe.from_string decoded with
            | `Assoc fields ->
              (match List.assoc_opt "exp" fields with
               | Some (`Int value) -> Ok (Float.of_int value)
               | Some (`Intlit value) ->
                 (match Float.of_string_opt value with
                  | Some value -> Ok value
                  | None -> Error "ID token response is invalid.")
               | _ -> Error "ID token response is invalid.")
            | _ -> Error "ID token response is invalid."
          with
          | Yojson.Json_error _ -> Error "ID token response is invalid."))
    | _ -> Error "ID token response is invalid.")
;;

let cancel_token_flight cache message =
  match cache.flight with
  | None -> ()
  | Some flight ->
    cache.flight <- None;
    ignore (Eio.Promise.try_resolve flight.resolve (Error message) : bool)
;;

let clear_id_token_cache cache message =
  cache.entry <- None;
  cache.epoch <- cache.epoch + 1;
  cancel_token_flight cache message
;;

let reconcile_authenticated_user cache ~user_id =
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    if cache.authenticated_user <> user_id
    then (
      cache.authenticated_user <- user_id;
      clear_id_token_cache cache "ID token request is no longer current."))
;;

let reusable_token cache owner =
  match cache.entry with
  | Some entry
    when entry.owner = owner
         && Int64.compare (cache.monotonic_ns ()) entry.reuse_deadline_ns < 0 ->
    Some entry.token
  | Some _ ->
    cache.entry <- None;
    None
  | None -> None
;;

type token_acquisition =
  | Cached_token of string
  | Await_token of (string, string) result Eio.Promise.t
  | Start_token_request of token_flight
  | Token_cache_stopped

let start_token_request cache owner =
  let outcome, resolve = Eio.Promise.create () in
  let request =
    { challenge_id = Printf.sprintf "id-token-%d" cache.next_challenge
    ; owner
    ; epoch = cache.epoch
    }
  in
  cache.next_challenge <- cache.next_challenge + 1;
  let flight = { request; outcome; resolve } in
  cache.flight <- Some flight;
  Start_token_request flight
;;

let acquire_id_token cache ~(account : Sync.account_scope) =
  let owner = token_owner account in
  let acquisition =
    Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
      if cache.stopped
      then Token_cache_stopped
      else (
        (match cache.authenticated_user with
         | Some user_id when not (String.equal user_id owner.user_id) ->
           clear_id_token_cache cache "ID token request is no longer current."
         | None | Some _ -> ());
        cache.authenticated_user <- Some owner.user_id;
        match reusable_token cache owner with
        | Some token -> Cached_token token
        | None ->
          (match cache.flight with
           | Some flight when flight.request.owner = owner -> Await_token flight.outcome
           | Some _ ->
             clear_id_token_cache cache "ID token request is no longer current.";
             start_token_request cache owner
           | None -> start_token_request cache owner)))
  in
  match acquisition with
  | Cached_token token -> Ok token
  | Await_token outcome -> Eio.Promise.await outcome
  | Token_cache_stopped -> Error "ID token cache is stopped."
  | Start_token_request flight ->
    (try cache.request flight.request with
     | _ ->
       Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
         match cache.flight with
         | Some current when current.request = flight.request ->
           cache.flight <- None;
           ignore
             (Eio.Promise.try_resolve current.resolve (Error "ID token is unavailable.")
              : bool)
         | None | Some _ -> ()));
    Eio.Promise.await flight.outcome
;;

let provide_id_token cache request token =
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    match cache.flight with
    | Some flight
      when flight.request = request && request.epoch = cache.epoch && not cache.stopped ->
      cache.flight <- None;
      let result =
        Result.bind (token_expiration token) (fun expiration ->
          let now = cache.wall_clock_s () in
          if Float.compare expiration now <= 0
          then Error "ID token response is expired."
          else (
            let reuse_seconds = min 86_400. (expiration -. now -. 3_600.) in
            if Float.compare reuse_seconds 0. > 0
            then (
              let duration_ns = Int64.of_float (reuse_seconds *. 1_000_000_000.) in
              cache.entry
              <- Some
                   { owner = request.owner
                   ; token
                   ; reuse_deadline_ns = Int64.add (cache.monotonic_ns ()) duration_ns
                   });
            Ok token))
      in
      ignore (Eio.Promise.try_resolve flight.resolve result : bool)
    | None | Some _ -> ())
;;

let reject_id_token cache request _message =
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    match cache.flight with
    | Some flight when flight.request = request ->
      cache.flight <- None;
      ignore
        (Eio.Promise.try_resolve flight.resolve (Error "ID token is unavailable.") : bool)
    | None | Some _ -> ())
;;

let invalidate_id_token cache ~(account : Sync.account_scope) ~token =
  let owner = token_owner account in
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    match cache.entry with
    | Some entry when entry.owner = owner && String.equal entry.token token ->
      cache.entry <- None
    | None | Some _ -> ())
;;

let shutdown_id_token_cache cache =
  Eio.Mutex.use_rw ~protect:true cache.lock (fun () ->
    if not cache.stopped
    then (
      cache.stopped <- true;
      cache.authenticated_user <- None;
      clear_id_token_cache cache "ID token cache is stopped."))
;;

type runtime = { fork : sw:Eio.Switch.t -> (unit -> unit) -> unit }

type sync_runner =
  { submit : Sync.runner_effect -> unit
  ; shutdown : unit -> unit
  ; decrypt_protected_value : Sync.graph_key_handle -> string -> (string, string) result
  ; encrypt_protected_values :
      Sync.graph_key_handle -> string list -> ((string * string) list, string) result
  }

type dependencies =
  { runtime : runtime
  ; config : Logseq_db_worker_contract.Config.t
  ; overlay : Database.dependencies
  ; sync_runner : sync_runner
  ; publish : Core.output -> unit
  }

type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string

type waiter =
  { request : Protocol.request
  ; resolve : Protocol.response Eio.Promise.u
  }

type change_window =
  { id : string
  ; predecessor : string
  ; successor : string
  ; block_uuids : Graph.block_uuid list
  ; page_uuids : Graph.page_uuid list
  ; structure_interests : Protocol.v2_structure_interest list
  }

type database_session =
  { database : Database.t
  ; subscription : Database.subscription
  ; mutable generation : string
  ; mutable next_window : int
  ; mutable acknowledged_through : string
  ; mutable windows : change_window list
  }

type t =
  { sw : Eio.Switch.t
  ; dependencies : dependencies
  ; post : Core.event -> unit
  ; databases : (string, database_session) Hashtbl.t
  ; inspections : (string, Database.mirror_inspection) Hashtbl.t
  ; waiters : (int64, waiter) Hashtbl.t
  ; waiter_lock : Eio.Mutex.t
  ; mutable attached : (string * Sync.graph_scope) option
  ; mutable next_database_id : int64
  ; mutable stopped : bool
  }

let runtime ~fork = Ok { fork }

let sync_runner
      ?(decrypt_protected_value = fun _ _ -> Error "sync decryption is unavailable")
      ?(encrypt_protected_values = fun _ _ -> Error "sync encryption is unavailable")
      ~submit
      ~shutdown
      ()
  =
  { submit; shutdown; decrypt_protected_value; encrypt_protected_values }
;;

let dependencies ~runtime ~config ~overlay ~sync_runner ~publish =
  Ok { runtime; config; overlay; sync_runner; publish }
;;

let create ~sw dependencies ~post =
  ignore dependencies.sync_runner.encrypt_protected_values;
  Ok
    { sw
    ; dependencies
    ; post
    ; databases = Hashtbl.create 4
    ; inspections = Hashtbl.create 4
    ; waiters = Hashtbl.create 32
    ; waiter_lock = Eio.Mutex.create ()
    ; attached = None
    ; next_database_id = 0L
    ; stopped = false
    }
;;

let worker_error ~code message =
  Logseq_db_worker_contract.Error.create ~code ~message ~details:[] |> Result.get_ok
;;

let effect_error message =
  worker_error ~code:Logseq_db_worker_contract.Error.Storage_busy message
;;

let failure request code message =
  Protocol.failed ~request_id:request.Protocol.request_id (worker_error ~code message)
;;

let response request outcome =
  Protocol.V2_response
    { api_version = Protocol.api_version
    ; request_id = request.Protocol.request_id
    ; outcome
    }
;;

let task_status_to_protocol = function
  | Overlay.Todo -> Protocol.V2_todo
  | Doing -> V2_doing
  | In_review -> V2_in_review
  | Now -> V2_now
  | Done -> V2_done
  | Canceled -> V2_canceled
  | Backlog -> V2_backlog
  | Waiting -> V2_waiting
  | Later -> V2_later
;;

let task_status_of_protocol = function
  | Protocol.V2_todo -> Overlay.Todo
  | V2_doing -> Doing
  | V2_in_review -> In_review
  | V2_now -> Now
  | V2_done -> Done
  | V2_canceled -> Canceled
  | V2_backlog -> Backlog
  | V2_waiting -> Waiting
  | V2_later -> Later
;;

let block_record (value : Overlay.block_record) : Protocol.v2_block_record =
  { block = value.block
  ; task_status = Option.map task_status_to_protocol value.task_status
  ; rendered_page_title = value.rendered_page_title
  }
;;

let revision_scope_to_protocol = function
  | Overlay.Children_revision parent -> Protocol.V2_children_revision parent
;;

let structure_interest_to_protocol = function
  | Overlay.Children_interest parent -> Protocol.V2_children_interest parent
  | Page_tree_interest page -> V2_page_tree_interest page
  | Journal_index_interest -> V2_journal_index_interest
;;

let resync_reason = function
  | Overlay.Change_limit_exceeded -> "changeLimitExceeded"
  | Dispatcher_retention_exceeded -> "dispatcherRetentionExceeded"
  | Generation_changed -> "generationChanged"
  | Publication_recovered -> "publicationRecovered"
;;

let publish_projection_change t session = function
  | Overlay.Exact
      { generation
      ; before_revision
      ; after_revision
      ; block_uuids
      ; page_uuids
      ; structure_interests
      } ->
    let generation = Overlay.Generation.to_string generation in
    if not (String.equal generation session.generation)
    then (
      session.generation <- generation;
      session.windows <- [];
      session.next_window <- 1;
      session.acknowledged_through <- "change-window:v1:0");
    let id = Printf.sprintf "change-window:v1:%d" session.next_window in
    session.next_window <- session.next_window + 1;
    session.windows
    <- session.windows
       @ [ { id
           ; predecessor = Overlay.Projection_revision.to_string before_revision
           ; successor = Overlay.Projection_revision.to_string after_revision
           ; block_uuids
           ; page_uuids
           ; structure_interests =
               List.map structure_interest_to_protocol structure_interests
           }
         ];
    t.post
      (Core.Projection_push
         (Protocol.V2_changes_available
            { api_version = Protocol.api_version; generation; through = id }))
  | Overlay.Projection_resync_required { generation; reason; _ } ->
    let generation = Overlay.Generation.to_string generation in
    if not (String.equal generation session.generation) then session.next_window <- 1;
    session.generation <- generation;
    session.windows <- [];
    session.acknowledged_through
    <- Printf.sprintf "change-window:v1:%d" (session.next_window - 1);
    t.post
      (Core.Projection_push
         (Protocol.V2_resync_required_push
            { api_version = Protocol.api_version
            ; generation
            ; reason = resync_reason reason
            }))
;;

let close_database_by_id t database_id =
  match Hashtbl.find_opt t.databases database_id with
  | None -> Ok ()
  | Some session ->
    Database.unlisten session.subscription;
    let result = Database.close session.database in
    Hashtbl.remove t.databases database_id;
    Result.map_error
      (fun _ -> effect_error "The overlay database failed to close.")
      result
;;

let close_attached t =
  match t.attached with
  | None -> Ok ()
  | Some (database_id, _) ->
    t.attached <- None;
    close_database_by_id t database_id
;;

let overlay_scope_of_protocol = function
  | Protocol.V2_children_scope parent -> Overlay.Children_revision parent
;;

let parse_preconditions (value : Protocol.v2_preconditions) =
  let rec blocks reversed = function
    | [] -> Ok (List.rev reversed)
    | (uuid, revision) :: rest ->
      (match Overlay.Block_state_revision.of_string revision with
       | Error message -> Error message
       | Ok revision -> blocks ((uuid, revision) :: reversed) rest)
  in
  let rec pages reversed = function
    | [] -> Ok (List.rev reversed)
    | (uuid, revision) :: rest ->
      (match Overlay.Page_state_revision.of_string revision with
       | Error message -> Error message
       | Ok revision -> pages ((uuid, revision) :: reversed) rest)
  in
  let rec scopes reversed = function
    | [] -> Ok (List.rev reversed)
    | (scope, revision) :: rest ->
      (match Overlay.Scope_revision.of_string revision with
       | Error message -> Error message
       | Ok revision ->
         scopes ((overlay_scope_of_protocol scope, revision) :: reversed) rest)
  in
  Result.bind (blocks [] value.blocks) (fun blocks ->
    Result.bind (pages [] value.pages) (fun pages ->
      Result.bind (scopes [] value.scopes) (fun scopes ->
        Database.write_precondition ~blocks ~pages ~scopes
        |> Result.map_error (fun _ -> "duplicate write precondition"))))
;;

let rec block_tree (value : Protocol.v2_block_tree) : Overlay.block_tree =
  { uuid = value.uuid
  ; title = value.title
  ; children = List.map block_tree value.children
  }
;;

let local_mutation = function
  | Protocol.V2_save_block { mutation_id; block; title; preconditions } ->
    Ok (preconditions, Overlay.Save_block { mutation_id; block; title })
  | V2_insert_blocks { mutation_id; parent; roots = [ root ]; preconditions } ->
    Ok
      ( preconditions
      , Overlay.Insert_blocks { mutation_id; parent; tree = block_tree root } )
  | V2_insert_blocks _ -> Error "insertBlocks requires exactly one root"
  | V2_delete_blocks { mutation_id; root; preconditions } ->
    Ok (preconditions, Overlay.Delete_blocks { mutation_id; root })
  | V2_create_journal_page { mutation_id; page; journal_day; title; preconditions } ->
    Ok
      ( preconditions
      , Overlay.Create_journal_page { mutation_id; page; journal_day; title } )
  | V2_set_task_status { mutation_id; block; status; preconditions } ->
    Ok
      ( preconditions
      , Overlay.Set_task_status
          { mutation_id; block; status = task_status_of_protocol status } )
  | V2_clear_task_status { mutation_id; block; preconditions } ->
    Ok (preconditions, Overlay.Clear_task_status { mutation_id; block })
  | V2_graph_info
  | V2_inspect_admission
  | V2_list_journals _
  | V2_get_page _
  | V2_get_block _
  | V2_get_children _
  | V2_get_page_tree _
  | V2_pull_changes _
  | V2_ack_changes _ -> Error "not a local mutation"
;;

let local_status = function
  | Overlay.Applied -> Protocol.V2_applied
  | No_change -> V2_no_change
  | Already_applied -> V2_already_applied
;;

let committed_outcome (commit : Overlay.local_commit) =
  Protocol.V2_mutation_committed
    { mutation_id = commit.mutation_id
    ; status = local_status commit.status
    ; generation = Overlay.Generation.to_string commit.generation
    ; before_projection_revision =
        Overlay.Projection_revision.to_string commit.before_projection_revision
    ; after_projection_revision =
        Overlay.Projection_revision.to_string commit.after_projection_revision
    }
;;

let execute_mutation database request command =
  match local_mutation command with
  | Error message -> failure request Unsupported_semantics message
  | Ok (raw_preconditions, mutation) ->
    (match parse_preconditions raw_preconditions with
     | Error message -> failure request Conflict message
     | Ok expected ->
       (match Database.commit_local database ~expected mutation with
        | Error
            ( Overlay.Local_commit_busy
            | Local_commit_persistence_failed _
            | Local_commit_fatal_state _ ) ->
          failure request Storage_busy "The mutation could not be stored."
        | Error _ -> failure request Conflict "The mutation precondition did not match."
        | Ok (Overlay.Local_existing (Overlay.Existing_applied commit)) ->
          response request (committed_outcome commit)
        | Ok (Local_existing _) ->
          failure request Conflict "The mutation ID already has a terminal outcome."
        | Ok (Local_committed commit) -> response request (committed_outcome commit)))
;;

let inspect_admission database request =
  match Database.inspect_admission database with
  | Error _ -> failure request Closed_session "Admission information is unavailable."
  | Ok inspection ->
    response
      request
      (Protocol.V2_admission_outcome
         { active_records = inspection.active_records
         ; active_bytes = inspection.active_bytes
         ; protected_wire_bytes = inspection.protected_wire_bytes
         ; retained_origin_evidence_bytes = inspection.retained_origin_evidence_bytes
         ; maximum_records = inspection.maximum_records
         ; maximum_bytes = inspection.maximum_bytes
         })
;;

let read_failure request = function
  | Overlay.Stale_read_cursor ->
    failure request Stale_read_cursor "The read continuation is no longer current."
  | Invalid_read_request message -> failure request Invalid_request message
  | Read_limit_exceeded ->
    failure request Response_too_large "The read exceeded its resource limit."
  | Database_closed | Snapshot_released | Snapshot_generation_invalidated ->
    failure request Closed_session "The read snapshot is no longer available."
  | Fatal_read_state message -> failure request Corrupt_storage message
;;

let read_snapshot database request command =
  match Database.current_snapshot database with
  | Error _ -> failure request Closed_session "The graph snapshot is unavailable."
  | Ok snapshot ->
    Fun.protect
      ~finally:(fun () -> Database.release_snapshot snapshot)
      (fun () ->
         match command with
         | Protocol.V2_graph_info ->
           (match Database.graph_info snapshot with
            | Error _ -> failure request Corrupt_storage "Graph info is unavailable."
            | Ok info ->
              let limits = info.Overlay.limits in
              response
                request
                (Protocol.V2_graph_info_outcome
                   { graph_uuid = info.graph_uuid
                   ; graph_name = info.graph_name
                   ; schema = info.schema
                   ; admission_facts = info.admission_facts
                   ; limits =
                       { response_budget_bytes = limits.response_budget_bytes
                       ; outbox_max_records = limits.outbox_max_records
                       ; outbox_max_bytes = limits.outbox_max_bytes
                       ; change_max_items = limits.change_max_items
                       ; change_max_bytes = limits.change_max_bytes
                       ; dispatcher_capacity = limits.dispatcher_capacity
                       ; wire_batch_max_bytes = limits.wire_batch_max_bytes
                       }
                   ; generation = Overlay.Generation.to_string info.version.generation
                   ; projection_revision =
                       Overlay.Projection_revision.to_string
                         info.version.projection_revision
                   }))
         | V2_inspect_admission ->
           failure request Invalid_request "The command is not a snapshot read."
         | V2_list_journals { from_day; through_day; limit; cursor; _ } ->
           (match
              Database.get_journals snapshot ~from_day ~through_day ~limit ~cursor
            with
            | Error error -> read_failure request error
            | Ok result ->
              let items =
                result.items
                |> List.map (fun (item : Overlay.journal_item) ->
                  Protocol.
                    { page = item.page.page
                    ; journal_day = item.journal_day
                    ; revision = Overlay.Page_state_revision.to_string item.revision
                    })
              in
              response
                request
                (Protocol.V2_journals_outcome { items; next_cursor = result.next_cursor }))
         | V2_get_page { page; _ } ->
           (match Database.get_pages snapshot [ page ] with
            | Ok [ Overlay.Present_page { value; revision } ] ->
              response
                request
                (Protocol.V2_page_outcome
                   (V2_present_page
                      { page = value.page
                      ; revision = Overlay.Page_state_revision.to_string revision
                      }))
            | Ok [ Missing_page { uuid; revision } ] ->
              response
                request
                (Protocol.V2_page_outcome
                   (V2_missing_page
                      { uuid; revision = Overlay.Page_state_revision.to_string revision }))
            | Ok _ | Error _ -> failure request Corrupt_storage "The page lookup failed.")
         | V2_get_block { block; _ } ->
           (match Database.get_blocks snapshot [ block ] with
            | Ok [ Overlay.Present_block { value; revision } ] ->
              response
                request
                (Protocol.V2_block_outcome
                   (V2_present_block
                      { value = block_record value
                      ; revision = Overlay.Block_state_revision.to_string revision
                      }))
            | Ok [ Missing_block { uuid; revision } ] ->
              response
                request
                (Protocol.V2_block_outcome
                   (V2_missing_block
                      { uuid; revision = Overlay.Block_state_revision.to_string revision }))
            | Ok _ | Error _ -> failure request Corrupt_storage "The block lookup failed.")
         | V2_get_children { parent; limit; cursor; _ } ->
           (match
              Database.get_structure snapshot (Overlay.Children { parent; limit; cursor })
            with
            | Ok
                (Overlay.Children_result
                   { parent; revision_scope; scope_revision; items; next_cursor }) ->
              response
                request
                (Protocol.V2_children_outcome
                   { parent
                   ; revision_scope = revision_scope_to_protocol revision_scope
                   ; scope_revision = Overlay.Scope_revision.to_string scope_revision
                   ; items =
                       List.map
                         (fun (item : Overlay.child_member) ->
                            Protocol.
                              { value = block_record item.Overlay.block
                              ; revision =
                                  Overlay.Block_state_revision.to_string item.revision
                              })
                         items
                   ; next_cursor
                   })
            | Error error -> read_failure request error
            | Ok (Page_tree_result _) ->
              failure request Invalid_request "The children query returned a page tree.")
         | V2_get_page_tree { page; maximum_depth; limit; cursor; _ } ->
           (match
              Database.get_structure
                snapshot
                (Overlay.Page_tree { page; maximum_depth; limit; cursor })
            with
            | Ok (Overlay.Page_tree_result { page; maximum_depth; items; next_cursor }) ->
              response
                request
                (Protocol.V2_page_tree_outcome
                   { page
                   ; maximum_depth
                   ; items =
                       List.map
                         (fun (item : Overlay.tree_member) ->
                            Protocol.
                              { value = block_record item.Overlay.block
                              ; revision =
                                  Overlay.Block_state_revision.to_string item.revision
                              ; depth = item.depth
                              ; parent = item.parent
                              })
                         items
                   ; next_cursor
                   })
            | Error error -> read_failure request error
            | Ok (Children_result _) ->
              failure request Invalid_request "The page-tree query returned children.")
         | V2_save_block _
         | V2_insert_blocks _
         | V2_delete_blocks _
         | V2_create_journal_page _
         | V2_set_task_status _
         | V2_clear_task_status _
         | V2_pull_changes _
         | V2_ack_changes _ ->
           failure request Invalid_request "The command is not a snapshot read.")
;;

let windows_after session cursor =
  if String.equal cursor session.acknowledged_through
  then Some session.windows
  else (
    let rec drop = function
      | [] -> None
      | window :: rest -> if String.equal window.id cursor then Some rest else drop rest
    in
    drop session.windows)
;;

let cursor_resync session request reason =
  response
    request
    (Protocol.V2_resync_required { generation = session.generation; reason })
;;

let pull_changes session request generation after limit =
  if not (String.equal generation session.generation)
  then cursor_resync session request "generationChanged"
  else (
    let windows =
      match after with
      | None -> Some session.windows
      | Some cursor -> windows_after session cursor
    in
    match windows with
    | None -> cursor_resync session request "changeCursorUnavailable"
    | Some windows ->
      let rec take count reversed = function
        | _ when count = 0 -> List.rev reversed
        | [] -> List.rev reversed
        | value :: rest -> take (count - 1) (value :: reversed) rest
      in
      let selected = take (max 0 limit) [] windows in
      let through =
        match List.rev selected with
        | window :: _ -> window.id
        | [] -> Option.value after ~default:session.acknowledged_through
      in
      let next =
        if List.length selected < List.length windows then Some through else None
      in
      response
        request
        (Protocol.V2_changes
           { generation
           ; from_exclusive = after
           ; through
           ; next
           ; windows =
               List.map
                 (fun (window : change_window) ->
                    Protocol.
                      { id = window.id
                      ; predecessor = window.predecessor
                      ; successor = window.successor
                      ; block_uuids = window.block_uuids
                      ; page_uuids = window.page_uuids
                      ; structure_interests = window.structure_interests
                      })
                 selected
           }))
;;

let acknowledge_changes session request generation through =
  if not (String.equal generation session.generation)
  then cursor_resync session request "generationChanged"
  else (
    match windows_after session through with
    | None -> cursor_resync session request "changeCursorUnavailable"
    | Some windows ->
      session.windows <- windows;
      session.acknowledged_through <- through;
      response request (Protocol.V2_changes_acknowledged { generation; through }))
;;

let execute_database session request =
  match request.Protocol.command with
  | Protocol.V2_pull_changes { generation; after; limit } ->
    pull_changes session request generation after limit
  | V2_ack_changes { generation; through } ->
    acknowledge_changes session request generation through
  | V2_inspect_admission -> inspect_admission session.database request
  | ( V2_save_block _
    | V2_insert_blocks _
    | V2_delete_blocks _
    | V2_create_journal_page _
    | V2_set_task_status _
    | V2_clear_task_status _ ) as command ->
    execute_mutation session.database request command
  | command -> read_snapshot session.database request command
;;

let sync_result ?event ?(lifecycle = Core.Lifecycle_unchanged) () =
  Core.{ event; lifecycle }
;;

let attached_session t scope =
  match t.attached with
  | Some (database_id, attached_scope) when attached_scope = scope ->
    Hashtbl.find_opt t.databases database_id
  | Some _ | None -> None
;;

let protected_envelope (iv, ciphertext) =
  Transit_codec.to_string (Transit.Array [ Transit.Binary iv; Transit.Binary ciphertext ])
;;

let protect_request t key request =
  match key with
  | None -> Error (effect_error "The graph key is unavailable for protected values.")
  | Some key ->
    let plaintexts = Database.protection_plaintexts request in
    let raw = List.map snd plaintexts in
    (match t.dependencies.sync_runner.encrypt_protected_values key raw with
     | Error message -> Error (effect_error message)
     | Ok encrypted ->
       let encrypted =
         List.map2
           (fun (id, _) value -> id, protected_envelope value)
           plaintexts
           encrypted
       in
       Ok (request, encrypted))
;;

let unprotect_request t key request =
  match key with
  | None -> Error (effect_error "The graph key is unavailable for protected values.")
  | Some key ->
    let rec decrypt reversed = function
      | [] -> Ok (List.rev reversed)
      | (id, ciphertext) :: rest ->
        (match t.dependencies.sync_runner.decrypt_protected_value key ciphertext with
         | Error message -> Error (effect_error message)
         | Ok plaintext -> decrypt ((id, plaintext) :: reversed) rest)
    in
    (match decrypt [] (Database.unprotection_ciphertexts request) with
     | Error _ as error -> error
     | Ok plaintexts -> Ok (request, plaintexts))
;;

let authoritative_transition_error = function
  | Overlay.Authoritative_database_closed -> "authoritative database closed"
  | Authoritative_sync_token_conflict -> "authoritative sync token conflict"
  | Authoritative_cursor_discontinuous -> "authoritative cursor discontinuous"
  | Authoritative_checksum_mismatch -> "authoritative checksum mismatch"
  | Authoritative_crypto_required -> "authoritative crypto required"
  | Authoritative_crypto_unexpected -> "authoritative crypto unexpected"
  | Authoritative_crypto_error _ -> "authoritative crypto result invalid"
  | Authoritative_decode_failed message -> "authoritative decode failed: " ^ message
  | Authoritative_origin_unresolved -> "authoritative origin unresolved"
  | Authoritative_preparation_consumed -> "authoritative preparation consumed"
  | Authoritative_prepare_busy -> "authoritative preparation busy"
  | Authoritative_integrity_failure message ->
    "authoritative integrity failure: " ^ message
  | Authoritative_commit_database_closed -> "authoritative database closed at commit"
  | Authoritative_commit_token_conflict -> "authoritative commit token conflict"
  | Authoritative_commit_generation_invalidated ->
    "authoritative commit generation invalidated"
  | Authoritative_commit_busy -> "authoritative commit busy"
  | Authoritative_commit_persistence_failed message ->
    "authoritative commit persistence failed: " ^ message
  | Authoritative_commit_fatal_state message ->
    "authoritative commit fatal state: " ^ message
;;

let handle_sync_worker_effect t = function
  | Sync.Inspect_mirror request ->
    (match
       Database.inspect_mirror
         ~application_support_directory:
           t.dependencies.config.application_support_directory
         ~graph_id:request.graph.graph_id
     with
     | Error _ -> Error (effect_error "The overlay mirror inspection failed.")
     | Ok inspection ->
       Hashtbl.replace
         t.inspections
         (Graph.Uuid.to_string request.graph.graph_id)
         inspection;
       (match Database.mirror_presence inspection with
        | Overlay.Absent _ ->
          Ok (sync_result ~event:(Sync.Mirror_inspected (Mirror_absent request.scope)) ())
        | Available _ ->
          Ok (sync_result ~event:(Sync.Mirror_inspected (Mirror_available request)) ())))
  | Activate_snapshot request ->
    let key = Graph.Uuid.to_string request.scope.graph_id in
    (match Hashtbl.find_opt t.inspections key with
     | None -> Error (effect_error "The snapshot mirror inspection is stale.")
     | Some inspection ->
       let cursor =
         Overlay.Server_cursor.of_string
           (Printf.sprintf "server-cursor:v1:%d" request.applied_server_t)
         |> Result.get_ok
       in
       (match
          Database.prepare_snapshot_activation
            t.dependencies.overlay
            inspection
            ~path:(Sync.staged_artifact_path request.artifact)
            ~applied_server_cursor:cursor
            ~expected_checksum:None
            ~expected_rows:(Sync.staged_artifact_expected_rows request.artifact)
        with
        | Error _ -> Error (effect_error "The snapshot activation could not start.")
        | Ok prepared ->
          Fun.protect
            ~finally:(fun () -> Database.cancel_snapshot_activation prepared)
            (fun () ->
               let rec supply () =
                 match Database.next_snapshot_unprotection_batch prepared with
                 | Error _ -> Error (effect_error "The snapshot crypto request failed.")
                 | Ok None -> Ok ()
                 | Ok (Some crypto_request) ->
                   let ciphertexts = Database.unprotection_ciphertexts crypto_request in
                   let plaintexts =
                     match request.key with
                     | None -> Ok ciphertexts
                     | Some graph_key ->
                       let rec decrypt reversed = function
                         | [] -> Ok (List.rev reversed)
                         | (id, ciphertext) :: rest ->
                           (match
                              t.dependencies.sync_runner.decrypt_protected_value
                                graph_key
                                ciphertext
                            with
                            | Error message -> Error message
                            | Ok plaintext -> decrypt ((id, plaintext) :: reversed) rest)
                       in
                       decrypt [] ciphertexts
                   in
                   (match plaintexts with
                    | Error message -> Error (effect_error message)
                    | Ok plaintexts ->
                      (match
                         Database.supply_snapshot_unprotection_batch
                           prepared
                           ~request:crypto_request
                           ~plaintexts
                       with
                       | Error _ -> Error (effect_error "Snapshot crypto supply failed.")
                       | Ok () -> supply ()))
               in
               match supply () with
               | Error error -> Error error
               | Ok () ->
                 (match Database.commit_snapshot_activation prepared with
                  | Error _ -> Error (effect_error "Snapshot activation did not commit.")
                  | Ok inspection ->
                    Hashtbl.replace t.inspections key inspection;
                    Ok
                      (sync_result
                         ~event:(Sync.Snapshot_activated { scope = request.scope })
                         ())))))
  | Delete_mirror request ->
    let key = Graph.Uuid.to_string request.graph_id in
    (match Hashtbl.find_opt t.inspections key with
     | None -> Error (effect_error "The mirror deletion inspection is unavailable.")
     | Some inspection ->
       (match Database.delete_mirror inspection with
        | Error _ -> Error (effect_error "The overlay mirror could not be deleted.")
        | Ok _ ->
          Hashtbl.remove t.inspections key;
          Ok (sync_result ~event:(Sync.Mirror_deleted (request, Ok ())) ())))
  | Attach_graph request ->
    ignore (close_attached t);
    let key = Graph.Uuid.to_string request.graph.graph_id in
    (match Hashtbl.find_opt t.inspections key with
     | None -> Error (effect_error "The graph attachment inspection is stale.")
     | Some inspection ->
       (match
          Database.open_
            ~sw:t.sw
            t.dependencies.overlay
            inspection
            ~graph_name:request.graph.name
        with
        | Error _ -> Error (effect_error "The overlay graph could not be opened.")
        | Ok database ->
          (match Database.listen database with
           | Error _ ->
             ignore (Database.close database);
             Error (effect_error "The overlay change listener could not start.")
           | Ok (subscription, predecessor) ->
             let version = Database.snapshot_version predecessor in
             Database.release_snapshot predecessor;
             let database_id = "managed-" ^ Int64.to_string t.next_database_id in
             t.next_database_id <- Int64.succ t.next_database_id;
             let session =
               { database
               ; subscription
               ; generation = Overlay.Generation.to_string version.generation
               ; next_window = 1
               ; acknowledged_through = "change-window:v1:0"
               ; windows = []
               }
             in
             Hashtbl.replace t.databases database_id session;
             t.attached <- Some (database_id, request.scope);
             (match
                Database.activate_subscription subscription ~notify:(fun change ->
                  publish_projection_change t session change)
              with
              | Error _ ->
                ignore (close_database_by_id t database_id);
                Error (effect_error "The overlay change listener could not activate.")
              | Ok () ->
                let sync = Database.inspect_sync database in
                let opened =
                  Core.database_opened ~database_id ~graph_id:request.graph.graph_id
                in
                (match sync with
                 | Error _ ->
                   ignore (close_database_by_id t database_id);
                   Error (effect_error "The overlay Sync view is unavailable.")
                 | Ok sync ->
                   Ok
                     (sync_result
                        ~event:(Sync.Graph_attached { scope = request.scope; sync })
                        ~lifecycle:
                          (Core.Lifecycle_opened (opened, request.scope.graph_generation))
                        ()))))))
  | Detach_graph scope ->
    let closed =
      match t.attached with
      | Some (_, attached) when attached = scope -> close_attached t
      | None -> Ok ()
      | Some _ -> Error (effect_error "The graph close scope is stale.")
    in
    Result.map
      (fun () ->
         sync_result
           ~event:(Sync.Graph_detached (scope, Ok ()))
           ~lifecycle:(Core.Lifecycle_closed scope.graph_generation)
           ())
      closed
  | Reset_managed_account account ->
    let lifecycle =
      match t.attached with
      | Some (_, scope) when scope.account = account ->
        ignore (close_attached t);
        Core.Lifecycle_closed scope.graph_generation
      | Some _ | None -> Core.Lifecycle_unchanged
    in
    Ok (sync_result ~lifecycle ())
  | Inspect_sync scope ->
    (match attached_session t scope with
     | None -> Error (effect_error "The overlay database is unavailable.")
     | Some session ->
       (match Database.inspect_sync session.database with
        | Error _ -> Error (effect_error "The overlay Sync view is unavailable.")
        | Ok sync -> Ok (sync_result ~event:(Sync.Sync_inspected { scope; sync }) ())))
  | Apply_outbox_transition request ->
    (match attached_session t request.scope with
     | None -> Error (effect_error "The overlay database is unavailable.")
     | Some session ->
       (match
          Database.begin_outbox_transition
            session.database
            ~expected:request.expected
            request.transition
        with
        | Error _ -> Error (effect_error "The overlay outbox transition was rejected.")
        | Ok (prepared, crypto) ->
          let encrypted =
            match crypto with
            | None -> Ok None
            | Some crypto -> Result.map Option.some (protect_request t request.key crypto)
          in
          (match encrypted with
           | Error error -> Error error
           | Ok encrypted ->
             (match
                Database.apply_outbox_transition session.database prepared ~encrypted
              with
              | Error _ -> Error (effect_error "The overlay outbox transition failed.")
              | Ok commit ->
                (match Database.inspect_sync session.database with
                 | Error _ -> Error (effect_error "The overlay Sync view is unavailable.")
                 | Ok sync ->
                   Ok
                     (sync_result
                        ~event:
                          (Sync.Outbox_transition_applied
                             { scope = request.scope; commit; sync })
                        ()))))))
  | Apply_authoritative_batch request ->
    (match attached_session t request.scope.graph with
     | None -> Error (effect_error "The overlay database is unavailable.")
     | Some session ->
       (match Database.inspect_sync session.database with
        | Error _ -> Error (effect_error "The overlay Sync view is unavailable.")
        | Ok sync ->
          (match
             Database.begin_authoritative
               session.database
               ~expected:(Overlay.sync_view_token sync)
               request.input
           with
           | Error _ -> Error (effect_error "The authoritative transition was rejected.")
           | Ok (prepared, crypto) ->
             let decrypted =
               match crypto with
               | None -> Ok None
               | Some crypto ->
                 Result.map Option.some (unprotect_request t request.key crypto)
             in
             (match decrypted with
              | Error error -> Error error
              | Ok decrypted ->
                (match
                   Database.apply_authoritative session.database prepared ~decrypted
                 with
                 | Error error ->
                   Error (effect_error (authoritative_transition_error error))
                 | Ok (Database.Authoritative_deferred defer) ->
                   Ok
                     (sync_result
                        ~event:
                          (Sync.Authoritative_batch_deferred
                             { scope = request.scope.graph; defer })
                        ())
                 | Ok (Authoritative_applied commit) ->
                   (match Database.inspect_sync session.database with
                    | Error _ ->
                      Error (effect_error "The overlay Sync view is unavailable.")
                    | Ok sync ->
                      Ok
                        (sync_result
                           ~event:
                             (Sync.Authoritative_batch_applied
                                { scope = request.scope.graph; commit; sync })
                           ())))))))
;;

let run_request t (type a) (request : a Core.runner_request)
  : (a, Core.effect_error) result
  =
  match request with
  | Core.Execute_request { database; request } ->
    (match Hashtbl.find_opt t.databases (Core.database_handle_id database) with
     | None -> Error (effect_error "The overlay database is unavailable.")
     | Some session -> Ok (execute_database session request))
  | Close_database database -> close_database_by_id t (Core.database_handle_id database)
  | Handle_sync_worker_effect worker_effect -> handle_sync_worker_effect t worker_effect
;;

let complete t (Core.Request (ticket, request)) =
  match request with
  | Core.Execute_request _ ->
    let result = run_request t request in
    t.post (Core.Runner_completed (Core.Execute_request_completed (ticket, result)))
  | Close_database _ ->
    let result = run_request t request in
    t.post (Core.Runner_completed (Core.Close_database_completed (ticket, result)))
  | Handle_sync_worker_effect _ ->
    let result = run_request t request in
    t.post (Core.Runner_completed (Core.Sync_worker_effect_completed (ticket, result)))
;;

let submit t = function
  | Core.Run_worker request ->
    if not t.stopped
    then t.dependencies.runtime.fork ~sw:t.sw (fun () -> complete t request)
  | Run_sync sync_effect ->
    if not t.stopped then t.dependencies.sync_runner.submit sync_effect
  | Publish output -> if not t.stopped then t.dependencies.publish output
;;

let await_reply t ~id ~request ~post =
  let promise, resolve = Eio.Promise.create () in
  let key = Core.request_id_to_int64 id in
  Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () ->
    Hashtbl.replace t.waiters key { request; resolve });
  post ();
  let response = Eio.Promise.await promise in
  Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () -> Hashtbl.remove t.waiters key);
  response
;;

let submit t instruction =
  match instruction with
  | Core.Publish (Reply (id, response)) ->
    let key = Core.request_id_to_int64 id in
    Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () ->
      match Hashtbl.find_opt t.waiters key with
      | None -> ()
      | Some waiter -> Eio.Promise.resolve waiter.resolve response)
  | instruction -> submit t instruction
;;

let shutdown t =
  if not t.stopped
  then (
    t.stopped <- true;
    ignore (close_attached t);
    Hashtbl.iter (fun id _ -> ignore (close_database_by_id t id)) t.databases;
    t.dependencies.sync_runner.shutdown ();
    Eio.Mutex.use_rw ~protect:true t.waiter_lock (fun () ->
      Hashtbl.iter
        (fun _ waiter ->
           let response = failure waiter.request Closed_session "The Worker stopped." in
           Eio.Promise.resolve waiter.resolve response)
        t.waiters;
      Hashtbl.clear t.waiters))
;;
