module Core = Logseq_db_worker_pure_reducer.Core
module Sync = Logseq_sync_pure_reducer.Core
module Config = Logseq_db_worker.Config
module Protocol = Logseq_db_worker.Protocol

let uuid value = Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok

let worker_config () =
  Config.create
    ~application_support_directory:"/tmp/logseq-db-worker-reducer-contract"
    ~target:(Managed_sync { base_url = "https://api.logseq.io" })
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:Protocol.maximum_response_bytes
    ~default_page_size:Protocol.default_page_size
  |> Result.get_ok
;;

let sync_config () =
  let limits =
    Sync.limits
      ~maximum_response_bytes:Protocol.maximum_response_bytes
      ~maximum_artifact_bytes:(1024 * 1024 * 1024)
      ~submission_batch_size:32
    |> Result.get_ok
  in
  Sync.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits
  |> Result.get_ok
;;

let initial () =
  Core.config ~worker:(worker_config ()) ~sync:(sync_config ())
  |> Core.initial
  |> Result.get_ok
;;

let graph_info_request () =
  Protocol.
    { api_version
    ; request_id = uuid "10000000-0000-4000-8000-000000000001"
    ; command = V2_graph_info
    }
;;

let test_managed_worker_starts_without_local_open () =
  let transition = Core.step (initial ()) Core.Start in
  Alcotest.check Alcotest.int "no local open effects" 0 (List.length transition.effects);
  Alcotest.check
    Alcotest.bool
    "graph starts closed"
    true
    ((Core.view transition.next).graph.phase = Core.Graph_closed)
;;

let test_closed_graph_request_replies_once () =
  let id = Core.request_id_of_int64 1L in
  let transition =
    Core.step (initial ()) (Core.Graph_request { id; request = graph_info_request () })
  in
  let replies =
    List.filter
      (function
        | Core.Publish (Core.Reply (actual, _)) -> Core.equal_request_id actual id
        | Run_worker _
        | Run_sync _
        | Run_asset _
        | Run_upload _
        | Read_uploads _
        | Close_asset_scope _
        | Publish _ -> false)
      transition.effects
  in
  Alcotest.check Alcotest.int "one terminal reply" 1 (List.length replies)
;;

let test_sync_instructions_are_translated_in_order () =
  let transition =
    Core.step
      (initial ())
      (Sync_event (Sync.Restore_local_account { user_id = "user-1" }))
  in
  match List.map Core.instruction_diagnostic transition.effects with
  | [ "publish:sync-output"; run ] ->
    Alcotest.check
      Alcotest.bool
      "load catalog follows state publication"
      true
      (String.starts_with ~prefix:"run-sync:request:" run)
  | values -> Alcotest.failf "unexpected child order: %s" (String.concat ", " values)
;;

let test_replay_is_deterministic () =
  let replay () =
    let transition =
      Core.step
        (initial ())
        (Sync_event (Sync.Restore_local_account { user_id = "user-1" }))
    in
    Core.view transition.next, transition.effects
  in
  let first_view, first_effects = replay () in
  let second_view, second_effects = replay () in
  Alcotest.check Alcotest.bool "view replay" true (Core.equal_view first_view second_view);
  Alcotest.check
    Alcotest.bool
    "effect replay"
    true
    (Core.equal_instructions first_effects second_effects)
;;

