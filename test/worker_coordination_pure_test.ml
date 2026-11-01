module W = Journal_worker_coordination.Worker_api
module C = Journal_worker_coordination.Worker_pure_coordinator
module P = Logseq_db_worker.Protocol
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Id = Logseq_db_worker_lui.Journal_worker_ids
module Sync = Logseq_sync_pure_reducer.Core

let check condition message = if not condition then failwith message
let uuid s = W.Uuid.of_string s |> Result.get_ok
let graph = uuid "98000000-0000-4000-8000-000000000001"
let client = uuid "98000000-0000-4000-8000-000000000002"

let limits : P.v2_capability_limits =
  { response_budget_bytes = 65536
  ; outbox_max_records = 32
  ; outbox_max_bytes = 65536
  ; change_max_items = 32
  ; change_max_bytes = 65536
  ; dispatcher_capacity = 32
  ; wire_batch_max_bytes = 65536
  }
;;

let fixture epoch =
  let issuer =
    W.issuer
      ~managed_origin:"https://example.invalid"
      ~user_id:"synthetic"
      ~runtime_epoch:(Id.Runtime.Epoch.of_int64 epoch)
      ~worker_generation:Id.Worker.Generation.one
    |> Result.get_ok
  in
  let module I = (val issuer : W.ISSUER) in
  let registration =
    match I.bootstrap_request () with
    | Ok (S.Register_coordination id) -> id
    | _ -> assert false
  in
  let account : Sync.account_scope =
    { managed_sync_origin = Uri.of_string "https://example.invalid"
    ; user_id = "synthetic"
    ; account_generation = 1
    ; presentation_generation = 1
    ; lifecycle_generation = 1L
    }
  in
  let scope : Sync.graph_scope = { account; graph_id = graph; graph_generation = 7 } in
  let cfg =
    Sync.limits
      ~maximum_response_bytes:65536
      ~maximum_artifact_bytes:65536
      ~submission_batch_size:1
    |> Result.get_ok
    |> fun limits ->
    Sync.config ~managed_sync_origin:account.managed_sync_origin ~limits |> Result.get_ok
  in
  let state = Sync.initial cfg |> Result.get_ok |> Sync.state in
  let state =
    { state with
      snapshot =
        { state.snapshot with
          selected_graph = Some graph
        ; resident_graphs = [ graph ]
        ; startup =
            { state.snapshot.startup with
              account_generation = 1
            ; graph_generation = 7
            ; presentation_generation = 1
            }
        }
    }
  in
  let owner : S.timeline_scope =
    { startup = { account_generation = 1; presentation_generation = 1 }
    ; graph_id = graph
    ; graph_generation = 7
    }
  in
  let sync : Sync.coordination_state =
    { account = Some account
    ; desired_residents = [ graph ]
    ; residents = [ scope, state ]
    ; selected = Some owner
    ; deletion = None
    }
  in
  let physical : Logseq_db_worker.graph_state =
    { graph_id = Some graph; generation = 7; phase = Graph_open; error = None }
  in
  let raw : S.coordination_baseline =
    { registration
    ; authority_user = None
    ; limits
    ; baseline =
        { version = 1L
        ; presentation = 1L
        ; state = { sync; residents = [ scope, physical ] }
        }
    }
  in
  let projection =
    match I.bootstrap (S.Coordination_registered raw) with
    | Ok (W.Ready p) -> p
    | _ -> failwith "valid fixture baseline rejected"
  in
  let session = (List.hd (W.residents projection)).session in
  issuer, raw, projection, session
;;

let ready binding projection =
  let state = (C.step (C.initial ~client_id:client) (C.Worker_bound binding)).next in
  (C.step state (C.Bootstrap_received (binding, W.Ready projection))).next
;;

let test_bootstrap_validation () =
  let issuer, raw, projection, _ = fixture 101L in
  let module I = (val issuer : W.ISSUER) in
  let empty =
    { raw with
      baseline =
        { raw.baseline with
          version = 0L
        ; state =
            { sync =
                { raw.baseline.state.sync with
                  account = None
                ; desired_residents = []
                ; residents = []
                ; selected = None
                }
            ; residents = []
            }
        }
    }
  in
  (match I.bootstrap (S.Coordination_registered empty) with
   | Ok (W.Ready current) ->
     check (W.equal_projection current projection) "old baseline replaced Ready"
   | _ -> failwith "old not-ready/revocation beat newer Ready");
  let malformed =
    [ (fun (b : S.coordination_baseline) ->
        { b with limits = { b.limits with change_max_bytes = 0 } })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  residents = b.baseline.state.residents @ b.baseline.state.residents
                }
            }
        })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  sync = { b.baseline.state.sync with desired_residents = [] }
                }
            }
        })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  residents =
                    List.map
                      (fun (scope, g) ->
                         scope, { g with Logseq_db_worker.generation = 8 })
                      b.baseline.state.residents
                }
            }
        })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  sync =
                    { b.baseline.state.sync with
                      selected =
                        Option.map
                          (fun (owner : S.timeline_scope) ->
                             { owner with graph_generation = 8 })
                          b.baseline.state.sync.selected
                    }
                }
            }
        })
    ]
  in
  List.iteri
    (fun n corrupt ->
       let issuer, raw, _, _ = fixture (Int64.of_int (200 + n)) in
       let module I = (val issuer : W.ISSUER) in
       let bad = corrupt { raw with baseline = { raw.baseline with version = 2L } } in
       match I.bootstrap (S.Coordination_registered bad) with
       | Error (W.Protocol_mismatch _) -> ()
       | _ -> failwith "malformed baseline issued authority")
    malformed
