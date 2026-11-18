module D = Sync_dsl.Core
module X = Execute.Core

let get = function
  | Ok x -> x
  | Error e -> Alcotest.fail (D.error_message e)
;;

let check b message = Alcotest.(check bool) message true b

let identity =
  get
    (D.identity
       ~origin:"https://example.com"
       ~account:"a"
       ~graph:"g"
       ~account_generation:0L
       ~graph_generation:0L)
;;

let limits_with_items maximum_items =
  get
    (D.limits
       ~maximum_items
       ~maximum_bytes:1024
       ~maximum_pending:8
       ~maximum_resources:8
       ~steps_per_turn:8
       ~maximum_tasks:8
       ~maximum_messages:8
       ~maximum_message_bytes:1024
       ~maximum_demands:8
       ~maximum_active_assets:2
       ~foreground_reserve:1
       ~foreground_demand_reserve:1
       ~foreground_descriptor_reserve_bytes:128
       ~asset_cache_budget_bytes:4096L
       ~asset_maximum_file_bytes:1024
       ~asset_pending_budget_bytes:4096L
       ~snapshot_maximum_artifact_bytes:4096L
       ~snapshot_staging_budget_bytes:4096L
       ~snapshot_scratch_budget_bytes:4096L)
;;

let limits = limits_with_items 8

module Worker = struct
  type scope = unit
  type imported_file = string

  let bind_runtime ~identity:_ ~database_owner:_ ~limits:_ ~cleanup_seconds:_ ~network:_ =
    Ok ()
  ;;

  let with_scope ~identity:_ ~operation:_ f = f ()
  let crypto (type a) () (_ : a D.crypto) : (a, D.error) result = Error D.Locked
  let unavailable () = Error (D.Invalid_input "Import not used by this fixture")
  let prepare_import () _ = unavailable ()
  let publish_import_preview () _ = unavailable ()
  let persist_import () _ ~expected:_ = unavailable ()
  let inspect_import () _ = unavailable ()
  let apply_local_import () _ = unavailable ()
  let put_import () _ = unavailable ()
  let apply_import_metadata () _ = unavailable ()
  let await_import_publication () _ = unavailable ()
  let cancel_import () _ = unavailable ()
  let release_import_staging () _ = unavailable ()
  let recover_import_inputs () ~after:_ ~maximum_items:_ ~maximum_bytes:_ = unavailable ()
  let confirm_import_input () _ = unavailable ()
  let acknowledge_import_input () ~input:_ ~prepared:_ = unavailable ()
  let cancel () = Ok ()
  let retain_imported_file () _ = unavailable ()
  let imported_file_path x = x
  let release_imported_file _ = Ok ()
  let fence ~identity:_ = Ok ()
  let await_quiescent ~identity:_ = Ok ()
end

let owner ~sw =
  let module O = D.Overlay in
  let deps =
    match
      O.Database.dependencies
        ~epoch_ms:(fun () -> 0L)
        ~monotonic_ns:(fun () -> 0L)
        ~limits:
          { O.Types.response_budget_bytes = 1024
          ; outbox_max_records = 8
          ; outbox_max_bytes = 4096
          ; change_max_items = 8
          ; change_max_bytes = 1024
          ; dispatcher_capacity = 8
          ; wire_batch_max_bytes = 1024
          }
    with
    | Ok x -> x
    | Error _ -> failwith "dependencies"
  in
  let graph_id =
    match
      Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111"
    with
    | Ok x -> x
    | Error _ -> failwith "uuid"
  in
  let inspection =
    match
      O.Database.inspect_mirror
        ~application_support_directory:"/tmp/execute-runtime-absent-fixture"
        ~graph_id
    with
    | Ok x -> x
    | Error _ -> failwith "inspection"
  in
  get
    (X.activation_owner
       ~sw
       ~dependencies:deps
       ~inspection
       ~graph_name:"Runtime fixture"
       ~snapshot_source:(fun _ -> Error (D.Invalid_input "No snapshot in fixture")))
;;

let capabilities
      ?dispatch
      ?(close_network = fun _ -> Ok ())
      ?(restore =
        fun ~scope:_ _ ->
          Ok { D.keys = D.Unencrypted; checkpoint = None; recovery_pending = false })
      ()
  : X.capabilities
  =
  { validate_identity = (fun _ -> Ok ())
  ; validate_limits = (fun _ -> Ok ())
  ; websocket_liveness = X.Peer_close_only
  ; network_deadlines =
      { setup_seconds = 1.
      ; tls_handshake_seconds = 1.
      ; http_response_seconds = 1.
      ; download_seconds = 1.
      }
  ; cleanup_seconds = 1.
  ; acquire = (fun _ -> Ok ())
  ; fence_network = (fun _ -> Ok ())
  ; close_network
  ; authorize_network =
      (fun _ ~epoch ->
        if epoch = 7L then Ok () else Error (D.Authentication_failure "epoch"))
  ; validate_resource = (fun _ -> Ok ())
  ; restore
  ; worker_owner = (module Worker)
  ; dispatch =
      (match dispatch with
       | Some dispatch -> dispatch
       | None ->
         { database =
             (fun ~owner:_ ~scope:_ ~identity:_ _ ->
               Error (D.Storage_failure "No mirror"))
         ; transport = (fun ~scope:_ ~identity:_ _ -> Error D.Network_closed)
         ; crypto = (fun ~scope:_ ~identity:_ _ -> Error D.Locked)
         ; assets = (fun ~scope:_ ~identity:_ _ -> Error (D.Invalid_input "No asset"))
         })
  ; observe =
      (fun _ ->
        Ok
          { D.identity
          ; keys = D.Unencrypted
          ; network = D.Closed
          ; checkpoint = None
          ; pending_submissions = 0
          ; pending_assets = 0
          ; cleanup_pending = 0
          ; last_failure = None
          })
  ; fence = (fun _ -> Ok ())
  ; retire = (fun _ -> Ok ())
  ; release_file = (fun _ _ -> Ok ())
  ; release_lease = (fun _ _ -> Ok ())
  ; release_snapshot = (fun _ _ -> Ok ())
  }
;;

let fixture
      env
      ~sw
      ?(limits = limits)
      ?database_owner
      ?dispatch
      ?close_network
      ?restore
      ()
  =
  let owner =
    match database_owner with
    | Some owner -> owner
    | None -> owner ~sw
  in
  let capabilities = capabilities ?dispatch ?close_network ?restore () in
  let t, cold =
    get
      (X.create
         ~sw
         ~clock:(Eio.Stdenv.mono_clock env)
         ~database_owner:owner
         ~identity
         ~limits
         capabilities)
  in
  t, cold, owner
;;

let restore = D.perform D.Restore ~success:(fun _ -> D.return ()) ~failure:D.abort

let ready t cold =
  match X.await (get (X.start t cold restore)) with
  | X.Completed (next, ()) -> next
  | X.Failed (_, e) -> Alcotest.fail (D.error_message e)
;;

let run t context task =
  X.await
    (get
       (X.start
          t
          context
          (D.perform (D.Run_task task) ~success:D.return ~failure:D.abort)))
;;

let task op = D.task_perform op ~success:D.task_return ~failure:D.task_fail

let contexts env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let next = ready t cold in
    check (Result.is_error (X.start t cold restore)) "spent context rejects";
    let other, _, _ = fixture env ~sw () in
    check (Result.is_error (X.start other next (D.return ()))) "foreign runtime rejects";
    let version = X.version next in
    (match get (X.current t) with
     | X.Context (_, c) ->
       check (X.equal_version version (X.version c)) "same recovery version");
    let task =
      D.with_scope (fun scope ->
        D.task_bind
          (D.spawn scope (D.task_return 42))
          (function
            | Error e -> D.task_fail e
            | Ok child ->
              D.task_bind (D.join child) (function
                | Ok n -> D.task_return n
                | Error e -> D.task_fail e)))
    in
    match run t next task with
    | X.Completed (_, 42) -> ()
    | _ -> Alcotest.fail "typed child result")
;;

let network env () =
  Eio.Switch.run (fun sw ->
    let entered, enter = Eio.Promise.create ()
    and release, resolve = Eio.Promise.create () in
    let closes = ref 0 in
    let t, _, _ =
      fixture
        env
        ~sw
        ~close_network:(fun _ ->
          incr closes;
          ignore (Eio.Promise.try_resolve enter ());
          Eio.Promise.await release;
          Ok ())
        ()
    in
    get (X.open_network t ~authorization_epoch:7L);
    let receipt = get (X.close_network t) in
    let receipt2 = get (X.close_network t) in
    check (receipt == receipt2) "same retirement receipt";
    check
      (Result.is_error (X.open_network t ~authorization_epoch:7L))
      "cannot reopen before join";
    let joined =
      Eio.Fiber.fork_promise ~sw (fun () -> X.await_network_retirement receipt)
    in
    Eio.Promise.await entered;
    Eio.Promise.resolve resolve ();
    get (Eio.Promise.await_exn joined);
    get (X.open_network t ~authorization_epoch:7L);
    check (!closes = 1) "one physical close";
    check
      (Result.is_error (X.open_network t ~authorization_epoch:8L))
      "actual epoch checked")
;;