let worker_open_graph_transition () =
  let graph : Sync.graph =
    { graph_id = uuid "11111111-1111-4111-8111-111111111111"
    ; name = "Journal"
    ; schema = { major = 1; minor = 0; exact = true }
    ; encrypted = false
    }
  in
  let auth =
    Core.step
      (initial ())
      (Sync_event (Sync.Account_authenticated { user_id = Some "user" }))
  in
  let fetched =
    List.find_map
      (function
        | Core.Run_sync (Sync.Request (ticket, Sync.Fetch_catalog _)) ->
          Some
            (Core.Sync_event
               (Sync.Runner_completed (Sync.Completion (ticket, Ok [ graph ]))))
        | _ -> None)
      auth.effects
    |> Option.get
  in
  let catalog = Core.step auth.next fetched in
  let selected =
    Core.step catalog.next (Sync_event (Sync.Graph_selected graph.graph_id))
  in
  let inspected =
    List.find_map
      (function
        | Core.Run_worker
            (Core.Request
               (ticket, Core.Handle_sync_worker_effect (Sync.Inspect_mirror request))) ->
          Some
            (Core.Runner_completed
               (Core.Sync_worker_effect_completed
                  ( ticket
                  , Ok
                      { Core.event =
                          Some (Sync.Mirror_inspected (Sync.Mirror_available request))
                      ; lifecycle = Core.Lifecycle_unchanged
                      } )))
        | _ -> None)
      selected.effects
    |> Option.get
  in
  let attaching = Core.step selected.next inspected in
  let attached, scope =
    List.find_map
      (function
        | Core.Run_worker
            (Core.Request
               (ticket, Core.Handle_sync_worker_effect (Sync.Attach_graph request))) ->
          let token =
            Logseq_overlay_db.Types.sync_token_of_string "sync-token:v1:worker-delete"
            |> Result.get_ok
          in
          let checkpoint =
            Logseq_overlay_db.Types.Server_cursor.of_string "server-cursor:v1:0"
            |> Result.get_ok
          in
          let sync =
            Logseq_overlay_db.Types.sync_view ~token ~checkpoint ~submissions:[]
          in
          let opened =
            Core.database_opened ~database_id:"db-delete" ~graph_id:graph.graph_id
          in
          Some
            ( Core.Runner_completed
                (Core.Sync_worker_effect_completed
                   ( ticket
                   , Ok
                       { Core.event =
                           Some (Sync.Graph_attached { scope = request.scope; sync })
                       ; lifecycle =
                           Core.Lifecycle_opened (opened, request.scope.graph_generation)
                       } ))
            , request.scope )
        | _ -> None)
      attaching.effects
    |> Option.get
  in
  let ready = Core.step attaching.next attached in
  ready, scope
;;

let worker_open_graph () =
  let ready, scope = worker_open_graph_transition () in
  ready.Core.next, scope
;;

