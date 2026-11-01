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

let fixture = Coordination_test_fixture.fixture

let ready binding projection =
  let state = (C.step (C.initial ~client_id:client) (C.Worker_bound binding)).next in
  (C.step state (C.Bootstrap_received (binding, W.Ready projection))).next
;;

let test_query_origin_boundary () =
  let issuer, raw, projection, session = fixture 310L in
  let module I = (val issuer : W.ISSUER) in
  let state = (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next in
  let owner = Option.get raw.baseline.state.sync.selected in
  let ticket, waiting =
    C.plan_query state ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  check
    (C.query_origin (C.view waiting.next) ticket = None)
    "queued read fabricated execution origin";
  let sent = C.step waiting.next (C.Bootstrap_received (I.binding, W.Ready projection)) in
  (match C.query_origin (C.view sent.next) ticket with
   | Some (actual, budget) ->
     check (W.equal_session actual session) "queued read origin changed session";
     check
       (W.validate_request actual (W.Query (budget, W.Graph_info)) = Ok ())
       "origin budget differs from actual Send"
   | None -> failwith "actual Send lost execution origin");
  check
    (C.validate_session
       ~owner:{ owner with graph_id = uuid "98000000-0000-4000-8000-000000000099" }
       sent.next
       session
     = Error W.Revoked_session)
    "foreign business graph accepted cached execution origin";
  check
    (C.validate_session sent.next session = Ok ())
    "Open origin cannot resume cached data";
  let _, closing =
    C.prepare_host_change sent.next (W.Graph_will_close (W.graph_id session))
    |> Result.get_ok
  in
  check
    (C.validate_session closing.next session = Error W.Host_change_in_progress)
    "handoff fence allowed cached read";
  let forgotten = C.step sent.next (C.Forget ticket) in
  check
    (C.query_origin (C.view forgotten.next) ticket = None)
    "forgotten ticket retained public origin";
  check
    (C.query_origin (C.view sent.next) ticket <> None)
    "origin lookup mutated preceding state"
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

let test_reads_wait_for_verified_baseline () =
  let issuer, raw, projection, _ = fixture 301L in
  let module I = (val issuer : W.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let bound = (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next in
  let ticket, waiting =
    C.plan_query
      bound
      ~owner
      ~maximum_items:64
      ~maximum_bytes:P.maximum_response_bytes
      W.Graph_info
    |> Result.get_ok
  in
  let sends instructions =
    List.fold_left
      (fun n -> function
         | C.Send _ -> n + 1
         | _ -> n)
      0
      instructions
  in
  check (sends waiting.instructions = 0) "query sent before verified baseline";
  let opened =
    C.step waiting.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check (sends opened.instructions = 1) "verified Open did not dispatch queued query";
  let duplicate = C.step opened.next (C.Projection_received projection) in
  check (sends duplicate.instructions = 0) "duplicate baseline dispatched query twice";
  (* Host messages may run while a newer baseline is only queued. Absence
     from the old snapshot is not evidence that the new generation retired. *)
  let future_owner = { owner with graph_generation = owner.graph_generation + 1 } in
  let future, future_waiting =
    C.plan_query
      (ready I.binding projection)
      ~owner:future_owner
      ~maximum_items:1
      ~maximum_bytes:65536
      W.Graph_info
    |> Result.get_ok
  in
  check
    (C.reply (C.view future_waiting.next) future = None)
    "future owner was rejected by stale baseline";
  let drained = C.step future_waiting.next C.Drain in
  check
    (sends drained.instructions = 0 && C.reply (C.view drained.next) future = None)
    "a queued future owner either sent early or was falsely retired";
  let update_scope (scope : S.asset_scope) =
    { scope with graph_generation = future_owner.graph_generation }
  in
  let raw_future =
    { raw with
      baseline =
        { raw.baseline with
          version = 2L
        ; state =
            { sync =
                { raw.baseline.state.sync with
                  selected = Some future_owner
                ; residents =
                    List.map
                      (fun (scope, state) -> update_scope scope, state)
                      raw.baseline.state.sync.residents
                }
            ; residents =
                List.map
                  (fun (scope, state) ->
                     ( update_scope scope
                     , { state with
                         Logseq_db_worker.generation = future_owner.graph_generation
                       } ))
                  raw.baseline.state.residents
            }
        }
    }
  in
  let future_projection =
    match I.bootstrap (S.Coordination_registered raw_future) with
    | Ok (W.Ready projection) -> projection
    | _ -> failwith "future fixture baseline rejected"
  in
  let arrived = C.step drained.next (C.Projection_received future_projection) in
  check
    (sends arrived.instructions = 1)
    "future owner did not send after matching baseline";
  let cancelled = C.step waiting.next (C.Cancel ticket) in
  check
    (C.reply (C.view cancelled.next) ticket = Some (W.Interrupted W.Cancelled))
    "unsent cancellation did not settle locally";
  let late =
    C.step cancelled.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check (sends late.instructions = 0) "cancelled waiting query was resurrected";
  let wrong = { owner with graph_generation = owner.graph_generation - 1 } in
  let stale, waiting =
    C.plan_query bound ~owner:wrong ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  let opened =
    C.step waiting.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check (sends opened.instructions = 0) "stale host identity minted a session";
  check
    (C.reply (C.view opened.next) stale = Some (W.Answered (Error W.Revoked_session)))
    "replaced scope left queued read waiting forever";
  let waiting =
    snd
      (C.plan_query bound ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
       |> Result.get_ok)
  in
  let shutdown = C.step waiting.next C.Shutdown_requested in
  let stopped = C.step shutdown.next (C.Binding_release_completed (I.binding, Ok ())) in
  let stopped =
    C.step stopped.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check
    (C.shutdown_state (C.view stopped.next) = C.Stopped)
    "unsent query prevented registration cleanup";
  check (sends stopped.instructions = 0) "shutdown sent a queued query"
;;

let test_opening_query_retires_on_removal () =
  let issuer, raw, _, _ = fixture 303L in
  let module I = (val issuer : W.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let opening =
    { raw with
      baseline =
        { raw.baseline with
          version = 2L
        ; state =
            { raw.baseline.state with
              residents =
                List.map
                  (fun (scope, state) ->
                     scope, { state with Logseq_db_worker.phase = Graph_opening })
                  raw.baseline.state.residents
            }
        }
    }
  in
  let project value =
    match I.bootstrap (S.Coordination_registered value) with
    | Ok (W.Ready projection) -> projection
    | _ -> failwith "opening/removal baseline fixture failed"
  in
  let opening = project opening in
  let ticket, waiting =
    C.plan_query
      (ready I.binding opening)
      ~owner
      ~maximum_items:1
      ~maximum_bytes:65536
      W.Graph_info
    |> Result.get_ok
  in
  check (C.reply (C.view waiting.next) ticket = None) "Opening query did not wait";
  let empty =
    project
      { raw with
        baseline =
          { raw.baseline with
            version = 3L
          ; state =
              { sync =
                  { raw.baseline.state.sync with
                    desired_residents = []
                  ; residents = []
                  ; selected = None
                  }
              ; residents = []
              }
          }
      }
  in
  let removed = C.step waiting.next (C.Projection_received empty) in
  check
    (C.reply (C.view removed.next) ticket = Some (W.Answered (Error W.Revoked_session)))
    "removed Opening owner retained its waiting query";
  let late, planned =
    C.plan_query removed.next ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  check
    (C.reply (C.view planned.next) late = Some (W.Answered (Error W.Revoked_session)))
    "late request for a known removed owner waited forever"
;;

let test_queued_query_properties () =
  let issuer, raw, first, _ = fixture 302L in
  let module I = (val issuer : W.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let later_owner = { owner with graph_generation = owner.graph_generation + 1 } in
  let later_scope (scope : S.asset_scope) =
    { scope with graph_generation = later_owner.graph_generation }
  in
  let later_raw =
    { raw with
      baseline =
        { raw.baseline with
          version = 2L
        ; state =
            { sync =
                { raw.baseline.state.sync with
                  selected = Some later_owner
                ; residents =
                    List.map
                      (fun (scope, state) -> later_scope scope, state)
                      raw.baseline.state.sync.residents
                }
            ; residents =
                List.map
                  (fun (scope, state) ->
                     ( later_scope scope
                     , { state with
                         Logseq_db_worker.generation = later_owner.graph_generation
                       } ))
                  raw.baseline.state.residents
            }
        }
    }
  in
  let later =
    match I.bootstrap (S.Coordination_registered later_raw) with
    | Ok (W.Ready value) -> value
    | _ -> failwith "later queued-query fixture rejected"
  in
  let run trace =
    let state =
      ref (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next
    in
    let tickets = ref []
    and expected = Hashtbl.create 128
    and sends = Hashtbl.create 128
    and forbidden = Hashtbl.create 128 in
    let apply (transition : C.transition) =
      List.iter
        (function
          | C.Send (ticket, session, operation) ->
            (match operation with
             | W.Query (budget,_) ->
               (match C.query_origin (C.view transition.next) ticket with
                | Some (actual,actual_budget) -> check (W.equal_session actual session && actual_budget=budget)
                    "queued property: origin differs from actual Send"
                | None->failwith "queued property: dispatched read lacks origin")
             | _ -> ());
            check (C.validate_session transition.next session=Ok ()) "dispatched query session is fenced";
            let id = C.ticket_id ticket in
            check (not (Hashtbl.mem forbidden id)) "cancelled unsent read was dispatched";
            check (not (Hashtbl.mem sends id)) "queued read sent more than once";
            check
              (W.matches_scope session (Hashtbl.find expected id))
              "queued read used foreign scope";
            check
              (Option.fold
                 ~none:false
                 ~some:(fun projection ->
                   List.exists
                     (fun resident ->
                        resident.W.phase = W.Open
                        && W.equal_session session resident.session)
                     (W.residents projection))
                 (C.projection (C.view transition.next)))
              "queued read bypassed verified Open session";
            Hashtbl.replace sends id ()
          | _ -> ())
        transition.C.instructions;
      check
        (List.length transition.instructions < 1000)
        "queued read emitted unbounded batch";
      state := transition.next
    in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next))
        "queued steps were nondeterministic";
      check (C.equal_view before (C.view !state)) "queued step mutated prior state";
      apply a
    in
    let ticket n f =
      match List.nth_opt !tickets (n mod 8) with
      | None -> ()
      | Some value -> f value
    in
    List.iter
      (fun (op, n) ->
         match op with
         | 0 ->
           let target =
             match n mod 3 with
             | 0 -> owner
             | 1 -> later_owner
             | _ -> { owner with graph_generation = owner.graph_generation - 1 }
           in
           (match
              C.plan_query
                !state
                ~owner:target
                ~maximum_items:1
                ~maximum_bytes:65536
                W.Graph_info
            with
            | Error _ -> ()
            | Ok (ticket, transition) ->
              Hashtbl.replace expected (C.ticket_id ticket) target;
              tickets := ticket :: List.filteri (fun i _ -> i < 7) !tickets;
              apply transition)
         | 1 -> step (C.Projection_received (if n mod 2 = 0 then first else later))
         | 2 ->
           ticket n (fun value ->
             step
               (C.Admitted (value, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 1)))))
         | 3 ->
           ticket n (fun value ->
             step (C.Completed (value, W.Interrupted W.Cancelled));
             let once = C.view !state in
             step (C.Completed (value, W.Answered (Error (W.Service_failed "duplicate"))));
             check (C.equal_view once (C.view !state)) "queued terminal consumed twice")
         | 4 | 5 ->
           ticket n (fun value ->
             if not (Hashtbl.mem sends (C.ticket_id value))
             then Hashtbl.replace forbidden (C.ticket_id value) ();
             step (if op = 4 then C.Cancel value else C.Forget value))
         | 6 -> step C.Drain
         | 7 -> step C.Shutdown_requested
         | 8 -> step C.Retry_bootstrap
         | 9 -> step (C.Binding_release_completed (I.binding, Ok ()))
         | 10 -> ticket n (fun value -> step (C.Admission_refused (value, W.Full)))
         | _ ->
           step
             (C.Bootstrap_received
                (I.binding, W.Ready (if n mod 2 = 0 then first else later))))
      trace
  in
  let prefixes =
    [ [ 0, 1; 1, 0; 6, 0; 2, 0; 3, 0; 1, 1; 2, 0; 3, 0 ]
    ; [ 0, 0; 4, 0; 1, 0 ]
    ; [ 0, 1; 5, 0; 1, 1 ]
    ; [ 0, 1; 7, 0; 9, 0; 11, 1 ]
    ]
  in
  List.iter run prefixes;
  for seed = 0 to 249 do
    let random = Random.State.make [| 0x0c001; seed |] in
    let prefix = List.nth prefixes (seed mod List.length prefixes) in
    let trace =
      prefix
      @ List.init 96 (fun _ -> Random.State.int random 16, Random.State.int random 8)
    in
    let fails trace =
      try
        run trace;
        false
      with
      | _ -> true
    in
    if fails trace
    then (
      let minimal = shrink fails trace in
      failwith
        (Printf.sprintf
           "queued-query seed=%d shrunk=%s"
           seed
           (String.concat
              ","
              (List.map (fun (op, n) -> Printf.sprintf "%d:%d" op n) minimal))))
  done
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

let test_durable_mutation_properties () =
  let issuer, _, projection, session = fixture 1901L in
  let module I = (val issuer : W.ISSUER) in
  let intent =
    W.mutation_intent
      session
      ~mutation_id:(uuid "98000000-0000-4000-8000-000000000091")
      (W.Save_block
         { block = graph
         ; title = "stable durable choice"
         ; preconditions =
             { blocks = [ graph, "block-state:v1:synthetic" ]; pages = []; scopes = [] }
         })
    |> Result.get_ok
  in
  let wire = W.encode_mutation_intent intent in
  let run trace =
    let state = ref (ready I.binding projection)
    and tickets = ref []
    and committed = ref false
    and original_point = ref None in
    let apply event =
      let before = C.view !state in
      let first = C.step !state event
      and second = C.step !state event in
      check
        (C.equal_view (C.view first.next) (C.view second.next))
        "durable step is nondeterministic";
      check (C.equal_view before (C.view !state)) "durable step modified shared input";
      state := first.next;
      check
        (W.encode_mutation_intent intent = wire)
        "unknown write changed durable payload";
      (match C.intent_progress (C.view !state) intent with
       | Some (W.Committed_pending_presentation receipt) ->
         check
           (W.encode_mutation_intent (W.receipt_intent receipt) = wire)
           "foreign receipt poisoned durable identity";
         let point = W.receipt_revisions receipt in
         (match !original_point with
          | None -> original_point := Some point
          | Some original ->
            check (point = original) "later completion replaced original commit point")
       | _ -> ());
      if !committed
      then (
        match C.intent_progress (C.view !state) intent with
        | Some (W.Committed_pending_presentation _ | W.Confirmed _) -> ()
        | _ -> failwith "committed evidence regressed or vanished")
    in
    let with_ticket n f = Option.iter f (List.nth_opt !tickets (n mod 8)) in
    List.iter
      (fun (action, n) ->
         match action with
         | 0 ->
           (match C.request !state session (W.Mutate intent) with
            | Ok (ticket, transition) ->
              state := transition.next;
              tickets := ticket :: List.take 7 !tickets
            | Error _ -> ())
         | 1 ->
           with_ticket n (fun ticket ->
             apply
               (C.Admitted (ticket, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 100)))))
         | 2 ->
           with_ticket n (fun ticket ->
             apply (C.Completed (ticket, W.Interrupted W.Cancelled)))
         | 3 -> with_ticket n (fun ticket -> apply (C.Cancel ticket))
         | 4 -> with_ticket n (fun ticket -> apply (C.Forget ticket))
         | 5 -> with_ticket n (fun ticket -> apply (C.Admission_refused (ticket, W.Full)))
         | 6 ->
           with_ticket n (fun ticket ->
             apply (C.Completed (ticket, W.Answered (Ok W.Outcome_unknown))))
         | 7 | 9 | 10 ->
           with_ticket n (fun ticket ->
             let receipt_intent =
               if action <> 9
               then intent
               else
                 W.mutation_intent
                   session
                   ~mutation_id:(uuid "98000000-0000-4000-8000-000000000092")
                   (W.Save_block
                      { block = graph
                      ; title = "unrelated durable choice"
                      ; preconditions =
                          { blocks = [ graph, "block-state:v1:synthetic" ]
                          ; pages = []
                          ; scopes = []
                          }
                      })
                 |> Result.get_ok
             in
             let request_id =
               match
                 I.request session ~request_id:(C.ticket_id ticket) (W.Mutate intent)
               with
               | Ok (S.Coordination_mutation { request_id; _ }) -> request_id
               | _ -> assert false
             in
             let response =
               P.V2_response
                 { api_version = P.api_version
                 ; request_id
                 ; outcome =
                     P.V2_mutation_committed
                       { mutation_id = W.mutation_intent_id receipt_intent
                       ; status = P.V2_applied
                       ; generation = "generation:v1:1:1"
                       ; before_projection_revision = "projection:v1:0"
                       ; after_projection_revision =
                           (if action = 10 then "projection:v1:2" else "projection:v1:1")
                       }
                 }
             in
             let receipt =
               I.mutation_receipt
                 session
                 ~request_id:(C.ticket_id ticket)
                 ~intent:receipt_intent
                 response
               |> Result.get_ok
             in
             apply
               (C.Completed
                  (ticket, W.Answered (Ok (W.Committed_pending_presentation receipt))));
             match C.intent_progress (C.view !state) intent with
             | Some (W.Committed_pending_presentation _ | W.Confirmed _) ->
               committed := true
             | _ -> ())
         | _ ->
           with_ticket n (fun ticket ->
             apply
               (C.Completed
                  ( ticket
                  , W.Answered (Ok (W.Rejected (W.Invalid_input "known rejection"))) ))))
      trace
  in
  let prefixes =
    [ [ 0, 0; 1, 0; 9, 0 ]
    ; [ 0, 0; 1, 0; 7, 0; 0, 0; 1, 0; 10, 0 ]
    ; [ 0, 0; 1, 0; 3, 0; 7, 0; 4, 0 ]
    ; [ 0, 0; 7, 0; 1, 0; 6, 0 ]
    ; [ 0, 0; 1, 0; 7, 0; 0, 0; 1, 0; 8, 0; 7, 1 ]
    ; [ 0, 0; 4, 0; 1, 0; 7, 0 ]
    ]
  in
  let fails trace =
    try
      run trace;
      false
    with
    | _ -> true
  in
  List.iter run prefixes;
  for seed = 0 to 249 do
    let random = Random.State.make [| 0xd0a; seed |] in
    let trace =
      List.nth prefixes (seed mod List.length prefixes)
      @ List.init 80 (fun _ -> Random.State.int random 11, Random.State.int random 8)
    in
    if fails trace
    then (
      let reduced = shrink fails trace in
      failwith
        (Printf.sprintf
           "durable seed=%d shrunk=%s"
           seed
           (String.concat
              ";"
              (List.map (fun (a, n) -> Printf.sprintf "%d/%d" a n) reduced))))
  done