let stop_and_outbox env () =
  Eio.Switch.run (fun sw ->
    let t, cold, owner = fixture env ~sw () in
    let next = ready t cold in
    get (X.notify_outbox_changed t ~owner ~identity);
    let waiting =
      D.with_scope (fun _ ->
        D.task_bind (task D.Await_outbox_changed) (fun receipt ->
          D.task_bind (task (D.Acknowledge_outbox_check receipt)) (fun () ->
            task D.Next_input)))
    in
    let running =
      get
        (X.start
           t
           next
           (D.perform (D.Run_task waiting) ~success:D.return ~failure:D.abort))
    in
    Eio.Fiber.yield ();
    get (X.request_stop t);
    match X.await running with
    | X.Completed (_, D.Stop_requested) -> ()
    | _ -> Alcotest.fail "stop input")
;;

let cancellation env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let next = ready t cold in
    let running =
      get
        (X.start
           t
           next
           (D.perform (D.Run_task (task D.Next_input)) ~success:D.return ~failure:D.abort))
    in
    Eio.Fiber.yield ();
    get (X.cancel t running);
    get (X.cancel t running);
    match X.await running with
    | X.Failed (X.Context (D.Draining, _), D.Cancelled) -> ()
    | _ -> Alcotest.fail "cancel returns actual draining context")
;;

let observation env () =
  Eio.Switch.run (fun sw ->
    let t, _, _ = fixture env ~sw () in
    let first = get (X.observe_runtime t) in
    get (X.open_network t ~authorization_epoch:7L);
    let second = get (X.await_observation t ~after:first.revision) in
    check
      (second.state.network = D.Open { authorization_epoch = 7L })
      "actual gate overrides adapter";
    let other, _, _ = fixture env ~sw () in
    check
      (Result.is_error (X.await_observation other ~after:second.revision))
      "foreign revision rejects")
;;

let rec remove_fixture path =
  if Sys.is_directory path
  then (
    Array.iter (fun name -> remove_fixture (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path
;;

let real_activation env () =
  let root = Filename.temp_file "execute-activation-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_fixture root)
    (fun () ->
       let module O = D.Overlay in
       let require = function
         | Ok value -> value
         | Error _ -> Alcotest.fail "real fixture setup failed"
       in
       let module Transit = Transit_core.Json in
       let module Codec = Transit_native.Transit.Json in
       let module Storage_codec = Logseq_db_storage.Logseq_sqlite_codec in
       let attribute : Datascript.schema_attr =
         { cardinality = One
         ; unique = None
         ; indexed = true
         ; is_component = false
         ; no_history = false
         ; doc = None
         ; value_type = None
         ; tuple_attrs = None
         ; tuple_types = None
         }
       in
       let schema =
         List.map
           (fun name -> name, attribute)
           [ "db/ident"
           ; "block/uuid"
           ; "block/title"
           ; "block/parent"
           ; "block/page"
           ; "block/order"
           ; "kv/value"
           ]
       in
       let fact e a v : Datascript.datom = { e; a; v; tx = 536870913; added = true } in
       let kv e name value =
         [ fact e "db/ident" (Keyword name); fact e "kv/value" value ]
       in
       let facts =
         List.concat
           [ kv 1 "logseq.kv/graph-remote?" (Bool true)
           ; kv 2 "logseq.kv/graph-uuid" (Uuid "11111111-1111-4111-8111-111111111111")
           ; kv 3 "logseq.kv/db-type" (String "db")
           ; kv
               4
               "logseq.kv/schema-version"
               (Map [ Keyword "major", Int64 65L; Keyword "minor", Int64 33L ])
           ]
       in
       let stored = ref [] in
       let storage : Datascript.storage =
         { storage_store =
             (fun entries ->
               List.iter
                 (fun (key, value) ->
                    stored := (key, value) :: List.remove_assoc key !stored)
                 entries)
         ; storage_restore = (fun key -> List.assoc_opt key !stored)
         ; storage_list_addresses = (fun () -> List.map fst !stored)
         ; storage_delete =
             (fun keys ->
               stored := List.filter (fun (key, _) -> not (List.mem key keys)) !stored)
         }
       in
       ignore (Datascript.store ~storage (Datascript.init_db ~schema facts));
       let entries =
         require (Storage_codec.encode_physical_batch !stored)
         |> List.sort (fun (left : Storage_codec.physical_entry) right ->
           Int.compare (int_of_string left.address) (int_of_string right.address))
       in
       let rows =
         List.map
           (fun (entry : Storage_codec.physical_entry) ->
              Transit.Array
                [ Transit.Int (int_of_string entry.address)
                ; Transit.String entry.content
                ; (match entry.addresses with
                   | [] -> Transit.Null
                   | addresses ->
                     Transit.String
                       (Codec.to_string
                          ~mode:Codec.Verbose
                          (Transit.Array
                             (List.map
                                (fun address -> Transit.Int (int_of_string address))
                                addresses))))
                ])
           entries
       in
       let payload = Codec.to_string ~mode:Codec.Verbose (Transit.Array rows) in
       let path = Filename.concat root "snapshot.transit" in
       let output = open_out_bin path in
       Fun.protect
         ~finally:(fun () -> close_out_noerr output)
         (fun () ->
            output_binary_int output (String.length payload);
            output_string output payload);
       let dependencies =
         require
           (O.Database.dependencies
              ~epoch_ms:(fun () -> 0L)
              ~monotonic_ns:(fun () -> 0L)
              ~limits:
                { O.Types.response_budget_bytes = 1048576
                ; outbox_max_records = 8
                ; outbox_max_bytes = 1048576
                ; change_max_items = 8
                ; change_max_bytes = 1048576
                ; dispatcher_capacity = 8
                ; wire_batch_max_bytes = 1048576
                })
       in
       let graph_id =
         require
           (Logseq_db_types.Graph_types.Uuid.of_string
              "11111111-1111-4111-8111-111111111111")
       in
       let inspect support =
         require
           (O.Database.inspect_mirror ~application_support_directory:support ~graph_id)
       in
       let through = require (Logseq_db_types.Server_cursor.of_int64 0L) in
       let baseline = Filename.concat root "baseline" in
       Unix.mkdir baseline 0o700;
       let activation = function
         | Error (O.Types.Snapshot_parse_error message) -> Alcotest.fail message
         | result ->
           get (Result.map_error (fun error -> D.Activation_failure error) result)
       in
       let prepared =
         activation
           (O.Database.prepare_snapshot_activation
              dependencies
              (inspect baseline)
              ~path
              ~applied_server_cursor:through
              ~expected_checksum:None
              ~expected_rows:(List.length rows))
       in
       let committed =
         Fun.protect
           ~finally:(fun () -> O.Database.cancel_snapshot_activation prepared)
           (fun () ->
              check
                (require (O.Database.next_snapshot_unprotection_batch prepared) = None)
                "unencrypted fixture";
              require (O.Database.commit_snapshot_activation prepared))
       in
       let checksum =
         match O.Database.mirror_presence committed with
         | O.Types.Available { checksum = Some checksum; _ } ->
           O.Types.Checksum.to_string checksum
         | _ -> Alcotest.fail "baseline checksum missing"
       in
       let target = Filename.concat root "target" in
       Unix.mkdir target 0o700;
       Eio.Switch.run (fun sw ->
         let database_owner =
           get
             (X.activation_owner
                ~sw
                ~dependencies
                ~inspection:(inspect target)
                ~graph_name:"Real runtime activation"
                ~snapshot_source:(fun _ ->
                  Ok { X.path; expected_rows = List.length rows }))
         in
         check
           (Result.is_error (X.database database_owner))
           "mirror absent before activation";
         let snapshot =
           get
             (D.snapshot
                ~resource:(get (D.resource ~owner:identity ~token:"real-snapshot"))
                ~through
                ~checksum
                ~encrypted:false)
         in
         let dispatch : X.dispatch =
           { database =
               (fun ~owner:_ ~scope:_ ~identity:_ _ ->
                 Alcotest.fail "database must use real owner")
           ; transport =
               (fun (type a)
                 ~scope
                 ~identity:_
                 (operation : a D.transport)
                 : (a, D.error) result ->
                 match operation with
                 | D.Fetch_snapshot _ ->
                   Result.map
                     (fun () -> snapshot)
                     (X.handoff scope (Rrbvec.of_list [ D.Snapshot_reference snapshot ]))
                 | _ -> Error D.Network_closed)
           ; crypto = (fun ~scope:_ ~identity:_ _ -> Error D.Locked)
           ; assets = (fun ~scope:_ ~identity:_ _ -> Error (D.Invalid_input "No asset"))
           }
         in
         let t, cold, _ =
           fixture env ~sw ~limits:(limits_with_items 1) ~database_owner ~dispatch ()
         in
         let next = ready t cold in
         get (X.open_network t ~authorization_epoch:7L);
         let program =
           D.perform
             (D.Transport (D.Fetch_snapshot through))
             ~failure:D.abort
             ~success:(fun snapshot ->
               D.perform
                 (D.Database (D.Activate_snapshot snapshot))
                 ~failure:D.abort
                 ~success:D.return)
         in
         let next =
           match X.await (get (X.start t next program)) with
           | X.Completed (next, D.Activated _) -> next
           | X.Completed (_, D.Activation_deferred message) -> Alcotest.fail message
           | X.Failed (_, error) -> Alcotest.fail (D.error_message error)
         in
         let original = get (X.database database_owner) in
         let next, view =
           match
             X.await
               (get
                  (X.start
                     t
                     next
                     (D.perform (D.Database D.Inspect) ~failure:D.abort ~success:D.return)))
           with
           | X.Completed (next, view) -> next, view
           | X.Failed (_, error) -> Alcotest.fail (D.error_message error)
         in
         check
           (original == get (X.database database_owner))
           "same activated owner serves reads";
         ignore view;
         for index = 1 to 2 do
           let uuid suffix =
             require
               (Logseq_db_types.Graph_types.Uuid.of_string
                  (Printf.sprintf "22222222-2222-4222-8222-%012d" suffix))
           in
           let page = uuid (index + 10) in
           let snapshot = require (O.Database.current_snapshot original) in
           let expected =
             Fun.protect
               ~finally:(fun () -> O.Database.release_snapshot snapshot)
               (fun () ->
                  match require (O.Database.get_pages snapshot [ page ]) with
                  | [ O.Types.Missing_page { revision; _ } ] ->
                    require
                      (O.Database.write_precondition
                         ~blocks:[]
                         ~pages:[ page, revision ]
                         ~scopes:[])
                  | _ -> Alcotest.fail "new journal page must be absent")
           in
           ignore
             (require
                (O.Database.commit_local
                   original
                   ~expected
                   (O.Types.Create_journal_page
                      { mutation_id = uuid index
                      ; page
                      ; title = Printf.sprintf "2026-01-%02d" index
                      ; journal_day = 20260100 + index
                      })))
         done;
         (match run t next (task (D.Task_database D.Inspect)) with
          | X.Failed (_, D.Invalid_input "Sync view items") -> ()
          | X.Failed (_, error) -> Alcotest.fail (D.error_message error)
          | X.Completed _ -> Alcotest.fail "oversized durable view must fail permanently");
         match O.Database.mirror_presence (inspect target) with
         | O.Types.Available { checksum = Some actual; _ } ->
           Alcotest.(check string)
             "durable checksum"
             checksum
             (O.Types.Checksum.to_string actual)
         | _ -> Alcotest.fail "real mirror was not committed"))
;;

let nested_unlock env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let next = ready t cold in
    let consume =
      D.with_scope (fun _ ->
        D.task_bind (task D.Next_input) (function
          | D.Unlock_requested receipt ->
            D.task_perform
              (D.Consume_unlock receipt)
              ~success:(fun _ -> D.task_return ())
              ~failure:(function
                | D.Locked -> D.task_return ()
                | e -> D.task_fail e)
          | _ -> D.task_fail (D.Invalid_input "Expected unlock")))
    in
    let running =
      get
        (X.start
           t
           next
           (D.perform (D.Run_task consume) ~success:D.return ~failure:D.abort))
    in
    Eio.Fiber.yield ();
    ignore
      (get
         (X.submit_unlock
            t
            ~identity
            ~valid_for:10.
            (get (D.unlock_input ~wrapped_graph_key:"wrapped"))));
    match X.await running with
    | X.Completed (_, ()) -> ()
    | X.Failed (_, e) -> Alcotest.fail (D.error_message e))
;;

let cancelled_subtree env () =
  Eio.Switch.run (fun sw ->
    let entered = ref false
    and joined = ref false in
    let never, _ = Eio.Promise.create () in
    let dispatch : X.dispatch =
      { database = (fun ~owner:_ ~scope:_ ~identity:_ _ -> Error D.Stale_context)
      ; transport = (fun ~scope:_ ~identity:_ _ -> Error D.Network_closed)
      ; crypto = (fun ~scope:_ ~identity:_ _ -> Error D.Locked)
      ; assets =
          (fun (type a)
            ~scope:_
            ~identity:_
            (operation : a D.assets)
            : (a, D.error) result ->
            match operation with
            | D.Prune_cache ->
              entered := true;
              Fun.protect
                ~finally:(fun () -> joined := true)
                (fun () ->
                   Eio.Promise.await never;
                   Error D.Cancelled)
            | _ -> Error D.Stale_context)
      }
    in
    let t, cold, _ = fixture env ~sw ~dispatch () in
    let parent =
      D.with_scope (fun scope ->
        D.task_bind
          (D.spawn scope (task (D.Task_assets D.Prune_cache)))
          (function
            | Error e -> D.task_fail e
            | Ok _ -> task (D.Sleep 3600.)))
    in
    let rec wait_entered () =
      if !entered then D.task_return () else D.task_bind (task D.Yield) wait_entered
    in
    let body =
      D.with_scope (fun scope ->
        D.task_bind (D.spawn scope parent) (function
          | Error e -> D.task_fail e
          | Ok child ->
            D.task_bind (wait_entered ()) (fun () ->
              D.task_bind (D.cancel_child child) (fun () ->
                D.task_bind (D.join child) (fun _ -> D.task_return !joined)))))
    in
    match run t (ready t cold) body with
    | X.Completed (_, joined) ->
      check joined "grandchild physically joined before child result"
    | X.Failed (_, e) -> Alcotest.fail (D.error_message e))
;;

let ready_child_not_starved env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let rec select child turns =
      if turns = 4
      then D.task_return false
      else (
        ignore
          (get
             (X.submit_unlock
                t
                ~identity
                ~valid_for:10.
                (get (D.unlock_input ~wrapped_graph_key:"ready"))));
        D.task_bind
          (task (D.Await_input_or_child (Rrbvec.of_list [ child ])))
          (function
            | D.Child_ready _ -> D.task_bind (D.join child) (fun _ -> D.task_return true)
            | D.Input _ -> select child (turns + 1)))
    in
    let body =
      D.with_scope (fun scope ->
        D.task_bind
          (D.spawn scope (D.task_return ()))
          (function
            | Error e -> D.task_fail e
            | Ok child -> D.task_bind (task D.Yield) (fun () -> select child 0)))
    in
    match run t (ready t cold) body with
    | X.Completed (_, handled) ->
      check handled "ready child handled within four input turns"
    | X.Failed (_, e) -> Alcotest.fail (D.error_message e))
;;

let demand_change =
  let module A = Logseq_db_types.Asset_descriptor in
  let uuid =
    get
      (Result.map_error
         (fun message -> D.Invalid_input message)
         (Logseq_db_types.Graph_types.Uuid.of_string
            "11111111-1111-4111-8111-111111111111"))
  in
  let asset =
    get
      (Result.map_error
         (fun message -> D.Invalid_input message)
         (A.create
            ~uuid
            ~source:(A.External "https://example.com/asset")
            ~current_checksum:None
            ~size:None
            ~dimensions:None))
  in
  D.Demand { id = get (D.demand_id "consumer"); asset; priority = D.Foreground }
;;

let demand_loop =
  D.with_scope (fun _ ->
    let rec loop () =
      D.task_bind (task D.Next_input) (function
        | D.Demand_changed (receipt, _) ->
          D.task_bind (task (D.Publish_demand (receipt, D.Demand_queued))) loop
        | D.Stop_requested -> D.task_return ()
        | _ -> loop ())
    in
    loop ())
;;

let held_delivery_retirement env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let next = ready t cold in
    let running =
      get
        (X.start
           t
           next
           (D.perform (D.Run_task demand_loop) ~success:D.return ~failure:D.abort))
    in
    Eio.Fiber.yield ();
    ignore (get (X.update_demand t demand_change));
    let delivery = get (X.receive_demand t) in
    get (X.request_stop t);
    let next =
      match X.await running with
      | X.Completed (next, ()) -> next
      | X.Failed (_, e) -> Alcotest.fail (D.error_message e)
    in
    let closing =
      get
        (X.start
           t
           next
           (D.perform (D.begin_drain D.Ready_context) ~failure:D.abort ~success:(fun () ->
              D.perform D.finish_retirement ~failure:D.abort ~success:D.return)))
    in
    let finished = ref false in
    let result =
      Eio.Fiber.fork_promise ~sw (fun () ->
        let result = X.await closing in
        finished := true;
        result)
    in
    for _ = 1 to 4 do
      Eio.Fiber.yield ()
    done;
    let waited = not !finished in
    get (X.release_demand t delivery.delivery);
    get (X.release_demand t delivery.delivery);
    check waited "retirement waits for consumer release";
    match Eio.Promise.await_exn result with
    | X.Completed (_, ()) -> ()
    | X.Failed (_, e) -> Alcotest.fail (D.error_message e))