;;

type action =
  | Plan
  | Admit of int
  | Answer of int
  | Cancel of int
  | Forget of int
  | Refuse of int
  | Retry
  | Old_baseline
  | Stop
  | Release_ack

let show = function
  | Plan -> "plan"
  | Admit n -> "admit" ^ string_of_int n
  | Answer n -> "answer" ^ string_of_int n
  | Cancel n -> "cancel" ^ string_of_int n
  | Forget n -> "forget" ^ string_of_int n
  | Refuse n -> "refuse" ^ string_of_int n
  | Retry -> "retry"
  | Old_baseline -> "old"
  | Stop -> "stop"
  | Release_ack -> "release-ack"
;;

let remove_chunk values start count =
  List.filteri (fun i _ -> i < start || i >= start + count) values
;;

let shrink fails trace =
  let rec go trace chunk =
    if chunk = 0
    then trace
    else (
      let rec find offset =
        if offset >= List.length trace
        then go trace (chunk / 2)
        else (
          let candidate = remove_chunk trace offset chunk in
          if fails candidate then go candidate chunk else find (offset + 1))
      in
      find 0)
  in
  go trace (max 1 (List.length trace / 2))
;;

let test_pure_properties () =
  let issuer, _, projection, session = fixture 400L in
  let module I = (val issuer : W.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:10 ~maximum_bytes:65536 |> Result.get_ok
  in
  let run trace =
    let state = ref (ready I.binding projection)
    and tickets = ref [] in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next))
        "same pure input produced different state";
      check (C.equal_view before (C.view !state)) "step mutated its input snapshot";
      check (List.length a.instructions < 1000) "unbounded instruction batch";
      state := a.next
    in
    let with_ticket n f =
      match List.nth_opt !tickets (n mod 8) with
      | None -> ()
      | Some ticket -> f ticket
    in
    List.iter
      (function
        | Plan ->
          (match C.request !state session (W.Query (budget, W.Graph_info)) with
           | Error _ -> ()
           | Ok (ticket, a) ->
             let _, b =
               C.request !state session (W.Query (budget, W.Graph_info)) |> Result.get_ok
             in
             check
               (C.equal_view (C.view a.next) (C.view b.next))
               "planning is nondeterministic";
             tickets := ticket :: List.filteri (fun i _ -> i < 7) !tickets;
             state := a.next)
        | Admit n ->
          with_ticket n (fun ticket ->
            step
              (C.Admitted (ticket, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 1)))))
        | Answer n ->
          with_ticket n (fun ticket ->
            step (C.Completed (ticket, W.Interrupted W.Cancelled));
            let once = C.view !state in
            step (C.Completed (ticket, W.Answered (Error (W.Service_failed "duplicate"))));
            check (C.equal_view once (C.view !state)) "terminal delivered more than once")
        | Cancel n -> with_ticket n (fun ticket -> step (C.Cancel ticket))
        | Forget n ->
          with_ticket n (fun ticket ->
            step (C.Forget ticket);
            check (C.reply (C.view !state) ticket = None) "forgotten result resurfaced")
        | Refuse n ->
          with_ticket n (fun ticket -> step (C.Admission_refused (ticket, W.Full)))
        | Retry ->
          step C.Retry_bootstrap;
          check
            (Result.is_error (C.request !state session (W.Query (budget, W.Graph_info))))
            "retry retained session admission"
        | Old_baseline ->
          step (C.Bootstrap_received (I.binding, W.Ready projection));
          if C.shutdown_state (C.view !state) <> C.Active
          then
            check
              (C.projection (C.view !state) = None)
              "old baseline revived draining session"
        | Stop ->
          step C.Shutdown_requested;
          check
            (Result.is_error (C.request !state session (W.Query (budget, W.Graph_info))))
            "shutdown retained admission"
        | Release_ack -> step (C.Binding_release_completed (I.binding, Ok ())))
      trace
  in
  let fails trace =
    try
      run trace;
      false
    with
    | _ -> true
  in
  (* Prefixes exercise valid admission, reversed delivery and cancellation races.
     The suffix generator also injects duplicate/foreign/obsolete orderings. *)
  let prefixes =
    [ [ Plan; Admit 0; Answer 0 ]
    ; [ Plan; Answer 0; Admit 0 ]
    ; [ Plan; Cancel 0; Admit 0; Answer 0 ]
    ; [ Plan; Forget 0; Admit 0; Answer 0; Stop; Release_ack ]
    ; [ Plan; Answer 0; Refuse 0; Stop; Release_ack ]
    ]
  in
  List.iter run prefixes;
  for seed = 0 to 499 do
    let random = Random.State.make [| 0x51ec; seed |] in
    let pick () =
      let n = Random.State.int random 8 in
      match Random.State.int random 11 with
      | 0 -> Plan
      | 1 -> Admit n
      | 2 -> Answer n
      | 3 -> Cancel n
      | 4 -> Forget n
      | 5 -> Refuse n
      | 6 -> Retry
      | 7 -> Old_baseline
      | 8 -> Stop
      | 9 -> Release_ack
      | _ -> Plan
    in
    let trace =
      List.nth prefixes (seed mod List.length prefixes) @ List.init 60 (fun _ -> pick ())
    in
    if fails trace
    then (
      let reduced = shrink fails trace in
      failwith
        (Printf.sprintf
           "property seed=%d minimal=[%s]"
           seed
           (String.concat ";" (List.map show reduced))))
  done
