module D = Sync_dsl.Core
module Transport = Logseq_sync_transport.Core
module P = Logseq_sync_protocol.Sync_protocol
module O = Logseq_overlay_db.Types

let get = function
  | Ok value -> value
  | Error error -> Alcotest.fail (D.error_message error)
;;

let cursor n = Result.get_ok (O.Server_cursor.of_int64 n)

let identity =
  get
    (D.identity
       ~origin:"https://example.com"
       ~account:"a"
       ~graph:"g"
       ~account_generation:0L
       ~graph_generation:0L)
;;

let limits =
  get
    (D.limits
       ~maximum_items:8
       ~maximum_bytes:1024
       ~maximum_pending:8
       ~maximum_resources:8
       ~steps_per_turn:8
       ~maximum_tasks:8
       ~maximum_messages:4
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

let expect_error predicate = function
  | Error error when predicate error -> ()
  | Error error -> Alcotest.fail (D.error_message error)
  | Ok _ -> Alcotest.fail "Expected error"
;;

let protocol = function
  | D.Protocol_failure _ -> true
  | _ -> false
;;

type runner = { run : 'a. 'a D.transport -> ('a, D.error) result }

let with_owner
      ?(on_send = fun _ _ -> ())
      ?(connect = fun () -> Ok ())
      ?(token = fun ~epoch:_ ~refresh:_ -> Ok "synthetic")
      ?(fetch_snapshot =
        fun ~scope:_ _ -> Error (D.Storage_failure "synthetic snapshot unavailable"))
      callback
  =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let stopped = ref 0
      and joined = ref 0
      and sent = ref [] in
      let message = ref (fun (_ : string) -> ())
      and closed = ref (fun (_ : D.connection_end) -> ()) in
      let fail_handoff = ref false
      and ledger = ref [] in
      let backend : Transport.backend =
        { connect =
            (fun ~token:_ ~on_message ~on_close ->
              message := on_message;
              closed := on_close;
              Result.map
                (fun () ->
                   { Transport.activate = (fun () -> Ok ())
                   ; send =
                       (fun wire ->
                         sent := wire :: !sent;
                         on_send on_message wire;
                         Ok ())
                   ; stop = (fun () -> incr stopped)
                   ; await_stopped = (fun () -> incr joined)
                   })
                (connect ()))
        }
      in
      let owner =
        get
          (Transport.create
             ~sw
             ~clock:(Eio.Stdenv.mono_clock env)
             ~identity
             ~limits
             ~deadlines:
               { setup_seconds = 0.03
               ; tls_handshake_seconds = 0.03
               ; http_response_seconds = 0.03
               ; download_seconds = 0.1
               }
             ~cleanup_seconds:0.1
             ~backend
             ~token
             ~fetch_snapshot)
      in
      get (Transport.authorize owner ~identity ~epoch:1L);
      let scope : Transport.scope =
        { check_current = (fun () -> Ok ())
        ; admit_network = (fun () -> Ok ())
        ; handoff =
            (fun references ->
              if !fail_handoff
              then Error D.Stale_context
              else (
                ledger := Rrbvec.to_list references @ !ledger;
                Ok ()))
        }
      in
      let run =
        { run = (fun operation -> Transport.run owner ~scope ~identity operation) }
      in
      callback owner run message closed stopped joined sent ledger fail_handoff))
;;

let ownership () =
  with_owner (fun owner run _ _ stopped joined _ ledger _ ->
    let connection = get (run.run D.Connect) in
    Alcotest.(check int) "handoff" 1 (List.length !ledger);
    get (Transport.validate_resource owner (D.Connection_reference connection));
    let forged = get (D.connection ~owner:identity ~token:"forged" ~generation:1L) in
    expect_error
      (function
        | D.Stale_context -> true
        | _ -> false)
      (run.run (D.Receive forged));
    get (run.run (D.Retire_connection connection));
    get (run.run (D.Retire_connection connection));
    Alcotest.(check int) "one stop" 1 !stopped;
    Alcotest.(check int) "physical join" 1 !joined)
;;

let failed_handoff () =
  with_owner (fun _ run _ _ stopped joined _ _ fail ->
    fail := true;
    expect_error
      (function
        | D.Stale_context -> true
        | _ -> false)
      (run.run D.Connect);
    Alcotest.(check int) "untransferred socket stopped" 1 !stopped;
    Alcotest.(check int) "untransferred socket joined" 1 !joined)
;;

let notifications () =
  with_owner (fun _ run message _ _ _ _ _ _ ->
    let connection = get (run.run D.Connect) in
    let emit n =
      !message
        (Result.get_ok (P.encode_server_message (P.Server.Changed { t = cursor n })))
    in
    emit 2L;
    emit 1L;
    emit 3L;
    match (get (run.run (D.Receive connection))).message with
    | D.Remote_changed head ->
      Alcotest.(check int64)
        "greatest adjacent target"
        3L
        (O.Server_cursor.to_int64 head.through)
    | _ -> Alcotest.fail "Expected changed hint")
;;

let timeout () =
  with_owner (fun _ run _ _ stopped joined _ _ _ ->
    let connection = get (run.run D.Connect) in
    expect_error
      (function
        | D.Network_failure _ -> true
        | _ -> false)
      (run.run (D.On_connection (connection, D.Head)));
    Alcotest.(check int) "timeout stops" 1 !stopped;
    Alcotest.(check int) "timeout joins" 1 !joined)
;;

let scoped_matching () =
  with_owner (fun _ run message _ _ _ _ _ _ ->
    let connection = get (run.run D.Connect) in
    !message
      (Result.get_ok
         (P.encode_server_message
            (P.Server.Tx_batch_ok { t = cursor 1L; checksum = Some "0123456789abcdef" })));
    expect_error protocol (run.run (D.On_connection (connection, D.Head))))
;;

let auth_epoch () =
  with_owner (fun owner run _ _ stopped joined _ _ _ ->
    let connection = get (run.run D.Connect) in
    get (Transport.fence owner ~identity);
    expect_error
      (function
        | D.Network_closed -> true
        | _ -> false)
      (run.run (D.On_connection (connection, D.Head)));
    get (Transport.close_network owner ~identity);
    Alcotest.(check int) "epoch close" 1 !stopped;
    Alcotest.(check int) "epoch join" 1 !joined;
    expect_error
      (function
        | D.Stale_context -> true
        | _ -> false)
      (Transport.authorize owner ~identity ~epoch:1L);
    get (Transport.authorize owner ~identity ~epoch:2L))
;;

let invalid_nesting () =
  with_owner (fun _ run _ _ _ _ _ _ _ ->
    let connection = get (run.run D.Connect) in
    expect_error
      (function
        | D.Invalid_input _ -> true
        | _ -> false)
      (run.run (D.On_connection (connection, D.Receive connection)));
    expect_error
      (function
        | D.Invalid_input _ -> true
        | _ -> false)
      (run.run (D.On_connection (connection, D.On_connection (connection, D.Head)))))
;;

let emit callback message = callback (Result.get_ok (P.encode_server_message message))

let fresh_head () =
  let revision = ref 0L in
  with_owner
    ~on_send:(fun callback wire ->
      match Result.get_ok (P.decode_client_message wire) with
      | P.Client.Hello _ ->
        revision := Int64.succ !revision;
        emit callback (P.Server.Hello { t = cursor !revision; checksum = None })
      | _ -> ())
    (fun _ run _ _ _ _ _ _ _ ->
       let connection = get (run.run D.Connect) in
       let first = get (run.run (D.On_connection (connection, D.Head))) in
       let second = get (run.run D.Head) in
       Alcotest.(check int64) "first head" 1L (O.Server_cursor.to_int64 first.through);
       Alcotest.(check int64)
         "fresh second head"
         2L
         (O.Server_cursor.to_int64 second.through))
;;

let uuid index =
  Result.get_ok
    (O.Graph.Uuid.of_string (Printf.sprintf "00000000-0000-4000-8000-%012d" index))
;;

let batch =
  let wires =
    List.init 3 (fun index ->
      Result.get_ok
        (O.submission_wire
           ~maximum_bytes:1024
           ~mutation_id:(uuid (index + 1))
           ~operation:O.Save_block_operation
           ~protected_transaction:("frozen-wire-" ^ string_of_int index)))
  in
  Result.get_ok
    (O.submission_batch
       ~maximum_wires:8
       ~maximum_bytes:1024
       ~batch_id:
         (Result.get_ok (O.Submission_batch_id.of_string "submission-batch:v1:synthetic"))
       ~t_before:(cursor 1L)
       ~wires)
;;

let refresh_once () =
  let attempts = ref 0
  and credentials = ref [] in
  with_owner
    ~connect:(fun () ->
      incr attempts;
      if !attempts = 1 then Error Transport.Unauthorized else Ok ())
    ~token:(fun ~epoch ~refresh ->
      credentials := (epoch, refresh) :: !credentials;
      Ok "synthetic")
    (fun _ run _ _ _ _ _ _ _ ->
       ignore (get (run.run D.Connect));
       Alcotest.(check int) "one refresh" 2 !attempts;
       Alcotest.(check (list (pair int64 bool)))
         "same checked epoch"
         [ 1L, false; 1L, true ]
         (List.rev !credentials))
;;

let authentication_is_not_refreshable () =
  let attempts = ref 0 in
  with_owner
    ~connect:(fun () ->
      incr attempts;
      Error (Transport.Failed (D.Authentication_failure "synthetic certificate failure")))
    (fun _ run _ _ _ _ _ _ _ ->
       expect_error
         (function
           | D.Authentication_failure _ -> true
           | _ -> false)
         (run.run D.Connect);
       Alcotest.(check int) "certificate failure never refreshes" 1 !attempts)
;;

let refresh_bound () =
  let attempts = ref 0 in
  with_owner
    ~connect:(fun () ->
      incr attempts;
      Error Transport.Unauthorized)
    (fun _ run _ _ _ _ _ _ _ ->
       expect_error
         (function
           | D.Authentication_failure _ -> true
           | _ -> false)
         (run.run D.Connect);
       Alcotest.(check int) "second rejection is terminal" 2 !attempts)
;;

let pull_validation () =
  let response = ref (P.Server.Pull_ok { t = cursor 3L; checksum = None; txs = [] }) in
  with_owner
    ~on_send:(fun callback wire ->
      match Result.get_ok (P.decode_client_message wire) with
      | P.Client.Pull _ -> emit callback !response
      | _ -> ())
    (fun _ run _ _ _ _ _ _ _ ->
       let connection = get (run.run D.Connect) in
       (match get (run.run (D.On_connection (connection, D.Pull (cursor 1L)))) with
        | D.No_progress { since; through; expected_checksum } ->
          Alcotest.(check bool)
            "missing checksum remains optional"
            true
            (Option.is_none expected_checksum);
          Alcotest.(check int64)
            "no progress baseline"
            1L
            (O.Server_cursor.to_int64 since);
          Alcotest.(check int64)
            "no progress target"
            3L
            (O.Server_cursor.to_int64 through)
        | _ -> Alcotest.fail "Expected No_progress");
       response
       := P.Server.Pull_ok { t = cursor 3L; checksum = Some "0123456789abcdef"; txs = [] };
       (match get (run.run (D.Pull (cursor 1L))) with
        | D.No_progress { expected_checksum = Some expected; _ } ->
          Alcotest.(check string)
            "empty Pull retains checksum"
            "checksum:v1:0123456789abcdef"
            (O.Checksum.to_string expected)
        | _ -> Alcotest.fail "Expected No_progress checksum");
       response
       := P.Server.Pull_ok
            { t = cursor 3L
            ; checksum = None
            ; txs =
                [ { t = cursor 2L; tx = String.make (256 * 1024 + 1) 'x'; outliner_op = None }
                ; { t = cursor 3L; tx = "wire-3"; outliner_op = None }
                ]
            };
       (match get (run.run (D.Pull (cursor 1L))) with
        | D.Pulled batch ->
          Alcotest.(check int)
            "ordered transactions"
            2
            (List.length (O.authoritative_batch_transactions batch))
        | _ -> Alcotest.fail "Expected Pulled");
       response
       := P.Server.Pull_ok
            { t = cursor 3L
            ; checksum = None
            ; txs =
                [ { t = cursor 1L; tx = "replay"; outliner_op = None }
                ; { t = cursor 0L; tx = "invalid replay"; outliner_op = None }
                ]
            };
       expect_error protocol (run.run (D.Pull (cursor 2L))))
;;

let push_matching () =
  let observed = ref None in
  with_owner
    ~on_send:(fun callback wire ->
      match Result.get_ok (P.decode_client_message wire) with
      | P.Client.Tx_batch value ->
        observed
        := Some
             ( value.client_revision
             , value.t_before
             , List.map (fun (tx : P.Client.transaction) -> tx.tx) value.txs );
        emit
          callback
          (P.Server.Tx_batch_ok { t = cursor 4L; checksum = Some "0123456789abcdef" })
      | _ -> ())
    (fun _ run _ _ _ _ _ _ _ ->
       let connection = get (run.run D.Connect) in
       (match get (run.run (D.On_connection (connection, D.Push batch))) with
        | D.Accepted barrier ->
          Alcotest.(check int64)
            "advancing barrier"
            4L
            (O.Server_cursor.to_int64 barrier.through)
        | _ -> Alcotest.fail "Expected acceptance");
       match !observed with
       | Some (revision, before, wires) ->
         Alcotest.(check (option string))
           "durable batch ID"
           (Some (O.Submission_batch_id.to_string (O.submission_batch_id batch)))
           revision;
         Alcotest.(check int64) "frozen baseline" 1L (O.Server_cursor.to_int64 before);
         Alcotest.(check (list string))
           "exact durable wires"
           [ "frozen-wire-0"; "frozen-wire-1"; "frozen-wire-2" ]
           wires
       | None -> Alcotest.fail "Missing submission")
;;

let push_unknown () =
  with_owner (fun _ run _ _ stopped joined _ _ _ ->
    let connection = get (run.run D.Connect) in
    expect_error
      (function
        | D.Outcome_unknown _ -> true
        | _ -> false)
      (run.run (D.On_connection (connection, D.Push batch)));
    Alcotest.(check int) "unknown send stops" 1 !stopped;
    Alcotest.(check int) "unknown send joins" 1 !joined)
;;

let rejection_partition () =
  let rejection : P.rejection =
    { reason = P.Invalid_tx
    ; t = Some (cursor 2L)
    ; checksum = Some "0123456789abcdef"
    ; success_tx_ids = [ uuid 1 ]
    ; failed_tx_id = Some (uuid 2)
    ; missing_block_uuids = []
    ; error_detail = Some "secret rejected wire"
    ; data = None
    }
  in
  let response = ref rejection in
  with_owner
    ~on_send:(fun callback wire ->
      match Result.get_ok (P.decode_client_message wire) with
      | P.Client.Tx_batch _ -> emit callback (P.Server.Tx_reject !response)
      | _ -> ())
    (fun _ run _ _ _ _ _ _ _ ->
       ignore (get (run.run D.Connect));
       (match get (run.run (D.Push batch)) with
        | D.Rejected (O.Definitive { partition; _ }) ->
          Alcotest.(check int) "accepted prefix" 1 (List.length partition.accepted_prefix);
          Alcotest.(check bool)
            "failed member"
            true
            (partition.failed_member = Some (uuid 2));
          Alcotest.(check bool)
            "unexecuted suffix"
            true
            (partition.unexecuted_suffix = [ uuid 3 ]);
          Alcotest.(check (list string))
            "no raw server diagnostics"
            []
            partition.diagnostics
        | _ -> Alcotest.fail "Expected definitive rejection");
       response := { rejection with success_tx_ids = [ uuid 3 ] };
       expect_error protocol (run.run (D.Push batch)))
;;

let snapshot_handoff () =
  let fetch_snapshot ~scope () =
    let through = cursor 3L in
    let resource = get (D.resource ~owner:identity ~token:"synthetic-snapshot") in
    let snapshot =
      get
        (D.snapshot ~resource ~through ~checksum:"checksum:v1:synthetic" ~encrypted:false)
    in
    Result.map
      (fun () -> snapshot)
      (scope.Transport.handoff (Rrbvec.singleton (D.Snapshot_reference snapshot)))
  in
  with_owner ~fetch_snapshot (fun _ run _ _ _ _ _ ledger _ ->
    let snapshot = get (run.run D.Fetch_snapshot) in
    Alcotest.(check int64)
      "snapshot exact baseline"
      3L
      (O.Server_cursor.to_int64 snapshot.through);
    Alcotest.(check int) "original ledgers transferred" 1 (List.length !ledger))
;;

let retire_joins_waiters () =
  with_owner (fun _ run _ _ stopped joined _ _ _ ->
    let connection = get (run.run D.Connect) in
    let receiver_finished = ref false in
    Eio.Fiber.both
      (fun () ->
         let result = run.run (D.Receive connection) in
         receiver_finished := true;
         expect_error
           (function
             | D.Network_closed -> true
             | _ -> false)
           result)
      (fun () ->
         Eio.Fiber.yield ();
         get (run.run (D.Retire_connection connection)));
    Alcotest.(check bool) "receiver physically completed" true !receiver_finished;
    Alcotest.(check int) "shared stop" 1 !stopped;
    Alcotest.(check int) "shared join" 1 !joined)
;;

let one_response_family () =
  with_owner (fun _ run _ _ _ _ _ _ _ ->
    let connection = get (run.run D.Connect) in
    Eio.Fiber.both
      (fun () ->
         expect_error
           (function
             | D.Network_failure _ -> true
             | _ -> false)
           (run.run (D.On_connection (connection, D.Head))))
      (fun () ->
         Eio.Fiber.yield ();
         expect_error
           (function
             | D.Capacity_exceeded _ -> true
             | _ -> false)
           (run.run (D.On_connection (connection, D.Pull (cursor 1L))))))
;;

let () =
  Alcotest.run
    "production transport"
    [ ( "owner"
      , List.map
          (fun (name, test) -> Alcotest.test_case name `Quick test)
          [ "refresh once", refresh_once
          ; "authentication does not refresh", authentication_is_not_refreshable
          ; "second unauthorized is terminal", refresh_bound
          ; "pull validates before replay filtering", pull_validation
          ; "push retains exact durable wires", push_matching
          ; "unknown send joins", push_unknown
          ; "rejection ordered partition", rejection_partition
          ; "snapshot original handoff", snapshot_handoff
          ; "retirement joins waiters", retire_joins_waiters
          ; "one response family", one_response_family
          ; "Head performs a fresh request", fresh_head
          ; "original ownership and physical retirement", ownership
          ; "failed handoff joins", failed_handoff
          ; "bounded hint coalescing", notifications
          ; "response deadline joins", timeout
          ; "unsolicited response fails", scoped_matching
          ; "authorization epoch fence", auth_epoch
          ; "invalid nested constructors", invalid_nesting
          ] )
    ]
;;