let test_local_deletion_drains_worker_operations () =
  let ready, scope = worker_open_graph () in
  let request = graph_info_request () in
  let executing =
    Core.step ready (Core.Graph_request { id = Core.request_id_of_int64 11L; request })
  in
  let completion =
    List.find_map
      (function
        | Core.Run_worker instruction ->
          Core.complete_execute
            instruction
            (Error
               (Logseq_db_worker.Error.create
                  ~code:Closed_session
                  ~message:"Request finished."
                  ~details:[]
                |> Result.get_ok))
        | _ -> None)
      executing.effects
    |> Option.get
  in
  let inspecting = Core.step executing.next (Sync_event Sync.Local_outbox_changed) in
  let inspection_completion =
    List.find_map
      (function
        | Core.Run_worker
            (Core.Request (ticket, Core.Handle_sync_worker_effect (Sync.Inspect_sync _)))
          ->
          Some
            (Core.Runner_completed
               (Core.Sync_worker_effect_completed
                  ( ticket
                  , Error
                      (Logseq_db_worker.Error.create
                         ~code:Closed_session
                         ~message:"Inspection finished."
                         ~details:[]
                       |> Result.get_ok) )))
        | _ -> None)
      inspecting.effects
    |> Option.get
  in
  let deleting =
    Core.step
      inspecting.next
      (Sync_event (Sync.Local_cache_deletion_requested scope.graph_id))
  in
  Alcotest.(check bool)
    "graph closes admission immediately"
    true
    ((Core.view deleting.next).graph.phase = Core.Graph_closing);
  let has_close effects =
    List.exists
      (function
        | Core.Run_worker
            (Core.Request (_, Core.Handle_sync_worker_effect (Sync.Detach_graph _))) ->
          true
        | _ -> false)
      effects
  in
  Alcotest.(check bool)
    "close waits for executing work"
    false
    (has_close deleting.effects);
  let edit =
    { request with
      Protocol.command =
        Protocol.V2_save_block
          { mutation_id = uuid "20000000-0000-4000-8000-000000000001"
          ; block = uuid "30000000-0000-4000-8000-000000000001"
          ; title = "Must not be saved after deletion admission"
          ; preconditions = { blocks = []; pages = []; scopes = [] }
          }
    }
  in
  let rejected =
    Core.step
      deleting.next
      (Core.Graph_request { id = Core.request_id_of_int64 12L; request = edit })
  in
  Alcotest.(check bool)
    "new editing receives a terminal reply and no execution"
    true
    (List.exists
       (function
         | Core.Publish (Core.Reply _) -> true
         | _ -> false)
       rejected.effects
     && not
          (List.exists
             (function
               | Core.Run_worker _ -> true
               | _ -> false)
             rejected.effects));
  let one_finished = Core.step rejected.next completion in
  Alcotest.(check bool)
    "close still waits for sync DB operation"
    false
    (has_close one_finished.effects);
  let drained = Core.step one_finished.next inspection_completion in
  Alcotest.(check bool)
    "all DB completions release one close"
    true
    (has_close drained.effects);
  let duplicate = Core.step drained.next inspection_completion in
  Alcotest.(check bool)
    "duplicate completion cannot release another close"
    true
    (duplicate.effects = []);
  let close_failure =
    List.find_map
      (function
        | Core.Run_worker
            (Core.Request (ticket, Core.Handle_sync_worker_effect (Sync.Detach_graph _)))
          ->
          Some
            (Core.Runner_completed
               (Core.Sync_worker_effect_completed
                  ( ticket
                  , Error
                      (Logseq_db_worker.Error.create
                         ~code:Closed_session
                         ~message:"private close details"
                         ~details:[]
                       |> Result.get_ok) )))
        | _ -> None)
      drained.effects
    |> Option.get
  in
  let failed = Core.step drained.next close_failure in
  Alcotest.(check bool)
    "worker forwards close failure to owner"
    true
    ((Core.view failed.next).sync.snapshot.local_deletion
     = Some (Sync.Deletion_failed Sync.Closing_graph));
  Alcotest.(check bool)
    "close failure never deletes"
    false
    (List.exists
       (function
         | Core.Run_worker
             (Core.Request (_, Core.Handle_sync_worker_effect (Sync.Delete_mirror _))) ->
           true
         | _ -> false)
       failed.effects)
;;

module Asset = Logseq_db_types.Asset_descriptor
module Transfer = Logseq_sync_pure_reducer.Asset_transfer

let asset_demand (scope : Sync.graph_scope) =
  let version =
    Asset.version ~checksum:(String.make 64 'a') ~file_type:"png" |> Result.get_ok
  in
  let asset =
    Asset.create
      ~uuid:scope.Sync.graph_id
      ~source:(Managed (Some version))
      ~current_checksum:None
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  Core.Asset_requested
    { graph_generation = scope.graph_generation
    ; event =
        Transfer.Replace
          { consumer = "visible"; priority = Foreground; assets = [ asset ] }
    }
;;

let lookup effects =
  List.find_map
    (function
      | Core.Run_asset (_, Transfer.Check_cache ticket) -> Some ticket
      | _ -> None)
    effects
  |> Option.get
;;

let test_asset_demand_lifecycle () =
  let state, scope = worker_open_graph () in
  let requested = Core.step state (asset_demand scope) in
  let ticket = lookup requested.effects in
  Alcotest.(check bool)
    "live ticket"
    true
    (Core.asset_ticket_current requested.next ticket);
  let completed =
    Core.step
      requested.next
      (Asset_completed (scope, Transfer.Cache_checked (ticket, Ok (Some "handle"))))
  in
  Alcotest.(check bool)
    "consumer sees cached asset"
    true
    (List.exists
       (function
         | Core.Publish
             (Asset_notice (_, Asset_availability { availability = Ready "handle"; _ }))
           -> true
         | _ -> false)
       completed.effects);
  let switched = Core.step completed.next (Sync_event Sync.Graph_picker_requested) in
  Alcotest.(check bool)
    "scope retired"
    false
    (Core.asset_scope_current switched.next scope);
  Alcotest.(check bool)
    "cache session closed"
    true
    (List.mem (Core.Close_asset_scope scope) switched.effects);
  let stale =
    Core.step
      switched.next
      (Asset_completed (scope, Transfer.Cache_checked (ticket, Ok (Some "handle"))))
  in
  Alcotest.(check int) "stale completion invisible" 0 (List.length stale.effects)
