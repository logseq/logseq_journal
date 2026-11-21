module D = Sync_dsl.Core

let get = function
  | Ok value -> value
  | Error error -> failwith (D.error_message error)
;;

let identity () =
  get
    (D.identity
       ~origin:"https://example.com"
       ~account:"a"
       ~graph:"g"
       ~account_generation:0L
       ~graph_generation:0L)
;;

let check condition message = Alcotest.(check bool) message true condition

let ownership () =
  let owner = D.Producer.create (identity ()) in
  let foreign = D.Producer.create (identity ()) in
  let scope = D.Producer.scope owner in
  check
    (Result.is_error (D.Producer.check_scope foreign scope))
    "equal identity is not ownership";
  let calls = ref 0 in
  let child =
    get
      (D.Producer.child owner scope (D.task_return 7) ~poll:(fun () ->
         incr calls;
         Some (Ok 7)))
  in
  check
    (Result.is_error (D.Producer.child_result foreign scope child))
    "foreign child rejected";
  check (!calls = 0) "foreign callback not called";
  check (D.Producer.child_result owner scope child = Ok (Some (Ok 7))) "typed result";
  ignore (get (D.Producer.forget_child owner scope child));
  ignore (get (D.Producer.forget_child owner scope child));
  check
    (Result.is_error (D.Producer.child_result owner scope child))
    "consumed child rejected";
  let changing = ref 0 in
  let cached =
    get
      (D.Producer.child owner scope (D.task_return 0) ~poll:(fun () ->
         incr changing;
         Some (Ok !changing)))
  in
  check (D.Producer.child_result owner scope cached = Ok (Some (Ok 1))) "first completion";
  check
    (D.Producer.child_result owner scope cached = Ok (Some (Ok 1)))
    "completion is repeatable";
  check (!changing = 1) "completed poll pruned";
  let receipt = get (D.Producer.demand_receipt owner scope) in
  let id = get (D.demand_id "asset") in
  let output = get (D.Producer.demand_output owner scope receipt ~id D.Demand_queued) in
  ignore (get (D.Producer.close_scope owner scope));
  check
    (Result.is_error (D.Producer.check_demand_receipt owner scope receipt))
    "closed receipt rejected";
  check
    (Result.is_ok (D.Producer.check_delivery owner output.delivery))
    "cleanup survives close"
;;

let stack_safe () =
  let program = ref (D.return 0) in
  for _ = 1 to 200000 do
    program := D.bind !program (fun value -> D.return (value + 1))
  done;
  match D.view !program with
  | D.Return value -> Alcotest.(check int) "deep binds" 200000 value
  | _ -> Alcotest.fail "unexpected effect"
;;

let validation () =
  check
    (Result.is_error
       (D.identity
          ~origin:"http://example.com"
          ~account:"a"
          ~graph:"g"
          ~account_generation:0L
          ~graph_generation:0L))
    "HTTPS required";
  check
    (Result.is_error
       (D.retry_policy
          ~initial_seconds:nan
          ~maximum_seconds:2.
          ~multiplier:2.
          ~maximum_attempts:2))
    "NaN rejected";
  check (Result.is_error (D.demand_id (String.make 257 'x'))) "bounded ID"
;;

let make_limits
      ?(maximum_items = 8)
      ?(maximum_tasks = 8)
      ?(maximum_pending = 8)
      ?(foreground_demand_reserve = 1)
      ?(maximum_messages = 8)
      ()
  =
  D.limits
    ~maximum_items
    ~maximum_bytes:1024
    ~maximum_pending
    ~maximum_resources:8
    ~steps_per_turn:32
    ~maximum_tasks
    ~maximum_messages
    ~maximum_message_bytes:1024
    ~maximum_demands:8
    ~maximum_active_assets:2
    ~foreground_reserve:1
    ~foreground_demand_reserve
    ~foreground_descriptor_reserve_bytes:128
    ~asset_cache_budget_bytes:0L
    ~asset_maximum_file_bytes:0
    ~asset_pending_budget_bytes:0L
    ~snapshot_maximum_artifact_bytes:1073741824L
    ~snapshot_staging_budget_bytes:1L
    ~snapshot_scratch_budget_bytes:1L
;;

let limits_validation () =
  check (Result.is_ok (make_limits ())) "independent snapshot budgets and disabled assets";
  List.iter
    (fun result -> check (Result.is_error result) "invalid bounds rejected")
    [ make_limits ~maximum_items:4097 ()
    ; make_limits ~maximum_tasks:5 ()
    ; make_limits ~maximum_pending:5 ()
    ; make_limits ~foreground_demand_reserve:9 ()
    ; make_limits ~maximum_messages:3 ()
    ]
;;