;;

let test_durable_readback_reservation () =
  let issuer, _, projection, session = fixture 1902L in
  let module I = (val issuer : W.ISSUER) in
  let state = ref (ready I.binding projection)
  and admitted = ref 0 in
  for n = 1 to 128 do
    let intent =
      W.mutation_intent
        session
        ~mutation_id:(uuid (Printf.sprintf "98000000-0000-4000-8000-%012d" (1000 + n)))
        (W.Save_block
           { block = graph
           ; title = "bounded readback reservation"
           ; preconditions =
               { blocks = [ graph, "block-state:v1:synthetic" ]; pages = []; scopes = [] }
           })
      |> Result.get_ok
    in
    match C.request !state session (W.Mutate intent) with
    | Error _ -> ()
    | Ok (_, transition) ->
      incr admitted;
      state := transition.next
  done;
  check (!admitted > 0) "durable capacity admitted no legitimate operation";
  check
    (!admitted * P.maximum_response_bytes <= 16777216)
    "bounded intent keys admitted unreserved confirmation snapshots"
;;

let () =
  test_query_origin_boundary ();
  test_durable_readback_reservation ();
  test_durable_mutation_properties ();
  test_bootstrap_validation ();
  test_cleanup_admission_edges ();
  test_pure_properties ();
  test_compressed_response_ownership ();
  test_reads_wait_for_verified_baseline ();
  test_queued_query_properties ();
  test_opening_query_retires_on_removal ();
  print_endline
    "Pure coordinator: invariants, 500 lifecycle + 250 queued-read + 250 durable traces, \
     100 ownership traces and shrinking passed"
;;