;;

let test_cleanup_admission_edges () =
  let issuer, _, projection, session = fixture 500L in
  let module I = (val issuer : W.ISSUER) in
  let bound = (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next in
  let admitted =
    (C.step bound (C.Bootstrap_admitted (I.binding, Id.Worker.Request_id.one))).next
  in
  let stopping = (C.step admitted C.Shutdown_requested).next in
  let acknowledged =
    (C.step stopping (C.Binding_release_completed (I.binding, Ok ()))).next
  in
  check
    (C.shutdown_state (C.view acknowledged) = C.Draining)
    "shutdown ignored an outstanding bootstrap reply";
  let done_state =
    (C.step acknowledged (C.Bootstrap_received (I.binding, W.Ready projection))).next
  in
  check
    (C.shutdown_state (C.view done_state) = C.Stopped)
    "bootstrap completion did not settle draining owner";
  let stopping = (C.step (ready I.binding projection) C.Shutdown_requested).next in
  let failed =
    (C.step stopping (C.Binding_release_not_admitted (I.binding, W.Stopping))).next
  in
  check
    (match C.shutdown_state (C.view failed) with
     | C.Shutdown_failed _ -> true
     | _ -> false)
    "stopping transport left cleanup silently Draining";
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let ticket, planned =
    C.request (ready I.binding projection) session (W.Query (budget, W.Graph_info))
    |> Result.get_ok
  in
  let early =
    (C.step planned.next (C.Completed (ticket, W.Interrupted W.Cancelled))).next
  in
  let refused = (C.step early (C.Admission_refused (ticket, W.Full))).next in
  let stopping = (C.step refused C.Shutdown_requested).next in
  let stopped = (C.step stopping (C.Binding_release_completed (I.binding, Ok ()))).next in
  check
    (C.shutdown_state (C.view stopped) = C.Stopped)
    "refused request retained an unowned early result"
;;

let test_compressed_response_ownership () =
  let module O = C.Response_ownership in
  let id n = Id.Worker.Request_id.of_int64 (Int64.of_int n) in
  let history = ref O.empty in
  for n = 1 to 16384 do
    history := O.add !history (id n)
  done;
  check (O.spans !history = 1) "completed sequential requests expanded ownership history";
  List.iter
    (fun n -> check (O.mem !history (id n)) "old owned response lost disposition")
    [ 1; 4096; 8192; 16384 ];
  for seed = 0 to 99 do
    let random = Random.State.make [| 0x0a11; seed |]
    and expected = Array.make 128 false in
    let history = ref O.empty in
    for _ = 0 to 255 do
      let n = Random.State.int random 128 in
      expected.(n) <- true;
      history := O.add !history (id (n + 1));
      Array.iteri
        (fun n owned ->
           check
             (O.mem !history (id (n + 1)) = owned)
             "interval ownership swallowed a legacy gap")
        expected
    done
  done
;;

let () =
  test_bootstrap_validation ();
  test_cleanup_admission_edges ();
  test_pure_properties ();
  test_compressed_response_ownership ();
  print_endline
    "Pure coordinator: invariants, 500 seeded traces, 100 ownership traces and shrinking \
     passed"
;;