let identity_validation () =
  let create origin =
    D.identity ~origin ~account:"a" ~graph:"g" ~account_generation:0L ~graph_generation:0L
  in
  let normalized = get (create "HTTPS://EXAMPLE.COM:443/") in
  Alcotest.(check string) "canonical origin" "https://example.com" normalized.origin;
  List.iter
    (fun origin -> check (Result.is_error (create origin)) "not an origin")
    [ "https://example.com/path"
    ; "https://user@example.com"
    ; "https://example.com?query=1"
    ; "https://example.com#fragment"
    ; "https://exam ple.com"
    ]
;;

let scoped_handles () =
  let owner = D.Producer.create (identity ()) in
  let scope = D.Producer.scope owner in
  let other = D.Producer.scope owner in
  let unlock = get (D.Producer.unlock_receipt owner scope) in
  let outbox = get (D.Producer.outbox_check owner scope) in
  let channel = get (D.Producer.notifications owner scope) in
  let revision = get (D.Producer.capacity_revision owner scope ~sequence:12L) in
  check
    (D.Producer.capacity_sequence owner scope revision = Ok 12L)
    "old sequence remains valid";
  check
    (Result.is_error (D.Producer.capacity_sequence owner other revision))
    "foreign scope sequence";
  check
    (Result.is_error (D.Producer.check_unlock_receipt owner other unlock))
    "foreign unlock";
  check
    (Result.is_error (D.Producer.check_outbox_check owner other outbox))
    "foreign outbox";
  check
    (Result.is_error (D.Producer.check_notifications owner other channel))
    "foreign notifications";
  ignore (get (D.Producer.close_scope owner scope));
  ignore (get (D.Producer.close_scope owner scope));
  check
    (Result.is_error (D.Producer.check_unlock_receipt owner scope unlock))
    "closed unlock"
;;

let task_projection () =
  let calls = ref 0 in
  let task =
    D.with_scope (fun _ ->
      incr calls;
      D.task_return 1)
  in
  (match D.task_view task with
   | D.Task_scope _ -> ()
   | _ -> Alcotest.fail "scope projection");
  check (!calls = 0) "scope body not run by projection";
  let task =
    D.task_bind (D.task_return 1) (fun value ->
      incr calls;
      D.task_return (value + 1))
  in
  (match D.task_view task with
   | D.Task_bind _ -> ()
   | _ -> Alcotest.fail "bind projection");
  check (!calls = 0) "task continuation not run by projection"
;;

let authoritative_errors () =
  let module T = Logseq_overlay_db.Types in
  let module Diagnostic = Logseq_db_types.Authoritative_diagnostic in
  let render error = D.error_message (D.Authoritative_failure error) in
  Alcotest.(check string)
    "checksum classification"
    "Authoritative transition failed: checksum mismatch"
    (render T.Authoritative_checksum_mismatch);
  Alcotest.(check string)
    "origin classification"
    "Authoritative transition failed: origin unresolved"
    (render T.Authoritative_origin_unresolved);
  let diagnostic = Diagnostic.create ~stage:Decode ~reason:Reference_shape () in
  Alcotest.(check string)
    "typed decode context survives"
    (Diagnostic.message diagnostic)
    (render (T.Authoritative_decode_failed (Diagnostic.encode diagnostic)));
  let secret = String.make 4096 '\001' ^ " secret-payload-token" in
  List.iter
    (fun error ->
       let message = render error in
       check (String.length message < 512) "bounded message";
       check (not (String.contains message '\001')) "raw source excluded")
    [ T.Authoritative_decode_failed secret
    ; T.Authoritative_integrity_failure secret
    ; T.Authoritative_commit_persistence_failed secret
    ; T.Authoritative_commit_fatal_state secret
    ];
  Alcotest.(check string)
    "legacy decode source fails closed"
    "Authoritative transition failed: transaction decode rejected"
    (render (T.Authoritative_decode_failed secret))
;;

let () =
  Alcotest.run
    "sync DSL"
    [ "policy", Sync_dsl_policy_contract.tests
    ; ( "ownership"
      , [ Alcotest.test_case "original owners" `Quick ownership
        ; Alcotest.test_case "scoped handles" `Quick scoped_handles
        ] )
    ; ( "composition"
      , [ Alcotest.test_case "stack safe" `Quick stack_safe
        ; Alcotest.test_case "task projection" `Quick task_projection
        ] )
    ; ( "validation"
      , [ Alcotest.test_case "authoritative errors" `Quick authoritative_errors
        ; Alcotest.test_case "invalid input" `Quick validation
        ; Alcotest.test_case "limits" `Quick limits_validation
        ; Alcotest.test_case "identity" `Quick identity_validation
        ] )
    ]
;;
