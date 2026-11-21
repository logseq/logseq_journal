module D = Sync_dsl.Core
module T = Logseq_overlay_db.Types
module I = Sync_dsl_interpreter

let ok = Result.get_ok

let identity =
  ok
    (D.identity
       ~origin:"https://example.com"
       ~account:"account"
       ~graph:"graph"
       ~account_generation:0L
       ~graph_generation:0L)
;;

let cursor value = ok (T.Server_cursor.of_int64 value)
let generation = ok (T.Generation.of_string "generation:v1:dsl")
let projection = ok (T.Projection_revision.of_string "projection:v1:dsl")
let batch_id = ok (T.Submission_batch_id.of_string "submission-batch:v1:original")

let mutation_id =
  ok (Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111")
;;

let fingerprint = ok (T.Mutation_fingerprint.of_string "mutation-fingerprint:v1:dsl")
let checksum = ok (T.Checksum.of_string "checksum:v1:dsl")

let retry =
  ok
    (D.retry_policy
       ~initial_seconds:0.25
       ~maximum_seconds:2.
       ~multiplier:2.
       ~maximum_attempts:2)
;;

let config =
  ok (D.policy_config ~sync_retry:retry ~asset_retry:retry ~no_progress_seconds:0.125)
;;

let open_gate epoch = D.Open { authorization_epoch = epoch }

let descriptor state : T.submission_descriptor =
  { mutation_id
  ; fingerprint
  ; state
  ; operation = T.Save_block_operation
  ; dependency_eligible = true
  ; attempt_count = 0
  ; plaintext_bytes = 8
  ; protected_bytes = Some 8
  }
;;

let wire =
  ok
    (T.submission_wire
       ~maximum_bytes:1024
       ~mutation_id
       ~operation:T.Save_block_operation
       ~protected_transaction:"original durable ciphertext")
;;

let batch =
  ok
    (T.submission_batch
       ~maximum_wires:1
       ~maximum_bytes:1024
       ~batch_id
       ~t_before:(cursor 0L)
       ~wires:[ wire ])
;;

type fixture =
  { mutable trace : string list
  ; mutable checkpoint : T.server_cursor option
  ; mutable remote : T.server_cursor
  ; mutable submissions : T.submission_descriptor list
  ; mutable revision : int64
  ; mutable network : D.network_gate
  ; mutable keys : D.key_status
  ; mutable status : D.service_status
  ; mutable statuses : D.service_status list
  ; mutable connect_failures : D.error list
  ; mutable head_failure : D.error option
  ; mutable pull_checksum : T.checksum option
  ; mutable expected_checksum : T.checksum option
  ; mutable snapshot_checksum : string
  ; mutable snapshot_through : T.server_cursor option
  ; mutable snapshot_failures : D.error list
  ; mutable unknown_pushes : int
  ; mutable defer : bool
  ; mutable pause_sleep : bool
  ; mutable outbox_dirty : bool
  ; mutable install_count : int
  ; mutable pulls_without_progress : int
  ; mutable snapshot_activation : D.activation option
  ; mutable activation_failure : D.error option
  ; mutable inspect_failure : D.error option
  ; mutable scope : D.scope option
  ; mutable owner : D.Producer.owner option
  ; mutable asset_reports : D.demand_transfer list
  ; mutable availability : D.demand_availability list
  ; mutable publication_failure : D.error option
  }

let fixture ?(submissions = []) () =
  { trace = []
  ; checkpoint = Some (cursor 0L)
  ; remote = cursor 0L
  ; submissions
  ; revision = 0L
  ; network = D.Closed
  ; keys = D.Unencrypted
  ; status = D.Service_idle
  ; statuses = []
  ; connect_failures = []
  ; head_failure = None
  ; pull_checksum = None
  ; expected_checksum = None
  ; snapshot_checksum = "checksum:v1:verified"
  ; snapshot_through = None
  ; snapshot_failures = []
  ; unknown_pushes = 0
  ; defer = false
  ; pause_sleep = false
  ; outbox_dirty = false
  ; install_count = 0
  ; pulls_without_progress = 0
  ; snapshot_activation = None
  ; activation_failure = None
  ; inspect_failure = None
  ; scope = None
  ; owner = None
  ; asset_reports = []
  ; availability = []
  ; publication_failure = None
  }
;;

let record fixture event = fixture.trace <- fixture.trace @ [ event ]
let count fixture event = List.length (List.filter (( = ) event) fixture.trace)

let token fixture =
  ok (T.sync_token_of_string ("sync-token:v1:" ^ Int64.to_string fixture.revision))
;;

let view fixture =
  T.sync_view
    ~token:(token fixture)
    ~checkpoint:(Option.value fixture.checkpoint ~default:(cursor 0L))
    ~submissions:fixture.submissions
;;

let observation fixture : D.observation =
  { identity
  ; keys = fixture.keys
  ; network = fixture.network
  ; checkpoint = fixture.checkpoint
  ; pending_submissions = List.length fixture.submissions
  ; pending_assets = 0
  ; cleanup_pending = 0
  ; last_failure = None
  }
;;

let commit fixture transition submission_batch : T.outbox_commit =
  { generation
  ; before_projection_revision = projection
  ; after_projection_revision = projection
  ; sync_token = token fixture
  ; transition
  ; activity = T.Logically_active
  ; logical_change_summary = T.No_logical_change
  ; submission_batch
  }
;;

let database : type value. fixture -> value D.database -> (value, D.error) result =
  fun fixture operation ->
  match operation with
  | D.Inspect ->
    record fixture "inspect";
    (match fixture.inspect_failure with
     | Some error when List.mem "outbox-check" fixture.trace -> Error error
     | _ -> Ok (view fixture))
  | D.Prepare_submission (expected, transition) ->
    if not (T.sync_token_equal expected (token fixture))
    then Error (D.Outbox_failure T.Outbox_sync_token_conflict)
    else (
      fixture.revision <- Int64.succ fixture.revision;
      let submission_batch =
        match transition with
        | T.Submit_group ids ->
          Alcotest.(check bool) "fresh exact IDs" true (ids = [ mutation_id ]);
          record fixture "persist-submit";
          fixture.submissions <- [ descriptor (T.Submitted batch_id) ];
          Some batch
        | T.Retry_group id ->
          Alcotest.(check bool)
            "retry original batch ID"
            true
            (T.Submission_batch_id.equal id batch_id);
          record fixture "persist-retry";
          Some batch
        | T.Accept_group _ ->
          record fixture "persist-accept";
          fixture.submissions
          <- [ descriptor (T.Accepted_pending_authoritative batch_id) ];
          None
        | T.Reject_group _ ->
          record fixture "persist-reject";
          None
      in
      Ok (commit fixture transition submission_batch))
  | D.Apply_authoritative (_, authoritative) ->
    let submitted =
      List.exists
        (fun (item : T.submission_descriptor) ->
           match item.state with
           | T.Submitted _ -> true
           | _ -> false)
        fixture.submissions
    in
    if fixture.defer && submitted
    then (
      record fixture "deferred";
      Ok (D.Deferred (T.Await_submission_outcome batch_id)))
    else (
      record fixture "apply";
      fixture.checkpoint <- Some (T.authoritative_batch_through authoritative);
      fixture.revision <- Int64.succ fixture.revision;
      fixture.submissions
      <- List.filter
           (fun (item : T.submission_descriptor) -> item.state = T.Queued)
           fixture.submissions;
      Ok
        (D.Applied
           { generation
           ; before_projection_revision = projection
           ; after_projection_revision = projection
           ; checkpoint = Option.get fixture.checkpoint
           ; sync_token = token fixture
           ; terminal_receipts = []
           ; replanned_queued_ids = []
           ; blocked_ids = []
           ; logical_change_summary = T.No_logical_change
           }))
  | D.Activate_snapshot staged ->
    record fixture "activate";
    Alcotest.(check string)
      "activation retains actual local digest"
      fixture.snapshot_checksum
      staged.checksum;
    (match fixture.activation_failure, fixture.snapshot_activation with
     | Some error, _ -> Error error
     | None, Some result -> Ok result
     | None, None ->
       fixture.checkpoint <- Some staged.through;
       Ok (D.Activated generation))
  | D.Verify_checksum _ ->
    record fixture "verify-checksum";
    Ok ()
  | D.Release_snapshot _ ->
    record fixture "release-snapshot";
    Ok ()
;;

let rec transport
  : type value. fixture -> value D.transport -> (value, D.error) result option
  =
  fun fixture operation ->
  match operation with
  | D.Connect ->
    record fixture "connect";
    (match fixture.connect_failures with
     | error :: rest ->
       fixture.connect_failures <- rest;
       Some (Error error)
     | [] ->
       Some
         (Ok
            (ok
               (D.connection
                  ~owner:identity
                  ~token:("connection-" ^ string_of_int (count fixture "connect"))
                  ~generation:fixture.revision))))
  | D.Head ->
    record fixture "head";
    Some
      (match fixture.head_failure with
       | Some error -> Error error
       | None ->
         Ok
           { D.through = fixture.remote
           ; snapshot_available = true
           ; expected_checksum = fixture.expected_checksum
           })
  | D.On_connection (_, operation) -> transport fixture operation
  | D.Receive _ -> None
  | D.Retire_connection _ ->
    record fixture "retire";
    Some (Ok ())
  | D.Fetch_snapshot ->
    record fixture "snapshot";
    (match fixture.snapshot_failures with
     | error :: rest ->
       fixture.snapshot_failures <- rest;
       Some (Error error)
     | [] ->
       let resource = ok (D.resource ~owner:identity ~token:"staging") in
       Some
         (Ok
            (ok
               (D.snapshot
                  ~resource
                  ~through:(Option.value fixture.snapshot_through ~default:fixture.remote)
                  ~checksum:fixture.snapshot_checksum
                  ~encrypted:(fixture.keys = D.Key_available)))))
  | D.Push actual ->
    Alcotest.(check bool)
      "push exposes actual submitting workflow"
      true
      (fixture.status = D.Service_submitting);
    record fixture "push";
    Alcotest.(check bool)
      "exact frozen ID"
      true
      (T.Submission_batch_id.equal (T.submission_batch_id actual) batch_id);
    Alcotest.(check string)
      "exact frozen bytes"
      "original durable ciphertext"
      (T.submission_wire_protected_transaction
         (List.hd (T.submission_batch_wires actual)));
    fixture.remote <- cursor 1L;
    if fixture.unknown_pushes > 0
    then (
      fixture.unknown_pushes <- fixture.unknown_pushes - 1;
      Some (Error (D.Outcome_unknown "lost response")))
    else Some (Ok (D.Accepted { through = fixture.remote; checksum }))
  | D.Pull since ->
    Alcotest.(check bool)
      "pull exposes actual pulling workflow"
      true
      (fixture.status = D.Service_pulling);
    record fixture "pull";
    if fixture.pulls_without_progress > 0 || T.Server_cursor.equal since fixture.remote
    then (
      fixture.pulls_without_progress <- max 0 (fixture.pulls_without_progress - 1);
      Some
        (Ok
           (D.No_progress
              { since
              ; through = fixture.remote
              ; expected_checksum = fixture.pull_checksum
              })))
    else (
      let transaction =
        T.authoritative_transaction
          ~cursor:fixture.remote
          ~transaction:(ok (T.encoded_transaction_of_string ~maximum_bytes:1024 "[[]]"))
      in
      let batch =
        ok
          (T.authoritative_batch
             ~maximum_count:1
             ~maximum_bytes:1024
             ~transactions:[ transaction ]
             ~through:fixture.remote
             ~checksum:fixture.pull_checksum)
      in
      Some (Ok (D.Pulled batch)))
;;

let responder fixture owner =
  fixture.owner <- Some owner;
  let respond
    : type value. D.scope -> value D.task_operation -> (value, D.error) result option
    =
    fun scope operation ->
    fixture.scope <- Some scope;
    match operation with
    | D.Task_observe -> Some (Ok (observation fixture))
    | D.Task_database operation -> Some (database fixture operation)
    | D.Task_transport operation -> transport fixture operation
    | D.Capacity_revision ->
      Some (D.Producer.capacity_revision owner scope ~sequence:fixture.revision)
    | D.Await_capacity_changed revision ->
      (match D.Producer.capacity_sequence owner scope revision with
       | Error error -> Some (Error error)
       | Ok sequence -> if sequence <> fixture.revision then Some (Ok ()) else None)
    | D.Publish_status status ->
      if status = D.Service_online
      then (
        Alcotest.(check bool)
          "online has reached authoritative remote checkpoint"
          true
          (fixture.checkpoint = Some fixture.remote);
        Alcotest.(check int)
          "online has no unsettled submissions"
          0
          (List.length fixture.submissions));
      fixture.status <- status;
      fixture.statuses <- status :: fixture.statuses;
      record fixture "status";
      Some (Ok ())
    | D.Resample_outbox ->
      fixture.outbox_dirty <- true;
      record fixture "resample";
      Some (Ok ())
    | D.Await_outbox_changed ->
      if fixture.outbox_dirty
      then (
        record fixture "outbox-check";
        Some (D.Producer.outbox_check owner scope))
      else None
    | D.Acknowledge_outbox_check _ ->
      fixture.outbox_dirty <- false;
      record fixture "ack-outbox";
      Some (Ok ())
    | D.Abandon_outbox_check _ ->
      record fixture "abandon-outbox";
      Some (Ok ())
    | D.Sleep seconds ->
      if fixture.pause_sleep
      then (
        if not (List.mem "sleep" fixture.trace) then record fixture "sleep";
        None)
      else (
        record fixture ("sleep:" ^ string_of_float seconds);
        Some (Ok ()))
    | D.Yield -> Some (Ok ())
    | D.Consume_unlock _ ->
      fixture.keys <- D.Key_available;
      record fixture "unlock";
      Some (Ok D.Key_available)
    | D.Download_demand _ ->
      record fixture "asset-lookup";
      let report =
        match fixture.asset_reports with
        | report :: rest ->
          fixture.asset_reports <- rest;
          report
        | [] -> { D.result = Ok D.Waiting_remote; attempts = 0 }
      in
      for _ = 1 to report.attempts do
        record fixture "asset-attempt"
      done;
      Some (Ok report)
    | D.Task_assets (D.Retain file) ->
      record fixture "retain";
      Some (D.asset_lease (ok (D.resource ~owner:identity ~token:"lease")) file)
    | D.Task_assets (D.Release_file _) ->
      record fixture "release-file";
      Some (Ok ())
    | D.Task_assets (D.Release_lease _) ->
      record fixture "release-lease";
      Some (Ok ())
    | D.Publish_demand (_, availability) ->
      (match availability, fixture.publication_failure with
       | D.Demand_available _, Some error ->
         record fixture "publish-rejected";
         Some (Error error)
       | _ ->
         fixture.availability <- fixture.availability @ [ availability ];
         record fixture "publish";
         Some (Ok ()))
    | D.Finish_demand _ ->
      record fixture "finish-demand";
      Some (Ok ())
    | _ -> Alcotest.fail "unexpected policy task effect"
  in
  { I.respond }
;;

let run ?(policy = config) ?(initial_network = open_gate 1L) ?input ?admit fixture =
  let input =
    match input with
    | Some input -> input
    | None ->
      fun () ->
        (match fixture.status with
         | D.Service_online | D.Service_blocked _ -> Some D.Stop_requested
         | _ -> None)
  in
  I.run_program
    ~restore:(fun () ->
      record fixture "restore";
      Ok
        { D.keys = fixture.keys
        ; checkpoint = fixture.checkpoint
        ; recovery_pending = fixture.submissions <> []
        })
    ~install:(fun gate ->
      fixture.install_count <- fixture.install_count + 1;
      fixture.network <- gate;
      record fixture "install";
      Ok ())
    ~runner:
      { I.run_task =
          (fun task ->
            I.run_task ?admit ~identity ~responder:(responder fixture) ~input task)
      }
    (D.sync_policy policy ~initial_network)
;;

let check_success = function
  | Ok () -> ()
  | Error error -> Alcotest.fail (D.error_message error)
;;

let check_count fixture event expected =
  Alcotest.(check int) event expected (count fixture event)
;;

let metadata_initialization () =
  List.iter
    (fun baseline ->
       let fixture = fixture () in
       fixture.checkpoint <- None;
       fixture.snapshot_through <- Some (cursor baseline);
       fixture.remote <- cursor 9L;
       fixture.connect_failures <- [ D.Authentication_failure "WS unavailable" ];
       check_success (run fixture);
       check_count fixture "activate" 1;
       check_count fixture "release-snapshot" 1;
       Alcotest.(check bool)
         "metadata baseline available without WS"
         true
         (fixture.checkpoint = Some (cursor baseline));
       let rec before = function
         | "activate" :: _ -> true
         | "connect" :: _ | [] -> false
         | _ :: rest -> before rest
       in
       Alcotest.(check bool) "activation precedes connection" true (before fixture.trace))
    [ 3L; 12L ];
  let fixture = fixture () in
  fixture.checkpoint <- None;
  fixture.snapshot_through <- Some (cursor 3L);
  fixture.remote <- cursor 9L;
  check_success (run fixture);
  check_count fixture "snapshot" 1;
  check_count fixture "pull" 1;
  Alcotest.(check bool)
    "WS catches up from metadata"
    true
    (fixture.checkpoint = Some (cursor 9L))
;;

let snapshot_network_retry () =
  let fixture = fixture () in
  fixture.checkpoint <- None;
  fixture.snapshot_failures <- List.init 3 (fun _ -> D.Network_failure "HTTP offline");
  check_success (run fixture);
  check_count fixture "snapshot" 3;
  check_count fixture "connect" 0;
  check_count fixture "abandon-outbox" 3;
  check_count fixture "activate" 0;
  Alcotest.(check bool)
    "failed downloads leave mirror absent"
    true
    (fixture.checkpoint = None)
;;

let normal () =
  let fixture = fixture ~submissions:[ descriptor T.Queued ] () in
  check_success (run fixture);
  check_count fixture "connect" 1;
  check_count fixture "persist-submit" 1;
  check_count fixture "persist-accept" 1;
  check_count fixture "apply" 1;
  check_count fixture "retire" 1;
  let index event =
    let rec find index = function
      | [] -> max_int
      | head :: rest -> if head = event then index else find (index + 1) rest
    in
    find 0 fixture.trace
  in
  Alcotest.(check bool) "durable before send" true (index "persist-submit" < index "push");
  Alcotest.(check bool)
    "remote acceptance is not apply"
    true
    (index "persist-accept" < index "apply");
  Alcotest.(check int) "one-shot initial gate" 1 fixture.install_count
;;

let recovery () =
  let fixture = fixture ~submissions:[ descriptor (T.Submitted batch_id) ] () in
  fixture.expected_checksum
  <- Some (ok (T.Checksum.of_string "checksum:v1:ffffffffffffffff"));
  fixture.pull_checksum <- Some (ok (T.Checksum.of_string "checksum:v1:0000000000000000"));
  check_success (run fixture);
  check_count fixture "persist-submit" 0;
  check_count fixture "persist-retry" 1;
  check_count fixture "push" 1;
  check_count fixture "apply" 1
;;

let unknown_recovery () =
  let fixture = fixture ~submissions:[ descriptor T.Queued ] () in
  fixture.unknown_pushes <- 1;
  fixture.defer <- true;
  check_success (run fixture);
  check_count fixture "persist-submit" 1;
  check_count fixture "persist-retry" 1;
  check_count fixture "deferred" 1;
  check_count fixture "push" 2;
  check_count fixture "pull" 1;
  check_count fixture "apply" 1
;;

let nonnetwork () =
  List.iter
    (fun error ->
       let fixture = fixture () in
       fixture.head_failure <- Some error;
       check_success (run fixture);
       check_count fixture "connect" 1;
       check_count fixture "head" 1;
       check_count fixture "retire" 1;
       Alcotest.(check bool)
         "no non-network retry timer"
         false
         (List.exists
            (fun entry -> String.starts_with ~prefix:"sleep" entry)
            fixture.trace))
    [ D.Protocol_failure "bad framing"
    ; D.Authentication_failure "revoked"
    ; D.Storage_failure "disk full"
    ]
;;

let network_retry () =
  let fixture = fixture () in
  fixture.connect_failures <- [ D.Network_failure "offline" ];
  check_success (run fixture);
  check_count fixture "connect" 2;
  check_count fixture "sleep:0.25" 1
;;

let stop_backoff () =
  let fixture = fixture () in
  fixture.connect_failures <- [ D.Network_failure "offline" ];
  fixture.pause_sleep <- true;
  let input () = if List.mem "sleep" fixture.trace then Some D.Stop_requested else None in
  check_success (run ~input fixture);
  check_count fixture "connect" 1;
  check_count fixture "sleep" 1
;;

let gates () =
  let fixture = fixture () in
  let stage = ref 0 in
  let input () =
    match !stage with
    | 0 ->
      check_count fixture "connect" 0;
      stage := 1;
      fixture.network <- open_gate 7L;
      Some (D.Network_changed fixture.network)
    | 1 when fixture.status = D.Service_online ->
      stage := 2;
      fixture.network <- D.Closed;
      Some (D.Network_changed D.Closed)
    | 2 when count fixture "retire" = 1 ->
      stage := 3;
      Some D.Stop_requested
    | _ -> None
  in
  check_success (run ~initial_network:D.Closed ~input fixture);
  check_count fixture "connect" 1;
  check_count fixture "retire" 1;
  Alcotest.(check int) "initial gate not replayed" 1 fixture.install_count
;;

let locked () =
  let fixture = fixture () in
  fixture.keys <- D.Key_locked;
  let sent = ref false in
  let input () =
    if (not !sent) && fixture.scope <> None
    then (
      check_count fixture "connect" 0;
      sent := true;
      let receipt =
        ok
          (D.Producer.unlock_receipt
             (Option.get fixture.owner)
             (Option.get fixture.scope))
      in
      Some (D.Unlock_requested receipt))
    else if fixture.status = D.Service_online
    then Some D.Stop_requested
    else None
  in
  check_success (run ~input fixture);
  check_count fixture "unlock" 1;
  check_count fixture "connect" 1
;;

let no_progress () =
  let fixture = fixture () in
  fixture.remote <- cursor 1L;
  fixture.pulls_without_progress <- 1;
  check_success (run fixture);
  check_count fixture "pull" 2;
  check_count fixture "sleep:0.125" 1
;;

let snapshot () =
  let fixture = fixture () in
  fixture.checkpoint <- None;
  check_success (run fixture);
  check_count fixture "snapshot" 1;
  check_count fixture "activate" 1;
  check_count fixture "release-snapshot" 1
;;

let stop_completed_connection () =
  let fixture = fixture () in
  let input () = if count fixture "connect" > 0 then Some D.Stop_requested else None in
  check_success (run ~input fixture);
  check_count fixture "connect" 1;
  check_count fixture "retire" 1
;;

let stop_completed_check () =
  let fixture = fixture () in
  let input () =
    if count fixture "outbox-check" > 0 then Some D.Stop_requested else None
  in
  check_success (run ~input fixture);
  check_count fixture "outbox-check" 1;
  check_count fixture "abandon-outbox" 1
;;

let unlock_capacity () =
  let fixture = fixture () in
  fixture.keys <- D.Key_locked;
  let admissions = ref 0 in
  let admit () =
    incr admissions;
    if !admissions = 2 then Error (D.Capacity_exceeded "temporary") else Ok ()
  in
  let stage = ref 0 in
  let input () =
    if !stage = 0 && fixture.scope <> None
    then (
      stage := 1;
      let receipt =
        ok
          (D.Producer.unlock_receipt
             (Option.get fixture.owner)
             (Option.get fixture.scope))
      in
      Some (D.Unlock_requested receipt))
    else if !stage = 1 && !admissions >= 2
    then (
      stage := 2;
      fixture.revision <- Int64.succ fixture.revision;
      Some (D.Network_changed fixture.network))
    else if fixture.status = D.Service_online
    then Some D.Stop_requested
    else None
  in
  check_success (run ~input ~admit fixture);
  check_count fixture "unlock" 1
;;

let retry_capacity () =
  let fixture = fixture () in
  fixture.connect_failures <- [ D.Network_failure "lost" ];
  let rejected = ref false in
  let admit () =
    match fixture.status with
    | D.Service_backoff _ when not !rejected ->
      rejected := true;
      Error (D.Capacity_exceeded "temporary")
    | _ -> Ok ()
  in
  let input () =
    if !rejected && fixture.revision = 0L
    then (
      fixture.revision <- 1L;
      Some (D.Network_changed fixture.network))
    else if fixture.status = D.Service_online
    then Some D.Stop_requested
    else None
  in
  check_success (run ~input ~admit fixture);
  check_count fixture "sleep:0.25" 1;
  check_count fixture "connect" 2
;;

let retry_exhaustion () =
  let fixture = fixture () in
  fixture.connect_failures <- List.init 4 (fun _ -> D.Network_failure "lost");
  check_success (run fixture);
  check_count fixture "connect" 3;
  check_count fixture "sleep:0.25" 1;
  check_count fixture "sleep:0.5" 1
;;

let asset =
  let module A = Logseq_db_types.Asset_descriptor in
  let version = ok (A.version ~checksum:(String.make 64 'a') ~file_type:"png") in
  ok
    (A.create
       ~uuid:mutation_id
       ~source:(A.Managed (Some version))
       ~current_checksum:None
       ~size:(Some 8L)
       ~dimensions:None)
;;

let asset_file = ok (D.asset_file (ok (D.resource ~owner:identity ~token:"file")) asset)

let demand_input fixture =
  let receipt =
    ok (D.Producer.demand_receipt (Option.get fixture.owner) (Option.get fixture.scope))
  in
  let id = ok (D.demand_id "image") in
  D.Demand_changed (receipt, D.Demand { id; asset; priority = D.Foreground })
;;

let asset_flow reports =
  let fixture = fixture () in
  fixture.asset_reports <- reports;
  let sent = ref false in
  let input () =
    if (not !sent) && fixture.scope <> None
    then (
      sent := true;
      Some (demand_input fixture))
    else if count fixture "finish-demand" > 0
    then Some D.Stop_requested
    else None
  in
  check_success (run ~input fixture);
  fixture
;;

let asset_available () =
  let fixture = asset_flow [ { D.result = Ok (D.Available asset_file); attempts = 1 } ] in
  check_count fixture "retain" 1;
  check_count fixture "asset-attempt" 1;
  check_count fixture "release-file" 0;
  check_count fixture "release-lease" 0;
  Alcotest.(check bool)
    "transferred availability"
    true
    (List.exists
       (function
         | D.Demand_available _ -> true
         | _ -> false)
       fixture.availability)
;;

let asset_retry () =
  let fixture =
    asset_flow
      [ { D.result = Error (D.Asset_network "offline"); attempts = 1 }
      ; { D.result = Ok (D.Available asset_file); attempts = 1 }
      ]
  in
  check_count fixture "asset-attempt" 2;
  check_count fixture "sleep:0.25" 1;
  Alcotest.(check bool)
    "retry is actually scheduled"
    true
    (List.exists
       (function
         | D.Demand_failed { attempts = 1; retry_scheduled = true; _ } -> true
         | _ -> false)
       fixture.availability)
;;

let asset_nonnetwork () =
  List.iter
    (fun reason ->
       let fixture = asset_flow [ { D.result = Error reason; attempts = 1 } ] in
       check_count fixture "asset-attempt" 1;
       Alcotest.(check bool)
         "asset permanent failure has no timer"
         false
         (List.exists
            (fun entry -> String.starts_with ~prefix:"sleep" entry)
            fixture.trace))
    [ D.Asset_storage_full; D.Asset_authentication "revoked"; D.Asset_checksum_mismatch ]
;;

let asset_publish_failure () =
  let fixture = fixture () in
  fixture.asset_reports <- [ { D.result = Ok (D.Available asset_file); attempts = 1 } ];
  fixture.publication_failure <- Some D.Stale_context;
  let sent = ref false in
  let input () =
    if (not !sent) && fixture.scope <> None
    then (
      sent := true;
      Some (demand_input fixture))
    else if count fixture "release-file" > 0
    then Some D.Stop_requested
    else None
  in
  check_success (run ~input fixture);
  check_count fixture "release-file" 1;
  check_count fixture "release-lease" 1
;;

let asset_gate_close () =
  let fixture = fixture () in
  fixture.asset_reports
  <- [ { D.result = Error (D.Asset_network "offline"); attempts = 1 }
     ; { D.result = Error D.Asset_network_closed; attempts = 0 }
     ];
  fixture.pause_sleep <- true;
  let stage = ref 0 in
  let input () =
    if !stage = 0 && fixture.scope <> None
    then (
      stage := 1;
      Some (demand_input fixture))
    else if !stage = 1 && List.mem "sleep" fixture.trace
    then (
      stage := 2;
      fixture.network <- D.Closed;
      Some (D.Network_changed D.Closed))
    else if
      List.exists
        (function
          | D.Demand_waiting_network -> true
          | _ -> false)
        fixture.availability
    then Some D.Stop_requested
    else None
  in
  check_success (run ~input fixture);
  check_count fixture "asset-attempt" 1;
  check_count fixture "sleep" 1
;;

let snapshot_failure () =
  let fixture = fixture () in
  fixture.checkpoint <- None;
  fixture.activation_failure <- Some (D.Storage_failure "activation failed");
  check_success (run fixture);
  check_count fixture "activate" 1;
  check_count fixture "release-snapshot" 1
;;

let snapshot_crypto_capacity_failure () =
  let fixture = fixture () in
  fixture.checkpoint <- None;
  let cause = D.Capacity_exceeded "Crypto items" in
  fixture.activation_failure <- Some cause;
  check_success (run fixture);
  check_count fixture "activate" 1;
  check_count fixture "release-snapshot" 1;
  Alcotest.(check bool)
    "owned crypto failure blocks with original cause"
    true
    (List.mem (D.Service_blocked cause) fixture.statuses)
;;

let snapshot_checksum_policy () =
  List.iter
    (fun (expected, older, blocked) ->
       let fixture = fixture () in
       fixture.checkpoint <- None;
       fixture.remote <- cursor 53740L;
       fixture.keys <- D.Key_available;
       fixture.snapshot_checksum <- "checksum:v1:4c07439063f40db4";
       fixture.expected_checksum
       <- Option.map (fun value -> ok (T.Checksum.of_string value)) expected;
       if older then fixture.snapshot_through <- Some (cursor 1L);
       let resampled = ref false in
       let input () =
         match fixture.status with
         | D.Service_online when (not older) && not !resampled ->
           resampled := true;
           fixture.outbox_dirty <- true;
           None
         | D.Service_online when (not older) && count fixture "ack-outbox" < 2 -> None
         | D.Service_online | D.Service_blocked _ -> Some D.Stop_requested
         | _ -> None
       in
       check_success (run ~input fixture);
       Alcotest.(check bool)
         "checksum policy blocks exactly when required"
         blocked
         (List.exists
            (function
              | D.Service_blocked (D.Protocol_failure _) -> true
              | _ -> false)
            fixture.statuses);
       check_count fixture "release-snapshot" 1;
       check_count fixture "activate" 1;
       if not older
       then (
         Alcotest.(check bool)
           "checkpoint verification remains observational"
           true
           (count fixture "verify-checksum" = if Option.is_some expected then 2 else 0);
         Alcotest.(check bool)
           "snapshot checkpoint locally available"
           true
           (fixture.checkpoint = Some fixture.remote)))
    [ Some "checksum:v1:wrong", false, false
    ; Some "checksum:v1:55d5780f6d2331dd", false, false
    ; Some "checksum:v1:55d5780f6d2331dd", true, false
    ; Some "checksum:v1:4c07439063f40db4", false, false
    ; Some "checksum:v1:4c07439063f40db4", true, false
    ; None, false, false
    ; Some "checksum:v1:wrong", true, false
    ]
;;

let existing_checkpoint_checksum_policy () =
  List.iter
    (fun (expected, blocked) ->
       let fixture = fixture () in
       fixture.expected_checksum <- Some (ok (T.Checksum.of_string expected));
       check_success (run fixture);
       Alcotest.(check bool)
         "same-cursor head checksum"
         blocked
         (List.exists
            (function
              | D.Service_blocked (D.Protocol_failure _) -> true
              | _ -> false)
            fixture.statuses))
    [ "checksum:v1:wrong", false; "checksum:v1:verified", false ]
;;

let pull_checksum_policy () =
  List.iter
    (fun (expected, blocked) ->
       let fixture = fixture () in
       fixture.remote <- cursor 1L;
       fixture.expected_checksum <- Some (ok (T.Checksum.of_string "checksum:v1:head"));
       fixture.pull_checksum
       <- Option.map (fun value -> ok (T.Checksum.of_string value)) expected;
       check_success (run fixture);
       check_count fixture "apply" 1;
       check_count fixture "verify-checksum" 1;
       let relevant =
         List.filter
           (fun event -> List.mem event [ "apply"; "verify-checksum" ])
           fixture.trace
       in
       Alcotest.(check (list string))
         "checksum validation belongs to atomic authoritative application"
         [ "apply"; "verify-checksum" ]
         relevant;
       Alcotest.(check bool)
         "authoritative Pull checksum"
         blocked
         (List.exists
            (function
              | D.Service_blocked (D.Protocol_failure _) -> true
              | _ -> false)
            fixture.statuses))
    [ Some "checksum:v1:verified", false; Some "checksum:v1:wrong", false; None, false ]
;;

let no_progress_checksum_policy () =
  List.iter
    (fun (expected, ahead, blocked) ->
       let fixture =
         fixture
           ~submissions:[ descriptor (T.Accepted_pending_authoritative batch_id) ]
           ()
       in
       fixture.pull_checksum
       <- Option.map (fun value -> ok (T.Checksum.of_string value)) expected;
       if ahead
       then (
         fixture.remote <- cursor 1L;
         fixture.pulls_without_progress <- 1);
       let input () =
         if
           (match fixture.status with
            | D.Service_blocked _ -> true
            | _ -> false)
           || count fixture "sleep:0.125" >= if ahead then 1 else 2
         then Some D.Stop_requested
         else None
       in
       check_success (run ~input fixture);
       check_count fixture "pull" (if ahead then 1 else 2);
       check_count
         fixture
         "verify-checksum"
         (if Option.is_some expected && not ahead then 2 else 0);
       Alcotest.(check bool)
         "empty Pull checksum applies only at its cursor"
         blocked
         (List.exists
            (function
              | D.Service_blocked (D.Protocol_failure _) -> true
              | _ -> false)
            fixture.statuses))
    [ Some "checksum:v1:wrong", false, false
    ; Some "checksum:v1:verified", false, false
    ; None, false, false
    ; Some "checksum:v1:wrong", true, false
    ]
;;

let snapshot_deferred () =
  let fixture = fixture () in
  fixture.checkpoint <- None;
  fixture.snapshot_activation <- Some (D.Activation_deferred "local intent");
  let waits = ref 0 in
  let input () =
    if count fixture "release-snapshot" > 0 && !waits < 10
    then (
      check_count fixture "snapshot" 1;
      incr waits;
      if !waits = 10
      then (
        fixture.snapshot_activation <- None;
        fixture.outbox_dirty <- true;
        fixture.revision <- Int64.succ fixture.revision);
      None)
    else if fixture.status = D.Service_online
    then Some D.Stop_requested
    else None
  in
  check_success (run ~input fixture);
  check_count fixture "snapshot" 2;
  check_count fixture "release-snapshot" 2
;;

let outbox_inspection_failure () =
  let fixture = fixture () in
  fixture.inspect_failure <- Some (D.Storage_failure "inspection failed");
  let input () =
    match fixture.status with
    | D.Service_blocked _ -> Some D.Stop_requested
    | _ -> None
  in
  check_success (run ~input fixture);
  check_count fixture "outbox-check" 1;
  check_count fixture "abandon-outbox" 1
;;

let inspect_bound_classification () =
  let make_fixture = fixture in
  let fixture = make_fixture () in
  let cause = D.Invalid_input "Sync view items" in
  fixture.inspect_failure <- Some cause;
  let input () =
    match fixture.status with
    | D.Service_blocked actual ->
      Alcotest.(check bool) "permanent cause preserved" true (actual = cause);
      Some D.Stop_requested
    | _ -> None
  in
  check_success (run ~input fixture);
  Alcotest.(check bool)
    "permanent mismatch terminates inspection"
    true
    (count fixture "inspect" <= 2);
  let fixture = make_fixture () in
  fixture.inspect_failure <- Some (D.Capacity_exceeded "transient ledger");
  let input () =
    if count fixture "inspect" > 0 && fixture.revision = 0L
    then (
      fixture.inspect_failure <- None;
      fixture.revision <- 1L;
      Some (D.Network_changed fixture.network))
    else if fixture.status = D.Service_online
    then Some D.Stop_requested
    else None
  in
  check_success (run ~input fixture);
  Alcotest.(check bool) "transient capacity resumes" true (count fixture "inspect" >= 2)
;;

let demand_lifecycle_metadata () =
  let fixture = fixture () in
  let completed = ref 0
  and phase = ref `Demand in
  let baseline = ref 0
  and growth = ref None in
  let input () =
    if fixture.scope = None
    then None
    else (
      let id = ok (D.demand_id (string_of_int !completed)) in
      let receipt () =
        ok
          (D.Producer.demand_receipt
             (Option.get fixture.owner)
             (Option.get fixture.scope))
      in
      let finished = count fixture "finish-demand" > 0 in
      match !phase with
      | `Demand ->
        fixture.trace <- [];
        fixture.availability <- [];
        phase := `Finish;
        Some
          (D.Demand_changed (receipt (), D.Demand { id; asset; priority = D.Foreground }))
      | `Finish when finished ->
        fixture.trace <- [];
        fixture.availability <- [];
        phase := `Withdraw;
        Some (D.Demand_changed (receipt (), D.Withdraw id))
      | `Withdraw when finished ->
        fixture.trace <- [];
        fixture.availability <- [];
        incr completed;
        if !completed = 1000
        then (
          Gc.full_major ();
          baseline := (Gc.stat ()).live_words);
        if !completed = 2000
        then (
          Gc.full_major ();
          growth := Some ((Gc.stat ()).live_words - !baseline);
          Some D.Stop_requested)
        else (
          phase := `Demand;
          None)
      | _ -> None)
  in
  check_success (run ~initial_network:D.Closed ~input fixture);
  let growth = Option.get !growth in
  Alcotest.(check bool)
    (Printf.sprintf "pure policy retained growth: %d words" growth)
    true
    (growth < 5000)
;;

let retry_disabled () =
  let fixture = fixture () in
  fixture.connect_failures <- [ D.Network_failure "offline" ];
  let retry =
    ok
      (D.retry_policy
         ~initial_seconds:1.
         ~maximum_seconds:1.
         ~multiplier:1.
         ~maximum_attempts:0)
  in
  let policy =
    ok (D.policy_config ~sync_retry:retry ~asset_retry:retry ~no_progress_seconds:1.)
  in
  check_success (run ~policy fixture);
  check_count fixture "connect" 1;
  Alcotest.(check bool)
    "zero retries disables timers"
    false
    (List.exists (fun entry -> String.starts_with ~prefix:"sleep" entry) fixture.trace)
;;

let tests =
  List.map
    (fun (name, test) -> Alcotest.test_case name `Quick test)
    [ "metadata initialization before WebSocket", metadata_initialization
    ; "snapshot network retry is bounded", snapshot_network_retry
    ; "normal durable flow", normal
    ; "Submitted exact recovery", recovery
    ; "unknown outcome and Deferred reapply", unknown_recovery
    ; "non-network failures never retry", nonnetwork
    ; "bounded network retry", network_retry
    ; "stop cancels retry sleep", stop_backoff
    ; "gate changes and stop", gates
    ; "locked waits for unlock", locked
    ; "no-progress monotonic delay", no_progress
    ; "snapshot release", snapshot
    ; "stop joins unconsumed connection", stop_completed_connection
    ; "stop abandons unconsumed outbox check", stop_completed_check
    ; "unlock retained through capacity", unlock_capacity
    ; "retry timer retained through capacity", retry_capacity
    ; "retry exhaustion", retry_exhaustion
    ; "asset ownership transfer", asset_available
    ; "asset network retry", asset_retry
    ; "asset non-network failures", asset_nonnetwork
    ; "asset publication cleanup", asset_publish_failure
    ; "gate close cancels asset backoff", asset_gate_close
    ; "authoritative Pull checksum policy", pull_checksum_policy
    ; "empty Pull checksum policy", no_progress_checksum_policy
    ; "snapshot checksum checkpoint policy", snapshot_checksum_policy
    ; "existing checkpoint integrity", existing_checkpoint_checksum_policy
    ; "snapshot crypto capacity fails with cause", snapshot_crypto_capacity_failure
    ; "snapshot failure releases staging", snapshot_failure
    ; "deferred activation waits for change", snapshot_deferred
    ; "outbox inspection failure abandons reservation", outbox_inspection_failure
    ; "inspection permanent versus transient bounds", inspect_bound_classification
    ; "demand lifecycle metadata bounded", demand_lifecycle_metadata
    ; "retry disabled", retry_disabled
    ]
;;