;;

let test_asset_failure_is_independent () =
  let state, scope = worker_open_graph () in
  let requested = Core.step state (asset_demand scope) in
  let ticket = lookup requested.effects in
  let failed =
    Core.step
      requested.next
      (Asset_completed
         (scope, Transfer.Cache_checked (ticket, Error (Invalid_content "bad asset"))))
  in
  Alcotest.(check bool)
    "graph sync state unchanged"
    true
    ((Core.view requested.next).sync = (Core.view failed.next).sync);
  let stale =
    Core.step
      state
      (asset_demand { scope with graph_generation = scope.graph_generation + 1 })
  in
  Alcotest.(check int) "foreign demand rejected" 0 (List.length stale.effects)
;;

let test_upload_session () =
  let module U = Logseq_db_worker_pure_reducer.Asset_upload in
  let state, scope = worker_open_graph () in
  let id n =
    Logseq_db_types.Graph_types.Uuid.of_string
      (Printf.sprintf "77000000-0000-4000-8000-%012d" n)
    |> Result.get_ok
  in
  let intent =
    Logseq_db_types.Asset_upload_intent.prepare
      ~replace_reference:None
      ~operation_id:(id 1)
      ~origin:(Uri.to_string scope.account.managed_sync_origin)
      ~account:scope.account.user_id
      ~graph:scope.graph_id
      ~asset:(id 2)
      ~version:
        (Logseq_db_types.Asset_descriptor.version
           ~checksum:(String.make 64 'a')
           ~file_type:"png"
         |> Result.get_ok)
      ~title:"Image"
      ~size:4L
      ~staged_file:"source.bin"
      ~target:(id 3)
      ~local_mutation:(id 4)
      ~metadata_mutation:(id 5)
    |> Result.get_ok
  in
  let requested =
    Core.step
      state
      (Upload_requested
         { graph_generation = scope.graph_generation
         ; operation = intent.operation_id
         ; event = U.Start intent
         })
  in
  let ticket =
    List.find_map
      (function
        | Core.Run_upload (_, U.Persist (ticket, _, _)) -> Some ticket
        | _ -> None)
      requested.effects
  in
  Alcotest.(check bool) "worker executes durable upload" true (Option.is_some ticket);
  let ticket = Option.get ticket in
  Alcotest.(check bool)
    "exact upload ticket admitted"
    true
    (Core.upload_ticket_current requested.next ticket);
  let completed = Core.step requested.next (Upload_completed (ticket, U.Persisted)) in
  Alcotest.(check bool)
    "local mutation follows durable intent"
    true
    (List.exists
       (function
         | Core.Run_upload (_, U.Apply_local _) -> true
         | _ -> false)
       completed.effects);
  Alcotest.(check bool)
    "durable upload publishes scoped status"
    true
    (List.exists
       (function
         | Core.Publish
             (Asset_notice
                ( actual
                , Upload_status { operation; asset; target; title; status = U.Preparing }
                )) ->
           actual = scope
           && operation = intent.operation_id
           && asset = intent.asset
           && target = intent.target
           && title = intent.title
         | _ -> false)
       completed.effects);
  let duplicate = Core.step completed.next (Upload_completed (ticket, U.Persisted)) in
  Alcotest.(check bool)
    "duplicate completion does not repeat status"
    true
    (not
       (List.exists
          (function
            | Core.Publish (Asset_notice (_, Upload_status _)) -> true
            | _ -> false)
          duplicate.effects));
  let switched = Core.step completed.next (Sync_event Sync.Graph_picker_requested) in
  Alcotest.(check bool)
    "graph switch cancels upload"
    true
    (List.exists
       (function
         | Core.Run_upload (_, U.Cancel_operation _) -> true
         | _ -> false)
       switched.effects);
  let stale = Core.step switched.next (Upload_completed (ticket, U.Persisted)) in
  Alcotest.(check bool) "late upload completion ignored" true (stale.effects = [])