;;

let callback_failed_join_retains_owner env () =
  Eio.Switch.run (fun sw ->
    let weak = Weak.create 1 in
    let dispatch : X.dispatch =
      { database = (fun ~owner:_ ~scope:_ ~identity:_ _ -> Error D.Stale_context)
      ; transport = (fun ~scope:_ ~identity:_ _ -> Error D.Network_closed)
      ; crypto = (fun ~scope:_ ~identity:_ _ -> Error D.Locked)
      ; assets =
          (fun ~scope ~identity:_ _ ->
            let owner = ref 17 in
            Weak.set weak 0 (Some owner);
            X.Callback_bridge.run
              ~scope
              ~resources:(fun _ -> Rrbvec.of_list [])
              { start = (fun ~deliver -> deliver (Error D.Locked))
              ; stop = (fun () -> Error (D.Storage_failure "stop failed"))
              ; await_stopped =
                  (fun ~deadline:_ ->
                    ignore (Sys.opaque_identity !owner);
                    Error (D.Storage_failure "join failed"))
              })
      }
    in
    let t, cold, _ = fixture env ~sw ~dispatch () in
    (match run t (ready t cold) (task (D.Task_assets D.Prune_cache)) with
     | X.Failed (_, D.Cleanup_failure _) -> ()
     | _ -> Alcotest.fail "cleanup failure must force draining");
    Gc.full_major ();
    check (Weak.check weak 0) "failed producer owner stays reachable until physical join")
;;

let released_metadata_bounded env () =
  Eio.Switch.run (fun sw ->
    let scope = ref None in
    let t, cold, _ =
      fixture
        env
        ~sw
        ~restore:(fun ~scope:current _ ->
          scope := Some current;
          Ok { D.keys = D.Unencrypted; checkpoint = None; recovery_pending = false })
        ()
    in
    let context = ref (ready t cold) in
    let through =
      get
        (Result.map_error
           (fun _ -> D.Invalid_input "cursor")
           (Logseq_db_types.Server_cursor.of_int64 0L))
    in
    let batch offset =
      for index = 1 to 1000 do
        let snapshot =
          get
            (D.snapshot
               ~resource:
                 (get
                    (D.resource ~owner:identity ~token:(string_of_int (offset + index))))
               ~through
               ~checksum:"snapshot"
               ~encrypted:false)
        in
        get
          (X.handoff
             (Option.get !scope)
             (Rrbvec.of_list [ D.Snapshot_reference snapshot ]));
        let program =
          D.perform (D.release_snapshot snapshot) ~failure:D.abort ~success:D.return
        in
        match X.await (get (X.start t !context program)) with
        | X.Completed (next, ()) -> context := next
        | X.Failed (_, error) -> Alcotest.fail (D.error_message error)
      done
    in
    batch 0;
    Gc.full_major ();
    let before = (Gc.stat ()).live_words in
    batch 1000;
    Gc.full_major ();
    let growth = (Gc.stat ()).live_words - before in
    check
      (growth < 5000)
      (Printf.sprintf "released resource metadata bounded: grew %d words" growth))
;;

let callback_capacity env () =
  Eio.Switch.run (fun sw ->
    let starts = ref 0
    and stops = ref 0
    and joins = ref 0
    and rejected = ref false in
    let dispatch : X.dispatch =
      { database = (fun ~owner:_ ~scope:_ ~identity:_ _ -> Error D.Locked)
      ; transport = (fun ~scope:_ ~identity:_ _ -> Error D.Network_closed)
      ; crypto = (fun ~scope:_ ~identity:_ _ -> Error D.Locked)
      ; assets =
          (fun (type a)
            ~scope
            ~identity:_
            (operation : a D.assets)
            : (a, D.error) result ->
            match operation with
            | D.Prune_cache ->
              let rec reserve depth =
                X.Callback_bridge.run
                  ~scope
                  ~resources:(fun _ -> Rrbvec.empty)
                  { start =
                      (fun ~deliver ->
                        incr starts;
                        let result = reserve (depth + 1) in
                        (if depth = limits.maximum_resources
                         then
                           rejected
                           := match result with
                              | Error (D.Capacity_exceeded _) -> true
                              | _ -> false);
                        deliver (Error D.Locked))
                  ; stop =
                      (fun () ->
                        incr stops;
                        Ok ())
                  ; await_stopped =
                      (fun ~deadline:_ ->
                        incr joins;
                        Ok ())
                  }
              in
              reserve 1
            | _ -> Error D.Stale_context)
      }
    in
    let t, cold, _ = fixture env ~sw ~dispatch () in
    ignore (run t (ready t cold) (task (D.Task_assets D.Prune_cache)));
    check !rejected "producer capacity rejects before native start";
    Alcotest.(check int) "bounded starts" limits.maximum_resources !starts;
    Alcotest.(check int) "all admitted producers stopped" !starts !stops;
    Alcotest.(check int) "all admitted producers joined" !starts !joins)
;;

let callback_terminal_capacity_rejection env () =
  let releases = ref 0
  and joined = ref false
  and rejected = ref false in
  Eio.Switch.run (fun sw ->
    let cursor =
      get
        (Result.map_error
           (fun _ -> D.Invalid_input "cursor")
           (Logseq_db_types.Server_cursor.of_int64 0L))
    in
    let reference index =
      D.Snapshot_reference
        (get
           (D.snapshot
              ~resource:(get (D.resource ~owner:identity ~token:(string_of_int index)))
              ~through:cursor
              ~checksum:"capacity"
              ~encrypted:false))
    in
    let dispatch : X.dispatch =
      { database = (fun ~owner:_ ~scope:_ ~identity:_ _ -> Error D.Locked)
      ; transport = (fun ~scope:_ ~identity:_ _ -> Error D.Network_closed)
      ; crypto = (fun ~scope:_ ~identity:_ _ -> Error D.Locked)
      ; assets =
          (fun (type a)
            ~scope
            ~identity:_
            (operation : a D.assets)
            : (a, D.error) result ->
            match operation with
            | D.Prune_cache ->
              X.Callback_bridge.run
                ~scope
                ~resources:(fun _ -> Rrbvec.of_list [ reference 8; reference 9 ])
                { start =
                    (fun ~deliver ->
                      (rejected
                       := match
                            deliver
                              (Ok
                                 { D.resident_bytes = 0L
                                 ; pending_bytes = 0L
                                 ; retained_bytes = 0L
                                 ; cleanup_pending = 0
                                 ; over_budget = false
                                 })
                          with
                          | Error (D.Capacity_exceeded _) -> true
                          | _ -> false);
                      Ok ())
                ; stop = (fun () -> Ok ())
                ; await_stopped =
                    (fun ~deadline:_ ->
                      joined := true;
                      Ok ())
                }
            | _ -> Error D.Stale_context)
      }
    in
    let caps =
      capabilities
        ~dispatch
        ~restore:(fun ~scope _ ->
          get (X.handoff scope (Rrbvec.of_list (List.init 7 reference)));
          Ok { D.keys = D.Unencrypted; checkpoint = None; recovery_pending = false })
        ()
    in
    let caps =
      { caps with
        release_snapshot =
          (fun _ _ ->
            incr releases;
            Ok ())
      }
    in
    let t, cold =
      get
        (X.create
           ~sw
           ~clock:(Eio.Stdenv.mono_clock env)
           ~database_owner:(owner ~sw)
           ~identity
           ~limits
           caps)
    in
    match run t (ready t cold) (task (D.Task_assets D.Prune_cache)) with
    | X.Failed (_, D.Capacity_exceeded _) -> ()
    | _ -> Alcotest.fail "resource rejection must resolve terminal without hanging");
  check !rejected "callback receives rejected handoff ACK";
  check !joined "rejected terminal still physically joins producer";
  Alcotest.(check int) "no partially accepted resources" 7 !releases
;;

let terminal_cancel_rejected env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let running = get (X.start t cold restore) in
    ignore (X.await running);
    check (X.cancel t running = Error D.Stale_context) "terminal cancellation rejects";
    match get (X.current t) with
    | X.Context (D.Ready, next) ->
      (match X.await (get (X.start t next (D.return ()))) with
       | X.Completed _ -> ()
       | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
    | _ -> Alcotest.fail "terminal rejection must preserve ready context")
;;

let delivery_metadata_bounded env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let running =
      get
        (X.start
           t
           (ready t cold)
           (D.perform (D.Run_task demand_loop) ~success:D.return ~failure:D.abort))
    in
    Eio.Fiber.yield ();
    let batch () =
      for _ = 1 to 1000 do
        ignore (get (X.update_demand t demand_change));
        let output = get (X.receive_demand t) in
        get (X.release_demand t output.delivery);
        get (X.release_demand t output.delivery);
        check
          (get (X.demand_status t output.delivery) = X.Revoked)
          "released delivery stays revoked"
      done
    in
    batch ();
    Gc.full_major ();
    let before = (Gc.stat ()).live_words in
    batch ();
    Gc.full_major ();
    let growth = (Gc.stat ()).live_words - before in
    check
      (growth < 5000)
      (Printf.sprintf "released delivery metadata bounded: grew %d words" growth);
    get (X.request_stop t);
    match X.await running with
    | X.Completed _ -> ()
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

module Service = Logseq_sync_sync_service.Core

let service_config =
  let retry =
    get
      (D.retry_policy
         ~initial_seconds:0.01
         ~maximum_seconds:0.02
         ~multiplier:2.
         ~maximum_attempts:0)
  in
  { Service.identity
  ; limits
  ; network = D.Closed
  ; policy =
      get (D.policy_config ~sync_retry:retry ~asset_retry:retry ~no_progress_seconds:0.01)
  }
;;