;;

let recovery_instruction transition =
  List.find_map
    (function
      | Core.Read_uploads ticket -> Some ticket
      | _ -> None)
    transition.Core.effects
;;

let test_upload_recovery () =
  let opened, _ = worker_open_graph_transition () in
  Alcotest.(check bool)
    "graph attachment starts recovery"
    true
    (Option.is_some (recovery_instruction opened));
  let ticket = Option.get (recovery_instruction opened) in
  Alcotest.(check int) "bounded recovery page" 16 ticket.limit;
  let empty = Core.step opened.next (Uploads_loaded (ticket, Ok [])) in
  Alcotest.(check bool)
    "empty page finishes recovery"
    true
    (recovery_instruction empty = None);
  let duplicate = Core.step empty.next (Uploads_loaded (ticket, Ok [])) in
  Alcotest.(check bool)
    "duplicate recovery completion ignored"
    true
    (duplicate.effects = []);
  let switched = Core.step opened.next (Sync_event Sync.Graph_picker_requested) in
  let stale = Core.step switched.next (Uploads_loaded (ticket, Error "obsolete")) in
  Alcotest.(check bool) "old graph recovery ignored" true (stale.effects = [])
;;

let recovery_intent (scope : Sync.graph_scope) n =
  let id n =
    Logseq_db_types.Graph_types.Uuid.of_string
      (Printf.sprintf "88000000-0000-4000-8000-%012d" n)
    |> Result.get_ok
  in
  Logseq_db_types.Asset_upload_intent.prepare
    ~replace_reference:None
    ~operation_id:(id n)
    ~origin:(Uri.to_string scope.account.managed_sync_origin)
    ~account:scope.account.user_id
    ~graph:scope.graph_id
    ~asset:(id (n + 100))
    ~version:
      (Asset.version ~checksum:(String.make 64 'a') ~file_type:"png" |> Result.get_ok)
    ~title:"Recovered image"
    ~size:4L
    ~staged_file:"source.bin"
    ~target:(id 1000)
    ~local_mutation:(id (n + 200))
    ~metadata_mutation:(id (n + 300))
  |> Result.get_ok
;;

let test_upload_recovery_backpressure () =
  let opened, scope = worker_open_graph_transition () in
  let first = Option.get (recovery_instruction opened) in
  Alcotest.(check bool)
    "open graph admits an explicit import"
    true
    (Option.is_some
       (Core.import_context opened.next ~graph_generation:scope.graph_generation));
  Alcotest.(check bool)
    "stale graph import rejected"
    true
    (Core.import_context opened.next ~graph_generation:(scope.graph_generation + 1) = None);
  let page from = List.init 16 (fun n -> recovery_intent scope (from + n)) in
  let loaded = Core.step opened.next (Uploads_loaded (first, Ok (page 1))) in
  Alcotest.(check int)
    "bounded restored sessions"
    16
    (List.length
       (List.filter
          (function
            | Core.Run_upload (_, Logseq_db_worker_pure_reducer.Asset_upload.Inspect _) ->
              true
            | _ -> false)
          loaded.effects));
  let second = Option.get (recovery_instruction loaded) in
  let full = Core.step loaded.next (Uploads_loaded (second, Ok (page 17))) in
  Alcotest.(check bool)
    "full session queue stops enumeration"
    true
    (recovery_instruction full = None);
  Alcotest.(check bool)
    "full upload queue rejects import before staging"
    true
    (Core.import_context full.next ~graph_generation:scope.graph_generation = None);
  let cancelled =
    Core.step
      full.next
      (Upload_requested
         { graph_generation = scope.graph_generation
         ; operation = (recovery_intent scope 1).operation_id
         ; event = Logseq_db_worker_pure_reducer.Asset_upload.Cancel
         })
  in
  let save =
    List.find_map
      (function
        | Core.Run_upload
            (_, Logseq_db_worker_pure_reducer.Asset_upload.Persist (ticket, _, _)) ->
          Some ticket
        | _ -> None)
      cancelled.effects
    |> Option.get
  in
  let released =
    Core.step
      cancelled.next
      (Upload_completed (save, Logseq_db_worker_pure_reducer.Asset_upload.Persisted))
  in
  Alcotest.(check bool)
    "terminal status is published before retiring its owner"
    true
    (List.exists
       (function
         | Core.Publish
             (Asset_notice
                ( actual
                , Upload_status
                    { status = Logseq_db_worker_pure_reducer.Asset_upload.Cancelled; _ }
                )) -> actual = scope
         | _ -> false)
       released.effects);
  let third = Option.get (recovery_instruction released) in
  Alcotest.(check int) "resume uses only freed capacity" 1 third.limit;
  Alcotest.(check bool)
    "resume preserves enumeration cursor"
    true
    (third.after = Some (recovery_intent scope 32).operation_id)