let service_receipts_and_consumer ?(withdraw = false) env () =
  Eio.Switch.run (fun sw ->
    let unlocked = ref 0
    and released = ref [] in
    let asset =
      match demand_change with
      | D.Demand demand -> demand.asset
      | _ -> assert false
    in
    let file =
      get (D.asset_file (get (D.resource ~owner:identity ~token:"service-file")) asset)
    in
    let lease =
      get (D.asset_lease (get (D.resource ~owner:identity ~token:"service-lease")) file)
    in
    let dispatch : X.dispatch =
      { database =
          (fun ~owner:_ ~scope:_ ~identity:_ _ -> Error (D.Storage_failure "No mirror"))
      ; transport = (fun ~scope:_ ~identity:_ _ -> Error D.Network_closed)
      ; crypto =
          (fun (type a)
            ~scope:_
            ~identity:_
            (operation : a D.crypto)
            : (a, D.error) result ->
            match operation with
            | D.Unlock _ ->
              incr unlocked;
              Ok D.Unencrypted
            | _ -> Error D.Locked)
      ; assets =
          (fun (type a)
            ~scope
            ~identity:_
            (operation : a D.assets)
            : (a, D.error) result ->
            match operation with
            | D.Lookup _ ->
              Result.map
                (fun () -> Some file)
                (X.handoff scope (Rrbvec.of_list [ D.File_reference file ]))
            | D.Retain _ ->
              Result.map
                (fun () -> lease)
                (X.handoff scope (Rrbvec.of_list [ D.Lease_reference lease ]))
            | _ -> Error D.Stale_context)
      }
    in
    let caps =
      capabilities
        ~dispatch
        ~restore:(fun ~scope:_ _ ->
          Ok { D.keys = D.Key_locked; checkpoint = None; recovery_pending = false })
        ()
    in
    let caps =
      { caps with
        release_file =
          (fun _ _ ->
            released := !released @ [ "file" ];
            Ok ())
      ; release_lease =
          (fun _ _ ->
            released := !released @ [ "lease" ];
            Ok ())
      }
    in
    let ingress, bind = Eio.Promise.create () in
    let statuses = ref [] in
    let service =
      get
        (Service.start
           ~sw
           ~config:service_config
           ~dependencies:
             { clock = Eio.Stdenv.mono_clock env
             ; database_owner = owner ~sw
             ; capabilities = caps
             ; bind_ingress =
                 (fun value ->
                   check
                     (Result.is_error
                        (value.submit_unlock
                           ~identity
                           ~valid_for:10.
                           (get (D.unlock_input ~wrapped_graph_key:"too-early"))))
                     "binder precedes policy input scope";
                   Eio.Promise.resolve bind value)
             }
           ~on_change:(fun status -> statuses := status.lifecycle :: !statuses))
    in
    let ingress = Eio.Promise.await ingress in
    for _ = 1 to 12 do
      Eio.Fiber.yield ()
    done;
    ignore
      (get
         (ingress.submit_unlock
            ~identity
            ~valid_for:10.
            (get (D.unlock_input ~wrapped_graph_key:"wrapped"))));
    ignore (get (ingress.update_demand demand_change));
    let rec available () =
      let output = get (ingress.receive_demand ()) in
      match output.availability with
      | D.Demand_available _ -> output
      | _ ->
        get (ingress.release_demand output.delivery);
        available ()
    in
    let output = Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2. available in
    check (!unlocked = 1) "actual policy consumed exact unlock receipt once";
    check
      (get (ingress.demand_status output.delivery) = X.Current)
      "completed delivery remains current until revocation";
    if withdraw
    then (
      let demand_id =
        match demand_change with
        | D.Demand demand -> demand.id
        | _ -> assert false
      in
      ignore (get (ingress.update_demand (D.Withdraw demand_id)));
      check
        (get (ingress.demand_status output.delivery) = X.Revoked)
        "withdrawal revokes completed delivery");
    let closing = Eio.Fiber.fork_promise ~sw (fun () -> Service.close service) in
    for _ = 1 to 12 do
      Eio.Fiber.yield ()
    done;
    check (not (Eio.Promise.is_resolved closing)) "service close waits for consumer lease";
    check (!released = []) "revocation preserves consumer bytes";
    get (ingress.release_demand output.delivery);
    get (ingress.release_demand output.delivery);
    Eio.Promise.await_exn closing;
    Alcotest.(check (list string))
      "physical lease before file once"
      [ "lease"; "file" ]
      !released;
    check (List.mem Service.Closed !statuses) "closed callback follows retirement")
;;

let service_callback_failure env () =
  let retired = ref false in
  let callback_error = Failure "service callback regression" in
  let failed =
    try
      Eio.Switch.run (fun sw ->
        let caps = capabilities () in
        let caps =
          { caps with
            retire =
              (fun _ ->
                retired := true;
                Ok ())
          }
        in
        ignore
          (get
             (Service.start
                ~sw
                ~config:service_config
                ~dependencies:
                  { clock = Eio.Stdenv.mono_clock env
                  ; database_owner = owner ~sw
                  ; capabilities = caps
                  ; bind_ingress = (fun _ -> ())
                  }
                ~on_change:(fun _ -> raise callback_error)));
        let never, _ = Eio.Promise.create () in
        (Eio.Promise.await never : unit));
      false
    with
    | _ -> true
  in
  check failed "callback failure reaches service switch";
  check !retired "callback failure still retires original owners"
;;

let ( let@ ) = D.task_bind
let ( let* ) = Result.bind

let notification_capacity env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let notification = D.Policy_failure (D.Network_failure "caller-owned") in
    let body =
      D.with_scope (fun scope ->
        let@ first = task (D.Notifications scope) in
        let@ second = task (D.Notifications scope) in
        let rec fill count =
          if count = limits.maximum_messages
          then D.task_return ()
          else
            let@ () =
              task (D.Notify ((if count mod 2 = 0 then first else second), notification))
            in
            fill (count + 1)
        in
        let@ () = fill 0 in
        let@ rejected =
          D.task_perform
            (D.Notify (first, notification))
            ~success:(fun () -> D.task_return false)
            ~failure:(fun error ->
              D.task_return
                (match error with
                 | D.Capacity_exceeded _ -> true
                 | _ -> false))
        in
        check rejected "notification count is shared across channels";
        let@ received = task (D.Next_notification second) in
        check (received = notification) "rejection preserves queued payload";
        let@ () = task (D.Notify (first, notification)) in
        D.task_return ())
    in
    match run t (ready t cold) body with
    | X.Completed _ -> ()
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

let notification_descriptor_bytes env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let payload = String.make 800 'x' in
    let notification = D.Policy_failure (D.Network_failure payload) in
    let body =
      D.with_scope (fun scope ->
        let@ first = task (D.Notifications scope) in
        let@ second = task (D.Notifications scope) in
        let@ () = task (D.Notify (first, notification)) in
        let rejected = X.update_demand t demand_change in
        check
          (match rejected with
           | Error (D.Capacity_exceeded _) -> true
           | _ -> false)
          "descriptors share notification byte budget";
        let@ rejected =
          D.task_perform
            (D.Notify (second, notification))
            ~success:(fun () -> D.task_return false)
            ~failure:(fun error ->
              D.task_return
                (match error with
                 | D.Capacity_exceeded _ -> true
                 | _ -> false))
        in
        check rejected "notification bytes are shared across channels";
        let@ received = task (D.Next_notification first) in
        check
          (received = notification && String.length payload = 800)
          "byte rejection preserves caller and queued payload";
        ignore (get (X.update_demand t demand_change));
        let@ rejected =
          D.task_perform
            (D.Notify (second, notification))
            ~success:(fun () -> D.task_return false)
            ~failure:(fun error ->
              D.task_return
                (match error with
                 | D.Capacity_exceeded _ -> true
                 | _ -> false))
        in
        check rejected "notification admission includes descriptors";
        D.task_return ())
    in
    match run t (ready t cold) body with
    | X.Completed _ -> ()
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

let active_asset_capacity env () =
  Eio.Switch.run (fun sw ->
    let module A = Logseq_db_types.Asset_descriptor in
    let asset =
      Result.get_ok
        (A.create
           ~uuid:
             (Result.get_ok
                (Logseq_db_types.Graph_types.Uuid.of_string
                   "11111111-1111-4111-8111-111111111111"))
           ~source:
             (A.Managed
                (Some
                   (Result.get_ok
                      (A.version ~checksum:(String.make 64 'a') ~file_type:"png"))))
           ~current_checksum:None
           ~size:(Some 1L)
           ~dimensions:None)
    in
    let entered = ref 0 in
    let release, resolve = Eio.Promise.create () in
    let dispatch : X.dispatch =
      { (capabilities ()).dispatch with
        assets =
          (fun (type a) ~scope:_ ~identity:_ (op : a D.assets) : (a, D.error) result ->
            match op with
            | D.Download _ ->
              incr entered;
              Eio.Promise.await release;
              Ok D.Waiting_remote
            | D.Upload _ ->
              incr entered;
              if !entered <= 2 then Eio.Promise.await release;
              Ok ()
            | _ -> Error D.Stale_context)
      }
    in
    let t, cold, _ = fixture env ~sw ~dispatch () in
    get (X.open_network t ~authorization_epoch:7L);
    let rec until n =
      if !entered >= n
      then D.task_return ()
      else D.task_bind (task D.Yield) (fun () -> until n)
    in
    let body =
      D.with_scope (fun scope ->
        let@ first = D.spawn scope (task (D.Task_assets (D.Download asset))) in
        let@ () = until 1 in
        let@ second = D.spawn scope (task (D.Task_assets (D.Upload asset))) in
        let@ () = until 2 in
        let@ rejected =
          D.task_perform
            (D.Task_assets (D.Upload asset))
            ~success:(fun () -> D.task_return false)
            ~failure:(fun e ->
              D.task_return
                (match e with
                 | D.Capacity_exceeded _ -> true
                 | _ -> false))
        in
        Eio.Promise.resolve resolve ();
        check rejected "third transfer rejects before dispatch";
        check (!entered = 2) "rejection starts no transfer";
        let@ _ = D.join (get first) in
        let@ _ = D.join (get second) in
        task (D.Task_assets (D.Upload asset)))
    in
    match run t (ready t cold) body with
    | X.Completed _ -> check (!entered = 3) "joined work returns capacity after rejection"
    | X.Failed (_, e) -> Alcotest.fail (D.error_message e))
;;