;;

let test_upload_recovery_invalid_page () =
  let opened, scope = worker_open_graph_transition () in
  let ticket = Option.get (recovery_instruction opened) in
  let intent = recovery_intent scope 1 in
  let result = Core.step opened.next (Uploads_loaded (ticket, Ok [ intent; intent ])) in
  Alcotest.(check bool)
    "duplicate page is rejected before restoring"
    false
    (List.exists
       (function
         | Core.Run_upload _ -> true
         | _ -> false)
       result.effects);
  Alcotest.(check bool)
    "invalid page is observable"
    true
    (List.exists
       (function
         | Core.Publish (Diagnostic _) -> true
         | _ -> false)
       result.effects)
;;

let test_upload_recovery_failure () =
  let opened, _ = worker_open_graph_transition () in
  let ticket = Option.get (recovery_instruction opened) in
  let failed = Core.step opened.next (Uploads_loaded (ticket, Error "unavailable")) in
  Alcotest.(check bool)
    "recovery failure observable"
    true
    (List.exists
       (function
         | Core.Publish (Diagnostic _) -> true
         | _ -> false)
       failed.effects);
  Alcotest.(check bool)
    "recovery failure cannot spin"
    true
    (recovery_instruction failed = None);
  let retried = Core.step failed.next (Sync_event Sync.Online_recovery_requested) in
  Alcotest.(check bool)
    "explicit recovery retries failed enumeration"
    true
    (Option.is_some (recovery_instruction retried));
  let fresh = Option.get (recovery_instruction retried) in
  Alcotest.(check bool) "retry receives a fresh serial" true (fresh.serial > ticket.serial);
  let stale = Core.step retried.next (Uploads_loaded (ticket, Ok [])) in
  Alcotest.(check bool)
    "old failed attempt cannot finish retry"
    true
    (Core.upload_recovery_current stale.next fresh)
;;

let () =
  Alcotest.run
    "logseq db worker pure reducer"
    [ ( "asset session"
      , [ Alcotest.test_case "bounded upload recovery" `Quick test_upload_recovery
        ; Alcotest.test_case
            "upload recovery backpressure"
            `Quick
            test_upload_recovery_backpressure
        ; Alcotest.test_case
            "upload recovery invalid page"
            `Quick
            test_upload_recovery_invalid_page
        ; Alcotest.test_case "upload recovery failure" `Quick test_upload_recovery_failure
        ; Alcotest.test_case "durable upload session" `Quick test_upload_session
        ; Alcotest.test_case "demand lifecycle" `Quick test_asset_demand_lifecycle
        ; Alcotest.test_case
            "independent failure"
            `Quick
            test_asset_failure_is_independent
        ] )
    ; ( "managed lifecycle"
      , [ Alcotest.test_case
            "start has no local open"
            `Quick
            test_managed_worker_starts_without_local_open
        ; Alcotest.test_case
            "closed request replies"
            `Quick
            test_closed_graph_request_replies_once
        ; Alcotest.test_case
            "sync instruction order"
            `Quick
            test_sync_instructions_are_translated_in_order
        ; Alcotest.test_case
            "deletion drains executing work"
            `Quick
            test_local_deletion_drains_worker_operations
        ; Alcotest.test_case "deterministic replay" `Quick test_replay_is_deterministic
        ] )
    ]
;;