let active_asset_cancel_join env () =
  Eio.Switch.run (fun sw ->
    let asset =
      match demand_change with
      | D.Demand d -> d.asset
      | D.Withdraw _ -> assert false
    in
    let entered = ref 0
    and stopping = ref 0 in
    let joined, resolve_join = Eio.Promise.create () in
    let dispatch : X.dispatch =
      { (capabilities ()).dispatch with
        assets =
          (fun (type a) ~scope ~identity:_ (op : a D.assets) : (a, D.error) result ->
            match op with
            | D.Upload _ ->
              X.Callback_bridge.run
                ~scope
                ~resources:(fun () -> Rrbvec.empty)
                { start =
                    (fun ~deliver ->
                      incr entered;
                      if !entered > 2 then deliver (Ok ()) else Ok ())
                ; stop =
                    (fun () ->
                      incr stopping;
                      Ok ())
                ; await_stopped =
                    (fun ~deadline:_ ->
                      if !entered <= 2 then Eio.Promise.await joined;
                      Ok ())
                }
            | _ -> Error D.Stale_context)
      }
    in
    let t, cold, _ = fixture env ~sw ~dispatch () in
    get (X.open_network t ~authorization_epoch:7L);
    let rec until counter n =
      if !counter >= n
      then D.task_return ()
      else D.task_bind (task D.Yield) (fun () -> until counter n)
    in
    let body =
      D.with_scope (fun scope ->
        let@ first = D.spawn scope (task (D.Task_assets (D.Upload asset))) in
        let@ second = D.spawn scope (task (D.Task_assets (D.Upload asset))) in
        let@ () = until entered 2 in
        let@ () = D.cancel_child (get first) in
        let@ () = until stopping 1 in
        let@ rejected =
          D.task_perform
            (D.Task_assets (D.Upload asset))
            ~success:(fun () -> D.task_return false)
            ~failure:(fun e ->
              D.task_return
                (match e with
                 | D.Capacity_exceeded _ -> true
                 | _ -> false))
        in
        Eio.Promise.resolve resolve_join ();
        check rejected "cancel retains active capacity until physical join";
        check (!entered = 2) "cancel does not start a third producer";
        let@ _ = D.join (get first) in
        let@ () = D.cancel_child (get second) in
        let@ _ = D.join (get second) in
        D.task_return ())
    in
    match run t (ready t cold) body with
    | X.Completed _ -> ()
    | X.Failed (_, e) -> Alcotest.fail (D.error_message e))
;;

let active_asset_foreground env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let module A = Logseq_db_types.Asset_descriptor in
    let base =
      match demand_change with
      | D.Demand d -> d.asset
      | _ -> assert false
    in
    let asset checksum =
      Result.get_ok
        (A.create
           ~uuid:base.uuid
           ~source:
             (A.Managed
                (Some
                   (Result.get_ok
                      (A.version ~checksum:(String.make 64 checksum) ~file_type:"png"))))
           ~current_checksum:None
           ~size:(Some 1L)
           ~dimensions:None)
    in
    let change id selected priority =
      D.Demand { id = get (D.demand_id id); asset = selected; priority }
    in
    let rec next () =
      let@ input = task D.Next_input in
      match input with
      | D.Demand_changed (receipt, _) -> D.task_return receipt
      | _ -> next ()
    in
    let body =
      D.with_scope (fun scope ->
        ignore (get (X.update_demand t (change "bg" (asset 'a') D.Background)));
        let@ background = next () in
        let@ first = D.spawn_asset scope background (task (D.Sleep 3600.)) in
        ignore (get first);
        ignore (get (X.update_demand t (change "fg" (asset 'b') D.Foreground)));
        let@ foreground = next () in
        let@ second = D.spawn_asset scope foreground (task (D.Sleep 3600.)) in
        ignore (get second);
        ignore (get (X.update_demand t (change "extra" (asset 'c') D.Foreground)));
        let@ extra = next () in
        let@ rejected = D.spawn_asset scope extra (D.task_return ()) in
        let cap =
          match rejected with
          | Error (D.Capacity_exceeded _) -> true
          | _ -> false
        in
        let@ () = task (D.Finish_demand extra) in
        check
          (match X.update_demand t (change "shared" (asset 'b') D.Foreground) with
           | Error (D.Capacity_exceeded _) -> true
           | _ -> false)
          "finished interest remains descriptor charged until withdrawal";
        ignore (get (X.update_demand t (D.Withdraw (get (D.demand_id "extra")))));
        let@ withdrawn = next () in
        let@ () = task (D.Finish_demand withdrawn) in
        ignore (get (X.update_demand t (change "shared" (asset 'b') D.Foreground)));
        let@ shared = next () in
        let@ shared_child = D.spawn_asset scope shared (D.task_return ()) in
        let demotion = X.update_demand t (change "fg" (asset 'b') D.Background) in
        let shared_demotion =
          X.update_demand t (change "shared" (asset 'b') D.Background)
        in
        let@ _ = D.join (get shared_child) in
        let@ () = D.cancel_child (get first) in
        let@ _ = D.join (get first) in
        let@ () = D.cancel_child (get second) in
        let@ _ = D.join (get second) in
        D.task_return (cap, Result.is_ok demotion, shared_demotion))
    in
    match run t (ready t cold) body with
    | X.Completed (_, (cap, demoted, last_demotion)) ->
      check cap "asset child reserves before allocation";
      check demoted "shared foreground interest keeps shared work foreground";
      check
        (match last_demotion with
         | Error (D.Capacity_exceeded _) -> true
         | _ -> false)
        "last foreground demotion cannot borrow reserved work"
    | X.Failed (_, e) -> Alcotest.fail (D.error_message e))
;;

let active_asset_shared_download env () =
  Eio.Switch.run (fun sw ->
    let selected =
      match demand_change with
      | D.Demand d -> d.asset
      | _ -> assert false
    in
    let started = ref 0 in
    let release, resolve = Eio.Promise.create () in
    let dispatch : X.dispatch =
      { (capabilities ()).dispatch with
        assets =
          (fun (type a) ~scope:_ ~identity:_ (op : a D.assets) : (a, D.error) result ->
            match op with
            | D.Download _ ->
              incr started;
              Eio.Promise.await release;
              Ok D.Waiting_remote
            | _ -> Error D.Stale_context)
      }
    in
    let t, cold, _ = fixture env ~sw ~dispatch () in
    get (X.open_network t ~authorization_epoch:7L);
    let rec next () =
      let@ input = task D.Next_input in
      match input with
      | D.Demand_changed (receipt, _) -> D.task_return receipt
      | _ -> next ()
    in
    let body =
      D.with_scope (fun scope ->
        ignore (get (X.update_demand t demand_change));
        let@ first_receipt = next () in
        let@ first =
          D.spawn_asset scope first_receipt (task (D.Task_assets (D.Download selected)))
        in
        ignore
          (get
             (X.update_demand
                t
                (D.Demand
                   { id = get (D.demand_id "shared")
                   ; asset = selected
                   ; priority = D.Foreground
                   })));
        let@ second_receipt = next () in
        let@ second =
          D.spawn_asset scope second_receipt (task (D.Task_assets (D.Download selected)))
        in
        let@ () = task D.Yield in
        let@ () = task D.Yield in
        let count = !started in
        let@ () = D.cancel_child (get first) in
        let@ () = task D.Yield in
        Eio.Promise.resolve resolve ();
        let@ _ = D.join (get first) in
        let@ result = D.join (get second) in
        D.task_return (count, result))
    in
    match run t (ready t cold) body with
    | X.Completed (_, (count, result)) ->
      Alcotest.(check int) "shared demand admits one physical download" 1 count;
      check (result = Ok D.Waiting_remote) "cancelling one interest preserves the other"
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

let active_asset_available_owner env () =
  Eio.Switch.run (fun sw ->
    let selected =
      match demand_change with
      | D.Demand demand -> demand.asset
      | _ -> assert false
    in
    let original =
      get
        (D.asset_file
           (get (D.resource ~owner:identity ~token:"shared-original"))
           selected)
    in
    let entered = ref false in
    let release, resolve = Eio.Promise.create () in
    let dispatch : X.dispatch =
      { (capabilities ()).dispatch with
        assets =
          (fun (type a)
            ~scope
            ~identity:_
            (operation : a D.assets)
            : (a, D.error) result ->
            match operation with
            | D.Download _ ->
              entered := true;
              Eio.Promise.await release;
              let result =
                X.handoff scope (Rrbvec.of_list [ D.File_reference original ])
              in
              Result.map (fun () -> D.Available original) result
            | D.Lookup _ -> Ok None
            | _ -> Error D.Stale_context)
      }
    in
    let t, cold, _ = fixture env ~sw ~dispatch () in
    get (X.open_network t ~authorization_epoch:7L);
    let rec next () =
      let@ input = task D.Next_input in
      match input with
      | D.Demand_changed (receipt, _) -> D.task_return receipt
      | _ -> next ()
    in
    let rec until () =
      if !entered
      then D.task_return ()
      else
        let@ () = task D.Yield in
        until ()
    in
    let body =
      D.with_scope (fun scope ->
        ignore (get (X.update_demand t demand_change));
        let@ receipt = next () in
        let@ first =
          D.spawn_asset scope receipt (task (D.Task_assets (D.Download selected)))
        in
        let@ () = until () in
        let@ second =
          D.spawn_asset scope receipt (task (D.Task_assets (D.Download selected)))
        in
        let@ () = task D.Yield in
        let@ () = task D.Yield in
        let@ () = D.cancel_child (get first) in
        let@ () = task D.Yield in
        Eio.Promise.resolve resolve ();
        let@ _ = D.join (get first) in
        let@ result = D.join (get second) in
        check
          (result = Ok (D.Available original))
          "surviving waiter owns original available file";
        task (D.Task_assets (D.Release_file original)))
    in
    match run t (ready t cold) body with
    | X.Completed _ -> ()
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

let active_asset_demotion env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let selected =
      match demand_change with
      | D.Demand demand -> demand.asset
      | _ -> assert false
    in
    let rec next () =
      let@ input = task D.Next_input in
      match input with
      | D.Demand_changed (receipt, _) -> D.task_return receipt
      | _ -> next ()
    in
    let body =
      D.with_scope (fun scope ->
        ignore (get (X.update_demand t demand_change));
        let@ receipt = next () in
        let rec fill count children =
          if count = limits.maximum_pending - 3
          then D.task_return children
          else
            let@ child = D.spawn_asset scope receipt (task (D.Sleep 3600.)) in
            fill (count + 1) (get child :: children)
        in
        let@ children = fill 0 [] in
        let demoted =
          X.update_demand
            t
            (D.Demand
               { id =
                   (match demand_change with
                    | D.Demand demand -> demand.id
                    | _ -> assert false)
               ; asset = selected
               ; priority = D.Background
               })
        in
        check
          (match demoted with
           | Error (D.Capacity_exceeded _) -> true
           | _ -> false)
          "demotion cannot inherit foreground child reservations";
        let rec join = function
          | [] -> D.task_return ()
          | child :: rest ->
            let@ () = D.cancel_child child in
            let@ _ = D.join child in
            join rest
        in
        let@ () = join children in
        ignore
          (get
             (X.update_demand
                t
                (D.Demand
                   { id =
                       (match demand_change with
                        | D.Demand demand -> demand.id
                        | _ -> assert false)
                   ; asset = selected
                   ; priority = D.Background
                   })));
        D.task_return ())
    in
    match run t (ready t cold) body with
    | X.Completed _ -> ()
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

let active_asset_mixed_direction env () =
  Eio.Switch.run (fun sw ->
    let selected =
      match demand_change with
      | D.Demand demand -> demand.asset
      | _ -> assert false
    in
    let entered = ref 0 in
    let release, resolve = Eio.Promise.create () in
    let dispatch : X.dispatch =
      { (capabilities ()).dispatch with
        assets =
          (fun (type a)
            ~scope:_
            ~identity:_
            (operation : a D.assets)
            : (a, D.error) result ->
            match operation with
            | D.Download _ ->
              incr entered;
              Eio.Promise.await release;
              Ok D.Waiting_remote
            | D.Upload _ ->
              incr entered;
              Ok ()
            | _ -> Error D.Stale_context)
      }
    in
    let t, cold, _ = fixture env ~sw ~dispatch () in
    get (X.open_network t ~authorization_epoch:7L);
    let rec next () =
      let@ input = task D.Next_input in
      match input with
      | D.Demand_changed (receipt, _) -> D.task_return receipt
      | _ -> next ()
    in
    let rec until () =
      if !entered > 0
      then D.task_return ()
      else
        let@ () = task D.Yield in
        until ()
    in
    let body =
      D.with_scope (fun scope ->
        ignore (get (X.update_demand t demand_change));
        let@ receipt = next () in
        let@ first =
          D.spawn_asset scope receipt (task (D.Task_assets (D.Download selected)))
        in
        let@ () = until () in
        let module A = Logseq_db_types.Asset_descriptor in
        let other =
          Result.get_ok
            (A.create
               ~uuid:selected.uuid
               ~source:selected.source
               ~current_checksum:(Some (String.make 64 'b'))
               ~size:selected.size
               ~dimensions:selected.dimensions)
        in
        ignore
          (get
             (X.update_demand
                t
                (D.Demand
                   { id = get (D.demand_id "other")
                   ; asset = other
                   ; priority = D.Foreground
                   })));
        let@ other_receipt = next () in
        let@ blocker = D.spawn_asset scope other_receipt (task (D.Sleep 3600.)) in
        let@ second =
          D.spawn_asset scope receipt (task (D.Task_assets (D.Upload selected)))
        in
        let@ result = D.join (get second) in
        let rejected =
          match result with
          | Error (D.Capacity_exceeded _) -> true
          | _ -> false
        in
        Eio.Promise.resolve resolve ();
        let@ _ = D.join (get first) in
        check rejected "shared asset cannot silently run both transfer directions";
        check (!entered = 1) "mixed-direction rejection starts no producer";
        let@ () = D.cancel_child (get blocker) in
        let@ _ = D.join (get blocker) in
        task (D.Task_assets (D.Upload selected)))
    in
    match run t (ready t cold) body with
    | X.Completed _ -> ()
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

let active_asset_resource_rejection env () =
  Eio.Switch.run (fun sw ->
    let asset =
      match demand_change with
      | D.Demand demand -> demand.asset
      | _ -> assert false
    in
    let called = ref false in
    let dispatch : X.dispatch =
      { (capabilities ()).dispatch with
        assets =
          (fun (type a) ~scope:_ ~identity:_ (op : a D.assets) : (a, D.error) result ->
            match op with
            | D.Upload _ ->
              called := true;
              Ok ()
            | _ -> Error D.Stale_context)
      }
    in
    let restore ~scope _ =
      let references =
        List.init limits.maximum_resources (fun index ->
          D.File_reference
            (get
               (D.asset_file
                  (get (D.resource ~owner:identity ~token:(string_of_int index)))
                  asset)))
      in
      get (X.handoff scope (Rrbvec.of_list references));
      Ok { D.keys = D.Unencrypted; checkpoint = None; recovery_pending = false }
    in
    let t, cold, _ = fixture env ~sw ~dispatch ~restore () in
    get (X.open_network t ~authorization_epoch:7L);
    let result = run t (ready t cold) (task (D.Task_assets (D.Upload asset))) in
    check
      (match result with
       | X.Failed (_, D.Capacity_exceeded _) -> true
       | _ -> false)
      "asset reserves cleanup capacity before dispatch";
    check (not !called) "resource rejection does not allocate or start")
;;

let policy_demand_lifecycle env () =
  Eio.Switch.run (fun sw ->
    let dispatch : X.dispatch =
      { (capabilities ()).dispatch with
        assets =
          (fun (type a) ~scope:_ ~identity:_ (op : a D.assets) : (a, D.error) result ->
            match op with
            | D.Lookup _ -> Ok None
            | _ -> Error D.Stale_context)
      }
    in
    let t, cold, _ = fixture env ~sw ~dispatch () in
    let running =
      get (X.start t cold (D.sync_policy service_config.policy ~initial_network:D.Closed))
    in
    let selected =
      match demand_change with
      | D.Demand d -> d.asset
      | _ -> assert false
    in
    let batch offset =
      for index = 1 to 1000 do
        let id = get (D.demand_id (string_of_int (offset + index))) in
        ignore
          (get
             (X.update_demand
                t
                (D.Demand { id; asset = selected; priority = D.Foreground })));
        let rec terminal () =
          let output = get (X.receive_demand t) in
          get (X.release_demand t output.delivery);
          match output.availability with
          | D.Demand_missing_local -> ()
          | _ -> terminal ()
        in
        terminal ();
        ignore (get (X.update_demand t (D.Withdraw id)));
        let output = get (X.receive_demand t) in
        check (output.availability = D.Demand_revoked) "withdrawal delivered";
        get (X.release_demand t output.delivery);
        for _ = 1 to 8 do
          Eio.Fiber.yield ()
        done
      done
    in
    Eio.Fiber.yield ();
    batch 0;
    Gc.full_major ();
    let before = (Gc.stat ()).live_words in
    batch 1000;
    Gc.full_major ();
    let growth = (Gc.stat ()).live_words - before in
    check
      (growth < 5000)
      (Printf.sprintf "actual runtime and policy retained growth: %d words" growth);
    get (X.request_stop t);
    match X.await running with
    | X.Completed _ -> ()
    | X.Failed (_, e) -> Alcotest.fail (D.error_message e))
;;

let policy_download_capacity env () =
  Eio.Switch.run (fun sw ->
    let selected =
      match demand_change with
      | D.Demand d -> d.asset
      | _ -> assert false
    in
    let version =
      Result.get_ok
        (Logseq_db_types.Asset_descriptor.version
           ~checksum:(String.make 64 'a')
           ~file_type:"png")
    in
    let selected =
      Result.get_ok
        (Logseq_db_types.Asset_descriptor.create
           ~uuid:selected.uuid
           ~source:(Logseq_db_types.Asset_descriptor.Managed (Some version))
           ~current_checksum:None
           ~size:None
           ~dimensions:None)
    in
    let file token =
      get (D.asset_file (get (D.resource ~owner:identity ~token)) selected)
    in
    let original = file "capacity-original" in
    let lease =
      get
        (D.asset_lease
           (get (D.resource ~owner:identity ~token:"capacity-lease"))
           original)
    in
    let lookups = ref 0
    and downloads = ref 0 in
    let dispatch : X.dispatch =
      { (capabilities ()).dispatch with
        assets =
          (fun (type a) ~scope ~identity:_ (op : a D.assets) : (a, D.error) result ->
            match op with
            | D.Lookup _ ->
              incr lookups;
              if !lookups = 1
              then
                Result.map
                  (fun () -> Some original)
                  (X.handoff scope (Rrbvec.of_list [ D.File_reference original ]))
              else Ok None
            | D.Retain _ ->
              Result.map
                (fun () -> lease)
                (X.handoff scope (Rrbvec.of_list [ D.Lease_reference lease ]))
            | D.Download _ ->
              incr downloads;
              Ok D.Waiting_remote
            | _ -> Error D.Stale_context)
      }
    in
    let restore ~scope _ =
      get
        (X.handoff
           scope
           (Rrbvec.of_list
              (List.init 5 (fun index ->
                 D.File_reference (file ("held-" ^ string_of_int index))))));
      Ok { D.keys = D.Unencrypted; checkpoint = None; recovery_pending = false }
    in
    let t, cold, _ = fixture env ~sw ~dispatch ~restore () in
    let running =
      get
        (X.start
           t
           cold
           (D.sync_policy
              service_config.policy
              ~initial_network:(D.Open { authorization_epoch = 7L })))
    in
    Eio.Fiber.yield ();
    ignore
      (get
         (X.update_demand
            t
            (D.Demand
               { id = get (D.demand_id "capacity-first")
               ; asset = selected
               ; priority = D.Foreground
               })));
    let rec available () =
      let output = get (X.receive_demand t) in
      match output.availability with
      | D.Demand_available _ -> output
      | _ ->
        get (X.release_demand t output.delivery);
        available ()
    in
    let held = available () in
    let id = get (D.demand_id "capacity-second") in
    ignore
      (get
         (X.update_demand t (D.Demand { id; asset = selected; priority = D.Foreground })));
    let queued = get (X.receive_demand t) in
    check (queued.availability = D.Demand_queued) "second demand accepted";
    get (X.release_demand t queued.delivery);
    for _ = 1 to 32 do
      Eio.Fiber.yield ()
    done;
    let waiting_lookups = !lookups in
    for _ = 1 to 32 do
      Eio.Fiber.yield ()
    done;
    let after_wait_lookups = !lookups in
    let before_release_downloads = !downloads in
    get (X.release_demand t held.delivery);
    Alcotest.(check int)
      "capacity wait does not spin through lookups"
      waiting_lookups
      after_wait_lookups;
    Alcotest.(check int) "no dispatch before capacity" 0 before_release_downloads;
    let resumed = get (X.receive_demand t) in
    get (X.release_demand t resumed.delivery);
    check
      (resumed.availability = D.Demand_waiting_remote)
      "accepted receipt resumes without fake failure";
    Alcotest.(check int) "one real attempt after release" 1 !downloads;
    get (X.request_stop t);
    match X.await running with
    | X.Completed _ -> ()
    | X.Failed (_, e) -> Alcotest.fail (D.error_message e))
;;

let resource_demotion env () =
  Eio.Switch.run (fun sw ->
    let selected =
      match demand_change with
      | D.Demand demand -> demand.asset
      | _ -> assert false
    in
    let files =
      List.init limits.maximum_resources (fun index ->
        get
          (D.asset_file
             (get (D.resource ~owner:identity ~token:("demotion-" ^ string_of_int index)))
             selected))
    in
    let restore ~scope _ =
      get
        (X.handoff
           scope
           (Rrbvec.of_list (List.map (fun file -> D.File_reference file) files)));
      Ok { D.keys = D.Unencrypted; checkpoint = None; recovery_pending = false }
    in
    let t, cold, _ = fixture env ~sw ~restore () in
    let body =
      D.with_scope (fun _ ->
        ignore (get (X.update_demand t demand_change));
        let background =
          match demand_change with
          | D.Demand demand -> D.Demand { demand with priority = D.Background }
          | D.Withdraw _ -> assert false
        in
        let rejected = X.update_demand t background in
        check
          (match rejected with
           | Error (D.Capacity_exceeded _) -> true
           | _ -> false)
          "demotion includes retained resources";
        let@ () = task (D.Task_assets (D.Release_file (List.hd files))) in
        ignore (get (X.update_demand t background));
        D.task_return ())
    in
    match run t (ready t cold) body with
    | X.Completed _ -> ()
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

let rejected_handoff_preserves_caller env () =
  Eio.Switch.run (fun sw ->
    let selected =
      match demand_change with
      | D.Demand demand -> demand.asset
      | _ -> assert false
    in
    let file token =
      get (D.asset_file (get (D.resource ~owner:identity ~token)) selected)
    in
    let held =
      List.init (limits.maximum_resources - 1) (fun index ->
        file ("held-" ^ string_of_int index))
    in
    let first = file "caller-first"
    and second = file "caller-second" in
    let calls = ref 0 in
    let dispatch : X.dispatch =
      { (capabilities ()).dispatch with
        assets =
          (fun (type a)
            ~scope
            ~identity:_
            (operation : a D.assets)
            : (a, D.error) result ->
            match operation with
            | D.Prune_cache ->
              incr calls;
              let* () =
                if !calls = 1
                then (
                  let rejected =
                    X.handoff
                      scope
                      (Rrbvec.of_list [ D.File_reference first; D.File_reference second ])
                  in
                  check
                    (match rejected with
                     | Error (D.Capacity_exceeded _) -> true
                     | _ -> false)
                    "oversized handoff is atomic";
                  X.handoff scope (Rrbvec.of_list [ D.File_reference first ]))
                else X.handoff scope (Rrbvec.of_list [ D.File_reference second ])
              in
              Ok
                { D.resident_bytes = 0L
                ; pending_bytes = 0L
                ; retained_bytes = 0L
                ; cleanup_pending = 0
                ; over_budget = false
                }
            | _ -> Error D.Stale_context)
      }
    in
    let restore ~scope _ =
      get
        (X.handoff
           scope
           (Rrbvec.of_list (List.map (fun file -> D.File_reference file) held)));
      Ok { D.keys = D.Unencrypted; checkpoint = None; recovery_pending = false }
    in
    let t, cold, _ = fixture env ~sw ~dispatch ~restore () in
    let body =
      D.with_scope (fun _ ->
        let@ _ = task (D.Task_assets D.Prune_cache) in
        let@ () = task (D.Task_assets (D.Release_file first)) in
        let@ _ = task (D.Task_assets D.Prune_cache) in
        task (D.Task_assets (D.Release_file second)))
    in
    match run t (ready t cold) body with
    | X.Completed _ ->
      check (!calls = 2) "rejected caller reference remains transferable and releasable"
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

let active_asset_pending_slots env () =
  Eio.Switch.run (fun sw ->
    let t, cold, _ = fixture env ~sw () in
    let rec next () =
      let@ input = task D.Next_input in
      match input with
      | D.Demand_changed (receipt, _) -> D.task_return receipt
      | _ -> next ()
    in
    let body =
      D.with_scope (fun scope ->
        ignore (get (X.update_demand t demand_change));
        let@ receipt = next () in
        let rec fill count children =
          if count = limits.maximum_pending - 3
          then D.task_return children
          else
            let@ child = D.spawn_asset scope receipt (D.task_return ()) in
            fill (count + 1) (get child :: children)
        in
        let@ children = fill 0 [] in
        let@ () = task D.Yield in
        let@ rejected = D.spawn_asset scope receipt (D.task_return ()) in
        let first = List.hd children in
        let@ _ = D.join first in
        let@ accepted = D.spawn_asset scope receipt (D.task_return ()) in
        D.task_return (rejected, Result.is_ok accepted))
    in
    match run t (ready t cold) body with
    | X.Completed (_, (rejected, accepted)) ->
      check
        (match rejected with
         | Error (D.Capacity_exceeded _) -> true
         | _ -> false)
        "asset tasks preserve three pending control slots even after completion";
      check accepted "physical join returns pending reservation"
    | X.Failed (_, error) -> Alcotest.fail (D.error_message error))
;;

let () =
  Eio_main.run (fun env ->
    Alcotest.run
      "Execute runtime"
      [ ( "public boundary"
        , List.map
            (fun (name, test) -> Alcotest.test_case name `Quick (test env))
            [ "notification aggregate count", notification_capacity
            ; "notification descriptor aggregate bytes", notification_descriptor_bytes
            ; "active asset capacity", active_asset_capacity
            ; "active asset cancel join", active_asset_cancel_join
            ; "active asset foreground", active_asset_foreground
            ; "active asset shared download", active_asset_shared_download
            ; "active asset available ownership", active_asset_available_owner
            ; "active asset demotion", active_asset_demotion
            ; "active asset mixed direction", active_asset_mixed_direction
            ; "active asset resource rejection", active_asset_resource_rejection
            ; "policy demand lifecycle metadata", policy_demand_lifecycle
            ; ( "policy download capacity resumes"
              , fun env () ->
                  Eio.Time.with_timeout_exn
                    (Eio.Stdenv.clock env)
                    5.
                    (policy_download_capacity env) )
            ; "resource demotion", resource_demotion
            ; "rejected handoff preserves caller", rejected_handoff_preserves_caller
            ; "active asset pending slots", active_asset_pending_slots
            ; "contexts and typed child", contexts
            ; "network join controls", network
            ; "stop and durable outbox", stop_and_outbox
            ; "cancellation", cancellation
            ; "observations", observation
            ; "real snapshot activation and read", real_activation
            ; "nested unlock consumer", nested_unlock
            ; "cancel joins grandchildren", cancelled_subtree
            ; "ready child fairness", ready_child_not_starved
            ; "held delivery retirement", held_delivery_retirement
            ; "failed callback join retains owner", callback_failed_join_retains_owner
            ; "released metadata remains bounded", released_metadata_bounded
            ; ( "actual service policy receipts and consumer close"
              , service_receipts_and_consumer ~withdraw:false )
            ; ( "actual service withdrawal and consumer close"
              , service_receipts_and_consumer ~withdraw:true )
            ; "actual service callback failure cleanup", service_callback_failure
            ; "callback capacity before start", callback_capacity
            ; "callback terminal capacity rejection", callback_terminal_capacity_rejection
            ; "terminal cancellation rejects", terminal_cancel_rejected
            ; "released delivery metadata remains bounded", delivery_metadata_bounded
            ] )
      ])
;;
